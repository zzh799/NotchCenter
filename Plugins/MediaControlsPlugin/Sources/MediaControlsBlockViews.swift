import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 布局常量（打包期探针与块视图的唯一来源）

/// 单行版式的常量源：打包期探针与块视图都从这里推导，禁止各写一份。探针语义是
/// 「意图契约」，与视图布局漂移即门禁失效，所以两组数字必须同源。
enum MediaControlsMetrics {
    /// 内容区四周内边距：取块内容标准内边距（`Space.cardPadding`，DESIGN.md §5），
    /// 与其余抽屉块的块内边距同源，不再自留一份字面量。
    static let inset: CGFloat = NotchTokens.Space.cardPadding
    /// 应用图标圆角方块边长。
    static let tileSize: CGFloat = 40
    /// 方块内应用图标的渲染边长。
    static let appIconSize: CGFloat = 28
    /// 图标方块与文字之间的间距。
    static let tileToTextGap: CGFloat = 10
    /// 单个控制按钮的命中区边长。
    static let buttonSize: CGFloat = 28
    /// 控制按钮之间的间距。
    static let buttonSpacing: CGFloat = 2
    /// 控制按钮字形大小。
    static let glyphSize: CGFloat = 15
    /// 行高：一行里最高的元素决定。
    static let rowHeight: CGFloat = max(tileSize, buttonSize)
    /// 组件的完整高度（上下内边距 + 行高）。
    static let totalHeight: CGFloat = inset * 2 + rowHeight
    /// 行内容不被压缩所需的最小宽度，与块声明的 `minSize.width` 相等：声明的最小尺寸
    /// 下恒为 1:1，只有宿主给出**小于声明下限**的盒（存量落位 / 用户把格子调小）才缩。
    static let minRowWidth: CGFloat = 260

    /// 打包期探针矩形：整行区带，末段并入底部内边距（minSize 矮于总需求即越界）。
    static func rowProbeRect(for size: CGSize) -> CGRect {
        CGRect(
            x: inset,
            y: inset,
            width: max(size.width - inset * 2, 0),
            height: rowHeight + inset
        )
    }
}

// MARK: - 抽屉块视图

/// 媒体控制块：一行「应用图标 + 应用名 + 上一首/播放暂停/下一首」。
///
/// 数据全部来自插件级单例 `MediaPlayerController.shared`（媒体播放是系统级瞬态，
/// 与放置实例无关）；本视图只负责版式与可见性登记。
///
/// 卡片表面（近白填充 + 发丝描边）归 Kit `BlockCard`：宿主 `DrawerBlockContainer`
/// 只做裁剪与编辑态压暗，不自绘卡片壳（DESIGN.md §9）。悬停微亮不开：本卡自己不可点，
/// 反馈由三个控制键各自给（同 Notes / 命令调度 / 剪贴板）。
struct MediaControlsBlockView: View {
    let context: BlockContext
    @ObservedObject private var controller = MediaPlayerController.shared
    @Environment(\.isDrawerPresented) private var isDrawerPresented

