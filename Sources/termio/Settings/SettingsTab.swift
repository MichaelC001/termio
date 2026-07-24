import SwiftUI

/// The top-level settings groups. Each is one row in the Settings sidebar. Not
/// private so the launch reminder can open settings straight to a given tab (see
/// `AppDelegate.openSettings`).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case interface
    case terminal
    case keyboard
    case agents
    case languages
    case usage
    case mobile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .interface: return "Interface"
        case .terminal: return "Terminal"
        case .keyboard: return "Keyboard"
        case .agents: return "Agents"
        case .languages: return "Languages"
        case .usage: return "Usage"
        case .mobile: return "Mobile"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .interface: return "sidebar.left"
        case .terminal: return "terminal"
        case .keyboard: return "keyboard"
        case .agents: return "sparkles"
        case .languages: return "chevron.left.forwardslash.chevron.right"
        case .usage: return "gauge.medium"
        case .mobile: return "iphone"
        }
    }

    /// The one-line description shown under the pane title in the detail header,
    /// matching macOS System Settings' navigation subtitle.
    var subtitle: String {
        switch self {
        case .general: return "The termio command-line tool"
        case .appearance: return "Terminal font, theme, cursor, and window"
        case .interface: return "The app's own sidebar font and density"
        case .terminal: return "Scrollback history and text selection"
        case .keyboard: return "Keyboard shortcuts for every command"
        case .agents: return "Agent presets, live status, and control"
        case .languages: return "Language servers for editor code navigation"
        case .usage: return "Token usage for your connected agents"
        case .mobile: return "Pair your iPhone and remote access"
        }
    }
}
