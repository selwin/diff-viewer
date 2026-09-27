import Foundation

/// Character-level changes within a modified line, so a one-letter typo highlights one
/// letter instead of difftastic's whole token.
enum CharacterDiff {
    /// Lines over this limit use the caller's fallback highlighting; this only bounds the Myers work.
    static let maxUTF16Length = 500
    /// Below this share of matched characters the line was rewritten, not edited, and
    /// scattered character matches would be noise.
    static let minimumSimilarity = 0.5

    /// Compares two lines grapheme by grapheme and returns the changed UTF-16 ranges per side.
    static func ranges(old: String, new: String, hideWhitespace: Bool) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.utf16.count <= maxUTF16Length, new.utf16.count <= maxUTF16Length else { return nil }
        // Diffing Characters keeps every multi-unit grapheme whole.
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var oldChanged = Array(repeating: true, count: oldCharacters.count)
        var newChanged = Array(repeating: true, count: newCharacters.count)
        var matchedContentCharacters = 0
        for case let .equal(o, n) in LineDiff.diff(oldCharacters, newCharacters) {
            oldChanged[o] = false
            newChanged[n] = false
            if !DiffAligner.isIgnorableWhitespace(oldCharacters[o]) { matchedContentCharacters += 1 }
        }

        // Whitespace is left out so deep indentation can't make a rewrite look similar.
        let totalContentCharacters =
            oldCharacters.count(where: { !DiffAligner.isIgnorableWhitespace($0) })
            + newCharacters.count(where: { !DiffAligner.isIgnorableWhitespace($0) })
        if totalContentCharacters > 0,
            Double(matchedContentCharacters * 2) / Double(totalContentCharacters) < minimumSimilarity
        {
            return nil
        }

        return (
            changedRanges(oldCharacters, flags: oldChanged, hideWhitespace: hideWhitespace),
            changedRanges(newCharacters, flags: newChanged, hideWhitespace: hideWhitespace)
        )
    }

    private static func changedRanges(_ chars: [Character], flags: [Bool], hideWhitespace: Bool) -> [Range<Int>] {
        var flags = snapWords(chars, flags: flags)
        if hideWhitespace {
            for i in chars.indices where DiffAligner.isIgnorableWhitespace(chars[i]) { flags[i] = false }
        }
        var result: [Range<Int>] = []
        var offset = 0
        for (char, changed) in zip(chars, flags) {
            let end = offset + char.utf16.count
            if changed {
                if let last = result.last, last.upperBound == offset {
                    result[result.count - 1] = last.lowerBound..<end
                } else {
                    result.append(offset..<end)
                }
            }
            offset = end
        }
        return result
    }

    /// Marks a mostly-changed word wholly changed; a few surviving letters inside a
    /// replaced word read as noise.
    private static func snapWords(_ chars: [Character], flags: [Bool]) -> [Bool] {
        var flags = flags
        var i = 0
        while i < chars.count {
            guard isWordCharacter(chars[i]) else {
                i += 1
                continue
            }
            var end = i
            var units = 0
            var changedUnits = 0
            while end < chars.count, isWordCharacter(chars[end]) {
                let count = chars[end].utf16.count
                units += count
                if flags[end] { changedUnits += count }
                end += 1
            }
            if changedUnits * 2 > units {
                for j in i..<end { flags[j] = true }
            }
            i = end
        }
        return flags
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
