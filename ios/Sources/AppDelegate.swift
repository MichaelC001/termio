import TermioSSH
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

        // Automated companion test drive: `-companion-url ws://localhost:8787`.
        if let urlString = Self.argument("-companion-url", in: args),
           let url = URL(string: urlString) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                nav.pushViewController(TerminalViewController(companionURL: url), animated: false)
            }
            return true
        }

        // Automated SSH test drive: `-ssh-host H -ssh-port P -ssh-user U
        // -ssh-key-file /path` connects straight to an SSH server (simulator
        // apps run on the host, so the key path can be a host path).
        if let host = Self.argument("-ssh-host", in: args) {
            let key = Self.argument("-ssh-key-file", in: args)
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let config = SSHConfig(
                host: host,
                port: Self.argument("-ssh-port", in: args).flatMap(Int.init) ?? 22,
                username: Self.argument("-ssh-user", in: args) ?? "",
                password: Self.argument("-ssh-password", in: args),
                privateKey: key,
                command: Self.argument("-ssh-command", in: args)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                nav.pushViewController(TerminalViewController(sshConfig: config), animated: false)
            }
            return true
        }

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

    private static func argument(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}
