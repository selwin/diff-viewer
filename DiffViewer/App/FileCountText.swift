import Foundation

/// "1 file" or "N files"; the staging tray and the selection popover share it.
enum FileCountText {
    static func make(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}
