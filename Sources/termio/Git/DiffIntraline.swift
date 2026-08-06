import Foundation

// MARK: - Intraline emphasis

/// Marks the changed spans inside a modified line pair (Critique's and Xcode's intraline
/// highlight).
///
/// The spans come from a word-level diff, not from stripping the pair's common prefix and
/// suffix: a line with two separate edits — `foo(a, b)` → `bar(a, c)` — has no common
/// middle to strip, so prefix/suffix stripping has to emphasize everything between the
/// first and last change and the reader learns nothing. Diffing the words finds both
/// edits and leaves `(a, ` alone.
///
/// Offsets are `Character` counts, matching `DiffRow.text`.
enum DiffIntraline {
    /// Longer lines are left plain rather than diffed — the pathological cases here are
    /// minified bundles and embedded data, where every span would be noise anyway.
    private static let maximumLineLength = 2000
    /// The word diff is quadratic in tokens. Past this many comparisons the pair falls
    /// back to one span per side covering everything between the first and last change,
    /// which is what prefix/suffix stripping produced before.
    private static let maximumComparisons = 4096

    /// The changed spans of a deletion/addition line pair, or `nil` when the two share so
    /// little that spans would be noise (a rewritten line reads better as a plain
    /// add/delete pair than as one line-long highlight).
    static func spans(old oldText: String, new newText: String)
        -> (old: [Range<Int>], new: [Range<Int>])? {
        guard oldText != newText,
              oldText.count <= maximumLineLength, newText.count <= maximumLineLength
        else { return nil }

        let oldTokens = tokenize(Array(oldText))
        let newTokens = tokenize(Array(newText))

        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count,
              oldTokens[prefix].text == newTokens[prefix].text {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].text
                == newTokens[newTokens.count - 1 - suffix].text {
            suffix += 1
        }

        let oldCore = Array(oldTokens[prefix..<(oldTokens.count - suffix)])
        let newCore = Array(newTokens[prefix..<(newTokens.count - suffix)])
        guard !oldCore.isEmpty || !newCore.isEmpty else { return nil }

        let changed: (old: [Bool], new: [Bool])
        if oldCore.count * newCore.count > maximumComparisons {
            changed = (Array(repeating: true, count: oldCore.count),
                       Array(repeating: true, count: newCore.count))
        } else {
            changed = changedTokens(oldCore, newCore)
        }

        let oldSpans = spans(of: oldCore, changed: changed.old)
        let newSpans = spans(of: newCore, changed: changed.new)

        // The same "too different to be worth marking" test the prefix/suffix pass used,
        // now measured on what the word diff actually kept: at least a fifth of the
        // shorter line must survive unchanged.
        let shorter = min(oldText.count, newText.count)
        let changedCharacters = max(oldSpans.reduce(0) { $0 + $1.count },
                                    newSpans.reduce(0) { $0 + $1.count })
        guard shorter == 0 || (shorter - min(changedCharacters, shorter)) * 5 >= shorter
        else { return nil }

        return (oldSpans, newSpans)
    }

    // MARK: Tokens

    /// One token and the character range it occupies in its line.
    private struct Token {
        let text: [Character]
        let range: Range<Int>
        let isBlank: Bool
    }

    /// Splits a line into word runs, whitespace runs, and single characters. CJK scripts
    /// have no intra-word boundaries, so each ideograph or kana is its own token rather
    /// than being swallowed into a run that would span the whole line.
    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let start = index
            let character = characters[index]
            if isWord(character) {
                while index < characters.count, isWord(characters[index]) { index += 1 }
            } else if character == " " || character == "\t" {
                while index < characters.count,
                      characters[index] == " " || characters[index] == "\t" { index += 1 }
            } else {
                index += 1
            }
            tokens.append(Token(text: Array(characters[start..<index]),
                                range: start..<index,
                                isBlank: character == " " || character == "\t"))
        }
        return tokens
    }

    private static func isWord(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber || character == "_" else { return false }
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value < 0x2E80
    }

    // MARK: Diff

    /// Which tokens on each side are outside the longest common subsequence.
    private static func changedTokens(_ old: [Token], _ new: [Token]) -> (old: [Bool], new: [Bool]) {
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1),
                            count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i][j] = old[i].text == new[j].text
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var oldChanged = Array(repeating: true, count: old.count)
        var newChanged = Array(repeating: true, count: new.count)
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i].text == new[j].text {
                oldChanged[i] = false
                newChanged[j] = false
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (oldChanged, newChanged)
    }

    /// Contiguous runs of changed tokens, as character ranges. Runs separated only by
    /// unchanged whitespace are joined: `a = 1` → `b = 2` reads better as one span than
    /// as two boxes with a gap.
    private static func spans(of tokens: [Token], changed: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        while index < tokens.count {
            guard changed[index] else { index += 1; continue }
            var end = index
            var probe = index
            while probe < tokens.count {
                if changed[probe] {
                    end = probe
                    probe += 1
                } else if tokens[probe].isBlank, probe + 1 < tokens.count, changed[probe + 1] {
                    probe += 1
                } else {
                    break
                }
            }
            // A span that opens or closes on whitespace would paint empty background at
            // its edge; trim it back to real content unless whitespace *is* the change
            // (an indent edit, where there is nothing else to mark).
            var first = index, last = end
            while first < last, tokens[first].isBlank { first += 1 }
            while last > first, tokens[last].isBlank { last -= 1 }
            result.append(tokens[first].range.lowerBound..<tokens[last].range.upperBound)
            index = end + 1
        }
        return result
    }
}
