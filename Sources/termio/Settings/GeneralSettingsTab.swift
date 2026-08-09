import SwiftUI
import UserNotifications

/// App-level settings that aren't about a specific surface: task-completion
/// notifications, the `termio` command-line tool, and the machine-wide agent
/// integrations (status hooks, session control). The latter three install termio's
/// wiring outside the app — PATH, agent configs, instruction files — rather than
/// configure a particular agent, so they live here rather than in the Agents tab.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.notifyOnTaskCompletion) {
                    SettingsLabel(
                        .huge(.checkCircle),
                        title: "Task completion",
                        subtext: "Posts a notification when an agent finishes or needs you while Termio is in the background."
                    )
                }
                .toggleStyle(.switch)
                if settings.notifyOnTaskCompletion {
                    Toggle("Play sound", isOn: $settings.notificationSoundEnabled)
                    NotificationPermissionRow()
                }
            } header: {
                SectionHeaderLabel(title: "Notifications")
            }
            Section {
                CommandLineToolRow()
            } header: {
                SectionHeaderLabel(title: "Command line")
            }
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        .huge(.wireless),
                        title: "Live agent status",
                        subtext: "Shows when an agent is working or waiting on you — the sidebar spinner and menu-bar pulse. Installs Termio's hooks into each agent's config."
                    )
                }
                .toggleStyle(.switch)
                if settings.agentHooksEnabled {
                    // For re-applying after the user (or another tool) has edited
                    // ~/.claude/settings.json; install is idempotent.
                    InstallButtonRow(title: "Reinstall hooks") {
                        .summarizing(AgentStatusHooks.sync(enabled: true),
                                     headline: "Hooks reinstalled", unit: "agents")
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Status")
            }
            Section {
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        .huge(.gitBranch),
                        title: "Session control",
                        subtext: "Lets an agent see and drive its sibling sessions in this project via the `termio sessions` command."
                    )
                }
                .toggleStyle(.switch)
                if settings.sessionControlEnabled {
                    InstallButtonRow(title: "Reinstall note") {
                        .summarizing(SessionSkillInstaller.sync(enabled: true),
                                     headline: "Note reinstalled", unit: "files")
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Orchestration")
            }
            Section {
                Toggle(isOn: $settings.githubIntegrationEnabled) {
                    SettingsLabel(
                        .huge(.github),
                        title: "GitHub",
                        subtext: "Shows the Issues pane in the inspector for projects whose remote is on GitHub."
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: "Integrations")
            }
        }
        .formStyle(.grouped)
    }
}

/// Surfaces the macOS-side notification authorization under the toggle. An app
/// cannot grant itself notification permission — only the system prompt or
/// System Settings can — so this row offers whichever of the two applies:
/// "Request Permission" while macOS has never been asked, a System Settings
/// deep link once the user has denied. Silent when already authorized (or when
/// running unbundled, where the framework is untouchable). Re-audits whenever
/// the app comes back to front, so returning from System Settings updates it.
private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                HStack(spacing: 10) {
                    Text("macOS hasn't been asked to allow Termio's notifications yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Request Permission") {
                        Task {
                            _ = await TaskNotificationCenter.requestPermission()
                            status = await TaskNotificationCenter.authorizationStatus()
                        }
                    }
                }
            case .denied:
                HStack(spacing: 10) {
                    Text("Notifications for Termio are turned off in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
        .task { status = await TaskNotificationCenter.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { status = await TaskNotificationCenter.authorizationStatus() }
        }
    }
}

/// Installs and reports the `termio` command-line tool. It audits on appear so the
/// row always reflects reality (a moved app shows "Update"), and re-audits after
/// the install action so the button and caption update in place.
private struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled
    @State private var state = InstallFeedbackState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SettingsLabel(.huge(.terminal), title: "Command-line tool", subtext: description)
                Spacer()
                if let title = buttonTitle {
                    Button(title) { install() }
                }
            }
            if let feedback = state.feedback {
                // Aligned under the caption, past the row's icon badge.
                InstallFeedbackLabel(feedback: feedback)
                    .padding(.leading, 32)
            }
        }
        .onAppear { status = CommandLineTool.audit() }
        .autoDismissing($state)
    }

    /// Installs, then reports the fresh audit. The caption alone can't carry this:
    /// a declined admin prompt leaves the row reading exactly as it did before the
    /// click, so success and cancellation would be indistinguishable. The
    /// confirmation stays short — the caption above it already names the path — and
    /// echoes the verb of the button that was pressed.
    private func install() {
        // Echo the verb the button offered: an "Update" that lands says "Updated."
        let wasStale: Bool
        if case .stale = status { wasStale = true } else { wasStale = false }
        let result = CommandLineTool.install()
        withAnimation {
            status = result
            switch result {
            case .installed:
                state.show(.success(wasStale ? "Updated." : "Installed."))
            case .conflict:
                state.show(.failure("Something else already owns \(CommandLineTool.installURL.path)."))
            case .unavailable:
                state.show(.failure("No bundled tool to install from."))
            case .notInstalled, .stale:
                let directory = CommandLineTool.installURL.deletingLastPathComponent().path
                state.show(.failure("Couldn’t link `\(CommandLineTool.toolName)` into \(directory)."))
            }
        }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return "`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder."
        case .stale(let path):
            return "An older install points at \(path). Update it to this version of Termio."
        case .notInstalled:
            return "Install `\(tool)` so you (and agents) can run `\(tool) sessions …` from any shell. Links to /usr/local/bin."
        case .conflict:
            return "A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — Termio won't overwrite a file it didn't create."
        case .unavailable:
            return "Available when Termio runs from the built app bundle."
        }
    }

    private var buttonTitle: String? {
        switch status {
        case .installed: return "Reinstall"
        case .stale: return "Update"
        case .notInstalled: return "Install"
        case .conflict, .unavailable: return nil
        }
    }
}
