import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let projects = ProjectListViewController()
        let nav = UINavigationController(rootViewController: projects)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        // Screenshot-driven verification: `-demo sessions|terminal|drawer`
        // walks the project → session → terminal stack so simctl runs can
        // capture states that gestures can't reach from the CLI.
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "-demo"), args.indices.contains(flagIndex + 1) {
            let mode = args[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let project = MockProject.samples[0]
                nav.pushViewController(SessionListViewController(project: project), animated: false)
                guard mode != "sessions" else { return }
                let terminal = TerminalViewController(session: project.sessions[0])
                nav.pushViewController(terminal, animated: false)
                if mode == "drawer" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        terminal.setDrawer(open: true, animated: false)
                    }
                }
            }
        }
        return true
    }
}
