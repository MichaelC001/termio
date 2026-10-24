import AppKit

/// Dev-only diagnostics behind the palette's "Debug: Snapshot Window": renders the
/// frontmost window into a PNG and dumps its view hierarchy with frames. Capturing its
/// own window needs no Screen Recording permission, so an automated session can
/// inspect a layout glitch it drove the app into.
enum DebugWindowSnapshot {
    /// Dev-only: lets an automated session trigger a capture without window focus —
    /// `swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("termio.dev.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)'`
    static func installTrigger() {
        // Selector-based registration so `.deliverImmediately` applies — the block API
        // suspends distributed notifications while the app is in the background, which
        // is exactly when an automated session needs this.
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.fire),
            name: Notification.Name("termio.dev.snapshot"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // @unchecked: stateless — it exists only as a selector target, and `fire`
    // hops to the main actor before touching anything.
    private final class Trigger: NSObject, @unchecked Sendable {
        static let shared = Trigger()
        @objc func fire(_ note: Notification) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DebugWindowSnapshot.capture() }
            }
        }
    }

    @MainActor
    static func capture() {
        guard let window = target() else { return }
        // The frame view (contentView's superview) includes the titlebar/toolbar chrome.
        let root = window.contentView?.superview ?? window.contentView
        guard let view = root else { return }

        // Scoped by channel because every dev-channel app on the machine answers the
        // same distributed notification; a probe build and the dev app would
        // otherwise overwrite each other's capture.
        let stem = "/tmp/termio\(AppChannel.suffix)"
        var lines: [String] = ["window frame=\(window.frame) key=\(window.isKeyWindow)"]
        dump(view, depth: 0, into: &lines)
        try? lines.joined(separator: "\n").write(
            toFile: stem + "-views.txt", atomically: true, encoding: .utf8)

        guard let rep = composited(window) ?? cached(view),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: stem + "-window.png"))
    }

    /// The window as the window server composited it: materials, glass and SwiftUI
    /// `Form` content included, which `cacheDisplay` leaves blank. A process may
    /// capture its own windows without Screen Recording permission. The function is
    /// marked unavailable in the macOS 15 SDK, so it is looked up at runtime.
    @MainActor
    private static func composited(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        guard let image = createImage(
            .null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution
        )?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    @MainActor
    private static func cached(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Which window a capture means: the frontmost ordinary window.
    ///
    /// It used to be the main window specifically, which made Settings —
    /// a second window, and the one most layout questions are about —
    /// unreachable: a capture driven while it was open returned the terminal
    /// behind it. Panels are skipped because the command palette is one, and it
    /// is *always* frontmost at the moment a palette action runs.
    @MainActor
    private static func target() -> NSWindow? {
        NSApp.orderedWindows.first {
            $0.isVisible && !($0 is NSPanel) && $0.contentView != nil
        }
        ?? NSApp.windows.first { $0.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName }
        ?? NSApp.mainWindow
    }

    @MainActor
    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var bits = "\(indent)\(type(of: view)) frame=\(view.frame)"
        if view.isHidden { bits += " HIDDEN" }
        if view.alphaValue < 1 { bits += " alpha=\(view.alphaValue)" }
        if let bg = view.layer?.backgroundColor, let c = NSColor(cgColor: bg), c.alphaComponent > 0 {
            bits += " bg=\(c)"
        }
        lines.append(bits)
        for sub in view.subviews {
            dump(sub, depth: depth + 1, into: &lines)
        }
    }
}
