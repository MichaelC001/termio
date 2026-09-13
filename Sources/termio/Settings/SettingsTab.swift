import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case keyboard
    /// The roster: this Mac and every device sessions can run on, one row apiece,
    /// drilling into how that device is reached.
    ///
    /// Sits directly above Workspaces because that is the containment order the
    /// app itself uses: a workspace belongs to a device, so the machine is named
    /// before the things filed on it.
    ///
    /// **Devices**, matching the word the whole codebase already uses —
    /// `KnownDevice`, `DeviceRoster`, `DeviceClient`, `deviceInvite` — so the UI
    /// and the model stop disagreeing. The earlier objection was that "Devices"
    /// was spent on a `~/.ssh/config` projection; that tab is gone, and the name
    /// with it.
    ///
    /// What this tab is *not* is anywhere a device's behaviour is configured.
    /// A page that varies by device carries a device scope of its own (see
    /// `DeviceScopePicker`), because "which machine is this about" is a scope,
    /// not a place to navigate to.
    ///
    /// The raw value stays `ssh` because it is the value persisted under
    /// `lastOpenKey`; changing it would reopen Settings on another tab for
    /// everyone who left this one showing. It has now survived four renamings,
    /// which is the point of it.
    case devices = "ssh"
    case workspaces
    case agents
    case usage
    /// Pairing an iPhone, and the tunnel that carries it.
    ///
    /// This was folded into Devices ▸ this Mac ▸ Serving on the argument that
    /// every line of it is a fact about one machine (see `DeviceServingSection`).
    /// That argument was right about scope and wrong about cost: it put the QR —
    /// the one step a new user cannot guess at — three levels down a tab named
    /// after something else. A setting nobody finds is not a setting. It is
    /// first-level again, and the card names the machine it answers for, which
    /// is what the scope objection was actually asking for.
    case mobile
    case community

    var id: String { rawValue }

    /// Opens a new sidebar group. Devices starts the run about the machines this
    /// Mac reaches and what runs on them — the device, the workspaces filed on
    /// it, the agents, their usage — where the group above is how the app itself
    /// behaves; Community stands alone because it leaves the app entirely.
    var startsGroup: Bool { self == .devices || self == .community }

    /// `allCases` cut into the sidebar's groups, which System Settings separates
    /// with a gap rather than a header. Derived from `startsGroup` so a new tab
    /// can never fall out of the sidebar by being left off a hand-kept list.
    /// The gap itself is row inset, not a `Section` — see `SettingsView`.
    static var groups: [[SettingsTab]] {
        allCases.reduce(into: [[SettingsTab]]()) { groups, tab in
            if tab.startsGroup || groups.isEmpty {
                groups.append([tab])
            } else {
                groups[groups.count - 1].append(tab)
            }
        }
    }

    /// UserDefaults key remembering the last tab the user had open, so ⌘,
    /// reopens where they left off (see `AppDelegate.showSettings`).
    static let lastOpenKey = "settings.lastTab"

    var title: String {
        switch self {
        case .general: return localized("General")
        case .appearance: return localized("Appearance")
        case .terminal: return localized("Terminal")
        case .workspaces: return localized("Workspaces")
        case .devices: return localized("Devices")
        case .keyboard: return localized("Keyboard")
        case .agents: return localized("Agents")
        case .usage: return localized("Usage")
        case .mobile: return localized("Mobile")
        case .community: return localized("Community")
        }
    }

    /// The sidebar glyph, drawn from the app's Hugeicons set so the settings
    /// window matches the main sidebar's line-icon style instead of SF Symbols.
    var icon: HugeIcon {
        switch self {
        case .general: return .settings
        case .appearance: return .paintBoard
        case .terminal: return .terminal
        case .workspaces: return .copy
        case .devices: return .serverStack
        case .keyboard: return .keyboard
        case .agents: return .bot
        case .usage: return .chartColumn
        case .mobile: return .smartPhoneWifi
        case .community: return .bubbleChat
        }
    }

    /// The one-line description shown under the pane title in the detail header,
    /// matching macOS System Settings' navigation subtitle.
    var subtitle: String {
        switch self {
        case .general: return localized("Language, notifications, and GitHub")
        case .appearance: return localized("Theme, fonts, cursor, and window")
        case .terminal: return localized("Scrollback history and text selection")
        case .workspaces: return localized("The workspaces your projects and sessions are filed under")
        case .devices: return localized("This Mac and the machines you reach from it")
        case .keyboard: return localized("Keyboard shortcuts for every command")
        case .agents: return localized("The coding agents offered when you start a session")
        case .usage: return localized("Token usage for your connected agents")
        case .mobile: return localized("Pair your iPhone with the machines you work on")
        case .community: return localized("Discord, GitHub, and the WeChat group")
        }
    }
}
