import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 条目悬浮预览（决策记录 2026-09-20-clipboard-hover-preview）
//
// 与长按浮窗（`BlockPopover`）的分工：悬浮是"快速一瞥"——停稳后从光标下方长出、
// 不吃点击、不可交互；长按仍是"看全 + 可滚动 + 可选中复制"。
//
// **为什么不用 `BlockPopover`**：它是进程内单例（任一时刻至多一个浮窗在屏），每次
// `present` 都要建 `NSPanel` + `NSHostingView`、查一次 `CGWindowList`、装一次全局
// 鼠标监听——而悬浮是高频动作，这个代价不成比例；而且它与长按会互相顶掉。
// 块内 overlay 三条都避开了：零窗口开销、由构造保证不越出块矩形（因而不可能踩
// "光标离开抽屉停留区就收起"那条红线）、与长按各走各的。

/// 悬浮预览的命名坐标空间。
///
/// 行与浮层必须共用同一套坐标：行的 `onContinuousHover` 报出的光标位置要直接能当
/// 浮层的摆放基准，中间少一次坐标换算就少一处错位。
enum ClipboardHoverSpace {
    static let list = "clipboard.hover.list"
}

/// 待浮现 / 已浮现的目标。`cursor` 位于 `ClipboardHoverSpace.list` 坐标空间。
struct ClipboardHoverTarget: Equatable {
    var entry: ClipboardEntry
    var cursor: CGPoint
}

/// 悬浮预览的计时模型。两处列表各持一个实例，但计时语义只在这里写一处。
@MainActor
final class ClipboardHoverPreviewModel: ObservableObject {
    /// 光标停稳多久才浮现。跟手浮现会在鼠标扫过列表时逐行长出又收掉。
    static let defaultDwell: Duration = .milliseconds(400)
    /// 行内位移容差：小于它视为"没动"，系统抖动不该重置计时。
    static let movementTolerance: CGFloat = 2

    @Published private(set) var shown: ClipboardHoverTarget?

    private let dwell: Duration
    private var candidate: ClipboardHoverTarget?
    private var dwellTask: Task<Void, Never>?

    /// `dwell` 可注入，供单测把 400ms 压到几毫秒跑真实计时。
    init(dwell: Duration = ClipboardHoverPreviewModel.defaultDwell) {
        self.dwell = dwell
    }

    /// 光标进入或在 `entry` 上移动。
    func hover(entry: ClipboardEntry, at cursor: CGPoint) {
        if candidate?.entry.id == entry.id {
            if shown?.entry.id == entry.id {
                // 已浮现：只跟随重定位，不重新计时——已经看到的卡片不该因为手抖一下消失。
                shown?.cursor = cursor
                candidate?.cursor = cursor
                return
            }
            if let previous = candidate?.cursor,
               hypot(cursor.x - previous.x, cursor.y - previous.y) <= Self.movementTolerance {
                return
            }
        }
        arm(ClipboardHoverTarget(entry: entry, cursor: cursor))
    }

    /// 光标离开 `entry`。非当前目标的通知直接忽略（相邻行的进入/离开会交叉投递）。
    func end(entry: ClipboardEntry) {
        guard candidate?.entry.id == entry.id || shown?.entry.id == entry.id else { return }
        cancel()
    }

    /// 无条件收起并作废计时：点击写回、长按、列表内容变化、抽屉收起都走它。
    func cancel() {
        dwellTask?.cancel()
        dwellTask = nil
        candidate = nil
        shown = nil
    }

    private func arm(_ target: ClipboardHoverTarget) {
        dwellTask?.cancel()
        candidate = target
        shown = nil
        let expected = target.entry.id
        // `dwell` 显式捕获：闭包里 `self` 是 weak（可选），隐式访问实例属性需要 `self.`，
        // 而这里只要那个值，不需要拽住实例。
        dwellTask = Task { [weak self, dwell] in
            try? await Task.sleep(for: dwell)
            // 计时到期时还要复核候选没被换掉：期间可能已经移到别的行了。
            guard !Task.isCancelled, let self else { return }
            guard self.candidate?.entry.id == expected else { return }
            self.shown = target
        }
    }
}

// MARK: - 摆放几何（纯函数）

enum ClipboardHoverCardGeometry {
    /// 卡片与光标的间距：留一点，别让卡片压住光标本身。
    static let cursorOffset = CGSize(width: 12, height: 18)

