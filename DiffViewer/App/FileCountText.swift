import Foundation

/// "1 file" or "N files"; used by the staging tray and directory captions.
enum FileCountText {
    static func make(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}
