import NotchCenterKit
import SwiftUI

// MARK: - 渲染快照（`today` + 块尺寸的纯函数，无隐藏状态）

/// 一次渲染所需的全部派生字符串与几何量。视图只读它，测试也直接断言它
/// （不渲染 SwiftUI 即可覆盖月网格、农历文案与行高分配）。
struct CalendarMonthSnapshot {
    let monthTitle: String
    /// 头部农历（「八月初十」）；今天不在展示月内时为 nil。
    let lunarLine: String?
    let weekdaySymbols: [String]
    let weeks: [[CalendarDayCell?]]
    let rowHeight: CGFloat
    let todayCircleDiameter: CGFloat
    let shortDate: String
    let weekdayName: String
    let lunarFullName: String

    init(date: Date, size: CGSize, calendar: Calendar, locale: Locale) {
        var chineseCalendar = Calendar(identifier: .chinese)
        chineseCalendar.timeZone = calendar.timeZone

        let grid = CalendarMonthBuilder.grid(for: date, calendar: calendar, today: date)
        monthTitle = CalendarMonthBuilder.monthTitle(
            for: date, locale: locale, timeZone: calendar.timeZone)
        lunarLine = ChineseLunarFormatter.monthDayName(for: date, chineseCalendar: chineseCalendar)
        weekdaySymbols = CalendarMonthBuilder.orderedWeekdaySymbols(calendar: calendar)
        weeks = grid.weeks
        rowHeight = CalendarMonthMetrics.rowHeight(for: size, rowCount: grid.rowCount)
        todayCircleDiameter = CalendarMonthMetrics.todayCircleDiameter(
            for: size, rowCount: grid.rowCount)
        shortDate = CalendarMonthBuilder.shortDate(
            for: date, locale: locale, timeZone: calendar.timeZone)
        weekdayName = CalendarMonthBuilder.weekdayName(for: date, calendar: calendar)
        lunarFullName = ChineseLunarFormatter.fullName(for: date, chineseCalendar: chineseCalendar)
    }
}

// MARK: - 块视图

/// `calendar.month`：头部（公历月｜今日农历）+ 星期行 + 当月网格，点击打开日历.app。
///
/// 视觉：卡片壳走 Kit `BlockCard`；颜色/字体一律 `NotchTokens`，今日为白色实心圆 +
/// 反色数字（对齐 macOS 通知中心日历）。交互：整卡叠 `blockPopoverTrigger`——
/// 点击走该管线的 `DragGesture`（裸 `TapGesture` 真机不回调），长按弹今日详情的浮窗。
struct CalendarMonthBlockView: View {
    let context: BlockContext

    @Environment(\.isDrawerPresented) private var isDrawerPresented
    /// 渲染锚点：只在跨天 / 抽屉重新可见时更新，避免每帧取 `Date()`。
    @State private var today = Date()

    var body: some View {
        let size = context.layoutInfo.frame.size
        let calendar = Calendar.autoupdatingCurrent
        let snapshot = CalendarMonthSnapshot(
            date: today,
            size: size,
            calendar: calendar,
            locale: .autoupdatingCurrent)

        // 整块即一个按钮（点哪儿都开日历.app），悬停微亮与「整块可交互」语义相符。
        BlockCard(hoverEffect: true) { _ in
            content(snapshot: snapshot, size: size)
                .frame(width: size.width, height: size.height)
        }
        .blockPopoverTrigger(
            onTap: { _ in CalendarAppLauncher.open() },
            onLongPress: { frameInWindow in
                CalendarPopover.present(
                    snapshot: snapshot,
                    blockSize: size,
                    frameInWindow: frameInWindow)
            }
        )
        .help(L("calendar.help.open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            LF("calendar.a11y.today", snapshot.shortDate, snapshot.weekdayName, snapshot.lunarFullName)
        )
        .task { await keepAlignedToCurrentDay() }
        .onChange(of: isDrawerPresented) { _, isPresented in
            // 抽屉被温存（收起不卸载）：重新可见时幂等校准一次，覆盖睡眠唤醒后
            // 定时器已失准的情况。见 docs/agents/插件开发约定.md 的温存契约。
            guard isPresented else { return }
            today = Date()
        }
    }

    // MARK: 版式

    private func content(snapshot: CalendarMonthSnapshot, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot: snapshot)
                .frame(height: CalendarMonthMetrics.headerHeight, alignment: .leading)
            Spacer(minLength: 0)
                .frame(height: CalendarMonthMetrics.headerToWeekdayGap)
            weekdayRow(snapshot: snapshot)
                .frame(height: CalendarMonthMetrics.weekdayHeight)
            grid(snapshot: snapshot, size: size)
                .frame(height: CalendarMonthMetrics.gridContentHeight(for: size))
        }
        .padding(CalendarMonthMetrics.padding)
    }

    private func header(snapshot: CalendarMonthSnapshot) -> some View {
        HStack(spacing: 6) {
            Text(snapshot.monthTitle)
                .font(NotchTokens.Text.system(CalendarMonthMetrics.headerFontSize, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.body)
            Rectangle()
                .fill(NotchTokens.Hairline.chipSelected)
                .frame(width: 1, height: 9)
            if let lunarLine = snapshot.lunarLine {
                Text(lunarLine)
                    .font(NotchTokens.Text.system(CalendarMonthMetrics.lunarFontSize))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(1)
            }
        }
    }

    private func weekdayRow(snapshot: CalendarMonthSnapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(snapshot.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(NotchTokens.Text.system(CalendarMonthMetrics.weekdayFontSize))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func grid(snapshot: CalendarMonthSnapshot, size: CGSize) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        dayCell(cell, snapshot: snapshot)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: snapshot.rowHeight)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: CalendarDayCell?, snapshot: CalendarMonthSnapshot) -> some View {
        if let cell {
            ZStack {
                if cell.isToday {
                    Circle()
                        .fill(Color.white)
                        .frame(width: snapshot.todayCircleDiameter, height: snapshot.todayCircleDiameter)
                }
                Text(String(cell.day))
                    .font(NotchTokens.Text.system(
                        CalendarMonthMetrics.dayFontSize,
                        weight: cell.isToday ? .semibold : .regular))
                    .foregroundStyle(cell.isToday ? CalendarMonthPalette.todayInk : NotchTokens.Foreground.secondary)
                    .monospacedDigit()
            }
        } else {
            Color.clear
        }
    }

    // MARK: 跨天校准

    /// 睡到次日零点后重算；`Task` 随视图消失自动取消。
    private func keepAlignedToCurrentDay() async {
        while !Task.isCancelled {
            let now = Date()
            today = now
            let calendar = Calendar.autoupdatingCurrent
            guard let nextMidnight = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime) else {
                return
            }
            let seconds = max(nextMidnight.timeIntervalSince(now) + 1, 1)
            try? await Task.sleep(for: .seconds(seconds))
        }
    }
}

// MARK: - 插件本地视觉常量

/// 今日白圆上的反色数字。`NotchTokens` 的白色 alpha 阶梯不覆盖「浅底深字」，
/// 故按插件本地视觉收敛为单一常量（不散写内联字面量）。
enum CalendarMonthPalette {
    static let todayInk = Color(white: 0.07)
}
