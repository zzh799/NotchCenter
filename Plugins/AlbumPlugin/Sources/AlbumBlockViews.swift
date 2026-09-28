import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 相册块（轮播 / 单张共用一份实现）

/// `album.carousel` 与 `album.photo` 的视图实现：差别只在悬停角标与点击动作，
/// 其余（图面、说明带、四类降级态、可见性登记）完全同源，所以合成一个结构
/// 用 `isCarousel` 分叉，避免两份几乎一样的视图各自漂移。
struct AlbumBlockView: View {
    let context: BlockContext
    let isCarousel: Bool

    @ObservedObject private var model: AlbumPlacementModel

    /// 抽屉是否真的在屏上。温存让 `onDisappear` 只表示"卸载"，不表示"用户看不到"，
    /// 所以定时器的开关必须读这个值（见 `AlbumPlacementModel.setViewer`）。
    @Environment(\.isDrawerPresented) private var isDrawerPresented
    @Environment(\.displayScale) private var displayScale

    /// 本视图副本的身份。多屏各有一份，模型按它登记"谁在屏上"。
    @State private var viewerID = UUID()
    @State private var isHovering = false

    init(context: BlockContext, isCarousel: Bool) {
        self.context = context
        self.isCarousel = isCarousel
        _model = ObservedObject(
            wrappedValue: AlbumInstanceRegistry.shared.model(
                placementID: context.placementID,
                blockID: isCarousel ? AlbumBlock.carousel : AlbumBlock.photo,
                stateStore: context.stateStore,
                hostController: context.hostController))
    }

    var body: some View {
        let size = context.layoutInfo.frame.size
        BlockCard(hoverEffect: true) { _ in
            content(size: size)
                .padding(AlbumLayout.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                hoverBadges
                    .padding(AlbumLayout.badgeInset)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .blockPopoverTrigger(
            onTap: { _ in handleTap() },
            onLongPress: { _ in handleTap() }
        )
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // 首帧也要上报：`onAppear` 拿不到尺寸，而尺寸决定解码档位。
        .onChange(of: size, initial: true) { _, newSize in
            guard !isPreview else { return }
            model.setDisplaySize(newSize, scale: displayScale)
        }
        .onChange(of: isDrawerPresented, initial: true) { _, presented in
            guard !isPreview else { return }
            model.setViewer(id: viewerID, visible: presented)
        }
        .onDisappear {
            guard !isPreview else { return }
            model.setViewer(id: viewerID, visible: false)
        }
    }

    /// 滑动切页的过渡副本：不得登记可见性（否则会多开一份计时）、也不得响应点击。
    private var isPreview: Bool { context.layoutInfo.isPreview }

    // MARK: 主体

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch model.loadState {
        case .unconfigured:
            stateView(
                size: size,
                symbol: "photo.on.rectangle.angled",
                title: L("empty.unconfigured.title"),
                message: L("empty.unconfigured.message"),
                action: nil)
        case let .photosPermission(status):
            permissionState(size: size, status: status)
        case .loading:
            // 只留底衬，不留空洞也不闪烁文字——枚举通常几十毫秒就回来了。
            emptySurface
        case .ready:
            if model.isCurrentItemFailed {
                failedState(size: size)
            } else {
                photoSurface(size: size)
            }
        case .empty:
            stateView(
                size: size,
                symbol: "photo",
                title: L("empty.noItems.title"),
                message: emptyMessage,
                action: nil)
        case .missingSource:
            stateView(
                size: size,
                symbol: "questionmark.folder",
                title: L("source.missing.title"),
                message: L("source.missing.message"),
                action: nil)
        case .unreadable:
            stateView(
                size: size,
                symbol: "lock",
                title: L("source.unreadable.title"),
                message: L("source.unreadable.message"),
                action: nil)
        }
    }

    /// 空来源的分叉：图库来源可能是"只授权了部分照片"，那句提示要指到权限里去。
    private var emptyMessage: String {
        if model.source?.isFromPhotosLibrary == true { return L("empty.noAlbums.message") }
        return L("empty.noItems.message")
    }

    // MARK: 图面

    private func photoSurface(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            AlbumPalette.placeholder
            if let image = model.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: model.fillsFrame ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(model.currentItem?.id)
                    .transition(.opacity)
            }
            if model.showsCaption, AlbumLayout.showsCaptionBand(in: size) {
                captionBand
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AlbumLayout.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AlbumLayout.radius, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
        }
        // 换图时淡入淡出；只有图片层的 identity 变了，说明带不跟着闪。
        .animation(AlbumPalette.crossfade, value: model.currentItem?.id)
    }

