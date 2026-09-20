import Foundation

/// The sidebar's text for a binary file's byte counts. No SwiftUI: the view picks
/// colour and layout from `kind`, and the strings are testable on their own.
enum BinaryChurnText {
    enum ChangeKind {
        case added, deleted, grown, shrunk, sameSize
    }

    struct Presentation: Equatable {
        let kind: ChangeKind
        /// "+4 kB" for an addition, "−4 kB" for a deletion, the new size otherwise.
        let primaryText: String
        /// The signed byte delta, or nil unless the file grew or shrank.
        let deltaText: String?
        /// Exact grouped byte counts for the tooltip.
        let helpText: String
    }

    /// Nil when both sides are absent.
    static func presentation(for sizes: BinarySizes, locale: Locale) -> Presentation? {
        switch (sizes.oldByteCount, sizes.newByteCount) {
        case (nil, nil):
            return nil
        case let (nil, new?):
            return Presentation(
                kind: .added,
                primaryText: plus + FileSizeText.string(new, locale: locale),
                deltaText: nil,
                helpText: "Added, \(bytes(new, locale))"
            )
        case let (old?, nil):
            return Presentation(
                kind: .deleted,
                primaryText: minus + FileSizeText.string(old, locale: locale),
                deltaText: nil,
                helpText: "Deleted, \(bytes(old, locale))"
            )
        case let (old?, new?):
            // Compared before rounding, so a 1-byte change never reads as the same size.
            let delta = new - old
            if delta == 0 {
                return Presentation(
                    kind: .sameSize,
                    primaryText: FileSizeText.string(new, locale: locale),
                    deltaText: nil,
                    helpText: "\(bytes(new, locale)), size unchanged"
                )
            }
            return Presentation(
                kind: delta > 0 ? .grown : .shrunk,
                primaryText: FileSizeText.string(new, locale: locale),
                deltaText: (delta > 0 ? plus : minus) + FileSizeText.string(abs(delta), locale: locale),
                helpText: "\(bytes(old, locale)) → \(bytes(new, locale))"
            )
        }
    }

    private static let plus = "+"
    /// U+2212, the minus the line counts use; the formatter's own negatives vary by locale.
    private static let minus = "−"

    /// Exact grouped count: "1 byte", "12,345 bytes".
    private static func bytes(_ count: Int64, _ locale: Locale) -> String {
        let number = count.formatted(IntegerFormatStyle<Int64>().locale(locale))
        return count == 1 ? "\(number) byte" : "\(number) bytes"
    }
}
