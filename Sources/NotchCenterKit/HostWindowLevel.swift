import AppKit

// MARK: - 宿主界面层级阶梯

/// 本程序所有窗口所在层级的唯一真源。
///
/// **为什么要有这个类型**：宿主的面板刻意压在系统常规窗层之上（抽屉要盖住其他
/// 应用的窗口），而系统出品的辅助窗口默认层级极低。层级是**全局排序**——低层级
/// 窗口永远渲染在高层级窗口之下，与谁是 key、谁后 `orderFront` 都无关。于是
/// 「从自己的界面里弹一个系统窗口」只要忘了抬层级，就会被自己的界面整个压住，
/// 用户看到的是「点了没反应」。相册插件的本地文件选择面板就栽在这里（默认 0，
/// 而抽屉 25、浮窗 27）。
///
/// 所以层级不再逐处手挑字面量：新窗口一律从本类型的阶梯取名；**不由我们创建、
/// 层级也不由我们决定**的系统窗口（`NSOpenPanel` / `NSAlert` / `QLPreviewPanel`），
/// 呈现前必须经 `auxiliary(above:)` 抬到对应域之上。
///
/// 递增不变量（`HostWindowLevelTests` 守）：
/// `drawer < popover < drawerAuxiliary < utility < utilityAuxiliary < dragPreview
/// < effectOverlay`。
public enum HostWindowLevel {
    /// 抽屉面板与紧凑热区面板（`.statusBar`，25）。
    public static let drawer = NSWindow.Level.statusBar

    /// 抽屉域内的浮窗：块浮窗与设置浮窗（`.statusBar + 2`，27）。
    public static let popover = NSWindow.Level.statusBar + 2

    /// 抽屉域内的**系统辅助窗口**：文件选择面板、Quick Look 等（`.statusBar + 3`，28）。
    /// 恰好在抽屉与浮窗之上、系统弹出菜单（101 层）之下——系统菜单仍能正常盖在它上面。
    public static let drawerAuxiliary = NSWindow.Level.statusBar + 3

    /// 设置窗口与权限引导窗口（`popUpMenuWindow`，101）。
    public static let utility = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))

    /// 设置域内的**系统辅助窗口与模态确认**（102）。
    ///
    /// 低于 `dragPreview` 是刻意的：拖拽预览只存在于拖动块的过程中，而拖拽期间
    /// 不可能去设置窗点安装/停用，两者不会同时在场，无须为了压过它而抬到更高。
    public static let utilityAuxiliary = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1
    )

    /// 拖拽预览面板（103）。
    public static let dragPreview = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2
    )

    /// 全屏效果覆盖层（合盖透视等）：屏保层下一档（999），只低于屏保本身。
    public static let effectOverlay = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1
    )
}

// MARK: - 系统辅助窗口的层级推导

extension HostWindowLevel {
    /// 系统辅助窗口（文件面板 / `NSAlert` / Quick Look）的锚点所在的界面域。
    ///
    /// 判定只看**域**，不看锚点窗口此刻的具体层级：抽屉域（抽屉、块浮窗）内弹的
    /// 抬到 `drawerAuxiliary`，设置域（设置窗、权限引导窗、拖拽预览）内弹的抬到
    /// `utilityAuxiliary`。
    public enum Anchor: Sendable {
        /// 锚点在抽屉 / 块浮窗等 `.statusBar` 域的界面上。
        case drawer
        /// 锚点在设置窗 / 权限引导窗等 `popUpMenuWindow` 域的界面上。
        case utility
    }

    /// 系统辅助窗口应当被抬到的层级：严格高于该域内的全部宿主界面。
    public static func auxiliary(above anchor: Anchor) -> NSWindow.Level {
        switch anchor {
        case .drawer: return drawerAuxiliary
        case .utility: return utilityAuxiliary
        }
    }
}
