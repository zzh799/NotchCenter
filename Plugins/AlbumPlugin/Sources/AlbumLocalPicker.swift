import AppKit
import NotchCenterKit
import UniformTypeIdentifiers

// MARK: - 本地文件 / 文件夹选择

/// 系统文件面板的调用收口。
///
/// 两件在这里必须做对的事（都踩过）：
///
/// 1. **不能用 `runModal()`**。模态循环会阻塞主线程，抽屉的收起动画与悬停判定都
///    推进不了，弹窗就悬在一个即将收起的抽屉上方——这是面板与抽屉领域文档的红线
///    （确认与提示要用内联浮窗）。文件面板没有内联替代品，所以改用 `begin` 的
///    **非模态**形态：主线程继续跑，抽屉该收就收，面板独立存在等用户作答。
/// 2. **必须抬层级**。`NSOpenPanel` 默认层级是 `NSModalPanelWindowLevel`（8），
///    而宿主抽屉面板在 `.statusBar`（25）、块浮窗在 `.statusBar + 2`（27）——
///    默认层级下文件面板会被我们自己的界面整个压住，点不到也看不见。
///    取 `.statusBar + 3`：正好高过上述两者，又低于菜单/Dock 层级（菜单位菜单
///    仍能正常盖在它上面）。
///
/// 面板还必须被**本类型**强引用着：设置卡会随抽屉收起被拆掉，视图里的 `@State`
/// 一释放，没人持有的面板会跟着消失。
@MainActor
final class AlbumLocalPicker {
    static let shared = AlbumLocalPicker()

    /// 正在显示的面板（配置阶段之外的面板由 AppKit 显示，但没人持有就会被销毁）。
    private var activePanel: NSOpenPanel?

    private init() {}

    /// 弹一个本地图片/文件夹选择面板。
    /// - Parameter choosingDirectory: true = 选文件夹（轮播），false = 选图片文件。
    /// - Parameter onPicked: 用户确认后的回调（主线程）。回调里只做"把 URL 写进模型"，
    ///   那时设置卡可能早已随抽屉收起而消失，所以不要依赖任何视图状态。
    func present(
        choosingDirectory: Bool,
        title: String,
        onPicked: @escaping (URL) -> Void
    ) {
        // 已经有一个在等用户作答：忽略重复触发，不叠第二个面板。
        guard activePanel == nil else { return }

        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = choosingDirectory
        panel.canChooseFiles = !choosingDirectory
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        if !choosingDirectory {
            panel.allowedContentTypes = [.image]
        }
        panel.level = .statusBar + 3

        activePanel = panel
        panel.begin { [weak self] response in
            // 回调由 AppKit 在主线程上调用（`NSSavePanel` 的既定契约）。
            let url = response == .OK ? panel.url : nil
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activePanel = nil
                if let url { onPicked(url) }
            }
        }
    }
}
