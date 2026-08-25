import SwiftUI
import UserNotifications

/// App-and-account settings: language, task-completion notifications, and the
/// GitHub integration.
///
/// It used to also carry the `termio` command-line tool, the session-control
/// skill and the status hooks. Every one of those installs a file **on a
/// machine** — an agent's config directory, `/usr/local/bin` — so presented here
/// they read as app-wide and silently meant this Mac, which is why a VPS agent
/// had no hook status and nobody could see why. They now live on a machine's pane
/// (RFC §D8), and this tab stops lying about its scope.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LanguageRow()
            } header: {
                SectionHeaderLabel(title: localized("Language"))
            }
            Section {
                Toggle(isOn: $settings.notifyOnTaskCompletion) {
                    SettingsLabel(
                        title: localized("Task completion"),
                        subtext: localized("Posts a notification when an agent finishes or needs you while Termio is in the background."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                if settings.notifyOnTaskCompletion {
                    Toggle(localized("Play sound"), isOn: $settings.notificationSoundEnabled)
                    NotificationPermissionRow()
                }
            } header: {
                SectionHeaderLabel(title: localized("Notifications"))
            }
            Section {
                Toggle(isOn: $settings.githubIntegrationEnabled) {
                    SettingsLabel(
                        title: localized("GitHub"),
                        subtext: localized("Shows the Issues pane in the inspector for projects whose remote is on GitHub."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Integrations"))
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
                    Text(localized("macOS hasn’t been asked to allow Termio’s notifications yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Request Permission")) {
                        Task {
                            _ = await TaskNotificationCenter.requestPermission()
                            status = await TaskNotificationCenter.authorizationStatus()
                        }
                    }
                }
            case .denied:
                HStack(spacing: 10) {
                    Text(localized("Notifications for Termio are turned off in System Settings."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Open System Settings")) {
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