    /// 底部说明带：来源名/文件名 + 轮播位置。黑渐变是必须的——文字压在任意一张
    /// 照片上，只有黑色遮罩能保证白字始终可读（豁免理由见 `AlbumPalette`）。
    private var captionBand: some View {
        HStack(spacing: 6) {
            Text(model.captionTitle ?? "")
                .foregroundStyle(AlbumPalette.scrimTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let position = model.captionPosition {
                Text(
                    LF(
                        "caption.position",
                        String(position.index), String(position.count))
                )
                .foregroundStyle(AlbumPalette.scrimPosition)
                .monospacedDigit()
                .layoutPriority(1)
            }
        }
        .font(NotchTokens.Text.system(10, weight: .medium))
        .padding(.horizontal, 8)
        .frame(height: AlbumLayout.captionHeight, alignment: .bottom)
        .padding(.bottom, 5)
        .background {
            LinearGradient(
                colors: [AlbumPalette.scrimTop, AlbumPalette.scrimBottom],
                startPoint: .top,
                endPoint: .bottom)
        }
    }

    private var emptySurface: some View {
        RoundedRectangle(cornerRadius: AlbumLayout.radius, style: .continuous)
            .fill(AlbumPalette.placeholder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(size: CGSize) -> some View {
        stateView(
            size: size,
            symbol: "exclamationmark.triangle",
            title: L("item.failed.title"),
            message: L("item.failed.message"),
            action: nil)
    }

    // MARK: 降级态

    private func permissionState(size: CGSize, status: PermissionStatus) -> some View {
        let denied = status == .denied || status == .restricted
        return stateView(
            size: size,
            symbol: "photo.on.rectangle",
            title: denied ? L("gate.photos.denied.title") : L("gate.photos.title"),
            message: denied ? L("gate.photos.denied.message") : L("gate.photos.message"),
            action: (
                title: L("gate.photos.action"),
                help: L("gate.photos.action.help"),
                handler: { context.hostController.presentPermissions([.photos]) }
            ))
    }

    /// 降级态统一长相：图标 +（够大才有的）标题与说明 +（够高才有的）动作按钮。
    /// 小到 75×60 时只剩一个图标，也不至于把块撑破。
    private func stateView(
        size: CGSize,
        symbol: String,
        title: String,
        message: String?,
        action: (title: String, help: String, handler: () -> Void)?
    ) -> some View {
        let showsTitle = AlbumLayout.showsStateTitle(in: size)
        let showsMessage = message != nil && AlbumLayout.showsStateMessage(in: size)
        let showsAction = action != nil && AlbumLayout.showsStateAction(in: size)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(NotchTokens.Text.system(AlbumLayout.stateSymbolSize, weight: .light))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                if showsTitle {
                    Text(title)
                        .font(NotchTokens.Text.system(12, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.secondary)
                        .lineLimit(1)
                }
            }
            if showsMessage, let message {
                Text(message)
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(showsAction ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsAction, let action {
                Button(action: action.handler) {
                    Text(action.title)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(AlbumActionButtonStyle())
                .help(action.help)
                .accessibilityLabel(action.help)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 悬停角标

    @ViewBuilder
    private var hoverBadges: some View {
        if case .ready = model.loadState, !model.items.isEmpty {
            HStack(spacing: 4) {
                if isCarousel, model.canAdvance {
                    IconCircleButton(
                        systemImage: "backward.fill",
                        helpText: L("help.carousel.previous")
                    ) { model.previous() }
                    IconCircleButton(
                        systemImage: model.isPaused ? "play.fill" : "pause.fill",
                        helpText: model.isPaused ? L("help.carousel.play") : L("help.carousel.pause")
                    ) { model.togglePause() }
                    IconCircleButton(
                        systemImage: "forward.fill",
                        helpText: L("help.carousel.next")
                    ) { model.next() }
                } else {
                    IconCircleButton(
                        systemImage: "arrow.clockwise",
                        helpText: L("help.photo.refresh")
                    ) { model.refresh() }
                }
            }
            // 过渡副本护栏：滑动切页的预览副本不得真的推进共享状态。
            .disabled(isPreview)
        }
    }

    // MARK: 交互

    private func handleTap() {
        guard !isPreview else { return }
        if isCarousel {
            // 点击 = 下一张（说明带上写着）。取不到 "next" 的语义时（只有一张）就是空操作。
            model.next()
        } else {
            openCurrentItem()
        }
    }

    /// 单张块点击打开原图：本地交给默认应用，图库资产没有公开的单张深链，退一步
    /// 打开照片.app 让用户自己找——比什么都不做诚实。
    private func openCurrentItem() {
        guard let item = model.currentItem else { return }
        switch item.kind {
        case .localFile:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.identifier))
        case .photosAsset:
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Photos")
            else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var helpText: String {
        guard let item = model.currentItem else { return L("empty.unconfigured.message") }
        if isCarousel { return L("help.carousel.next") }
        return item.kind == .localFile ? L("help.photo.openFile") : L("help.photo.openLibrary")
    }

    private var accessibilityText: String {
        if isCarousel, let position = model.captionPosition {
            return LF("a11y.carousel", "\(position.index)/\(position.count)")
        }
        return LF("a11y.photo", model.captionTitle ?? L("caption.photos"))
    }
}

// MARK: - 插件内动作按钮样式

/// 走 Kit 统一圆角按钮基体（DESIGN.md §9），参数与同族官方块一致，字号按
/// 块内档收敛到 11。块内降级态与设置面板共用一份，免得两处各自调三态灰阶。
struct AlbumActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: NotchTokens.Text.system(11, weight: .semibold),
            normalOpacity: 0.07,
            hoverOpacity: 0.11,
            pressedOpacity: 0.15,
            strokeOpacity: 0.10,
            foregroundOpacity: 0.92,
            pressedForegroundOpacity: 0.60
        )
    }
}
