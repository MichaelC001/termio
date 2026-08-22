import Foundation

/// When something was last typed into each session, from any device.
///
/// Input is a fact about the session, not about the connection that carried it.
/// The Mac and a phone hold separate attachments to one session, so a timestamp
/// kept on either attachment is invisible to the other — which is what let a
/// phone's typing read as agent output and promote an idle row to `working`.
///
/// Thread safety is this type's own, deliberately, because its two sides live
/// on different threads and always will: the status tap **reads it on the
/// daemon reader thread** (`TermiodSessionLink.onOutput`'s documented contract),
/// while writes arrive on the main actor and from the companion's bridge. Making
/// it main-actor state and reading it from the tap would be a data race dressed
/// up as a lookup — the compiler cannot catch it because the read happens inside
/// an escaping closure the tap owns.
final class SessionInputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Session.ID: Date] = [:]

    /// Records that something was typed into a session, now.
    func note(_ id: Session.ID) {
        lock.lock()
        stamps[id] = Date()
        lock.unlock()
    }

    /// When this session was last typed into, or `nil` if it never was.
    func lastInput(for id: Session.ID) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return stamps[id]
    }

    /// Drops a session's entry once it is gone, so a long-lived app does not
    /// accumulate a stamp per session it has ever opened.
    func forget(_ id: Session.ID) {
        lock.lock()
        stamps.removeValue(forKey: id)
        lock.unlock()
    }

    /// Test seam: whether anything is recorded at all.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stamps.isEmpty
    }
}
