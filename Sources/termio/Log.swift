import OSLog

/// Unified-logging categories for the Mac app. One `Logger` per subsystem area,
/// so Console.app and the `log` CLI can filter first-class:
///
///     log stream --predicate 'subsystem == "com.termio.app" && category == "companion"'
///
/// The subsystem is taken from the bundle id at runtime rather than hardcoded,
/// so it always matches the app's real identity — and it auto-follows a future
/// bundle-id rename (the id is `com.termio.app` today; the brand domain is
/// termio.sh, so a deliberate rename to `sh.termio.app` is owed, with a
/// defaults-migration shim) without touching this file.
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
    static let companion = Logger(subsystem: subsystem, category: "companion")
    static let files = Logger(subsystem: subsystem, category: "files")
}
