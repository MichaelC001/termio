import TermioShared
import XCTest
@testable import termio

/// Pins the live-title sanitizer both platforms display through: what counts as
/// the animated status mark agents prefix their `OSC 0/2` title with, and what
/// is the title itself.
final class LiveTerminalTitleTests: XCTestCase {
    func testSpinnerFramesCollapseToOneTitle() {
        let frames = ["✳ Refactoring", "✻ Refactoring", "· Refactoring", "⁝ Refactoring"]
        XCTAssertEqual(Set(frames.map(LiveTerminalTitle.sanitized)), ["Refactoring"])
    }

    func testStripsLeadingRunAndWhitespace() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("  ✳ ·· Building the app  "), "Building the app")
    }

    /// Only the *leading* run goes: separators inside the title carry meaning
    /// (Pi reports `pi | 019fe98c | working`).
    func testKeepsInteriorPunctuation() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("· pi | 019fe98c | working"), "pi | 019fe98c | working")
    }

    /// Callers treat empty as "nothing to show" rather than blanking a good title.
    func testMarkOnlyTitleSanitizesToEmpty() {
        XCTAssertEqual(LiveTerminalTitle.sanitized(" ✳ "), "")
    }

    func testPlainTitleIsUnchanged() {
        XCTAssertEqual(LiveTerminalTitle.sanitized("termio — zsh"), "termio — zsh")
    }

    func testPromptTitleCollapsesFormattingAndWhitespace() {
        XCTAssertEqual(
            AgentPromptTitle.normalized("  ##  Refactor\n the   Codex\t integration  "),
            "Refactor the Codex integration")
    }

    func testPromptTitleIsBoundedAtAWordBoundary() {
        let title = AgentPromptTitle.normalized(
            "Refactor the Codex hook so Termio can show a useful automatic title in every sidebar session")

        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title?.count ?? .max, AgentPromptTitle.maximumLength)
        XCTAssertEqual(
            title, "Refactor the Codex hook so Termio can show a useful automatic…")
    }

    func testPromptTitleRejectsFormattingOnlyInput() {
        XCTAssertNil(AgentPromptTitle.normalized("  ## -- `  "))
    }

    func testAgentTitlePrecedence() {
        XCTAssertEqual(
            AgentSessionTitle.resolved(
                stored: "Codex", agentName: "Codex", native: "Native title",
                promptFallback: "Prompt title"),
            "Native title")
        XCTAssertEqual(
            AgentSessionTitle.resolved(
                stored: "Codex", agentName: "Codex", native: nil,
                promptFallback: "Prompt title"),
            "Prompt title")
        XCTAssertEqual(
            AgentSessionTitle.resolved(
                stored: "My name", agentName: "Codex", native: "Native title",
                promptFallback: "Prompt title"),
            "My name")
        XCTAssertEqual(
            AgentSessionTitle.resolved(
                stored: "Codex", agentName: "Codex", native: nil, promptFallback: nil),
            "Codex")
    }

    func testCodexHookForwardsToolAndPromptFields() {
        let hooks = AgentDefinition.codex.hookSpec
        XCTAssertEqual(hooks?.tool, "tool_name")
        XCTAssertEqual(hooks?.promptTitle, "prompt")
    }

    func testPromptTitlePersistsWithSession() throws {
        var session = Session(title: "Codex", agent: .codex)
        session.promptTitle = "Refactor Codex titles"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        XCTAssertEqual(decoded.promptTitle, "Refactor Codex titles")
    }
}
