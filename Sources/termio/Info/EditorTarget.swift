import AppKit

/// An external editor termio can hand a file or folder to from the Info pane. The
/// catalog is a fixed set of well-known editors; only the ones actually installed
/// (resolved by bundle id) are offered, so the list configures itself — a machine
/// with VS Code and Zed shows exactly those two, with no setup UI to maintain.
struct EditorTarget: Identifiable, Hashable {
    let name: String
    /// The bundle identifier used to detect the app, launch it, and fetch its real
    /// icon. An editor whose id doesn't resolve is simply never shown, so a stale
    /// or wrong id degrades to "absent" rather than to a broken row.
    let bundleID: String

    var id: String { bundleID }

    /// The installed app's on-disk URL, or `nil` when the editor isn't present.
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The editor's real app icon (the `.icns` macOS shows in the Dock/Finder), so
    /// each row is unmistakably that app rather than a generic glyph. `nil` only if
    /// the app isn't installed — but callers render only installed targets.
    var appIcon: NSImage? {
        applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Every editor termio knows how to open, in display order. Kept deliberately
    /// short — the popular coding editors that open a folder or file cleanly from
    /// `NSWorkspace`.
    static let catalog: [EditorTarget] = [
        EditorTarget(name: "VS Code", bundleID: "com.microsoft.VSCode"),
        EditorTarget(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        EditorTarget(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        EditorTarget(name: "Zed", bundleID: "dev.zed.Zed"),
        EditorTarget(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        EditorTarget(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        EditorTarget(name: "Sublime Text", bundleID: "com.sublimetext.4"),
    ]

    /// The subset of the catalog installed on this machine, in catalog order.
    static var installed: [EditorTarget] {
        catalog.filter { $0.applicationURL != nil }
    }

    /// Opens `url` (a file or a folder) in this editor. A no-op if it isn't
    /// installed — the caller only ever renders installed targets, so this is a
    /// belt-and-braces guard against the app being removed mid-session.
    func open(_ url: URL) {
        guard let app = applicationURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
