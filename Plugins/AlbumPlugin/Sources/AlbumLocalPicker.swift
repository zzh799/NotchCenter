import AppKit
import NotchCenterKit
import UniformTypeIdentifiers

// MARK: - 本地文件 / 文件夹选择

/// 相册设置卡里的「选文件夹 / 选图片」入口。
///
/// 三条规矩（非模态 + 抬层级 + 长寿命持有者）全在 `SystemFilePanelPresenter` 里，
/// 本类型只负责按块类型把面板配好。面板被收起抽屉拆掉也不怕——持有者在 Kit 的
/// 收口单例上，不在视图里。
@MainActor
final class AlbumLocalPicker {
    static let shared = AlbumLocalPicker()

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
        // 锚点在抽屉里的块设置卡：抬到抽屉域之上（抽屉 25 / 块浮窗 27）。
        SystemFilePanelPresenter.shared.present(panel, anchor: .drawer) { response in
            guard response == .OK, let url = panel.url else { return }
            onPicked(url)
        }
    }
}
