import UIKit

/// iMessage-style shell: the session list is the root screen (the inbox);
/// tapping a session slides its terminal in full-screen and "back" slides it
/// away to reveal the list. Screens draw their own chrome (the list its large
/// title + search, the terminal its compact header), so there is no navigation
/// bar.
///
/// **Why containment instead of a UINavigationController.** Destroying a
/// libghostty surface races the engine's render/IO threads — the source of the
/// iOS `drawFrame` / `os_unfair_lock` crashes. The wrapper frees the surface
/// the instant its view leaves the window (`UITerminalView.didMoveToWindow`),
/// and rebuilds it on re-attach, so a plain push/pop tore down and recreated a
/// surface on every back-and-reopen — racing the engine every time. Here a
/// switched-away terminal is only *hidden*: its view stays installed in the
/// window, so the surface is never freed and never rebuilt. It is torn down
/// only on eviction/close, detached and idle, with no in-flight frames to race.
/// Keyed by `MockSession.key`; a small LRU bounds live surfaces.
final class RootContainerViewController: UIViewController {
    let list = SessionListViewController()

    /// Every parked terminal is a live libghostty surface (scrollback + render
    /// buffers + a streaming socket) whose view stays in the window. On the
    /// phone those add up fast, and libghostty answers memory exhaustion by
    /// replacing the surface with its own "non-functional" panic screen — so
    /// keep the cache small.
    private var recentTerminals: [String: UIViewController] = [:]
    private var recentKeys: [String] = []
    private let maxRecentTerminals = 2

    /// The terminal currently slid in over the list, or nil when the list is
    /// the top screen. Tracked directly (not via the key) so keyless demo
    /// runs are handled too.
    private weak var activeScreen: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // The list is the permanent base layer: added once, always behind any
        // terminal, revealed whenever no terminal is slid in over it.
        addChild(list)
        list.view.frame = view.bounds
        list.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list.view)
        list.didMove(toParent: self)

        list.onOpenSession = { [weak self] session, companionURL in
            guard let self else { return }
            // Coming back to a parked session reuses its screen: same surface,
            // scrollback and connection intact — no surface teardown/rebuild.
            // Every session is the terminal + composer (the Moshi pattern): the
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
    }

    /// Under memory pressure, shed every parked terminal except the one on
    /// screen: each is a live libghostty surface, and the alternative is the
    /// engine hitting its allocator ceiling and painting the "out of memory /
    /// non-functional" panic. The visible screen is kept; parked screens tear
    /// down detached and idle.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        let survivor = recentTerminals.first { $0.value === activeScreen }?.key
        for key in recentKeys where key != survivor {
            if let screen = recentTerminals.removeValue(forKey: key) {
                evict(screen)
            }
        }
        recentKeys = survivor.map { [$0] } ?? []
    }

    // MARK: - Content

    /// Slide a session screen in over the list. `sessionKey` marks the list row
    /// as current (nil for demo runs) and parks the screen in the keep-alive
    /// cache. One conversation at a time, like Messages.
    func open(_ screen: UIViewController, sessionKey: String? = nil, animated: Bool = true) {
        loadViewIfNeeded()
        guard activeScreen !== screen else { return }

        if let sessionKey {
            recentTerminals[sessionKey] = screen
            recentKeys.removeAll { $0 == sessionKey }
            recentKeys.append(sessionKey)
            // Evict the coldest parked screen (never the incoming one). It
            // tears down detached and idle — no in-flight frames to race.
            while recentKeys.count > maxRecentTerminals {
                let coldest = recentKeys.removeFirst()
                if let cold = recentTerminals.removeValue(forKey: coldest), cold !== screen {
                    evict(cold)
                }
            }
        }
        if let terminal = screen as? TerminalViewController {
            terminal.onRequestBack = { [weak self] in self?.goHome() }
            terminal.onClose = { [weak self, weak screen] in
                guard let screen else { return }
                self?.close(screen)
            }
        }

        // A parked screen is only hidden, never removed, so `viewDidAppear`
        // won't fire on its way back — re-run the per-return work explicitly.
        // A brand-new screen gets `viewDidAppear` for free from containment.
        let isReopen = screen.parent === self
        installIfNeeded(screen)
        if isReopen {
            (screen as? TerminalViewController)?.prepareForReappearance()
        }
        list.currentSessionKey = sessionKey
        list.refresh()

        // Start off the right edge, on top, and slide to fill.
        let offscreen = view.bounds.offsetBy(dx: view.bounds.width, dy: 0)
        screen.view.frame = offscreen
        screen.view.isHidden = false
        view.bringSubviewToFront(screen.view)
        activeScreen = screen

        let settle = { screen.view.frame = self.view.bounds }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: .curveEaseOut, animations: settle)
        } else {
            settle()
        }
    }

    /// Back to the list: slide the active terminal off to the right. It stays
    /// parked (view installed, surface alive) if it is still in the cache;
    /// otherwise it is torn down.
    private func goHome(animated: Bool = true) {
        guard let screen = activeScreen else { return }
        activeScreen = nil
        list.currentSessionKey = nil
        list.refresh()

        let parked = recentTerminals.contains { $0.value === screen }
        let offscreen = view.bounds.offsetBy(dx: view.bounds.width, dy: 0)
        let finish = {
            if parked {
                screen.view.isHidden = true // stays in the window: surface alive
            } else {
                self.evict(screen)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0,
                           options: .curveEaseIn,
                           animations: { screen.view.frame = offscreen },
                           completion: { _ in finish() })
        } else {
            screen.view.frame = offscreen
            finish()
        }
    }

    /// The session ended (or its connection died) — different from navigating
    /// back, which parks the screen: drop it from the cache and, if it owned the
    /// screen, reveal the list.
    private func close(_ screen: UIViewController) {
        if let key = recentTerminals.first(where: { $0.value === screen })?.key {
            recentTerminals.removeValue(forKey: key)
            recentKeys.removeAll { $0 == key }
        }
        if activeScreen === screen {
            goHome() // screen is no longer cached, so goHome evicts it
        } else {
            evict(screen)
        }
    }

    // MARK: - Child lifecycle

    private func installIfNeeded(_ screen: UIViewController) {
        guard screen.parent !== self else { return }
        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
    }

    /// The one place a surface is torn down — always detached and idle.
    private func evict(_ screen: UIViewController) {
        guard screen.parent === self else { return }
        screen.willMove(toParent: nil)
        screen.view.removeFromSuperview()
        screen.removeFromParent()
    }
}
