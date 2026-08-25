import AppKit
import SwiftUI
import TermioShared

/// Which machine the Search pane searches, and therefore what a hit opens. The
/// pane is one pane either way — a field, hits grouped under their file, click to
/// open — so the two roads differ only here.
enum SearchScope {
    /// This Mac: `git grep` under a local root (`ContentSearch`), and a hit opens
    /// the editor at its line.
    case thisMac(URL)
    /// Another machine: that device's own `fs.search`, and a hit opens the
    /// read-only preview the device's file tree already uses. `root` is a path on
    /// **that** box, so it is carried as a string; the `URL`s the rows build from
    /// it are synthetic (names and icons only), exactly like `RemoteFileNode`.
    case device(DeviceFileProvider, host: String, root: String)
}

/// The inspector's Search pane — a sibling of Files / Changes / Info on the
/// toolbar switch, searching file *contents* (VS Code's ⇧⌘F; the filename jump
/// lives in Open Quickly, ⌘⇧O). Queries run debounced through `git grep` — this
/// Mac's own for a local root, the device's for a checkout on another machine —
/// results group under their file with the matched substring tinted accent, and
/// clicking a hit opens the file scrolled to that line.
struct FileSearchView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    /// The root the search runs under, and the machine it lives on.
    let scope: SearchScope
    /// Leaves the pane (back to the Files tab) — Esc in an empty field.
    let onDismiss: () -> Void

    /// Total hits kept per query — past this the footer says so and the user
    /// should sharpen the query rather than scroll.
    private static let matchLimit = 400
    /// Typing pause before a grep actually runs (Warp uses 50ms for in-memory
    /// matching; a subprocess earns a slightly longer breath).
    private static let debounce: Duration = .milliseconds(250)

    @State private var query = ""
    @State private var matches: [ContentMatch] = []
    @State private var isSearching = false
    /// What the device said when it refused to search — shown in place of the
    /// no-matches state, since "nothing here" and "the search never ran" are
    /// different answers and only one of them is about the query.
    @State private var failure: String?
    /// The in-flight debounce+grep, cancelled by the next keystroke.
    @State private var searchTask: Task<Void, Never>?
    /// The in-flight download of a hit's file, for a device checkout.
    @State private var openTask: Task<Void, Never>?
    @State private var fieldFocused = false
    @State private var focusRequest = 0
    @State private var isVisible = false
    @State private var collapsedFiles: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            searchField
            resultList
        }
        .onAppear {
            isVisible = true
            claimFocus(attempt: 0)
        }
        .onChange(of: query) { scheduleSearch() }
        .onDisappear {
            isVisible = false
            searchTask?.cancel()
            openTask?.cancel()
        }
    }

    /// Whether a hit is a file this Mac can hand to the Finder. A device's is
    /// not: the row's URL names a path over there, so a drag would produce a
    /// promise nothing can keep.
    private var allowsDrag: Bool {
        if case .thisMac = scope { return true }
        return false
    }

    // MARK: - Pieces

    private var searchField: some View {
        VStack(spacing: 0) {
            // The magnifier and clear button are drawn here, not by AppKit: the field
            // is a bare `NSTextField` (see `NativeSearchField`) because a bezel-less
            // `NSSearchField` misplaces its built-in icons.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                NativeSearchField(
                    text: $query,
                    isFocused: $fieldFocused,
                    focusRequest: focusRequest,
                    placeholder: placeholder,
                    onSubmit: {
                        if let first = matches.first { open(first) }
                    },
                    // Esc clears a live query first; a second Esc (empty field)
                    // leaves the pane.
                    onExit: {
                        if query.isEmpty {
                            onDismiss()
                        } else {
                            query = ""
                        }
                    }
                )
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Clear"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background { fieldChrome }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, trimmedQuery.isEmpty ? 7 : 4)

            if !trimmedQuery.isEmpty {
                HStack(spacing: 5) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(isSearching ? localized("Searching…") : summary(fileCount: groups.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            }
        }
    }

    /// What the field invites: the project locally, the machine by name for a
    /// checkout on a device — the same "say which box" rule the empty states use.
    private var placeholder: String {
        switch scope {
        case .thisMac: return localized("Search Project")
        case .device(_, let host, _): return localized("Search \(host)")
        }
    }

    /// The field's own chrome, replacing the `NSSearchField` bezel (stripped in
    /// `makeNSView`): a Liquid Glass capsule on macOS 26 — same material recipe as
    /// the toolbar's `InspectorTabsToolbar` track — and a flat capsule fill below.
    @ViewBuilder
    private var fieldChrome: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        }
    }

    /// One flat row of the results list, with a globally unique, stable id.
    /// The list is deliberately a single `ForEach` over these: the previous
    /// shape — a per-file `ForEach` nesting a per-hit `ForEach` keyed by bare
    /// line number — mis-diffed inside `LazyVStack` when typing replaced the
    /// whole match set (line-number ids collide across files, so SwiftUI
    /// stitched rows from different files under one header, or rendered them
    /// empty). Flat rows keyed by `path` / `path:line` make the diff
    /// unambiguous.
    private enum ResultRow: Identifiable {
        case header(relative: String, url: URL, count: Int, isExpanded: Bool)
        case match(ContentMatch)

        var id: String {
            switch self {
            case .header(let relative, _, _, _): return relative
            case .match(let match): return "\(match.relative):\(match.line)"
            }
        }
    }

    private var rows: [ResultRow] {
        var out: [ResultRow] = []
        for group in groups {
            let isExpanded = !collapsedFiles.contains(group.relative)
            out.append(.header(relative: group.relative, url: group.url,
                               count: group.items.count, isExpanded: isExpanded))
            if isExpanded {
                for match in group.items { out.append(.match(match)) }
            }
        }
        return out
    }

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(rows) { row in
                    switch row {
                    case .header(let relative, let url, let count, let isExpanded):
                        FileHeaderRow(
                            url: url,
                            relative: relative,
                            count: count,
                            isExpanded: isExpanded,
                            chrome: chrome,
                            toggleExpanded: {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if isExpanded {
                                        collapsedFiles.insert(relative)
                                    } else {
                                        collapsedFiles.remove(relative)
                                    }
                                }
                            },
                            allowsDrag: allowsDrag,
                            open: { openFirstHit(inFile: relative) }
                        )
                    case .match(let match):
                        MatchRow(
                            match: match,
                            query: trimmedQuery,
                            chrome: chrome,
                            open: { open(match) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if !trimmedQuery.isEmpty, matches.isEmpty, !isSearching {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                    Text(failure == nil ? localized("No Matches") : localized("Can’t Search"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    // The device's own words when it refused: it named the cause,
                    // and "no matches" would be a different — and wrong — answer.
                    Text(failure ?? localized("Try another search term."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private func summary(fileCount: Int) -> String {
        let capped = matches.count >= Self.matchLimit
        return localized("\(matches.count)\(capped ? "+" : "") matches in \(fileCount) files")
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Hits folded under their file, in grep's own order (file-grouped already —
    /// consecutive runs are enough, no re-sort).
    private var groups: [(relative: String, url: URL, items: [ContentMatch])] {
        var out: [(relative: String, url: URL, items: [ContentMatch])] = []
        for match in matches {
            if out.last?.relative == match.relative {
                out[out.count - 1].items.append(match)
            } else {
                out.append((match.relative, match.url, [match]))
            }
        }
        return out
    }

    // MARK: - Search

    /// Debounce + cancel-on-keystroke (Warp's abort pattern): each edit kills
    /// the in-flight task, and the cancellation reaches all the way down —
    /// `ContentSearch` terminates its grep subprocess — so a stale search stops
    /// consuming the machine instead of racing the fresh one. Deliberately NOT
    /// `Task.detached`: a detached task sits outside this task tree, which is
    /// exactly what would strand the grep beyond cancellation's reach.
    private func scheduleSearch() {
        searchTask?.cancel()
        // Cleared here rather than inside the task: the message belongs to the
        // query that produced it, and the debounce would otherwise leave it
        // sitting under a quarter second of a different one.
        failure = nil
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let limit = Self.matchLimit
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await find(trimmed, limit: limit)
            guard !Task.isCancelled else { return }
            matches = found
            isSearching = false
        }
    }

    /// Runs one query on whichever machine holds the root. The device's search is
    /// a network round trip, so its failures are shown rather than swallowed —
    /// `git grep` outside a repo, a daemon too old for `fs.search`, a box that
    /// stopped answering.
    private func find(_ query: String, limit: Int) async -> [ContentMatch] {
        switch scope {
        case .thisMac(let root):
            return await ContentSearch.search(query, under: root, limit: limit)
        case .device(let provider, let host, let root):
            do {
                let result = try await provider.search(query, limit: limit)
                let base = URL(fileURLWithPath: root, isDirectory: true)
                return result.hits.map { hit in
                    ContentMatch(
                        relative: hit.path,
                        url: base.appendingPathComponent(hit.path),
                        line: hit.line,
                        text: hit.text)
                }
            } catch {
                guard !Task.isCancelled else { return [] }
                Log.files.error("""
                device search \(host, privacy: .public):\(root, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
                failure = Self.message(for: error, fallback: localized("The search failed."))
                return []
            }
        }
    }

    /// The device described what went wrong; wording it is this client's job, and
    /// only for the cases the client decides itself — a daemon that named a cause
    /// is quoted verbatim. `fallback` says which of the two round trips failed,
    /// since an error with no message of its own tells the user nothing else.
    private static func message(for error: Error, fallback: String) -> String {
        switch error {
        case DeviceFileError.unsupported:
            return localized("This device’s termiod is too old to browse files.")
        case DeviceFileError.tooLarge:
            return localized("Preview is capped at 1 MB.")
        case DeviceFileError.notRegularFile:
            return localized("Only regular files can be previewed.")
        case TermiodClientError.timedOut:
            // Silence, not a refusal — and the likeliest cause is a host that
            // has never heard of the op, so the sentence names that.
            return localized("This device didn’t answer. Its termiod may be too old to search.")
        case TermiodClientError.requestFailed(let detail) where !detail.isEmpty:
            return detail
        default:
            return fallback
        }
    }

    // MARK: - Opening a hit

    private func openFirstHit(inFile relative: String) {
        guard let match = matches.first(where: { $0.relative == relative }) else { return }
        open(match)
    }

    /// Opens a hit at its line: the editor for a local file, and for a device the
    /// same read-only preview its file tree opens — the bytes are downloaded,
    /// never edited in place.
    private func open(_ match: ContentMatch) {
        guard case .device(let provider, let host, _) = scope else {
            store.openFileInEditor(match.url, at: match.line)
            return
        }
        openTask?.cancel()
        let path = match.url.path
        let name = match.url.lastPathComponent
        let line = match.line
        let generation = store.filePresentationGeneration
        openTask = Task { @MainActor in
            do {
                let file = try await provider.read(
                    path, limit: Termiod.filePreviewByteLimit)
                try Task.checkCancellation()
                let lease = try RemotePreviewStorage.stage(file.data, named: name)
                store.presentRemoteFilePreview(
                    lease, expectedGeneration: generation, at: line,
                    origin: RemoteDocument(
                        route: provider.route, root: provider.root, path: path,
                        mtime: file.mtime, host: host))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Log.files.error("""
                device read \(host, privacy: .public):\(path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
                // The click has to answer for itself: the results list stays on
                // screen, so a failure recorded only in the pane's empty state
                // would be a click that did nothing.
                let alert = NSAlert()
                alert.messageText = "“\(name)” couldn’t be opened."
                alert.informativeText = Self.message(
                    for: error, fallback: localized("The read failed."))
                alert.runModal()
            }
        }
    }

    /// The terminal surface fights for first responder; keep asking for a few
    /// ticks until the field actually has it (the palette's focus-retry gotcha).
    private func claimFocus(attempt: Int) {
        guard isVisible, attempt < 8 else { return }
        focusRequest += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
            if !fieldFocused { claimFocus(attempt: attempt + 1) }
        }
    }
}

// MARK: - Native search field

/// AppKit owns the search field chrome and editing behavior. Rebuilding this
/// control from a plain SwiftUI text field misses the native bezel, focus ring,
/// cancel button, and field-editor behavior that make it feel at home on macOS.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: Int
    let placeholder: String
    let onSubmit: () -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Switching away from the Search pane tears this field down by removing it from the view
    /// tree. If it's still first responder at that moment, AppKit plays its ~0.4s focus-ring
    /// fade-out — the blue outline you saw hanging over the next pane. Resign first responder
    /// with animations disabled (and drop the ring type) so the outline goes the instant the tab
    /// changes, matching the now-instant content swap.
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.focusRingType = .none
        guard let window = field.window,
              window.firstResponder === field || window.firstResponder === field.currentEditor()
        else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        window.makeFirstResponder(nil)
        NSAnimationContext.endGrouping()
    }

    func makeNSView(context: Context) -> NSTextField {
        // A plain text field, not `NSSearchField`: the SwiftUI wrapper draws the
        // chrome (glass capsule, magnifier, clear button — see `searchField`), and
        // a bezel-less `NSSearchField` misplaces its built-in icons. Bare text is
        // also what sidesteps the field's appearance animations (the focus-ring
        // bloom and the centered-placeholder slide) that replayed on every
        // auto-focused appearance of the pane.
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.focusRingType = .none
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }

        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        // The hosting view can enter the window one run-loop turn after SwiftUI
        // asks for focus, so wait until AppKit has attached the search field.
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil, field.currentEditor() == nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        var lastFocusRequest = -1

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func submit(_ sender: NSTextField) {
            updateText(from: sender)
            parent.onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updateText(from: field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let field = control as? NSTextField else { return false }
                submit(field)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onExit()
                return true
            default:
                return false
            }
        }

        private func updateText(from field: NSTextField) {
            guard parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - Rows

/// A file's group header: icon, name, dimmed directory, and its hit count on
/// the trailing edge — VS Code's search-tree file row. Clicking it opens the
/// file at its first hit.
private struct FileHeaderRow: View {
    let url: URL
    let relative: String
    let count: Int
    let isExpanded: Bool
    let chrome: ChromeTheme?
    let toggleExpanded: () -> Void
    /// Whether the row's file exists on this Mac. A device's does not, so it is
    /// not draggable — the URL names a path over there.
    let allowsDrag: Bool
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? localized("Collapse Results") : localized("Expand Results"))

            HStack(spacing: 5) {
                FileIconView(url: url, size: 15, symbolSize: 13)
                    .frame(width: 16, alignment: .leading)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                let directory = (relative as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                // Count as a capsule badge (VS Code's count badge), so the number
                // reads as metadata rather than trailing content.
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .draggableFile(url, when: allowsDrag)
    }
}

private extension View {
    /// Drags the row out as its file, but only when the file is on this Mac. A
    /// device's row carries a path on that box, and a drag promising the Finder
    /// a local file at that path would be a promise nothing can keep.
    @ViewBuilder
    func draggableFile(_ url: URL, when allowed: Bool) -> some View {
        if allowed {
            draggable(url)
        } else {
            self
        }
    }
}

/// One hit line, styled after Xcode's Find navigator: the line's text in the
/// system font with the context dimmed and the matched substring lifted to
/// full-strength semibold — the matches are what the eye lands on, not the
/// context. No line-number gutter (neither Xcode nor VS Code shows one; the
/// click jumps to the line anyway), so the text aligns under the file name.
private struct MatchRow: View {
    let match: ContentMatch
    let query: String
    let chrome: ChromeTheme?
    let open: () -> Void

    @State private var isHovering = false

    /// Leading context kept before the first hit, cut at a word boundary — VS
    /// Code's `lcut(…, 26)`: enough to identify the line, short enough that the
    /// hit stays near the left edge.
    private static let leadingContextMax = 26

    var body: some View {
        HStack(spacing: 0) {
            Text(highlightedText())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        // Aligns the text's leading edge with the header row's file name
        // (10 padding + 12 chevron + 4 spacing + 16 icon + 5 spacing).
        .padding(.leading, 47)
        .padding(.trailing, 8)
        // One flat row height for every hit (VS Code pins all search rows to
        // 22px) — the list's rhythm stays even no matter what the text holds.
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }

    /// The line trimmed for display: leading context word-boundary-cut to
    /// `leadingContextMax` chars (with an ellipsis) so the first hit sits near
    /// the left edge, then every occurrence of the query marked with the
    /// highlighter treatment — full-strength text on a soft accent wash. The
    /// context stays `.secondary` (the row's base style), so hits carry the
    /// row's visual weight even when the match is two characters inside a word.
    private func highlightedText() -> AttributedString {
        var display = Substring(match.text.trimmingCharacters(in: .whitespaces))
        if let first = display.range(of: query, options: .caseInsensitive),
           display.distance(from: display.startIndex, to: first.lowerBound) > Self.leadingContextMax {
            var start = display.index(first.lowerBound, offsetBy: -Self.leadingContextMax)
            // Land on the next word boundary so the cut doesn't open mid-word.
            if let space = display[start..<first.lowerBound].firstIndex(of: " ") {
                start = display.index(after: space)
            }
            display = display[start...]
        } else {
            return marked(display)
        }
        return AttributedString("…") + marked(display)
    }

    /// `display` with every case-insensitive occurrence of the query lifted to
    /// `.primary` over an accent wash.
    private func marked(_ display: Substring) -> AttributedString {
        var attributed = AttributedString()
        var rest = display
        while let range = rest.range(of: query, options: .caseInsensitive) {
            attributed += AttributedString(String(rest[..<range.lowerBound]))
            var hit = AttributedString(String(rest[range]))
            hit.foregroundColor = .primary
            hit.backgroundColor = Color.accentColor.opacity(0.28)
            attributed += hit
            rest = rest[range.upperBound...]
        }
        attributed += AttributedString(String(rest))
        return attributed
    }
}
