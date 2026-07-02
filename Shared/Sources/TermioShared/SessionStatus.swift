import SwiftUI

/// A session's live activity. The four states follow the desktop model
/// (see the main app's `Models.swift`): a finished turn is `done`, *not*
/// "needs you" — `needsAttention` is reserved for an agent actually blocked
/// on the user, keeping "ready for you" (calm) distinct from "waiting on
/// you" (urgent).
public enum SessionStatus: Hashable, Sendable {
    /// Nothing pending, or the user is already looking at the session.
    case idle
    /// The agent is actively processing a turn (shown as the spinning icon).
    case working
    /// The agent finished its turn while the user was elsewhere — a calm
    /// "ready for you" cue, not a demand.
    case done
    /// The agent is blocked waiting on the user (permission prompt, or a
    /// bell / desktop notification it raised).
    case needsAttention

    /// Sort rank for mobile lists: attention first, then working.
    public var rank: Int {
        switch self {
        case .needsAttention: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        }
    }
}

/// A small coloured dot trailing a session title: hidden when idle/working
/// (working is shown by the leading spinner instead), green when done,
/// orange when the session needs the user.
public struct StatusDot: View {
    let status: SessionStatus

    public init(status: SessionStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

/// The "agent is working" mark: a 3×3 grid of dots with a bright comet that
/// orbits the eight perimeter cells, so the small nine-square grid reads as
/// rotating. Sits in place of the session's brand icon while a turn is in
/// flight, tinted with the agent's brand color.
public struct WorkingIndicator: View {
    let tint: Color

    public init(tint: Color = .secondary) {
        self.tint = tint
    }

    /// The eight perimeter cells of the 3×3 grid in clockwise order, as
    /// `(column, row)` with the center at `(1, 1)`. The comet travels this ring.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]
    private let dotSize: CGFloat = 2.3
    private let spacing: CGFloat = 3.6
    private let period: Double = 1.1

    public var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            ZStack {
                // A faint steady center anchors the spinning ring.
                dot(opacity: 0.3)
                ForEach(Array(Self.ring.enumerated()), id: \.offset) { index, cell in
                    dot(opacity: opacity(at: index, phase: phase))
                        .offset(
                            x: CGFloat(cell.0 - 1) * spacing,
                            y: CGFloat(cell.1 - 1) * spacing
                        )
                }
            }
            .frame(width: 13, height: 13)
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(tint)
            .frame(width: dotSize, height: dotSize)
            .opacity(opacity)
    }

    /// Brightness of a perimeter cell: peaks at the comet's head and fades over
    /// the next few cells, measured the shorter way around so the tail wraps.
    private func opacity(at index: Int, phase: Double) -> Double {
        let count = Double(Self.ring.count)
        let head = phase * count
        let raw = abs(Double(index) - head)
        let distance = min(raw, count - raw)
        return max(0.22, 1 - distance / 3)
    }
}