    /// 卡片左上角。先按"光标右下"摆，越界则翻到左侧 / 上方，最后夹进容器。
    ///
    /// 为什么翻完还要夹：块被压到最小尺寸时容器可能比卡片还小，翻转也放不下。
    /// 宁可夹住（裁掉一角）也不能越出块矩形——越出就压到邻块身上，而悬浮控件按
    /// 既有约定**不单列 `BlockProbe`**，打包期校验不会替我们兜这件事。
    static func origin(
        cursor: CGPoint,
        cardSize: CGSize,
        containerSize: CGSize,
        inset: CGFloat = 6
    ) -> CGPoint {
        var x = cursor.x + cursorOffset.width
        if x + cardSize.width > containerSize.width - inset {
            x = cursor.x - cursorOffset.width - cardSize.width
        }
        var y = cursor.y + cursorOffset.height
        if y + cardSize.height > containerSize.height - inset {
            y = cursor.y - cursorOffset.height - cardSize.height
        }
        let maxX = max(containerSize.width - cardSize.width - inset, inset)
        let maxY = max(containerSize.height - cardSize.height - inset, inset)
        return CGPoint(x: min(max(x, inset), maxX), y: min(max(y, inset), maxY))
    }
}

enum ClipboardHoverMetrics {
    /// 理想卡片尺寸。比行里的 32×20 缩略图大约 8 倍，够"一瞥认出"。
    static let idealSize = CGSize(width: 240, height: 160)
    static let padding: CGFloat = 10
    /// 头部（类型标识）行高。
    static let headerHeight: CGFloat = 14
    static let spacing: CGFloat = 6
    static let margin: CGFloat = 6
    /// 正文最多几行。
    static let textLines = 8
    /// 文件最多列几条路径。
    static let fileRows = 5

    /// 按容器夹紧后的卡片尺寸。
    static func cardSize(in containerSize: CGSize) -> CGSize {
        CGSize(
            width: min(idealSize.width, max(containerSize.width - margin * 2, 0)),
            height: min(idealSize.height, max(containerSize.height - margin * 2, 0))
        )
    }
}

// MARK: - 卡片

/// 悬浮卡内容：头部一行类型标识，下面是放大的图片 / 多行正文 / 路径列表。
struct ClipboardHoverCard: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?
    let size: CGSize

    private var contentHeight: CGFloat {
        max(size.height - ClipboardHoverMetrics.padding * 2
            - ClipboardHoverMetrics.headerHeight - ClipboardHoverMetrics.spacing, 0)
    }

    private var contentWidth: CGFloat {
        max(size.width - ClipboardHoverMetrics.padding * 2, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClipboardHoverMetrics.spacing) {
            header
            content
        }
        .padding(ClipboardHoverMetrics.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // 先裁内容再画底：块被压到最小尺寸时正文可能排不下，溢出必须被裁在卡片内，
        // 漏出去就压到邻块身上了（悬浮控件不单列 BlockProbe，没人替我们兜）。
        .clipShape(RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous))
        .background(
            // 抽屉主背景同款：这是浮层级，必须不透明——半透明填充会让底下的列表
            // 文字透上来，正好毁掉"看清这一条"的用途。
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(NotchTokens.Surface.drawer)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.kind.symbolName)
                .font(NotchTokens.Text.system(9, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.muted)
            Text(L(entry.kind.localizationKey))
                .font(NotchTokens.Text.system(9.5, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.muted)
            Spacer(minLength: 0)
        }
        .frame(height: ClipboardHoverMetrics.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .image:
            ClipboardImageView(
                url: thumbnailURL,
                width: contentWidth,
                height: contentHeight,
                contentMode: .fit
            )
            .frame(width: contentWidth, height: contentHeight)
        case .file:
            fileList
        case .text, .link, .color:
            Text(entry.text)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(ClipboardHoverMetrics.textLines)
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(entry.fileURLs.prefix(ClipboardHoverMetrics.fileRows)), id: \.self) { path in
                Text((path as NSString).lastPathComponent)
                    .font(NotchTokens.Text.system(10.5))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if entry.fileURLs.count > ClipboardHoverMetrics.fileRows {
                Text(LF("hover.file.more", entry.fileURLs.count - ClipboardHoverMetrics.fileRows))
                    .font(NotchTokens.Text.system(9.5))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
    }
}

/// 悬浮预览层：把卡片按光标位置夹进容器。
///
/// 宿主视图必须在本层所在容器上声明 `ClipboardHoverSpace.list` 坐标空间——行上报的
/// 光标位置与这里的摆放基准必须是同一套坐标。
struct ClipboardHoverPreviewLayer: View {
    let target: ClipboardHoverTarget
    let thumbnailURL: URL?

    var body: some View {
        GeometryReader { proxy in
            let cardSize = ClipboardHoverMetrics.cardSize(in: proxy.size)
            let origin = ClipboardHoverCardGeometry.origin(
                cursor: target.cursor,
                cardSize: cardSize,
                containerSize: proxy.size,
                inset: ClipboardHoverMetrics.margin
            )
            ClipboardHoverCard(entry: target.entry, thumbnailURL: thumbnailURL, size: cardSize)
                .offset(x: origin.x, y: origin.y)
                .transition(.opacity)
        }
        // 不吃点击是硬要求：否则用户想点下一行会被卡片截胡。命中穿透后点击照常落到正确的行上。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(NotchTokens.Motion.hover, value: target.entry.id)
    }
}
