import AppKit
import SwiftUI

/// Why the simulator can't run yet on a Mac that could run it: a step of Xcode's
/// own setup that hasn't happened. Each one names the step that fixes it, since
/// every one is fixed outside Termio — Termio never installs Xcode, accepts a
/// license or downloads a platform itself.
enum SimulatorSetupProblem: Equatable {
    /// No Xcode at all; the Command Line Tools alone have no simulator.
    case noXcode
    /// Xcode is installed, but the active developer folder is the Command Line Tools.
    case xcodeNotSelected(xcode: String)
    /// Xcode's license hasn't been accepted.
    case license
    /// Xcode hasn't finished its first launch, which installs CoreSimulator.
    case firstLaunch
    /// Xcode is ready, but no iOS platform is downloaded.
    case noRuntime

    var title: String {
        switch self {
        case .noXcode: localized("Install Xcode")
        case .xcodeNotSelected: localized("Choose Xcode")
        case .license: localized("Accept the Xcode License")
        case .firstLaunch: localized("Finish Setting Up Xcode")
        case .noRuntime: localized("Download the iOS Platform")
        }
    }

    var message: String {
        switch self {
        case .noXcode:
            localized("The iOS Simulator comes with Xcode. Install it from the App Store, then open it once.")
        case .xcodeNotSelected:
            localized("This Mac uses the Command Line Tools, which have no simulator. Switch to Xcode in Terminal.")
        case .license:
            localized("Xcode needs its license accepted before the simulator runs. Open Xcode, or accept it in Terminal.")
        case .firstLaunch:
            localized("Xcode hasn’t finished installing its components. Open Xcode once, or finish in Terminal.")
        case .noRuntime:
            localized("No iOS simulator is downloaded. Get one in Xcode ▸ Settings ▸ Components, or in Terminal.")
        }
    }

    /// The Terminal command that fixes it, where there is one.
    var command: String? {
        switch self {
        case .noXcode: nil
        case .xcodeNotSelected(let xcode): "sudo xcode-select -s \(xcode)"
        case .license: "sudo xcodebuild -license accept"
        case .firstLaunch: "sudo xcodebuild -runFirstLaunch"
        case .noRuntime: "xcodebuild -downloadPlatform iOS"
        }
    }

    /// What the probe found, read in the order Xcode is set up: an Xcode, then
    /// the developer folder pointing at it, then its license and first launch
    /// (both of which make `simctl` fail with their own words), then a platform.
    static func diagnose(
        developerFolder: String?, installedXcode: String?, simctlError: String?, iOSRuntimes: Int
    ) -> SimulatorSetupProblem? {
        let folder = developerFolder ?? ""
        if folder.isEmpty || folder.contains("CommandLineTools") {
            guard let installedXcode else { return .noXcode }
            return .xcodeNotSelected(xcode: installedXcode)
        }
        if let simctlError {
            return simctlError.localizedCaseInsensitiveContains("license") ? .license : .firstLaunch
        }
        return iOSRuntimes == 0 ? .noRuntime : nil
    }
}

extension SimulatorHost {
    /// Checks Xcode's setup and publishes what is missing, if anything. Run as
    /// the pane opens and when the person asks to check again.
    func checkSetup() async {
        setupProblem = await Self.probeSetup()
        setupChecked = true
    }

    private static func probeSetup() async -> SimulatorSetupProblem? {
        let folder = await output("/usr/bin/xcode-select", ["-p"])
        // The app's own path: `xcode-select -s` takes it, and it reads shorter.
        let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")?.path
        var simctlError: String?
        var runtimes = 0
        if let folder, !folder.contains("CommandLineTools") {
            do {
                let result = try await simctlProcess("/usr/bin/xcrun", ["simctl", "list", "runtimes", "--json"], input: nil)
                if result.status != 0 {
                    simctlError = result.error.isEmpty ? "simctl failed" : result.error
                } else if let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
                          let rows = object["runtimes"] as? [[String: Any]] {
                    runtimes = rows.filter { $0["platform"] as? String == "iOS" && $0["isAvailable"] as? Bool == true }.count
                }
            } catch {
                simctlError = error.localizedDescription
            }
        }
        let problem = SimulatorSetupProblem.diagnose(
            developerFolder: folder, installedXcode: xcode, simctlError: simctlError, iOSRuntimes: runtimes)
        if let problem { Log.simulator.info("simulator setup: \(String(describing: problem), privacy: .public)") }
        return problem
    }

    /// A tool's standard output, trimmed; nil when it can't run or fails.
    private static func output(_ executable: String, _ arguments: [String]) async -> String? {
        do {
            let result = try await simctlProcess(executable, arguments, input: nil)
            guard result.status == 0 else { return nil }
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            Log.simulator.error("running \(executable, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The pane while Xcode's setup is incomplete: the one step still to do, the
/// button that starts it, and Check Again for when it is done.
struct SimulatorSetupView: View {
    let problem: SimulatorSetupProblem
    @ObservedObject private var host = SimulatorHost.shared
    @State private var checking = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(problem.title)
                .font(.system(size: 13, weight: .semibold))
            Text(problem.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let command = problem.command {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TreeHeaderButton(huge: .copy, help: localized("Copy Command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        host.notice = localized("Copied")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                if let action = primaryAction {
                    Button(action.title, action: action.run)
                }
                Button(localized("Check Again")) {
                    Task {
                        checking = true
                        await host.checkSetup()
                        checking = false
                        if host.setupProblem == nil { await host.refreshDevices() }
                    }
                }
                .disabled(checking)
            }
            .controlSize(.small)
            if let notice = host.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primaryAction: (title: String, run: () -> Void)? {
        switch problem {
        case .noXcode:
            return (localized("Open the App Store"), {
                // Xcode's App Store page.
                if let url = URL(string: "macappstore://apps.apple.com/app/id497799835") {
                    NSWorkspace.shared.open(url)
                }
            })
        case .xcodeNotSelected:
            return nil
        case .license, .firstLaunch, .noRuntime:
            return (localized("Open Xcode"), {
                guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
                else { return }
                NSWorkspace.shared.openApplication(at: xcode, configuration: NSWorkspace.OpenConfiguration())
            })
        }
    }
}
