import Foundation
import Observation
import TermioShared

/// Per-session live state that changes at agent-tick frequency: the agent's
/// status, the tool it is running, its live `OSC 0/2` title, and the shell's
/// working directory.
///
/// These four fields used to be `@Published` dictionaries on `TermioStore`. That
/// made them share the store's single `objectWillChange`, so one session's status
/// flipping (which happens several times a second while an agent works) invalidated
/// *every* view holding the store — the whole sidebar tree rebuilt on each tick,
/// which is what made scrolling stutter once a few projects were open.
///
/// Splitting them into a per-session `@Observable` fixes that at the root: a
/// `SessionRow` that reads `runtime.status` takes an Observation dependency on *that
/// session's* runtime alone, so a status change re-renders only the owning row and
/// never touches the container or its siblings. The store keeps its `ObservableObject`
/// role for the structural spine (projects, selection, overlays); only this
/// high-frequency state lives here, one object per session.
@MainActor
@Observable
final class SessionRuntime {
    /// Live status, driven by agent hooks / screen detection (see `TermioStore+AgentStatus`).
    var status: SessionStatus = .idle
    /// The tool a `.working` session is currently running (`PreToolUse.tool_name`),
    /// shown in the status tooltip; `nil` once the turn ends.
    var currentTool: String?
    /// The running program's live terminal title (`OSC 0/2`), used as an agent
    /// session's display label so two sessions of the same agent stay distinguishable.
    var liveTitle: String?
    /// The live working directory (shell `OSC 7`); for loose terminals this *is* the
    /// entity's path — it labels the row and roots the inspector.
    var workingDirectory: String?
    /// The row's second line while a declared agent has exited but its wrapped
    /// login shell survives ("Claude Code exited — shell"). Set by the
    /// foreground-demotion streak (RFC 20260830 §D2), cleared the moment the
    /// foreground stops being the shell or the agent reports working again.
    var agentExitNotice: String?
    /// The PTY's real grid, from the daemon: the viewport of whichever screen a
    /// person is in front of. The bytes on the wire are wrapped for it, and the
    /// only faithful way to show them is a surface laid out at it — letterboxed
    /// in the pane, not stretched to the window (§C.5 of the session protocol).
    /// Not read together with `isWriter` any more: under a size policy the pane
    /// holding the write token is letterboxed too whenever the session is sized
    /// to somebody else's screen.
    var sharedGrid: TerminalGrid?
    /// Whether this pane's own viewport change is still in flight.
    ///
    /// The letterbox reads it, and it is the difference between the two reasons
    /// the session's grid can differ from the pane's. Somebody else is using the
    /// session on a smaller screen: letterbox, or this pane re-wraps bytes that
    /// were wrapped for theirs (§C.5). *This* pane was just resized and the
    /// daemon has not answered yet: letterboxing there pins the screen to the
    /// width the drag started at and slides it around inside the growing pane,
    /// which is what a window drag looked like. Under a size policy that follows
    /// the device being used, an in-flight change of this pane's own is a
    /// resize that is about to be granted — so the surface follows the pane, the
    /// way it would in a terminal with no host at all, and the keyframe at the
    /// end is what everyone converges on.
    var viewportPending = false
}
