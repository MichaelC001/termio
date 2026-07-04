import Foundation

/// Shared reconnect backoff for the two companion links (roster + terminal).
///
/// The two outages look identical to a dead socket but want opposite handling:
/// a Mac app rebuild or Wi-Fi blip clears in seconds (retry fast, notice the
/// instant it's back), while a **closed laptop** can be gone for hours (stop
/// hammering the radio). So the cadence is tiered — a fast burst for the first
/// ~30s, then a slow 30s steady-state heartbeat — rather than the old
/// retry-every-6s-forever loop.
///
/// It never gives up: a companion link self-heals instead of dead-ending in a
/// "disconnected" state that needs a manual tap. The event-driven wakeups
/// (app foreground, network path returning) are the *real* reconnect triggers
/// — they call `reset()` to drop back to the fast burst — and this backoff is
/// just the fallback for the case events miss (lid reopened on the same Wi-Fi
/// while the app is already foreground).
struct ReconnectPolicy {
    /// Failed attempts since the last `reset()`. Exposed for logging/tests.
    private(set) var attempts = 0

    /// The next backoff delay in seconds, with ±20% jitter, advancing the
    /// attempt counter. `0.5 → 1 → 2 → 4 → 5` for the first six tries (~17s of
    /// failure), then a flat 30s heartbeat once the Mac is probably asleep, not
    /// rebuilding.
    mutating func nextDelay(ceiling: Double = 30, jitter: ClosedRange<Double> = 0.8...1.2) -> Double {
        attempts += 1
        let base = attempts <= 6
            ? min(0.5 * pow(2.0, Double(attempts - 1)), 5)
            : ceiling
        return base * .random(in: jitter)
    }

    /// Back to the fast burst — called when an event says the Mac is likely
    /// reachable again (foreground, network path up, a manual "Try Again").
    mutating func reset() {
        attempts = 0
    }
}
