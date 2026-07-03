import Foundation

/// Frecency-ranked memory of what the user has sent from this phone — the
/// highest-hit-rate completion source on mobile (Termius's Helium engine and
/// Happy both lead with history), because phone sessions mostly re-send
/// yesterday's prompts. Local-only and zero-latency by design: it never
/// consults the Mac, so the suggestion panel can never show a spinner.
///
/// Scope is deliberately narrow: only prompts sent through the composer on
/// this device. The Mac's shell history stays on the Mac (a future wire
/// completion source, not this store's job).
final class PromptHistory {
    static let shared = PromptHistory()

    private struct Entry: Codable {
        var text: String
        var count: Int
        var lastUsed: Date
    }

    private static let defaultsKey = "composer.promptHistory"
    private static let capacity = 200
    /// Frecency half-life: an entry's score halves every week it goes unused,
    /// so stale commands sink without ever needing manual cleanup.
    private static let halfLifeDays = 7.0

    private let defaults: UserDefaults
    private var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Records one sent prompt: repeats bump the counter, new text appends.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        if let index = entries.firstIndex(where: { $0.text == trimmed }) {
            entries[index].count += 1
            entries[index].lastUsed = Date()
        } else {
            entries.append(Entry(text: trimmed, count: 1, lastUsed: Date()))
        }
        if entries.count > Self.capacity {
            // Evict by the same score users see, not raw age.
            entries.sort { score($0) > score($1) }
            entries.removeLast(entries.count - Self.capacity)
        }
        save()
    }

    /// Top matches for the draft, prefix hits ranked ahead of substring hits,
    /// frecency within each tier. The draft itself is excluded — suggesting
    /// exactly what's already typed helps no one.
    func matches(for query: String, limit: Int) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var prefix: [Entry] = []
        var substring: [Entry] = []
        for entry in entries where entry.text != query {
            let haystack = entry.text.lowercased()
            if haystack.hasPrefix(needle) {
                prefix.append(entry)
            } else if haystack.contains(needle) {
                substring.append(entry)
            }
        }
        let ranked = prefix.sorted { score($0) > score($1) }
            + substring.sorted { score($0) > score($1) }
        return ranked.prefix(limit).map(\.text)
    }

    /// Long-press delete on a suggestion row.
    func remove(_ text: String) {
        entries.removeAll { $0.text == text }
        save()
    }

    private func score(_ entry: Entry) -> Double {
        let ageDays = max(0, -entry.lastUsed.timeIntervalSinceNow / 86400)
        return Double(entry.count) * pow(0.5, ageDays / Self.halfLifeDays)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.defaultsKey)
    }
}
