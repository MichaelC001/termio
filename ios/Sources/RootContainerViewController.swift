import UIKit

/// iMessage-style shell: the session list is the root screen (the inbox);
/// tapping a session pushes its terminal full-screen and the system back
/// gesture pops home. Screens draw their own chrome (the list its large
/// title + search, the terminal its compact header), so the navigation bar
/// stays hidden throughout.
///
/// Switched-away terminals park in a keep-alive cache instead of
/// deallocating: destroying a surface races libghostty's render/IO threads
/// (the source of the engine crashes on iOS), and reuse also preserves
/// scrollback and the live connection. Keyed by `MockSession.key`; small
/// LRU so a long session-hopping run doesn't accumulate live sockets.
final class RootContainerViewController: UINavigationController {
    let list = SessionListViewController()
    private var recentTerminals: [String: UIViewController] = [:]
    private var recentKeys: [String] = []
    private let maxRecentTerminals = 3

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setNavigationBarHidden(true, animated: false)
        list.onOpenSession = { [weak self] session, companionURL in
            guard let self else { return }
            // Coming back to a parked session: same surface, scrollback and
            // connection intact — no surface teardown/re-creation. Every
            // session is the terminal + composer (the Moshi pattern): the
            // agent's TUI is already the conversation UI.
            let screen: UIViewController
            if let parked = recentTerminals[session.key] {
                screen = parked
            } else if let companionURL, session.rosterID != nil {
                screen = TerminalViewController(companionURL: companionURL, session: session)
            } else {
                screen = TerminalViewController(session: session)
            }
            open(screen, sessionKey: session.key)
        }
        list.onOpenSSH = { [weak self] config in
            self?.open(TerminalViewController(sshConfig: config))
        }
        viewControllers = [list]
    }

    // MARK: - Content

    /// Show a session screen. `sessionKey` marks the list row as current
    /// (nil for SSH/demo runs) and parks the screen in the keep-alive cache.
    /// One conversation at a time, like Messages: the stack is always
    /// [list, screen].
    func open(_ screen: UIViewController, sessionKey: String? = nil, animated: Bool = true) {
        loadViewIfNeeded()
        guard topViewController !== screen else { return }
        if let sessionKey {
            recentTerminals[sessionKey] = screen
            recentKeys.removeAll { $0 == sessionKey }
            recentKeys.append(sessionKey)
            // Evict the coldest parked screen (never the incoming one).
            // It tears down detached and idle — no in-flight frames to race.
            while recentKeys.count > maxRecentTerminals {
                recentTerminals.removeValue(forKey: recentKeys.removeFirst())
            }
        }
        if let terminal = screen as? TerminalViewController {
            terminal.onClose = { [weak self, weak screen] in
                guard let screen else { return }
                self?.close(screen)
            }
        }
        list.currentSessionKey = sessionKey
        list.refresh()
        setViewControllers([list, screen], animated: animated)
    }

    /// The session ended (or its connection died) — different from the user
    /// navigating back, which parks the screen: drop it from the cache and
    /// pop home if it owned the screen.
    private func close(_ screen: UIViewController) {
        if let key = recentTerminals.first(where: { $0.value === screen })?.key {
            recentTerminals.removeValue(forKey: key)
            recentKeys.removeAll { $0 == key }
        }
        if topViewController === screen {
            popToRootViewController(animated: true)
        }
    }
}
