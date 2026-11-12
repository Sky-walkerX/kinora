import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == CommandLine.arguments[1] {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, "layer", w[kCGWindowLayer as String]!, "onscreen", w[kCGWindowIsOnscreen as String] ?? false, "bounds", b["Width"] ?? 0, "x", b["Height"] ?? 0, "name", w[kCGWindowName as String] ?? "")
}
