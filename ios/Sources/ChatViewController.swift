import SwiftUI
import TermioShared
import UIKit

/// The chat lens: a read-only native rendering of one agent session's
/// structured plane (ACP `SessionUpdate` events derived from the agent's own
/// transcript on the Mac). It never parses PTY bytes and it owns no socket —
/// `TerminalViewController` hosts it as a sibling of the terminal surface,
/// feeds it events from the shared companion transport, and keeps the
/// composer as the single input for both lenses. Because the events come
/// from the transcript on disk, a dormant session's full history renders
/// here even when its terminal would be blank.
final class ChatViewController: UIViewController {

    // MARK: - Model

    private enum Role {
        case user, assistant
    }

    fileprivate struct ToolCallState {
        let id: String
        var title: String
        var kind: ToolKind
        var status: ToolCallStatus
        var diffs: [DiffChange]
        var output: String?
        /// Expanded detail (diff + output) for this one call.
        var detailShown = false
    }

    struct DiffChange {
        let path: String
        let oldText: String?
        let newText: String
    }

    /// One rendered row. Consecutive tool calls collapse into a single
    /// `.tools` group; text chunks sharing a `messageId` merge in place.
    private enum ChatItem {
        case text(role: Role, text: String, messageId: String?)
        case thought(text: String, messageId: String?, expanded: Bool)
        case tools(calls: [ToolCallState], expanded: Bool)
    }

    private var items: [ChatItem] = []
    /// toolCallId → its position, for `tool_call_update` resolution.
    private var toolPositions: [String: (item: Int, call: Int)] = [:]

