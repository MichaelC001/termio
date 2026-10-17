import AppKit
import SwiftUI

// MARK: - Inspector pane menu

/// The inspector's panes (Files / Search / Changes / Issues / Info), behind one button in the
/// focused card's header. It is also the inspector's only toggle: choosing a pane opens the
/// inspector on it, and the menu's last row closes it.
///
/// One button rather than a button per pane, so a card header carries one control for the panel
/// however many panes there are. While the panel is open the button names the pane on screen
/// ("Files"), so which one is open is still readable at a glance.
///
/// It lives on the focused card because that is the session the inspector reads — its tree,
/// changes and info all come from `inspectorCheckout`, the selected session's checkout.
struct InspectorPaneMenu: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    /// Whether any of the current project's remotes points at github.com — probed
    /// async per selection change; gates the Issues row together with the
    /// General "GitHub" setting.
    @State private var hasGitHubRemote = false
    /// Whether the selected session's root is a git work tree — probed per selection
    /// change, gating the Changes row. Starts `true`: most roots are repos.
    @State private var isRepository = true
    @State private var isHovering = false
    @State private var anchor = MenuAnchor()

    private static let panes: [(tab: InspectorTab, icon: HugeIcon, title: String.LocalizationValue)] = [
        (.files, .listBullet, "Project Files"),
        (.search, .search, "Search Files"),
        (.changes, .gitBranch, "Changes"),
        (.issues, .github, "Issues"),
        (.info, .infoCircle, "Info"),
    ]

    /// Two panes exist only where they have something to show, rather than leading
    /// to a dead pane: Issues for a project that actually lives on GitHub (and with the
    /// integration left on in General), Changes for a root git tracks at all.
    private var visiblePanes: [(tab: InspectorTab, icon: HugeIcon, title: String.LocalizationValue)] {
        Self.panes.filter { pane in
            switch pane.tab {
            case .issues: settings.githubIntegrationEnabled && hasGitHubRemote
            case .changes: isRepository
            default: true
            }
        }
    }

    /// The pane on screen, or nil while the panel is closed.
    private var openPane: (tab: InspectorTab, icon: HugeIcon, title: String.LocalizationValue)? {
        guard store.inspectorVisible else { return nil }
        return Self.panes.first { $0.tab == store.inspectorTab }
    }

    var body: some View {
        Button(action: popMenu) {
            HStack(spacing: 4) {
                HugeIconView(icon: openPane?.icon ?? .sidebarRight, size: 12,
                             color: openPane == nil ? .secondary : .primary)
                if let openPane {
                    Text(localized(openPane.title))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(openPane != nil ? 0.12 : isHovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localized("Open a panel"))
        .onHover { isHovering = $0 }
        .background(MenuAnchorView(anchor: anchor))
        // Re-probe when the selection moves or the General switch flips; keyed so
        // the check doesn't rerun on unrelated store churn.
        .task(id: "\(settings.githubIntegrationEnabled)|\(store.inspectorCheckout?.localRoot ?? "")") {
            if let path = store.inspectorCheckout?.localRoot, settings.githubIntegrationEnabled {
                hasGitHubRemote = await !GitService.gitHubRemotes(in: path).isEmpty
            } else {
                hasGitHubRemote = false
            }
            // The pane someone was on can vanish out from under them (setting
            // turned off, selection moved to a non-GitHub project) — land on Files.
            if store.inspectorTab == .issues,
               !(settings.githubIntegrationEnabled && hasGitHubRemote) {
                store.inspectorTab = .files
            }
        }
        // Same shape for Changes, keyed on the root alone — a `cd` in a loose
        // terminal moves this, so it re-runs there and not on GitHub's switch.
        .task(id: store.inspectorCheckout?.localRoot ?? "") {
            guard let path = store.inspectorCheckout?.localRoot else {
                isRepository = true
                return
            }
            isRepository = await GitService.isWorkTree(at: path)
            if store.inspectorTab == .changes, !isRepository {
                store.inspectorTab = .files
            }
        }
    }

    private func popMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        let open = openPane?.tab
        for pane in visiblePanes {
            let item = ClosureMenuItem(title: localized(pane.title)) { show(pane.tab) }
            item.state = pane.tab == open ? .on : .off
            menu.addItem(item)
        }
        if open != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: localized("Close Panel")) { toggleInspector() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// Set without `withAnimation`, so the inspector's content swaps instantly rather than
    /// cross-fading the outgoing pane.
    private func show(_ tab: InspectorTab) {
        store.inspectorTab = tab
        if !store.inspectorVisible { toggleInspector() }
    }

    private func toggleInspector() {
        NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
    }
}

/// The AppKit view under a SwiftUI control, so an `NSMenu` can pop up below it.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// A menu row that runs a closure — the menu is rebuilt on every open, so there is no
/// long-lived target to hang an action on.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor @objc private func run() { handler() }
}
