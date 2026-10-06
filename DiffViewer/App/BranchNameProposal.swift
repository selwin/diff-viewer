import Foundation

/// The name the branch picker offers for a new branch, from its search field's text.
enum BranchNameProposal {
    /// Search ignores whitespace; branch-name proposals replace whitespace runs with
    /// hyphens. Nil when the text is blank.
    static func make(from rawQuery: String) -> String? {
        let words = rawQuery.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: "-")
    }
}