    // MARK: - Views

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let jumpButton = UIButton(type: .system)
    /// The chat follows the newest message until the user scrolls away by
    /// hand; the jump button re-attaches. Gesture-driven on purpose — a
    /// distance heuristic would detach on the table's own growth.
    private var pinnedToBottom = true
    private var reloadScheduled = false
    private let typingIndicator = TypingIndicatorView()
    private var working = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "item")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        emptyLabel.text = "No conversation yet.\nSend a prompt below."
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        var jumpConfig: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        jumpConfig.image = UIImage(
            systemName: "arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        jumpConfig.cornerStyle = .capsule
        jumpButton.configuration = jumpConfig
        jumpButton.accessibilityLabel = "Scroll to bottom"
        jumpButton.isHidden = true
        jumpButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pinnedToBottom = true
            jumpButton.isHidden = true
            scrollToBottom(animated: true)
        }, for: .touchUpInside)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            jumpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            jumpButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            jumpButton.widthAnchor.constraint(equalToConstant: 38),
            jumpButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    /// Shows or hides the typing indicator under the last message — the
    /// "the agent is doing something" cue between transcript flushes, since
    /// the structured plane only speaks when a whole block lands. Driven by
    /// the owner from the roster's working status (plus its optimistic
    /// just-sent window); the chat itself stays a pure event renderer.
    func setWorking(_ working: Bool) {
        guard self.working != working else { return }
        self.working = working
        if working {
            typingIndicator.frame = CGRect(
                x: 0, y: 0, width: tableView.bounds.width, height: 40
            )
            tableView.tableFooterView = typingIndicator
            typingIndicator.startAnimating()
            emptyLabel.isHidden = true
            if pinnedToBottom { scrollToBottom(animated: true) }
        } else {
            typingIndicator.stopAnimating()
            tableView.tableFooterView = nil
            emptyLabel.isHidden = !items.isEmpty
        }
    }

    // MARK: - Event intake

    /// The owner (re)subscribed with a full replay: the incoming stream
    /// starts over from the top of the transcript, so the model must too —
    /// replay-then-reset is what keeps a reconnect gap-free without
    /// event ids or dedup bookkeeping.
    func resetForReplay() {
        items = []
        toolPositions = [:]
        pinnedToBottom = true
        jumpButton.isHidden = true
        scheduleReload()
    }

    func apply(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let chunk):
            appendText(role: .user, chunk: chunk)
        case .agentMessageChunk(let chunk):
            appendText(role: .assistant, chunk: chunk)
        case .agentThoughtChunk(let chunk):
            appendThought(chunk)
        case .toolCall(let event):
            appendToolCall(event)
        case .toolCallUpdate(let event):
            applyToolCallUpdate(event)
        case .usageUpdate, .unknown:
            return
        }
        scheduleReload()
    }

    private func appendText(role: Role, chunk: ContentChunk) {
        guard let text = chunk.content.text, !text.isEmpty else { return }
        // Same message, same role → one bubble: chunks are paragraphs of the
        // same reply, not separate turns.
        if case .text(let lastRole, let lastText, let lastId) = items.last,
           lastRole == role, let lastId, lastId == chunk.messageId {
            items[items.count - 1] = .text(
                role: role, text: lastText + "\n\n" + text, messageId: lastId
            )
        } else {
            items.append(.text(role: role, text: text, messageId: chunk.messageId))
        }
    }

    private func appendThought(_ chunk: ContentChunk) {
        guard let text = chunk.content.text, !text.isEmpty else { return }
        if case .thought(let lastText, let lastId, let expanded) = items.last,
           let lastId, lastId == chunk.messageId {
            items[items.count - 1] = .thought(
                text: lastText + "\n\n" + text, messageId: lastId, expanded: expanded
            )
        } else {
            items.append(.thought(text: text, messageId: chunk.messageId, expanded: false))
        }
    }

    private func appendToolCall(_ event: ToolCallEvent) {
        let state = ToolCallState(
            id: event.toolCallId,
            title: event.title,
            kind: event.kind ?? .other,
            status: event.status ?? .pending,
            diffs: Self.diffChanges(in: event.content),
            output: nil
        )
        if case .tools(var calls, let expanded) = items.last {
            calls.append(state)
            items[items.count - 1] = .tools(calls: calls, expanded: expanded)
            toolPositions[state.id] = (items.count - 1, calls.count - 1)
        } else {
            items.append(.tools(calls: [state], expanded: false))
            toolPositions[state.id] = (items.count - 1, 0)
        }
    }

    private func applyToolCallUpdate(_ event: ToolCallUpdateEvent) {
        guard let position = toolPositions[event.toolCallId],
              case .tools(var calls, let expanded) = items[position.item],
              calls.indices.contains(position.call) else { return }
        var call = calls[position.call]
        if let status = event.status { call.status = status }
        if let title = event.title { call.title = title }
        if let kind = event.kind { call.kind = kind }
        for content in event.content ?? [] {
            switch content.type {
            case "diff":
                if let path = content.path, let newText = content.newText {
                    call.diffs.append(DiffChange(path: path, oldText: content.oldText, newText: newText))
                }
            case "content":
                if let text = content.content?.text, !text.isEmpty {
                    call.output = text
                }
            default:
                break
            }
        }
        calls[position.call] = call
        items[position.item] = .tools(calls: calls, expanded: expanded)
    }

    private static func diffChanges(in content: [ToolCallContent]?) -> [DiffChange] {
        (content ?? []).compactMap { item in
            guard item.type == "diff", let path = item.path, let newText = item.newText
            else { return nil }
            return DiffChange(path: path, oldText: item.oldText, newText: newText)
        }
    }

    // MARK: - Reload & scroll

    /// Coalesces the per-event reloads of a replay burst into one pass per
    /// main-queue drain — hundreds of history events arrive back-to-back on
    /// attach, and a reload per event would be quadratic jank.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            emptyLabel.isHidden = !items.isEmpty
            tableView.reloadData()
            if pinnedToBottom { scrollToBottom(animated: false) }
        }
    }

    /// Offset math instead of scroll-to-row so the typing indicator (a table
    /// footer, not a row) is revealed too.
    private func scrollToBottom(animated: Bool) {
        guard !items.isEmpty || working else { return }
        tableView.layoutIfNeeded()
        let bottom = max(
            -tableView.adjustedContentInset.top,
            tableView.contentSize.height - tableView.bounds.height
                + tableView.adjustedContentInset.bottom
        )
        tableView.setContentOffset(CGPoint(x: 0, y: bottom), animated: animated)
    }

    private func toggleThought(at index: Int) {
        guard case .thought(let text, let messageId, let expanded) = items[safe: index] else { return }
        items[index] = .thought(text: text, messageId: messageId, expanded: !expanded)
        reloadRowPreservingPosition(index)
    }

    private func toggleToolGroup(at index: Int) {
        guard case .tools(let calls, let expanded) = items[safe: index] else { return }
        items[index] = .tools(calls: calls, expanded: !expanded)
        reloadRowPreservingPosition(index)
    }

    private func toggleToolDetail(at index: Int, call callIndex: Int) {
        guard case .tools(var calls, let expanded) = items[safe: index],
              calls.indices.contains(callIndex) else { return }
        calls[callIndex].detailShown.toggle()
        items[index] = .tools(calls: calls, expanded: expanded)
        reloadRowPreservingPosition(index)
    }

    /// Expanding a card mid-history must not yank the list to the bottom —
    /// a user tapping a disclosure is reading, not following.
    private func reloadRowPreservingPosition(_ index: Int) {
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
    }
}

// MARK: - Table

