import AppKit
import SwiftUI

/// Which palette is up. otty/VS Code's split: Open Quickly (⌘⇧O) jumps to
/// *things* — sessions, recent projects, files — while the Command Palette
/// (⌘⇧P) runs *verbs* — app actions. One panel, two modes; mixing both in a
/// single list buries the actions under a wall of same-named sessions and
/// muddles the mental model.
enum PaletteMode {
    case openQuickly
    case commands
}

/// The shared palette panel behind ⌘⇧O (Open Quickly) and ⌘⇧P (Command
/// Palette). One searchable list, fuzzy-matched (otty-style subsequence
/// scoring — word-boundary and consecutive hits win; no learned ranking).
///
/// Open Quickly sections: every session, recently-closed projects, and — once
/// a query is typed — the current project's files (`git ls-files`, so ignore
/// rules apply). The Command Palette lists every app action with its shortcut;
/// ⌘↩ runs one and keeps the palette open for chaining (otty's behaviour).
///
/// Presented in its own floating `NSPanel` (see `AppDelegate`), Xcode
/// Open-Quickly style, NOT as a SwiftUI overlay: the terminal surfaces are
/// NSViews, and AppKit draws child NSViews above the hosting view's SwiftUI
/// canvas — an in-tree overlay renders *underneath* the terminals no matter
/// its ZStack order. A panel also gets keyboard focus for free (it becomes the
/// key window), and floats with no backdrop dimming.
///
/// Keyboard: a *local* keyDown monitor consumes ↑/↓/Return/Esc before the
/// responder chain can hand them to the search field, and the search field
/// claims focus with a short retry loop.
struct CommandPaletteView: View {
    @EnvironmentObject var store: TermioStore
    let onClose: () -> Void

    /// The panel's fixed size — stable like VS Code's palette, whatever the
    /// result count; the list scrolls inside.
    static let panelSize = CGSize(width: 560, height: 400)

