import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - 块视图

/// `clock.analog`：指针表盘（60 刻度 + 1–12 数字 + 时/分针），整卡是按钮。
///
/// 视觉：卡片壳走 Kit `BlockCard`；表盘内切于内容盒短边，全部尺寸按直径等比
/// 换算（`ClockFaceMetrics`），在任意物理尺寸下都是同一张脸。配色见
/// `ClockFacePalette`——参考截图是浅色小部件（半透明材质叠壁纸），搬进近黑
/// 抽屉按"保层级、丢数值"解算。
/// 交互：整卡叠 `blockPopoverTrigger`，点击打开时钟.app；长按与点击同义
/// （该管线按满 0.2s 会抑制松手时的 onTap，onLongPress 留空等于吃点击）。
/// 刷新：只画时/分针 → 每分钟对齐跳变一次，秒级定时器是纯浪费。
struct ClockFaceBlockView: View {
    let context: BlockContext

    @Environment(\.isDrawerPresented) private var isDrawerPresented
    /// 渲染锚点：只在跨分 / 抽屉重新可见时更新，避免每帧取 `Date()`。
    @State private var now = Date()

    var body: some View {
        let size = context.layoutInfo.frame.size
        let snapshot = ClockFaceSnapshot(
            date: now,
            size: size,
            calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent)

        // 整块即一个按钮（点哪儿都开时钟.app），悬停微亮与「整块可交互」语义相符。
        BlockCard(hoverEffect: true) { _ in
            dial(snapshot: snapshot)
                .frame(width: size.width, height: size.height)
        }
        .blockPopoverTrigger(
            onTap: { _ in ClockAppLauncher.open() },
            onLongPress: { _ in ClockAppLauncher.open() }
        )
        .help(L("clock.help.open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LF("clock.a11y.time", snapshot.digitalTime))
        .task { await keepAlignedToMinute() }
        .onChange(of: isDrawerPresented) { _, isPresented in
            // 抽屉被温存（收起不卸载）：重新可见时幂等校准一次，覆盖睡眠唤醒后
            // 定时器已失准的情况。见 docs/agents/插件开发约定.md 的温存契约。
            guard isPresented else { return }
            now = Date()
        }
    }

    // MARK: 表盘

    /// 表盘 = 圆面 + 60 刻度 + 12 数字 + 两针 + 中心环，全部在 D×D 的坐标系里
    /// 用 `.position` 绝对定位（坐标即"以轴心为原点"的极坐标换算）。
    private func dial(snapshot: ClockFaceSnapshot) -> some View {
        let diameter = snapshot.diameter
        let radius = diameter / 2

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [ClockFacePalette.faceTop, ClockFacePalette.faceBottom],
                        startPoint: .top,
                        endPoint: .bottom)
                )
                .frame(width: diameter, height: diameter)

            // 60 根等长刻度：整点位白，其余暗（截图实测整点 249 / 分位 175 亮度）。
            ForEach(0..<60, id: \.self) { minute in
                tick(minute: minute, snapshot: snapshot)
            }
            ForEach(1...12, id: \.self) { hour in
                numeral(hour: hour, snapshot: snapshot)
            }
            hand(angle: snapshot.hourAngle, length: snapshot.hourHandLength, snapshot: snapshot)
            hand(angle: snapshot.minuteAngle, length: snapshot.minuteHandLength, snapshot: snapshot)
            Circle()
                .strokeBorder(ClockFacePalette.ink, lineWidth: snapshot.hubStrokeWidth)
                .frame(width: snapshot.hubOuterDiameter, height: snapshot.hubOuterDiameter)
                .position(x: radius, y: radius)
        }
        .frame(width: diameter, height: diameter)
    }

    /// 单根刻度：先绕**自身中心**旋到该分位，再整体放到刻度环中径上。顺序不能
    /// 颠倒——`rotationEffect` 的锚点是视图自身中心，`.position` 只负责摆位。
    private func tick(minute: Int, snapshot: ClockFaceSnapshot) -> some View {
        let length = snapshot.tickOuterRadius - snapshot.tickInnerRadius
        let midRadius = (snapshot.tickOuterRadius + snapshot.tickInnerRadius) / 2
        let degrees = Double(minute) * 6
        let radians = degrees * .pi / 180
        return Capsule()
            .fill(minute.isMultiple(of: 5) ? ClockFacePalette.ink : ClockFacePalette.tickMinor)
            .frame(width: snapshot.tickWidth, height: length)
            .rotationEffect(.degrees(degrees))
            .position(
                x: snapshot.diameter / 2 + midRadius * sin(radians),
                y: snapshot.diameter / 2 - midRadius * cos(radians))
    }

    /// 数字 1–12 落在数字环上：环心由比例表给定，字号随之等比。
    private func numeral(hour: Int, snapshot: ClockFaceSnapshot) -> some View {
        let radians = Double(hour) * 30 * .pi / 180
        return Text(String(hour))
            .font(NotchTokens.Text.system(
                snapshot.numeralFontSize,
                weight: .bold,
                design: .rounded))
            .foregroundStyle(ClockFacePalette.ink)
            .monospacedDigit()
            .position(
                x: snapshot.diameter / 2 + snapshot.numeralRadius * sin(radians),
                y: snapshot.diameter / 2 - snapshot.numeralRadius * cos(radians))
    }

    /// 单根指针：绕**根部**旋转（`anchor: .bottom`），并把自身中心抬到轴心上方
    /// length/2——旋转锚点因此恰落在表盘中心，指针从轴心指向角度方向。
    private func hand(
        angle: Double,
        length: CGFloat,
        snapshot: ClockFaceSnapshot
    ) -> some View {
        let radius = snapshot.diameter / 2
        return Capsule()
            .fill(ClockFacePalette.ink)
            .frame(width: snapshot.handWidth, height: length)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .position(x: radius, y: radius - length / 2)
    }

    // MARK: 跨分校准

    /// 睡到下一个整分再取时间；`Task` 随视图消失自动取消。
    private func keepAlignedToMinute() async {
        while !Task.isCancelled {
            let current = Date()
            now = current
            let wait = ClockHandAngles.secondsUntilNextMinute(
                after: current,
                calendar: .autoupdatingCurrent)
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}

// MARK: - 插件本地视觉常量

/// 表盘配色。`NotchTokens` 的白色 alpha 阶梯不覆盖"面板内再叠一阶面"与低对比
/// 刻度，按 [插件开发约定](../../../docs/agents/插件开发约定.md) 收敛为单一调色板
/// 常量并注明豁免理由。
///
/// 参考截图是浅色小部件（半透明材质叠壁纸：卡片 #747E8D / 圆面 #8A96A8 /
/// 数字 #E9FCFF），其配色**不可数值移植**到近黑抽屉——照搬会得到一块刺眼的
/// 浅灰圆，且违反 DESIGN.md §1「深色为主、克制的白色层级」。移植的是**层级**：
/// 圆面比卡片底亮一阶、分位刻度明显次于数字与指针、整点位与数字/指针同白
/// （截图实测 249 vs 246，本就是一种白）。
enum ClockFacePalette {
    /// 圆面：比 `BlockCard` 常态底（白 0.025）亮一阶。截图上亮下暗（光从上来），
    /// 深色版按"克制的白色层级"把渐变差压到 2.5pp。
    static let faceTop = Color.white.opacity(0.07)
    static let faceBottom = Color.white.opacity(0.045)
    /// 数字、指针、整点位刻度、中心环共用的一档白（`Foreground.body` 的别名，
    /// 收在此处是为了让"哪些元素同白"一眼可见）。
    static let ink = NotchTokens.Foreground.body
    /// 分位刻度。**层级移植而非数值移植**：截图分位只比面板亮 13/255，在中灰底
    /// 上可辨；近黑底上同等的绝对差不可见（暗底魏伯灵敏度更高），照搬 alpha
    /// 会得到一圈看不见的脏点。
    static let tickMinor = Color.white.opacity(0.32)
}
