import Foundation

/// Rounded byte counts shared by the sidebar and the image preview captions.
enum FileSizeText {
    /// Finder-style rounded size of a non-negative count: "300 bytes", "4 kB", "1.2 MB".
    static func string(_ count: Int64, locale: Locale) -> String {
        count.formatted(
            ByteCountFormatStyle(
                style: .file,
                allowedUnits: .all,
                spellsOutZero: false,
                includesActualByteCount: false,
                locale: locale
            )
        )
    }
}