    /// File-listing cap: enough for any sane repo, a guardrail for monorepos.
    private static let fileLimit = 5000
    /// How many file matches show per query — files are the long tail, and
    /// past this the user should just keep typing.
    private static let fileMatchLimit = 20

    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var projectFiles: [ProjectFile] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            itemList
        }
        // No background here: SwiftUI materials only sample within their own
        // window, and this panel contains nothing but the palette — they'd
        // collapse to an opaque grey. The glass backdrop lives on the panel's
        // AppKit contentView (see `AppDelegate.paletteBackdrop`).
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .onAppear {
            installKeyMonitor()
            claimSearchFocus(attempt: 0)
            loadProjectFiles()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: query) { _, _ in highlighted = 0 }
        // Pressing the other shortcut while open switches modes in place —
        // stale search text from the previous mode would just show "No matches".
        .onChange(of: store.paletteMode) { _, _ in
            query = ""
            highlighted = 0
            loadProjectFiles()
        }
    }

    /// The presented mode. The store owns it so the View-menu shortcuts can
    /// flip modes while the panel stays up; `.commands` covers the nil gap
    /// during dismissal.
    private var mode: PaletteMode { store.paletteMode ?? .commands }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            TextField(
                mode == .openQuickly ? "Jump to session, project, or file…" : "Run a command…",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .focused($searchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    let items = filtered
                    // Headers only when the list actually spans sections —
                    // a lone "Sessions" banner over everything is noise.
                    let sectioned = Set(items.map(\.section)).count > 1
                    if items.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if sectioned, index == 0 || items[index - 1].section != item.section,
                           let title = item.section.title {
                            sectionHeader(title)
                        }
                        PaletteRow(item: item, isHighlighted: index == highlighted)
                            .id(index)
                            .onTapGesture { run(item) }
                            .onHover { inside in if inside { highlighted = index } }
                    }
                }
                .padding(6)
            }
            .onChange(of: highlighted) { _, index in
                proxy.scrollTo(index, anchor: nil)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    // MARK: - Items

    private var allItems: [PaletteItem] {
        switch mode {
        case .openQuickly: return openQuicklyItems
        case .commands: return commandItems
        }
    }

    private var openQuicklyItems: [PaletteItem] {
        var items: [PaletteItem] = []
        for project in store.orderedProjects {
            for session in project.sessions {
                items.append(.init(
                    id: "session-\(session.id.uuidString)",
                    kind: .session(session),
                    section: .sessions,
                    title: store.displayTitle(for: session),
                    subtitle: project.name
                ))
            }
        }
        // Only folders that aren't already open — the open ones are reachable
        // through their sessions above.
        let openPaths = Set(store.projects.map(\.path))
        for recent in store.settings.recentProjects where !openPaths.contains(recent.path) {
            items.append(.init(
                id: "recent-\(recent.path)",
                kind: .recentProject(recent),
                section: .recentProjects,
                title: recent.name,
                subtitle: (recent.path as NSString).abbreviatingWithTildeInPath
            ))
        }
        for file in projectFiles {
            items.append(.init(
                id: "file-\(file.relative)",
                kind: .file(file),
                section: .files,
                title: file.url.lastPathComponent,
                subtitle: file.relative,
                searchKey: file.relative
            ))
        }
        return items
    }

    private var commandItems: [PaletteItem] {
        availableActions.map { action in
            .init(id: "action-\(action.id)", kind: .action(action),
                  section: .commands, title: action.title, subtitle: nil,
                  shortcut: action.shortcut)
        }
    }

    /// Every app action, minus the ones that could only no-op right now (the
    /// pane verbs need a pane), so the list never advertises dead rows.
    private var availableActions: [PaletteAction] {
        var actions: [PaletteAction] = []
        if store.selectedSessionID != nil {
            actions.append(.init(id: "split-right", title: "Split Right",
                                 symbol: "rectangle.split.2x1", shortcut: "⌘D") {
                $0.splitSelectedPane(.horizontal)
            })
            actions.append(.init(id: "split-down", title: "Split Down",
                                 symbol: "rectangle.split.1x2", shortcut: "⇧⌘D") {
                $0.splitSelectedPane(.vertical)
            })
        }
        if store.splitRoot != nil {
            actions.append(.init(id: "close-pane", title: "Close Pane",
                                 symbol: "rectangle", shortcut: "⌥⌘W") {
                $0.closeSelectedPane()
            })
            for (id, title, arrow, selector) in [
                ("focus-left", "Focus Pane Left", "←", #selector(AppDelegate.focusPaneLeft(_:))),
                ("focus-right", "Focus Pane Right", "→", #selector(AppDelegate.focusPaneRight(_:))),
                ("focus-up", "Focus Pane Up", "↑", #selector(AppDelegate.focusPaneUp(_:))),
                ("focus-down", "Focus Pane Down", "↓", #selector(AppDelegate.focusPaneDown(_:))),
            ] {
                actions.append(.init(id: id, title: title,
                                     symbol: "arrow.left.and.right.square", shortcut: "⌥⌘\(arrow)") { _ in
                    NSApp.sendAction(selector, to: nil, from: nil)
                })
            }
        }
        actions.append(.init(id: "new-terminal", title: "New Terminal",
                             symbol: "plus.rectangle", shortcut: "⌘T") {
            $0.addScratchTerminal()
        })
        // One "New … Session" verb per enabled agent — in the selected
        // project when there is one, else the scratch workspace (the welcome
        // page's behaviour).
        for agent in enabledAgentPresets(store.settings) where agent != .terminal {
            actions.append(.init(id: "new-session-\(agent.id)",
                                 title: "New \(agent.displayName) Session",
                                 symbol: nil, agent: agent, shortcut: nil) { store in
                if let sid = store.selectedSessionID, let project = store.project(for: sid) {
                    store.addSession(to: project.id, agent: agent)
                } else {
                    store.addScratchSession(agent: agent)
                }
            })
        }
        actions.append(.init(id: "open-project", title: "Open Project…",
                             symbol: "folder", shortcut: "⌘O") {
            $0.presentOpenProjectPanel()
        })
        actions.append(.init(id: "toggle-sidebar", title: "Toggle Sidebar",
                             symbol: "sidebar.leading", shortcut: nil) { _ in
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "toggle-files", title: "Toggle Project Files",
                             symbol: "sidebar.trailing", shortcut: "⌥⌘0") { _ in
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "settings", title: "Settings…",
                             symbol: "gearshape", shortcut: "⌘,") { _ in
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "check-updates", title: "Check for Updates…",
                             symbol: "arrow.triangle.2.circlepath", shortcut: nil) { _ in
            NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
        })
        return actions
    }

    /// Fuzzy filter + rank. Empty query shows the browsable sets (sessions,
    /// recents, every command) but no files — 5000 unranked paths is a wall,
    /// and files only mean anything once the user starts describing one.
    private var filtered: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return allItems.filter { $0.section != .files }
        }
        var fileCount = 0
        return allItems
            .enumerated()
            .compactMap { index, item -> (item: PaletteItem, index: Int, score: Int)? in
                guard let score = fuzzyScore(trimmed, in: item.searchKey) else { return nil }
                return (item, index, score)
            }
            // Section first (things before the file long-tail), then score;
            // the original index keeps the sort stable.
            .sorted {
                ($0.item.section.rawValue, -$0.score, $0.index)
                    < ($1.item.section.rawValue, -$1.score, $1.index)
            }
            .filter { entry in
                guard entry.item.section == .files else { return true }
                fileCount += 1
                return fileCount <= Self.fileMatchLimit
            }
            .map(\.item)
    }

    /// otty-style subsequence match: every query character must appear in
    /// order. Scoring is transparent, not learned — word-boundary hits beat
    /// consecutive runs beat scattered ones, and long candidates pay a small
    /// length tax so `App.swift` outranks a deep path with the same letters.
    private func fuzzyScore(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate)
        let lower = Array(candidate.lowercased())
        var qi = 0, score = 0, lastMatch = -2
        for i in 0..<lower.count where qi < q.count {
            guard lower[i] == q[qi] else { continue }
            if i == 0 || "/ ._-+".contains(lower[i - 1]) || (c[i].isUppercase && !c[i - 1].isUppercase) {
                score += 3
            } else if lastMatch == i - 1 {
                score += 2
            } else {
                score += 1
            }
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - candidate.count / 16
    }

    private func run(_ item: PaletteItem, keepOpen: Bool = false) {
        if !keepOpen { onClose() }
        switch item.kind {
        case .session(let session):
            store.selectedSessionID = session.id
        case .recentProject(let recent):
            // Reopens a closed folder or selects an already-open one — the
            // welcome page's one-click semantics.
            store.addProject(at: URL(fileURLWithPath: recent.path))
        case .file(let file):
            store.openFileInEditor(file.url)
        case .action(let action):
            action.perform(store)
        }
    }

    // MARK: - Project files

    /// The project whose files ⌘⇧O searches: the selected session's, falling
    /// back to the most recently active one when nothing is selected.
    private var currentProject: Project? {
        if let sid = store.selectedSessionID, let project = store.project(for: sid) {
            return project
        }
        return store.orderedProjects.first
    }

    /// Lists the current project's files off the main thread. Loaded once per
    /// palette presentation — the working tree won't meaningfully change in
    /// the seconds a palette is up.
    private func loadProjectFiles() {
        guard mode == .openQuickly, projectFiles.isEmpty,
              let root = currentProject.map({ URL(fileURLWithPath: $0.path) }) else { return }
        Task.detached(priority: .userInitiated) {
            let files = Self.listFiles(under: root)
            await MainActor.run { projectFiles = files }
        }
    }

    /// `git ls-files` (tracked + untracked-but-not-ignored, so ignore rules
    /// apply for free); a non-repo folder falls back to a filesystem walk
    /// that skips hidden entries. Both capped at `fileLimit`.
    nonisolated private static func listFiles(under root: URL) -> [ProjectFile] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let out = String(data: data, encoding: .utf8) {
                let relatives = out.split(separator: "\n").prefix(fileLimit)
                if !relatives.isEmpty {
                    return relatives.map {
                        ProjectFile(relative: String($0), url: root.appendingPathComponent(String($0)))
                    }
                }
            }
        }
        var out: [ProjectFile] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let prefixLength = root.path.count + 1
        while let url = enumerator?.nextObject() as? URL, out.count < fileLimit {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            out.append(ProjectFile(relative: String(url.path.dropFirst(prefixLength)), url: url))
        }
        return out
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                onClose()
                return nil
            case 125: // ↓
                highlighted = min(highlighted + 1, max(filtered.count - 1, 0))
                return nil
            case 126: // ↑
                highlighted = max(highlighted - 1, 0)
                return nil
            case 36, 76: // Return / keypad Enter; ⌘↩ chains (palette stays up)
                let items = filtered
                if items.indices.contains(highlighted) {
                    run(items[highlighted], keepOpen: event.modifierFlags.contains(.command))
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The terminal surface fights for first responder; keep asking for a few
    /// ticks until the field actually has it (muxy's focus-retry gotcha).
    private func claimSearchFocus(attempt: Int) {
        guard attempt < 8 else { return }
        searchFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
            if !searchFocused { claimSearchFocus(attempt: attempt + 1) }
        }
    }
}

// MARK: - Model

/// A file inside the current project, carried with its repo-relative path (the
/// search key and subtitle) alongside the absolute URL the editor opens.
private struct ProjectFile: Sendable {
    let relative: String
    let url: URL
}

/// Open Quickly's display groups, in rank order; `.commands` is the palette's
/// single (headerless) group.
private enum PaletteSection: Int, Hashable {
    case sessions, recentProjects, files, commands

    var title: String? {
        switch self {
        case .sessions: return "Sessions"
        case .recentProjects: return "Recent"
        case .files: return "Files"
        case .commands: return nil
        }
    }
}

private struct PaletteItem: Identifiable {
    enum Kind {
        case session(Session)
        case recentProject(RecentProject)
        case file(ProjectFile)
        case action(PaletteAction)
    }

    let id: String
    let kind: Kind
    let section: PaletteSection
    let title: String
    let subtitle: String?
    var shortcut: String?
    /// What the fuzzy matcher sees — defaults to title + subtitle; files
    /// override it with the relative path so directory names match too.
    var searchKey: String

    init(id: String, kind: Kind, section: PaletteSection, title: String,
         subtitle: String?, shortcut: String? = nil, searchKey: String? = nil) {
        self.id = id
        self.kind = kind
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.searchKey = searchKey ?? [title, subtitle ?? ""].joined(separator: " ")
    }
}

/// One runnable app action. A plain struct (not an enum) so the list can be
/// assembled dynamically — the "New … Session" verbs come from the enabled
/// agent roster, not a fixed case list. Store-backed actions call the store;
/// window-level ones (settings, inspector, updates) route through the
/// responder chain to `AppDelegate`, exactly as their menu items do.
private struct PaletteAction: Identifiable {
    let id: String
    let title: String
    /// SF Symbol name, or nil when `agent` supplies a brand icon instead.
    let symbol: String?
    var agent: AgentPreset?
    let shortcut: String?
    let perform: @MainActor (TermioStore) -> Void

    init(id: String, title: String, symbol: String?, agent: AgentPreset? = nil,
         shortcut: String?, perform: @escaping @MainActor (TermioStore) -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.agent = agent
        self.shortcut = shortcut
        self.perform = perform
    }
}

// MARK: - Row

private struct PaletteRow: View {
    @EnvironmentObject var store: TermioStore
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if case .session(let session) = item.kind, store.selectedSessionID == session.id {
            Text("current")
                .font(.system(size: 10))
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
        } else if let shortcut = item.shortcut {
            Text(shortcut)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .session(let session):
            AgentIconView(agent: session.agent, size: 14)
        case .recentProject:
            symbolIcon("clock.arrow.circlepath")
        case .file:
            symbolIcon("doc.text")
        case .action(let action):
            if let agent = action.agent {
                AgentIconView(agent: agent, size: 14)
            } else {
                symbolIcon(action.symbol ?? "questionmark")
            }
        }
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
    }
}
