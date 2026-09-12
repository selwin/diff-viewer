import CoreGraphics
import Foundation
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DiffViewer"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == name && (w["kCGWindowLayer"] as? Int) == 0 {
    print(w["kCGWindowNumber"] as! Int)
    exit(0)
}
exit(1)
