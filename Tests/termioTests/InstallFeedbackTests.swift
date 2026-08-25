import XCTest
@testable import termio

/// The line a Settings install button shows after it runs. The rule that matters:
/// anything that didn't land has to be visible and has to stay visible, so a
/// half-installed set of hooks can never read as a clean success.
final class InstallFeedbackTests: XCTestCase {
    private func outcome(succeeded: [String] = [], failed: [String] = []) -> InstallOutcome {
        var outcome = InstallOutcome()
        for name in succeeded { outcome.record(name, installed: true) }
        for name in failed { outcome.record(name, installed: false) }
        return outcome
    }

    func testNamesEveryTargetItReached() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code", "Codex", "Cursor"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .success)
        XCTAssertEqual(feedback.message, "Hooks reinstalled — Claude Code, Codex and Cursor.")
    }

    /// Past three the names would wrap the row, so the line counts instead.
    func testCountsBeyondThreeTargets() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["A", "B", "C", "D"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.message, "Hooks reinstalled — 4 agents.")
    }

    /// A partial install is a failure: it stays on screen, because the half that
    /// didn't land is the half the user has to deal with.
    func testPartialInstallReportsAsFailure() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code"], failed: ["Codex"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(
            feedback.message, "Hooks reinstalled — Claude Code. Couldn’t update Codex.")
    }

    func testTotalFailureNamesOnlyWhatFailed() {
        let feedback = InstallFeedback.summarizing(
            outcome(failed: ["~/.claude/CLAUDE.md"]),
            headline: "Note reinstalled", unit: "files")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Couldn’t update ~/.claude/CLAUDE.md.")
    }

    /// Nothing attempted is not a success — silence is what this feedback exists
    /// to eliminate.
    func testEmptyOutcomeIsNotASuccess() {
        let feedback = InstallFeedback.summarizing(
            outcome(), headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Nothing to install.")
    }

    /// Re-running the same action must restart the dismissal timer, which is keyed
    /// on the state's identity — so two identical messages must not compare equal.
    func testRepeatedShowChangesIdentity() {
        var state = InstallFeedbackState()
        state.show(.success("Installed."))
        let first = state
        state.show(.success("Installed."))
        XCTAssertNotEqual(first, state)
    }
}

/// Hooks and the skill are two installs the user asked for with one click, so
/// they are reported as one line. What that line may not do is round a mixed
/// result up: an agent that took its hook and refused the skill is not installed.
final class InstallOutcomeMergeTests: XCTestCase {
    private func outcome(succeeded: [String], failed: [String] = []) -> InstallOutcome {
        var result = InstallOutcome()
        for name in succeeded { result.record(name, installed: true) }
        for name in failed { result.record(name, installed: false) }
        return result
    }

    func testAnAgentThatTookBothIsNamedOnce() {
        let merged = outcome(succeeded: ["Claude Code", "Codex"])
            .merged(with: outcome(succeeded: ["Claude Code", "Codex"]))
        XCTAssertEqual(merged.succeeded, ["Claude Code", "Codex"])
        XCTAssertTrue(merged.failed.isEmpty)
    }

    func testRefusingEitherHalfCountsAsRefused() {
        let merged = outcome(succeeded: ["Claude Code", "Codex"])
            .merged(with: outcome(succeeded: ["Codex"], failed: ["Claude Code"]))
        XCTAssertEqual(merged.succeeded, ["Codex"])
        XCTAssertEqual(merged.failed, ["Claude Code"])
    }

    func testNothingToInstallStaysEmpty() {
        XCTAssertTrue(InstallOutcome().merged(with: InstallOutcome()).isEmpty)
    }
}