extension ChatViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let index = indexPath.row
        switch items[index] {
        case .text(let role, let text, _):
            cell.contentConfiguration = UIHostingConfiguration {
                switch role {
                case .user: UserBubbleRow(text: text)
                case .assistant: AssistantRow(text: text)
                }
            }
            .margins(.horizontal, 14)
            .margins(.vertical, 5)
        case .thought(let text, _, let expanded):
            cell.contentConfiguration = UIHostingConfiguration {
                ThoughtRow(text: text, expanded: expanded) { [weak self] in
                    self?.toggleThought(at: index)
                }
            }
            .margins(.horizontal, 14)
            .margins(.vertical, 5)
        case .tools(let calls, let expanded):
            cell.contentConfiguration = UIHostingConfiguration {
                ToolGroupRow(
                    calls: calls,
                    expanded: expanded,
                    onToggleGroup: { [weak self] in self?.toggleToolGroup(at: index) },
                    onToggleDetail: { [weak self] callIndex in
                        self?.toggleToolDetail(at: index, call: callIndex)
                    }
                )
            }
            .margins(.horizontal, 14)
            .margins(.vertical, 4)
        }
        return cell
    }

    // The pin releases on the *gesture*, never on content movement: only a
    // human drag detaches the chat from the newest message.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pinnedToBottom = false
        jumpButton.isHidden = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reattachIfAtBottom(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reattachIfAtBottom(scrollView)
    }

    /// A drag that lands back on the last row's tail is "return to now".
    private func reattachIfAtBottom(_ scrollView: UIScrollView) {
        let bottomEdge = scrollView.contentOffset.y + scrollView.bounds.height
            - scrollView.adjustedContentInset.bottom
        guard bottomEdge >= scrollView.contentSize.height - 1 else { return }
        pinnedToBottom = true
        jumpButton.isHidden = true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The iMessage-style "agent is working" cue: three dots in a small gray
/// bubble, pulsing in a staggered wave. Pure UIKit so it can live as the
/// table's footer view.
private final class TypingIndicatorView: UIView {
    private let bubble = UIView()
    private let dots: [UIView] = (0 ..< 3).map { _ in UIView() }
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "chat.typing"
        accessibilityLabel = "Agent is working"
        bubble.backgroundColor = .secondarySystemFill
        bubble.layer.cornerRadius = 16
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        var constraints = [
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bubble.centerYAnchor.constraint(equalTo: centerYAnchor),
            bubble.widthAnchor.constraint(equalToConstant: 58),
            bubble.heightAnchor.constraint(equalToConstant: 32),
        ]
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(dot)
            constraints += [
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
                dot.leadingAnchor.constraint(
                    equalTo: bubble.leadingAnchor, constant: 12 + CGFloat(index) * 12
                ),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        animating = true
        installAnimations()
    }

    func stopAnimating() {
        animating = false
        dots.forEach { $0.layer.removeAllAnimations() }
    }

    /// CoreAnimation drops animations when the view leaves the window (the
    /// lens toggle hides the chat); re-arm them on the way back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, animating { installAnimations() }
    }

    private func installAnimations() {
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAllAnimations()
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.25, 1.0, 0.25]
            pulse.keyTimes = [0, 0.4, 1]
            pulse.duration = 1.2
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.repeatCount = .infinity
            dot.layer.add(pulse, forKey: "pulse")
            dot.layer.opacity = 0.25
        }
    }
}

// MARK: - Rows

/// The user's prompt: right-aligned gray pill, the iMessage/ChatGPT shape.
private struct UserBubbleRow: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Color(uiColor: .secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}

/// The agent's reply: plain left-aligned rich markdown, no bubble chrome —
/// block-level structure (headings, fenced code, lists, quotes) rendered as
/// stacked views, since SwiftUI's `Text` only understands inline markdown.
private struct AssistantRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let content, let level):
            Text(content)
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let content):
            Text(content)
                .font(.subheadline)
                .textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.subheadline).foregroundStyle(.secondary)
                        Text(item).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
        case .code(let raw):
            Text(raw)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color(uiColor: .separator)).frame(width: 2)
                Text(content).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// A deliberately small block-level markdown split: fenced code first, then
