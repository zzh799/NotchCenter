import AppKit
import CoreGraphics

/// 屏幕查询的小工具。上游 Mac-Duo 把这两个放在 `ScreenSnapshotter.swift` 里,
/// 这里拆出来,因为抓帧与实时流都要用。
extension NSScreen {

    /// 这块屏的 `CGDirectDisplayID`。
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 内置屏;只接了外接屏时返回 nil。
    ///
    /// 效果只作用于内置屏——合盖时能看见的就是它。
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}
