import Foundation
import OSLog

/// Unified-logging categories for the Mac app. One `Logger` per subsystem area,
/// so Console.app and the `log` CLI can filter first-class:
///
///     log stream --predicate 'subsystem == "sh.termio.app" && category == "companion"'
///
/// The subsystem is taken from the bundle id at runtime rather than hardcoded, so
/// it always matches the app's real identity — release (`sh.termio.app`) or the
/// side-by-side dev build (`sh.termio.app.dev`), which lets `log stream` filter to
/// one channel.
///
/// Levels carry persistence semantics: `.debug` is memory-only (free in
/// release), `.info`/`.notice` are the default operational trail, and
/// `.error`/`.fault` are always persisted to disk. Interpolated values are
/// redacted by default — tag operational (non-sensitive) values `.public`;
/// never log the pairing token or anything that would grant access.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "sh.termio.app"
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let pty = Logger(subsystem: subsystem, category: "pty")
    static let termiod = Logger(subsystem: subsystem, category: "termiod")
    static let companion = Logger(subsystem: subsystem, category: "companion")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let issues = Logger(subsystem: subsystem, category: "issues")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let markdown = Logger(subsystem: subsystem, category: "markdown")
}

/// Timing for the paths a user waits on, in the same categories `Log` already
/// defines. Each span is an `os_signpost` interval — which is what Instruments'
/// os_signpost instrument and `xctrace` group by name — *and* a line carrying
/// `elapsed_ms`, so the numbers are readable without a trace running:
///
///     log show --last 5m --predicate 'subsystem BEGINSWITH "sh.termio" && category == "app"'
///
/// Instrumented paths are the ones with a user waiting on the other end. A span
/// that only ever reads sub-millisecond is noise and should be removed rather
/// than left to make the log harder to read.
struct Trace: Sendable {
    /// Switching the sidebar's scope: the gesture, the selection move it drags
    /// behind it, and the state write at the end.
    static let workspace = Trace(Log.app)
    /// Asking a device what is running on it, and landing the answer.
    static let device = Trace(Log.termiod)

    private let logger: Logger
    private let signposter: OSSignposter

    private init(_ logger: Logger) {
        self.logger = logger
        signposter = OSSignposter(logger: logger)
    }

    /// A span begun in one place and ended in another — a `defer` inside a
    /// property observer, where wrapping the body in a closure would reindent
    /// code that has nothing to do with measuring it.
    struct Span {
        let name: StaticString
        let state: OSSignpostIntervalState
        let started: ContinuousClock.Instant
    }

    func begin(_ name: StaticString) -> Span {
        Span(name: name,
             state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
             started: .now)
    }

    /// Ends `span`. `detail` is appended to the log line, never to the signpost
    /// name — the instrument groups by that name, so it has to stay constant.
    func end(_ span: Span, _ detail: String = "") {
        signposter.endInterval(span.name, span.state)
        report(span.name, detail, since: span.started)
    }

    /// Times `body` and reports it under `name`.
    @discardableResult
    func measure<Result>(
        _ name: StaticString,
        _ detail: @autoclosure () -> String = "",
        _ body: () throws -> Result
    ) rethrows -> Result {
        let span = begin(name)
        defer { end(span, detail()) }
        return try body()
    }

    /// Reports a span whose start was recorded elsewhere and whose two ends sit
    /// on different queues, so no interval can bracket it.
    func report(_ name: StaticString, _ detail: String = "", since started: ContinuousClock.Instant) {
        let label = "\(name)"
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        logger.info("""
        \(label, privacy: .public) \(detail, privacy: .public) \
        elapsed_ms=\(String(format: "%.2f", milliseconds), privacy: .public)
        """)
    }
}
