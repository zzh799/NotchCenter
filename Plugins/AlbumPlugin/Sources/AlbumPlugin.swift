import NotchCenterKit
import SwiftUI

// MARK: - AlbumPlugin（官方「相册」插件）

/// 两个抽屉块：文件夹/相册轮播与单张照片。来源可以是本地文件夹/图片，也可以是
/// 照片图库里的相册/某一张；图库来源经宿主「权限管理」通道要授权，缺权限只降级
/// 呈现。本插件只读——不复制、不移动、不删除、不改写用户原图，也不上传任何内容。
/// 决策与取舍见 docs/agent-notes/implemented/2026-09-28-album-plugin.md。
@objc(AlbumPlugin) @MainActor
public final class AlbumPlugin: NSObject, NotchCenterPlugin, NotchCenterPluginServices {
    private var stateStore: StateStore?

    public override init() { super.init() }

    /// 打包期最小尺寸遮挡校验探针：图片区是块内唯一"必须完整可见"的 UI，
    /// 说明带与悬停角标都压在它上面（角标按纪律不单列探针）。矩形由 `AlbumLayout`
    /// 推导，与块视图同一套常量。两个块各一个 id，便于失败信息定位到块。
    private static func carouselLayoutProbes(for size: CGSize) -> [BlockProbe] {
        AlbumLayout.probes(id: "album.carousel.frame", for: size)
    }

    private static func photoLayoutProbes(for size: CGSize) -> [BlockProbe] {
        AlbumLayout.probes(id: "album.photo.frame", for: size)
    }

    public static var blocks: [NotchBlock] {
        [carouselBlock, photoBlock]
    }

    private static var carouselBlock: NotchBlock {
        NotchBlock(
            id: AlbumBlock.carousel,
            displayName: L("block.carousel.name"),
            kind: .drawer,
            // 1×1 起（默认格 150×120 下正好一格）：再小连一句说明都放不下。
            minSize: BlockPixelSize(width: 150, height: 150),
            maxSize: BlockPixelSize(width: 600, height: 480),
            recommendedSize: BlockPixelSize(width: 300, height: 240),
            symbolName: "photo.on.rectangle.angled",
            instanceSettingsView: { context in
                AnyView(AlbumSettingsView(context: context))
            },
            probes: { info in
                Self.carouselLayoutProbes(for: info.frame.size)
            },
            makeView: { context in
                AnyView(AlbumBlockView(context: context, isCarousel: true))
            }
        )
    }

    private static var photoBlock: NotchBlock {
        NotchBlock(
            id: AlbumBlock.photo,
            displayName: L("block.photo.name"),
            kind: .drawer,
            // 下限就是全局地板：一张照片在 75×60 里也有意义，没理由不让它更小。
            minSize: BlockPixelSize(width: 75, height: 60),
            maxSize: BlockPixelSize(width: 600, height: 480),
            recommendedSize: BlockPixelSize(width: 300, height: 240),
            symbolName: "photo",
            instanceSettingsView: { context in
                AnyView(AlbumSettingsView(context: context))
            },
            probes: { info in
                Self.photoLayoutProbes(for: info.frame.size)
            },
            makeView: { context in
                AnyView(AlbumBlockView(context: context, isCarousel: false))
            }
        )
    }

    public func attachServices(stateStore: StateStore, hostController: any HostController) {
        self.stateStore = stateStore
        // 装载期**刻意什么都不做**：不预读来源、不查图库权限、不枚举目录。
        // 每次启动 App 都碰一遍 TCC / 文件系统正是权限红线禁止的那件事，
        // 一切读取都后移到块的视图真的出现时（见 AlbumPlacementModel.reload）。
    }

    public func placementWasRemoved(blockID: String, placementID: String) {
        // 宿主先通知再停用，这里清实例数据；带 placementID 的清理只有这样才覆盖得到，
        // 光写 pluginWasDisabled 是不够的。
        AlbumInstanceRegistry.shared.discard(placementID: placementID)
        guard let scope = stateStore?.placementScope(placementID: placementID) else { return }
        if blockID == AlbumBlock.carousel {
            AlbumConfigLogic.clearCarousel(from: scope)
        } else {
            AlbumConfigLogic.clearPhoto(from: scope)
        }
    }

    public func pluginWasDisabled() {
        AlbumInstanceRegistry.shared.discardAll()
    }
}
