import SwiftUI

/// The inspector's Search pane — a sibling of Files / Changes / Info on the
/// toolbar switch, searching file *contents* (VS Code's ⇧⌘F; the filename jump
/// lives in Open Quickly, ⌘⇧O). Queries run debounced through `ContentSearch`
/// (`git grep`, ignore rules for free), results group under their file with the
/// matched substring tinted accent, and clicking a hit opens the editor
/// scrolled to that line.
struct FileSearchView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    /// The project (or worktree) root the search runs under.
    let rootURL: URL
    let font: Font
    /// Leaves the pane (back to the Files tab) — Esc in an empty field.
    let onDismiss: () -> Void
    /// Opens a hit in the editor at its 1-based line.
    let onOpen: (_ url: URL, _ line: Int) -> Void

    /// Total hits kept per query — past this the footer says so and the user
    /// should sharpen the query rather than scroll.
    private static let matchLimit = 400
    /// Typing pause before a grep actually runs (Warp uses 50ms for in-memory
    /// matching; a subprocess earns a slightly longer breath).
    private static let debounce: Duration = .milliseconds(250)

    @State private var query = ""
    @State private var matches: [ContentMatch] = []
    @State private var isSearching = false
    /// The in-flight debounce+grep, cancelled by the next keystroke.
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            resultList
        }
        .onAppear { claimFocus(attempt: 0) }
        .onChange(of: query) { scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search in files", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit {
                    if let first = matches.first { onOpen(first.url, first.line) }
                }
                // Esc clears a live query first; a second Esc (empty field)
                // leaves the pane — VS Code's find-widget rhythm.
                .onExitCommand {
                    if query.isEmpty {
                        onDismiss()
                    } else {
                        query = ""
                    }
                }
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var resultList: some View {
        let grouped = groups
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if !matches.isEmpty {
                    // VS Code's tally line, so the scale of the result set is
                    // readable before any scrolling.
                    Text(summary(fileCount: grouped.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
                ForEach(grouped, id: \.relative) { group in
                    FileHeaderRow(
                        url: group.url,
                        relative: group.relative,
                        count: group.items.count,
                        chrome: chrome,
                        open: { onOpen(group.url, group.items[0].line) }
                    )
                    ForEach(group.items, id: \.line) { match in
                        MatchRow(
                            match: match,
                            query: trimmedQuery,
                            chrome: chrome,
                            open: { onOpen(match.url, match.line) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if !trimmedQuery.isEmpty, matches.isEmpty, !isSearching {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    private func summary(fileCount: Int) -> String {
        let capped = matches.count >= Self.matchLimit
        return "\(matches.count)\(capped ? "+" : "") results in \(fileCount) files"
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
    /// the in-flight task; only a typing pause reaches the actual grep, which
    /// runs detached so the field never hitches.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let root = rootURL
        let limit = Self.matchLimit
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await Task.detached(priority: .userInitiated) {
                ContentSearch.search(trimmed, under: root, limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            matches = found
            isSearching = false
        }
    }

    /// The terminal surface fights for first responder; keep asking for a few
    /// ticks until the field actually has it (the palette's focus-retry gotcha).
    private func claimFocus(attempt: Int) {
        guard attempt < 8 else { return }
        fieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
            if !fieldFocused { claimFocus(attempt: attempt + 1) }
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
    let chrome: ChromeTheme?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
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
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .draggable(url)
        .onTapGesture(perform: open)
    }
}

/// One hit line: the dimmed line number in a fixed gutter, then the line's text
/// with the matched substring tinted accent — enough context to pick the right
/// hit without opening anything.
private struct MatchRow: View {
    let match: ContentMatch
    let query: String
    let chrome: ChromeTheme?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Text(highlightedText())
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }

    /// The line trimmed for display, windowed so the hit is visible even when
    /// it sits deep in a long line (leading context replaced by an ellipsis),
    /// with the query's first occurrence tinted accent + bold.
    private func highlightedText() -> AttributedString {
        var display = match.text.trimmingCharacters(in: .whitespaces)
        if let range = display.range(of: query, options: .caseInsensitive) {
            let offset = display.distance(from: display.startIndex, to: range.lowerBound)
            if offset > 40 {
                let start = display.index(range.lowerBound, offsetBy: -20)
                display = "…" + display[start...]
            }
        }
        var attributed = AttributedString(display)
        if let range = attributed.range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = .accentColor
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
