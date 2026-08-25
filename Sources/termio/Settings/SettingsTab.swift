import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    /// Sits above Machines because that is the containment order the app itself
    /// uses: a workspace belongs to a device, and everything filed in it lives on
    /// that machine.
    case workspaces
    /// Every machine sessions can run on — this Mac and each device — as one row
    /// apiece, drilling into a pane that holds both halves of what a machine is:
    /// how it is reached, and what it runs.
    ///
    /// The name went back to **Machines** because the two things it had to name
    /// were a *route* and an *identity*, and "Devices" was only ever spent on the
    /// first: the shipped Devices tab was the renamed SSH tab, a `~/.ssh/config`
    /// projection, leaving machine identity homeless. Rather than two tabs that
    /// both list machines — which forces the user to learn that distinction to
    /// find anything — one tab holds both, and the distinction becomes two
    /// sections inside a pane (RFC §D2).
    ///
    /// The raw value stays `ssh` because it is the value persisted under
    /// `lastOpenKey`; changing it would reopen Settings on another tab for
    /// everyone who left this one showing. It has now survived three renamings,
    /// which is the point of it.
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
        case .workspaces: return localized("Workspaces")
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
        case .workspaces: return .copy
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
        case .general: return localized("Language, notifications, and GitHub")
        case .appearance: return localized("Theme, fonts, cursor, and window")
        case .terminal: return localized("Scrollback history and text selection")
        case .workspaces: return localized("The workspaces your projects and sessions are filed under")
        case .machines: return localized("This Mac and the machines you reach from it, and what each one runs")
        case .keyboard: return localized("Keyboard shortcuts for every command")
        case .agents: return localized("The coding agents offered when you start a session")
        case .usage: return localized("Token usage for your connected agents")
        case .mobile: return localized("Pair your iPhone and remote access")
        case .community: return localized("Discord, GitHub, and the WeChat group")
        }
    }
}
