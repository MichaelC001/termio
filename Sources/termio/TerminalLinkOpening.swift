import AppKit
import Foundation
import GhosttyTerminal

extension Notification.Name {
    /// Posted when the user cmd-clicks a hyperlink (an OSC 8 link, or a URL/`file://` path
    /// libghostty auto-detected) inside a terminal surface. `object` is the `TerminalViewState`
    /// that fired it; `userInfo[TerminalLinkKey.url]` carries the raw link string. `TermioStore`
    /// observes this to route local files into the read-only preview overlay and web links to the
    /// system browser.
    static let termioTerminalOpenURL = Notification.Name("termio.terminalOpenURL")
}

enum TerminalLinkKey {
    static let url = "url"
}

// libghostty's `TerminalViewRepresentable` hardcodes the surface delegate to the `TerminalViewState`,
// and that state does not itself implement the open-URL delegate — so a cmd-click is dispatched by
// the callback bridge but lands nowhere. Conforming the state to the protocol here (retroactively,
// from termio's own module) makes the bridge's `delegate as? any TerminalSurfaceOpenURLDelegate`
// cast succeed at runtime, with no fork of the prebuilt library. The state has no back-reference to
// the store, so it republishes the event as a notification the store picks up (keyed by the state
// instance, whose published `workingDirectory` resolves any relative path).
extension TerminalViewState: @retroactive TerminalSurfaceOpenURLDelegate {
    public func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        NotificationCenter.default.post(
            name: .termioTerminalOpenURL,
            object: self,
            userInfo: [TerminalLinkKey.url: url]
        )
    }
}

// Same retroactive-conformance trick for hover feedback: the prebuilt library never touches
// `NSCursor` (its tracking area doesn't even request `.cursorUpdate`, so the terminal shows the
// plain arrow everywhere and ghostty's MOUSE_SHAPE action is dropped). ghostty does fire
// MouseOverLink as the hovered link changes, so we adopt that to swap in the pointing-hand cursor —
// the VS Code terminal feel — and restore the arrow when the link is left.
extension TerminalViewState: @retroactive TerminalSurfaceHoverLinkDelegate {
    public func terminalDidUpdateHoverLink(_ url: String?) {
        TerminalLinkCursor.setHoveringLink(url != nil)
    }
}

/// Drives the pointing-hand cursor while a terminal hyperlink is hovered. There is only one mouse
/// cursor, so the on/off state is a single main-actor flag: MouseOverLink fires only when the hovered
/// link *changes* (enter / leave / different link), so we push the cursor on the first non-nil and
/// pop it on the next nil — a guarded transition, never an unbalanced push/pop stack.
@MainActor
enum TerminalLinkCursor {
    private static var showingPointer = false

    static func setHoveringLink(_ hovering: Bool) {
        if hovering, !showingPointer {
            NSCursor.pointingHand.push()
            showingPointer = true
        } else if !hovering, showingPointer {
            NSCursor.pop()
            showingPointer = false
        }
    }
}
