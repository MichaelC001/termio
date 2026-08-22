import Darwin
import XCTest
@testable import termio

/// Naming the program in the foreground of a PTY, pinned at both levels: the
/// selection rule on its own, and the real kernel case it exists for — a
/// pipeline that outlives the process its group is named after.
final class PTYForegroundTests: XCTestCase {
    private func live(_ pid: pid_t, group: pid_t = 100) -> PTYProcess.ForegroundGroupMember {
        PTYProcess.ForegroundGroupMember(pid: pid, liveness: .live, processGroup: group)
    }

    private func dead(_ pid: pid_t, group: pid_t = 100) -> PTYProcess.ForegroundGroupMember {
        PTYProcess.ForegroundGroupMember(pid: pid, liveness: .dead, processGroup: group)
    }

    /// Stand-in for the argv sysctl that also records the order it was probed in —
    /// the cost the closure exists to bound.
    private func reader(answering: [pid_t]) -> (read: (pid_t) -> [String]?, probed: () -> [pid_t]) {
        let probed = Probed()
        return ({ pid in
            probed.record(pid)
            return answering.contains(pid) ? ["command-\(pid)"] : nil
        }, { probed.pids })
    }

    private final class Probed {
        private(set) var pids: [pid_t] = []
        func record(_ pid: pid_t) { pids.append(pid) }
    }

    /// The ordinary case: one command, alive, named after itself. Nothing else is
    /// even probed.
    func testPrefersTheGroupLeaderWhileItIsUsable() {
        let (read, probed) = reader(answering: [100, 101])
        let arguments = PTYProcess.foregroundArguments(
            group: 100, members: [live(100), live(101)], read: read)
        XCTAssertEqual(arguments, ["command-100"])
        XCTAssertEqual(probed(), [100])
    }

    /// `sleep 60 | cat`: the leader finishes first and sits zombied — or reaped
    /// outright, in which case the kernel does not enumerate it at all — while the
    /// later stage is still the program the user is talking to.
    func testFallsBackToALiveMemberWhenTheLeaderIsGone() {
        let (zombieRead, _) = reader(answering: [103])
        XCTAssertEqual(
            PTYProcess.foregroundArguments(
                group: 100, members: [dead(100), live(103)], read: zombieRead),
            ["command-103"])

        let (reapedRead, probed) = reader(answering: [103])
        XCTAssertEqual(
            PTYProcess.foregroundArguments(group: 100, members: [live(103)], read: reapedRead),
            ["command-103"])
        XCTAssertEqual(probed(), [103], "a dead leader must not cost an argv read")
    }

    /// A leader that is alive but caught between fork and exec has no argv yet.
    /// Preferring it would report nothing while a sibling can answer.
    func testSkipsALiveLeaderWithNoArguments() {
        let (read, probed) = reader(answering: [104])
        XCTAssertEqual(
            PTYProcess.foregroundArguments(
                group: 100, members: [live(100), live(104)], read: read),
            ["command-104"])
        XCTAssertEqual(probed(), [100, 104], "the leader is tried first, then the rest in order")
    }

    /// Stable, not merely correct: two survivors must not take turns being the
    /// answer, or the pane would rename itself on every poll for no new reason.
    func testPicksTheSameSurvivorEveryTime() {
        let (ascending, _) = reader(answering: [105, 107])
        XCTAssertEqual(
            PTYProcess.foregroundArguments(
                group: 100, members: [live(107), live(105)], read: ascending),
            ["command-105"])
        let (descending, _) = reader(answering: [105, 107])
        XCTAssertEqual(
            PTYProcess.foregroundArguments(
                group: 100, members: [live(105), live(107)], read: descending),
            ["command-105"])
    }

    func testRefusesAGroupWithNobodyLeftInIt() {
        let (empty, _) = reader(answering: [])
        XCTAssertNil(PTYProcess.foregroundArguments(group: 100, members: [], read: empty))

        let (allDead, probed) = reader(answering: [100, 103])
        XCTAssertNil(
            PTYProcess.foregroundArguments(
                group: 100, members: [dead(100), dead(103)], read: allDead))
        XCTAssertTrue(probed().isEmpty, "a dead group must not cost an argv read")
    }

    /// The membership check is what keeps a recycled pid out of the answer: a pid
    /// that has since moved into another group is not the process we were asked
    /// about, whatever its number is.
    func testIgnoresProcessesFromAnotherGroup() {
        let (read, probed) = reader(answering: [100])
        XCTAssertNil(
            PTYProcess.foregroundArguments(
                group: 100, members: [live(100, group: 200)], read: read))
        XCTAssertTrue(probed().isEmpty)
    }

    func testRefusesAGroupThatIsNotAGroup() {
        let (read, _) = reader(answering: [0])
        XCTAssertNil(PTYProcess.foregroundArguments(group: 0, members: [live(0)], read: read))
        XCTAssertNil(PTYProcess.foregroundArguments(group: -1, members: [], read: read))
    }

    /// The case the search exists for, against the real kernel: an interactive
    /// shell runs `sleep … | cat`, whose two stages share one process group named
    /// after `sleep`. Reading the pgid directly names the pipeline while `sleep`
    /// lives and goes silent the instant it exits — with `cat` still holding the
    /// terminal.
    func testNamesAPipelineWhoseLeaderHasExited() throws {
        let shell = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw XCTSkip("no \(shell) on this host")
        }
        // `-f` skips the user's startup files (a slow rc would race the poll);
        // `-i` is what turns job control on, without which the pipeline would run
        // in the shell's own group and never show the split.
        guard let pty = PTYProcess(
            argv: [shell, "-f", "-i"], cwd: "/",
            env: ["TERM": "xterm-256color", "PS1": "$ "], cols: 80, rows: 24)
        else {
            XCTFail("could not spawn \(shell) on a PTY")
            return
        }
        defer { pty.terminate() }

        // `cat /dev/tty` rather than a bare `cat`: it is the same pipeline shape,
        // but it reads the terminal instead of the pipe, so it stays put after the
        // leader exits rather than following it out on EOF.
        XCTAssertTrue(waitForPrompt(pty), "the shell never reached a prompt")
        pty.write(Data("sleep 1 | cat /dev/tty\n".utf8))

        let named = try XCTUnwrap(
            waitForForeground(pty) { $0.first?.hasSuffix("sleep") == true },
            "the pipeline was never named while its leader ran")
        XCTAssertEqual(named, ["sleep", "1"])

        let survivor = try XCTUnwrap(
            waitForForeground(pty) { $0.first?.hasSuffix("cat") == true },
            "the foreground job lost its name when the group leader exited")
        XCTAssertEqual(survivor, ["cat", "/dev/tty"])
        XCTAssertTrue(pty.hasForegroundJob, "the survivor still holds the terminal")
    }

    /// The shell has to have claimed the tty before a typed command can reach it;
    /// until then `tcgetpgrp` still names the spawn.
    private func waitForPrompt(_ pty: PTYProcess) -> Bool {
        waitUntil(seconds: 5) { pty.foregroundProcessArguments()?.first?.hasSuffix("zsh") == true }
    }

    private func waitForForeground(
        _ pty: PTYProcess, matching: ([String]) -> Bool
    ) -> [String]? {
        var seen: [String]?
        _ = waitUntil(seconds: 5) {
            guard let arguments = pty.foregroundProcessArguments(), matching(arguments) else {
                return false
            }
            seen = arguments
            return true
        }
        return seen
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}
