import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    /// The raw value stays `ssh` because it is the value persisted under
    /// `lastOpenKey`; changing it would reopen Settings on another tab for
    /// everyone who left this one showing.
    case machines = "ssh"
    case keyboard
    case agents
    case usage
    case mobile
    case community

    var id: String { rawValue }

    /// UserDefaults key remembering the last tab the user had open, so ⌘,
    /// reopens where they left off (see `AppDelegate.showSettings`).
    static let lastOpenKey = "settings.lastTab"

    var title: String {
        switch self {
        case .general: return localized("General")
        case .appearance: return localized("Appearance")
        case .terminal: return localized("Terminal")
        case .machines: return localized("Machines")
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
        case .machines: return .serverStack
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
        case .general: return localized("The termio command-line tool, agent skill, and notifications")
        case .appearance: return localized("Theme, fonts, cursor, and window")
        case .terminal: return localized("Scrollback history and text selection")
        case .machines: return localized("The machines in your ~/.ssh/config, and the keys that reach them")
        case .keyboard: return localized("Keyboard shortcuts for every command")
        case .agents: return localized("The coding agents offered when you start a session")
        case .usage: return localized("Token usage for your connected agents")
        case .mobile: return localized("Pair your iPhone and remote access")
        case .community: return localized("Discord, GitHub, and the WeChat group")
        }
    }
}
