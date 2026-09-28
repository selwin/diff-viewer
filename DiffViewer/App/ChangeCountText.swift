import Foundation

/// How the commit picker says how many paths the working tree has changed.
enum ChangeCountText {
    static func make(_ count: Int) -> String {
        switch count {
        case 0: "No changes"
        case 1: "1 change"
        default: "\(count) changes"
        }
    }
}