/// paragraph-by-paragraph classification. Inline styling (bold, code spans,
/// links) comes from Foundation's markdown parser per block; tables and
/// anything exotic fall back to a mono code box rather than mangled prose.
private enum MarkdownBlock {
    case heading(AttributedString, level: Int)
    case paragraph(AttributedString)
    case bullets([AttributedString])
    case code(String)
    case quote(AttributedString)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Alternate text / fenced-code segments.
        let segments = text.components(separatedBy: "```")
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 2) {
                blocks += parseProse(segment)
            } else {
                // Drop the fence's language hint line.
                var lines = segment.split(separator: "\n", omittingEmptySubsequences: false)
                if let first = lines.first, !first.contains(" "), first.count < 24 {
                    lines = Array(lines.dropFirst())
                }
                let code = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty { blocks.append(.code(code)) }
            }
        }
        return blocks
    }

    private static func parseProse(_ text: String) -> [MarkdownBlock] {
        text.components(separatedBy: "\n\n").compactMap { rawParagraph in
            let paragraph = rawParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { return nil }
            let lines = paragraph.split(separator: "\n").map(String.init)
            if paragraph.hasPrefix("#") {
                let level = paragraph.prefix(while: { $0 == "#" }).count
                let title = paragraph.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                return .heading(inline(title), level: level)
            }
            if lines.count > 1, lines.allSatisfy({ $0.contains("|") }) {
                // A table: mono keeps the columns legible on a phone.
                return .code(paragraph)
            }
            if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
                return .bullets(lines.map { inline(String($0.dropFirst(2))) })
            }
            if lines.allSatisfy({ $0.hasPrefix(">") }) {
                let stripped = lines.map {
                    $0.drop(while: { $0 == ">" || $0 == " " })
                }.joined(separator: "\n")
                return .quote(inline(stripped))
            }
            return .paragraph(inline(paragraph))
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// The agent's reasoning: quiet italic, collapsed to a peek until tapped.
private struct ThoughtRow: View {
    let text: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(width: 2)
                Text(text)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A run of consecutive tool calls, folded behind one quiet summary line —
/// "Explored 2 files · 1 search" — the reference style: activity reads as a
/// sentence, not a log. Tapping it discloses the per-call rows; each row can
/// open its detail (± diff, result preview).
private struct ToolGroupRow: View {
    let calls: [ChatViewController.ToolCallState]
    let expanded: Bool
    let onToggleGroup: () -> Void
    let onToggleDetail: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if calls.count == 1, let only = calls.first {
                ToolCallRow(call: only) { onToggleDetail(0) }
            } else {
                Button(action: onToggleGroup) {
                    HStack(spacing: 6) {
                        Text(ToolPhrasing.summary(of: calls))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let badge = DiffBadge.text(for: calls.flatMap(\.diffs)) {
                            badge
                        }
                        if calls.contains(where: { $0.status == .inProgress }) {
                            ProgressView().controlSize(.mini)
                        } else if calls.contains(where: { $0.status == .failed }) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                        ToolCallRow(call: call) { onToggleDetail(index) }
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}

private struct ToolCallRow: View {
    let call: ChatViewController.ToolCallState
    let onToggleDetail: () -> Void

    private var hasDetail: Bool { !call.diffs.isEmpty || !(call.output ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggleDetail) {
                HStack(spacing: 6) {
                    statusIcon
                    Text(ToolPhrasing.line(for: call))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge = DiffBadge.text(for: call.diffs) {
                        badge
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            if call.detailShown {
                ForEach(Array(call.diffs.enumerated()), id: \.offset) { _, diff in
                    DiffView(diff: diff)
                }
                if let output = call.output, !output.isEmpty, call.diffs.isEmpty {
                    Text(output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(30)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
            }
        }
    }

    /// The kind icon carries the tool's category; the status paints it.
    @ViewBuilder private var statusIcon: some View {
        if call.status == .inProgress {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: call.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(call.status.tint)
        }
    }
}

/// The shared ± line-count badge an edit wears while collapsed.
private enum DiffBadge {
    static func text(for diffs: [ChatViewController.DiffChange]) -> Text? {
        guard !diffs.isEmpty else { return nil }
        let lines = diffs.map(DiffLines.counts)
        let additions = lines.map(\.additions).reduce(0, +)
        let deletions = lines.map(\.deletions).reduce(0, +)
        return Text("+\(additions)").font(.caption2.monospaced().weight(.semibold)).foregroundColor(.green)
            + Text(" −\(deletions)").font(.caption2.monospaced().weight(.semibold)).foregroundColor(.red)
    }
}

/// Turns tool-call records into the sentences the chat shows: a per-call
/// line ("Edited ComposerBar.swift", "Ran swift build") and a group summary
/// ("Explored 2 files · 1 search"). Vocabulary keys off the ACP kind, so it
/// works unchanged for any future agent adapter.
private enum ToolPhrasing {
    static func line(for call: ChatViewController.ToolCallState) -> String {
        let object = object(of: call)
        switch call.kind {
        case .read: return object.isEmpty ? "Read a file" : "Read \(object)"
        case .edit: return object.isEmpty ? "Edited a file" : "Edited \(object)"
        case .delete: return object.isEmpty ? "Deleted a file" : "Deleted \(object)"
        case .move: return object.isEmpty ? "Moved a file" : "Moved \(object)"
        case .search: return object.isEmpty ? "Searched" : "Searched \(object)"
        case .execute: return object.isEmpty ? "Ran a command" : "Ran \(object)"
        case .fetch: return object.isEmpty ? "Fetched a page" : "Fetched \(object)"
        case .think: return "Updated the plan"
        case .other: return call.title
        }
    }

    static func summary(of calls: [ChatViewController.ToolCallState]) -> String {
        if calls.count == 1, let only = calls.first { return line(for: only) }
        var parts: [String] = []
        let edits = Set(calls.filter { $0.kind == .edit }.map(object(of:)))
        if !edits.isEmpty {
            parts.append(edits.count == 1 ? "Edited \(edits.first ?? "a file")" : "Edited \(edits.count) files")
        }
        let reads = Set(calls.filter { $0.kind == .read }.map(object(of:))).count
        if reads > 0 { parts.append("Explored \(reads) file\(reads == 1 ? "" : "s")") }
        let searches = calls.filter { $0.kind == .search }.count
        if searches > 0 { parts.append("\(searches) search\(searches == 1 ? "" : "es")") }
        let commands = calls.filter { $0.kind == .execute }.count
        if commands > 0 { parts.append("Ran \(commands) command\(commands == 1 ? "" : "s")") }
        let rest = calls.filter {
            [.fetch, .think, .other, .delete, .move].contains($0.kind)
        }.count
        if rest > 0 { parts.append("\(rest) more step\(rest == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(calls.count) steps" : parts.joined(separator: " · ")
    }

    /// What the call acted on, phone-sized: a path becomes its filename, a
    /// command keeps its head. Falls back to empty when the Mac's title had
    /// no object part.
    private static func object(of call: ChatViewController.ToolCallState) -> String {
        guard let colon = call.title.firstIndex(of: ":") else { return "" }
        let raw = call.title[call.title.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return (raw as NSString).lastPathComponent
        }
        return String(raw.prefix(44))
    }
}

/// One file change, expanded: the path header and the unified diff lines.
private struct DiffView: View {
    let diff: ChatViewController.DiffChange

    var body: some View {
        let lines = DiffLines.unified(oldText: diff.oldText, newText: diff.newText)
        VStack(alignment: .leading, spacing: 0) {
            Text((diff.path as NSString).lastPathComponent)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    Text(line.marker + line.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 0.5)
                        .background(line.background)
                }
                if lines.count > 200 {
                    Text("… \(lines.count - 200) more lines")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(8)
                }
            }
            .padding(.vertical, 4)
        }
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

// MARK: - Diff computation

/// Line diffs for the chat lens's edit cards, via the standard library's
/// Myers difference — small inputs only (the Mac caps diff text it sends).
enum DiffLines {
    struct Line {
        enum Kind { case context, addition, deletion }
        let kind: Kind
        let text: String

        var marker: String {
            switch kind {
            case .context: return "  "
            case .addition: return "+ "
            case .deletion: return "− "
            }
        }

        var color: Color {
            switch kind {
            case .context: return .secondary
            case .addition: return .green
            case .deletion: return .red
            }
        }

        var background: Color {
            switch kind {
            case .context: return .clear
            case .addition: return .green.opacity(0.08)
            case .deletion: return .red.opacity(0.08)
            }
        }
    }

    static func counts(_ diff: ChatViewController.DiffChange) -> (additions: Int, deletions: Int) {
        let lines = unified(oldText: diff.oldText, newText: diff.newText)
        return (
            lines.filter { $0.kind == .addition }.count,
            lines.filter { $0.kind == .deletion }.count
        )
    }

    static func unified(oldText: String?, newText: String) -> [Line] {
        let oldLines = (oldText?.isEmpty ?? true) ? [] : (oldText ?? "").components(separatedBy: "\n")
        let newLines = newText.isEmpty ? [] : newText.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)
        var removals: Set<Int> = []
        var insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }
        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if removals.contains(oldIndex) {
                result.append(Line(kind: .deletion, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                result.append(Line(kind: .addition, text: inserted))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                result.append(Line(kind: .context, text: newLines[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }
}

// MARK: - Shared styling

extension ToolKind {
    var symbolName: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "list.bullet.rectangle"
        case .fetch: "arrow.down.circle"
        case .other: "gearshape"
        }
    }
}

extension ToolCallStatus {
    var tint: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .failed: .red
        }
    }
}
