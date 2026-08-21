import AppKit
import XCTest
@testable import termio

/// The `OSC 0/2` title as a status channel. It is the only signal that survives
/// when hooks are silent and the host reports nothing, so what it must not do is
/// go quiet on its own while the agent is still working.
@MainActor
final class AgentTitleStatusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The attention arms ask whether the user is looking, which reads `NSApp`.
        _ = NSApplication.shared
    }

    private func makeStore(with session: Session) -> TermioStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "agent-title-status-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    /// Every frame of a ticking title spinner is evidence the turn is still
    /// running. They collapse to a no-op at the transition guard, so if only the
    /// first one refreshed the liveness clock, `sweepStaleWorking` cleared the
    /// spinner 12s into a live turn — and the latch then stopped any later frame
    /// from raising it again, so the row stayed calm until the agent finished.
    func testEveryWorkingTitleFrameRefreshesLiveness() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)

        store.applyTitleActivity(.working, for: session.id)
        XCTAssertEqual(store.status(for: session.id), .working)

        // Stand in for a turn that has been running long enough for the sweep to
        // be interested, then let the agent tick its spinner once more.
        let stale = Date(timeIntervalSinceNow: -60)
        store.lastWorkingAt[session.id] = stale
        store.applyTitleActivity(.working, for: session.id)

        let refreshed = try? XCTUnwrap(store.lastWorkingAt[session.id])
        XCTAssertGreaterThan(refreshed ?? stale, stale)
    }

    /// The other direction still has to work: a title that calms is how a turn
    /// ends without a `Stop` hook.
    func testACalmTitleEndsTheTurn() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)

        store.applyTitleActivity(.working, for: session.id)
        store.applyTitleActivity(.idle, for: session.id)

        XCTAssertNotEqual(store.status(for: session.id), .working)
        XCTAssertNil(store.lastWorkingAt[session.id])
    }

    /// Claude Code ships two spinner alphabets: braille through 2.1.227, and the
    /// half-circles it switched to in 2.1.228. Matching only the first meant the
    /// title channel went silent the day a user updated.
    func testClaudeTitleRulesReadBothSpinnerAlphabets() throws {
        let rules = try XCTUnwrap(AgentDefinition.claudeCode.titleRules)

        for frame in ["⠋", "⠙", "⠹", "◐", "◑", "◒", "◓"] {
            XCTAssertEqual(rules.explain("\(frame) Fix the resize bug").activity, .working,
                           "\(frame) should read as working")
        }
        XCTAssertEqual(rules.explain("✳ Fix the resize bug").activity, .idle)
    }
}
