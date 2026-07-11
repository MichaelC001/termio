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

    private func scrollToBottom(animated: Bool) {
        guard !items.isEmpty else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(
            at: IndexPath(row: items.count - 1, section: 0),
            at: .bottom, animated: animated
        )
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

/// The agent's reply: plain left-aligned markdown, no bubble chrome.
private struct AssistantRow: View {
    let text: String

    var body: some View {
        HStack {
            Text(Self.attributed(text))
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer(minLength: 24)
        }
    }

    private static func attributed(_ text: String) -> AttributedString {
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

/// A run of consecutive tool calls, folded into one disclosure group. One
/// call renders directly; several fold behind a "N steps" header. Each call
/// row can open its detail: the ± diff and the result preview.
private struct ToolGroupRow: View {
    let calls: [ChatViewController.ToolCallState]
    let expanded: Bool
    let onToggleGroup: () -> Void
    let onToggleDetail: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if calls.count > 1 {
                Button(action: onToggleGroup) {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("\(calls.count) steps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if !expanded {
                            GroupSummaryDots(calls: calls)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
            if calls.count == 1 || expanded {
                ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                    ToolCallRow(call: call) { onToggleDetail(index) }
                }
            }
        }
    }
}

/// The collapsed group's at-a-glance state: one status-colored dot per call.
private struct GroupSummaryDots: View {
    let calls: [ChatViewController.ToolCallState]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(calls.prefix(12), id: \.id) { call in
                Circle()
                    .fill(call.status.tint)
                    .frame(width: 5, height: 5)
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
                    Text(call.title)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge = diffBadge {
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

    /// The ± line-count badge an edit wears collapsed.
    private var diffBadge: Text? {
        guard !call.diffs.isEmpty else { return nil }
        let lines = call.diffs.map(DiffLines.counts)
        let additions = lines.map(\.additions).reduce(0, +)
        let deletions = lines.map(\.deletions).reduce(0, +)
        return Text("+\(additions)").font(.caption2.monospaced().weight(.semibold)).foregroundColor(.green)
            + Text(" −\(deletions)").font(.caption2.monospaced().weight(.semibold)).foregroundColor(.red)
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
