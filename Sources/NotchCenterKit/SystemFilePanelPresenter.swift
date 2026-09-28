import AppKit

// MARK: - 系统文件面板的呈现收口

/// `NSOpenPanel` / `NSSavePanel` 的呈现收口。
///
/// 三条规矩缺一不可，全部在这个类型里做掉（每条都踩过，见
/// `docs/agents/面板与抽屉.md` 的「系统文件面板」一节）：
///
/// 1. **非模态**。`runModal()` 会阻塞主线程，抽屉的收起动画与悬停判定都推进不了，
///    面板悬在一个即将收起的抽屉上方；改用 `begin(completionHandler:)` 后主线程
///    继续跑，抽屉该收就收。
/// 2. **抬层级**。面板默认层级是 0（实测 `begin` 与 `runModal` 都是 0），低于抽屉
///    与块浮窗，会被自己的界面整个压住。经 `HostWindowLevel.auxiliary(above:)` 抬。
/// 3. **长寿命持有者**。`begin` 之后没人持有就会被销毁——调用方通常是抽屉里的设置
///    卡，卡片会随抽屉收起被拆掉，视图里的 `@State` 一释放面板就跟着消失。
@MainActor
public final class SystemFilePanelPresenter {
    public static let shared = SystemFilePanelPresenter()

    /// 正在等用户作答的面板（配置阶段之外由 AppKit 显示，没人持有就会被销毁）。
    private var activePanel: NSSavePanel?

    private init() {}

    /// 呈现一个系统文件面板。
    ///
    /// - Parameter anchor: 面板锚点所在的界面域，决定它被抬到哪一档层级。
    /// - Parameter onCompletion: 面板结束后的回调（主线程）。此时调用方所在的视图
    ///   可能早已消失，回调里只做「把结果写进模型」，不要依赖任何视图状态。
    ///
    /// 已经有一个面板在等用户作答时忽略本次调用——不叠第二个面板。
    public func present(
        _ panel: NSSavePanel,
        anchor: HostWindowLevel.Anchor,
        onCompletion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard activePanel == nil else { return }

        panel.level = HostWindowLevel.auxiliary(above: anchor)
        activePanel = panel
        panel.begin { [weak self] response in
            // 回调由 AppKit 在主线程上调用（`NSSavePanel` 的既定契约）。
            MainActor.assumeIsolated {
                self?.activePanel = nil
                onCompletion(response)
            }
        }
    }
}