    var body: some View {
        BlockCard(hoverEffect: false) { _ in
            // 单行版式在窄盒里无处可折：按声明下限等比缩到盒内，而不是把内容顶出去
            // 压到邻居块上（宿主卡片不裁切）。盒 ≥ 声明下限时恒为 1:1，绝不放大。
            GeometryReader { proxy in
                row
                    .frame(
                        width: proxy.size.width / fitScale(in: proxy.size),
                        height: MediaControlsMetrics.totalHeight
                    )
                    .scaleEffect(fitScale(in: proxy.size), anchor: .center)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("a11y.mediaControls"))
        // 宿主对抽屉内容做温存：`.onAppear` / `.onDisappear` 只表达挂载 / 卸载，
        // 「用户看不到我了」必须读 `\.isDrawerPresented`。三条入口共用一个幂等
        // 登记函数（收起与卸载会先后各触发一次）。
        .onAppear { syncPresentation() }
        .onDisappear { controller.setPresented(false, placementID: context.placementID) }
        .onChange(of: isDrawerPresented) { _, _ in syncPresentation() }
    }

    /// 适配缩放：声明下限内为 1，盒更小时等比缩小；永不放大。
    private func fitScale(in size: CGSize) -> CGFloat {
        min(
            1,
            size.width / MediaControlsMetrics.minRowWidth,
            size.height / MediaControlsMetrics.totalHeight
        )
    }

    /// 幂等登记：预览副本（滑动切页的非激活页、组件目录）不登记，否则会替真正的
    /// 块把常驻的桥子进程拉起来。
    private func syncPresentation() {
        guard !context.layoutInfo.isPreview else { return }
        controller.setPresented(isDrawerPresented, placementID: context.placementID)
    }

    // MARK: 版式

    private var row: some View {
        HStack(spacing: 0) {
            appTile
            Text(displayName)
                .font(NotchTokens.Text.system(15, weight: .medium))
                // 有可控制媒体时应用名是主信息（body）；空态 / 降级态只是一条状态说明，
                // 降到 muted 层级，不与应用名抢同一声量（DESIGN.md §2.2）。
                .foregroundStyle(
                    controller.state.rendersMediaItem
                        ? NotchTokens.Foreground.body
                        : NotchTokens.Foreground.muted
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, MediaControlsMetrics.tileToTextGap)
            // 拉宽时把余量全部给这里：应用名不跟着拉长，按钮始终贴右。
            Spacer(minLength: MediaControlsMetrics.tileToTextGap)
            controlButtons
        }
        .padding(MediaControlsMetrics.inset)
        .frame(height: MediaControlsMetrics.totalHeight)
    }

    /// 应用图标承托方块：透明底 / 单色图标的应用也能落到同一块可见底衬上。
    /// 底色取 `Surface.track`（块内通用内嵌底，先例：摄像头取景框 / 相册占位 /
    /// 剪贴板图片面），而非 `fillHighlighted`（后者语义是「选中 / 强调」，
    /// 用在常驻静态方框上会让样式阶梯失真；发丝边沿用内嵌面的 0.5。
    private var appTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                .fill(NotchTokens.Surface.track)
            tileContent
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchTokens.Radius.card, style: .continuous)
                .stroke(NotchTokens.Hairline.thumbnail, lineWidth: 0.5)
        }
        .frame(width: MediaControlsMetrics.tileSize, height: MediaControlsMetrics.tileSize)
    }

    @ViewBuilder
    private var tileContent: some View {
        if controller.state.rendersMediaItem, let icon = controller.app?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: MediaControlsMetrics.appIconSize, height: MediaControlsMetrics.appIconSize)
        } else {
            // 没有可展示的应用身份（空态、降级态、或播放器没向系统注册 bundle id）
            // 时给一个符号占位，避免方块里空着。
            Image(systemName: placeholderSymbol)
                .font(NotchTokens.Text.system(MediaControlsMetrics.appIconSize * 0.62, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.disabled)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: MediaControlsMetrics.buttonSpacing) {
            controlButton("backward.fill", help: L("help.previous")) {
                controller.previousTrack()
            }
            controlButton(isPaused ? "play.fill" : "pause.fill", help: isPaused ? L("help.play") : L("help.pause")) {
                controller.togglePlayPause()
            }
            controlButton("forward.fill", help: L("help.next")) {
                controller.nextTrack()
            }
        }
        // 没有可控制的媒体项时整组置灰：三个键点了也不会有任何反应。
        .disabled(!controller.state.rendersMediaItem)
    }

    private func controlButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // isPreview 契约：预览副本只读展示，点击不投递任何媒体命令。
            guard !context.layoutInfo.isPreview else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(MediaControlsMetrics.glyphSize, weight: .medium))
                .frame(width: MediaControlsMetrics.buttonSize, height: MediaControlsMetrics.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaGlyphButtonStyle())
        .focusable(false)
        .focusEffectDisabled(true)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: 文案与状态

    private var displayName: String {
        switch controller.state {
        case .unavailable: return L("drawer.unavailable")
        case .idle: return L("drawer.nothing")
        case .playing, .paused: return controller.app?.displayName ?? L("drawer.unknownApp")
        }
    }

    private var placeholderSymbol: String {
        controller.state == .unavailable ? "exclamationmark.triangle" : "music.note"
    }

    private var isPaused: Bool { controller.state == .paused }
}

// MARK: - 控制按钮样式

/// 裸符号控制按钮的三态外观：常态无底（与参考图一致），悬停 / 按下才浮出圆角底色。
/// 透明度取自 `NotchTokens.Foreground`（0.76/0.88/0.94）与 `NotchTokens.Surface`
/// （fillHover 0.04 / fillHighlighted 0.065）；基体只吃 CGFloat，故在此按值落数，
/// 与 NotesPlugin 的按钮样式同一写法。
private struct MediaGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: nil,
            normalOpacity: 0,
            hoverOpacity: 0.04,
            pressedOpacity: 0.065,
            strokeOpacity: 0,
            foregroundOpacity: 0.76,
            hoverForegroundOpacity: 0.88,
            pressedForegroundOpacity: 0.94
        )
    }
}
