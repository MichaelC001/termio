import AppKit
import SwiftUI

/// The center-pane welcome, shown by `TerminalPane` whenever no session is mounted
/// — the state a returning user lands in after closing everything (the seeded
/// first-run `home` project means this is never the very first launch). It replaces
/// the old dead-end `ContentUnavailableView("No session selected")` with an
/// Xcode-welcome-style two-column start page: a **Start** column of full-width
/// action rows (open a project, a new terminal, then one row per enabled agent) on
/// the left, a one-click **Recent** projects list on the right.
///
/// Every action is the same full-width row — no pill/capsule chips. On the Mac a
/// filled capsule reads as a *tag or filter*, not an action; Xcode's own welcome
/// window lists "Create New Project…", "Clone…", etc. as rows with a leading glyph
/// and a hover highlight, which is the language mirrored here so a new session and
/// "open a project" feel like the same kind of thing.
///
/// Everything here reuses existing store entry points — `presentOpenProjectPanel`,
/// `addScratchTerminal`/`addScratchSession`, `addProject` — so the welcome adds no
/// new session machinery, only a front door onto it.
struct WelcomeView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        // A header (wordmark + tagline) spanning the full card width, then the two
        // columns beneath it. Lifting the wordmark out of the Start column is what
        // lets the `START` and `RECENT` labels sit on the same baseline — the old
        // layout pushed `START` down by the wordmark's height while `RECENT` hugged
        // the top, so the columns read as unrelated.
        VStack(alignment: .leading, spacing: 34) {
            header
            HStack(alignment: .top, spacing: 40) {
                startColumn
                    .frame(width: 300, alignment: .leading)
                recentColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(40)
        // A fixed working width keeps the two columns a tidy, balanced card on a wide
        // window instead of letting Recent drift to the far edge of a full-screen pane.
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                // The real app icon (the rounded macOS icon), not a generic terminal
                // glyph — this is the app introducing itself, so it wears its own face.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    // The macOS app icon carries ~7% transparent bleed on each side, so
                    // its visible edge sits ~2.5pt inside the 36pt frame (measured). Pull
                    // it left by that much so the icon's visible left edge lines up with
                    // the tagline and the START / NEW SESSION labels below, not a hair
                    // to their right.
                    .padding(.leading, -2.5)
                Text("termio")
                    .font(.system(size: 26, weight: .semibold))
            }
            Text("Start an agent in a project.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        // Inset to the same 8pt as the section labels and row content below, so the
        // wordmark, tagline, and the START / NEW SESSION labels share one left edge.
        .padding(.leading, 8)
    }

    // MARK: Start

    private var startColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("Start")
                WelcomeActionRow(
                    icon: HugeIconView(icon: .folder, size: 15, color: .secondary),
                    title: "Open Project…",
                    shortcut: "⌘O"
                ) { store.presentOpenProjectPanel() }
                WelcomeActionRow(
                    icon: HugeIconView(icon: .terminal, size: 15, color: .secondary),
                    title: "New Terminal",
                    shortcut: "⌘T"
                ) { store.addScratchTerminal() }
            }

            // Agents only — a plain terminal already has its own "New Terminal" row
            // above (⌘T). Each agent is the same row as Start, just with its brand
            // icon, so a new session reads as one more thing you can start here.
            let agents = enabledAgentPresets(settings).filter { $0 != .terminal }
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("New session")
                    ForEach(agents) { preset in
                        WelcomeActionRow(
                            icon: AgentIconView(agent: preset, size: 16),
                            title: preset.displayName
                        ) { store.addScratchSession(agent: preset) }
                    }
                }
            }
        }
    }

    // MARK: Recent

    private var recentColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Recent")
            if recentEntries.isEmpty {
                Text("Projects you open show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            } else {
                ForEach(recentEntries) { entry in
                    WelcomeRecentRow(entry: entry) {
                        store.addProject(at: URL(fileURLWithPath: entry.path))
                    }
                }
            }
        }
    }

    /// The Recent list: currently-open projects first (so a user who merely closed
    /// the selected session can jump straight back), then remembered folders that
    /// aren't currently open — deduped by path, capped for a scannable column.
    /// `addProject` collapses both cases to one click: it reopens a closed folder or
    /// selects an already-open one.
    private var recentEntries: [RecentProject] {
        var seen = Set<String>()
        var out: [RecentProject] = []
        for project in store.orderedProjects where seen.insert(project.path).inserted {
            out.append(RecentProject(name: project.name, path: project.path))
        }
        for recent in settings.recentProjects where seen.insert(recent.path).inserted {
            out.append(recent)
        }
        return Array(out.prefix(8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            // Match the rows' inner inset (8pt) so the header lines up with the
            // action/recent labels below it rather than hanging off to the left.
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

/// A full-width welcome row: a leading glyph (a `HugeIcon` for Start actions, an
/// agent brand icon for a new session), a title, and an optional keyboard shortcut,
/// lifting a faint rounded fill under the cursor — the same hover affordance the
/// sidebar's controls use. Taking the icon as an arbitrary view is what lets the
/// Start actions and the agent sessions share one row type instead of splitting into
/// rows-and-chips.
private struct WelcomeActionRow: View {
    private let icon: AnyView
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    init(icon: some View, title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.icon = AnyView(icon)
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

/// A Recent-projects row: folder glyph, project name, and its home-relative path.
private struct WelcomeRecentRow: View {
    let entry: RecentProject
    let action: () -> Void
    @State private var isHovering = false

    /// The path with the user's home directory folded to `~`, the way the shell and
    /// Finder title bars show it — a full absolute path would dominate the row.
    private var displayPath: String {
        (entry.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HugeIconView(icon: .folder, size: 15, color: .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text(displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}
