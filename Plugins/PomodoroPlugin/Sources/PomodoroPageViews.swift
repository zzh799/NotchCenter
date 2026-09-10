import NotchCenterKit
import SwiftUI

// MARK: - 整页块视图（pomodoro.page）：大计时器 + 今日节奏 + 历史复盘
//
// 表面满血（Agent Note 2026-09-10-plugin-page-blocks §3）：不套 BlockCard、
// 不进宿主的抽屉 ScrollView，所以内边距与滚动由本页自管；顶部额外留出一段
// 空档让开宿主叠在左上角的设置齿轮（24pt 按钮 + 6pt 内距）。

private enum PomodoroPageMetrics {
    /// 内容左右内边距（与抽屉内容同值，页面左缘对齐其余块）。
    static let horizontal: CGFloat = NotchTokens.Space.contentHorizontal
    /// 顶部让位：宿主设置齿轮叠在内容区左上角。
    static let top: CGFloat = 34
    static let bottom: CGFloat = 14
    /// 区块之间的间距。
    static let sectionGap: CGFloat = 20
    /// 区块标题与内容之间的间距。
    static let titleGap: CGFloat = 7
    /// 大计时器字号下限 / 上限（随页宽插值）。
    static let countdownMin: CGFloat = 44
    static let countdownMax: CGFloat = 76
    /// 今日节奏柱高。
    static let hourBarHeight: CGFloat = 30
    /// 近 7 天柱高。
    static let dayBarHeight: CGFloat = 34
    /// 评分脸直径（整页）。
    static let moodDiameter: CGFloat = 30
}

/// 整页块根视图。
struct PomodoroPageView: View {
    let context: BlockContext
    @ObservedObject private var store = PomodoroStore.shared

    /// 复盘派生数据：明细只在写入时变，而页面每 0.5s 随 display 重绘——
    /// 全量扫描（上限 2 万条）摊到 history 变化的时刻，见 `onChange`。
    @State private var review = PomodoroReviewSnapshot(
        history: PomodoroStore.shared.history,
        now: Date()
    )

    private var isPreview: Bool { context.layoutInfo.isPreview }

    private var countdownSize: CGFloat {
        min(max(context.layoutInfo.frame.width * 0.13, PomodoroPageMetrics.countdownMin),
            PomodoroPageMetrics.countdownMax)
    }

    var body: some View {
        let display = store.display
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: PomodoroPageMetrics.sectionGap) {
                timerHero(display: display)
                todaySection
                historySection
                footnotes
            }
            .padding(.horizontal, PomodoroPageMetrics.horizontal)
            .padding(.top, PomodoroPageMetrics.top)
            .padding(.bottom, PomodoroPageMetrics.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.history) { _, newValue in
            review = PomodoroReviewSnapshot(history: newValue, now: Date())
        }
        .accessibilityLabel(L("a11y.pomodoro"))
    }

    // MARK: 大计时器

    private func timerHero(display: PomodoroDisplay) -> some View {
        let accent = PomodoroTheme.accent(for: display.phase)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(PomodoroTheme.phaseTitle(for: display))
                    .font(NotchTokens.Text.system(13, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                // 中点分隔是纯标点（非词汇），两侧文案各自本地化。
                Text("·")
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(LF("drawer.completed", display.completedToday))
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
            Text(heroCountdownText(display))
                .font(NotchTokens.Text.system(countdownSize, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(NotchTokens.Foreground.body)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchTokens.Surface.track)
                    Capsule()
                        .fill(accent.opacity(0.9))
                        .frame(width: max(3, proxy.size.width * display.progress))
                }
            }
            .frame(height: 6)
            heroActions(display: display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 空闲时预告本轮专注时长（"25:00"），其余阶段走真实剩余秒数。
    private func heroCountdownText(_ display: PomodoroDisplay) -> String {
        if display.phase == .idle {
            return pomodoroCountdownText(store.config.focusMinutes * 60)
        }
        return pomodoroCountdownText(display.remainingSeconds)
    }

    /// 待评分优先于阶段判定：用户在**休息期间**就能评（提示在专注完成那刻
    /// 就创建，见 Agent Note §9），此时评分条占掉整条控制带。
    @ViewBuilder
    private func heroActions(display: PomodoroDisplay) -> some View {
        if let pending = display.pendingRating {
            PomodoroRatingBar(
                pending: pending,
                diameter: PomodoroPageMetrics.moodDiameter,
                showsDetail: true,
                isDisabled: isPreview,
                onRate: { store.ratePending($0) },
                onDiscard: { store.discardPending() }
            )
        } else if display.phase == .idle {
            Button {
                store.start()
            } label: {
                Label(L("drawer.startFocus"), systemImage: "play.fill")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(PomodoroPrimaryButtonStyle())
            .disabled(isPreview)
        } else {
            HStack(spacing: 14) {
                IconCircleButton(
                    systemImage: display.isPaused ? "play.fill" : "pause.fill",
                    helpText: display.isPaused ? L("help.resume") : L("help.pause"),
                    diameter: 28
                ) {
                    store.togglePause()
                }
                .disabled(isPreview)
                IconCircleButton(
                    systemImage: "forward.fill",
                    helpText: L("help.skip"),
                    diameter: 28
                ) {
                    store.skip()
                }
                .disabled(isPreview)
                IconCircleButton(
                    systemImage: "stop.fill",
                    helpText: L("help.stop"),
                    diameter: 28
                ) {
                    store.stop()
                }
                .disabled(isPreview)
            }
        }
    }

    // MARK: 今日节奏

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: PomodoroPageMetrics.titleGap) {
            HStack(spacing: 8) {
                sectionTitle(L("page.section.today"))
                Spacer(minLength: 0)
                sectionNote(L("page.today.hours"))
            }
            hourStrip(review.todayBuckets)
            hourAxis
            if review.todayTotal == 0 {
                sectionNote(L("page.today.empty"))
            }
            sectionNote(L("page.week.title"))
            weekStrip(review.week)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 今日 8 个 3 小时时段：无记录的时段留一条轨道底（看得出"这段时间是空的"）。
    private func hourStrip(_ buckets: [Int]) -> some View {
        let peak = max(buckets.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, value in
                let filled = value > 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(filled
                        ? PomodoroTheme.activeAccent.opacity(0.85)
                        : NotchTokens.Surface.track)
                    .frame(height: filled
                        ? max(6, CGFloat(value) / CGFloat(peak) * PomodoroPageMetrics.hourBarHeight)
                        : 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: PomodoroPageMetrics.hourBarHeight, alignment: .bottom)
    }

    /// 时段刻度：每 3 小时一个起点（0 / 3 / … / 21）。
    private var hourAxis: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                Text("\(index * 3)")
                    .font(NotchTokens.Text.system(9, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.placeholder)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 近 7 天完成数：柱顶带计数，横轴是本地化短星期。
    private func weekStrip(_ week: [PomodoroDayCount]) -> some View {
        let peak = max(week.map(\.completed).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(week, id: \.day) { entry in
                let filled = entry.completed > 0
                VStack(spacing: 4) {
                    Text("\(entry.completed)")
                        .font(NotchTokens.Text.system(10, weight: .medium, design: .monospaced))
                        .foregroundStyle(filled
                            ? NotchTokens.Foreground.secondary
                            : NotchTokens.Foreground.placeholder)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(filled
                            ? PomodoroTheme.activeAccent.opacity(0.85)
                            : NotchTokens.Surface.track)
                        .frame(height: filled
                            ? max(6, CGFloat(entry.completed) / CGFloat(peak) * PomodoroPageMetrics.dayBarHeight)
                            : 3)
                    Text(PomodoroHistoryAnalysis.weekdayShortLabel(day: entry.day))
                        .font(NotchTokens.Text.system(9, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.placeholder)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: PomodoroPageMetrics.dayBarHeight + 34, alignment: .bottom)
    }

    // MARK: 历史复盘

    private var historySection: some View {
        let overview = review.overview
        return VStack(alignment: .leading, spacing: PomodoroPageMetrics.titleGap) {
            sectionTitle(L("page.section.history"))
            if overview.sessionCount == 0, overview.legacyDayCount == 0 {
                sectionNote(L("page.history.empty"))
            } else {
                summaryLine(overview)
                contrastCard(review.contrast)
                microBreakOutcomeLine(review.outcomeCounts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ overview: PomodoroHistoryOverview) -> some View {
        var parts = [LF("page.history.sessions", overview.completedCount, overview.sessionCount)]
        if let average = overview.averageRating {
            parts.append(LF("page.history.rating", average, overview.ratedCount))
        }
        if overview.microBreakCount > 0 {
            parts.append(LF("page.history.microBreaks", overview.microBreakCount))
        }
        return Text(parts.joined(separator: " · "))
            .font(NotchTokens.Text.system(11))
            .foregroundStyle(NotchTokens.Foreground.muted)
    }

    /// 微休息对照卡：两组各一行（平均情绪分 + 完成率），底部标注因果警示。
    private func contrastCard(_ contrast: PomodoroMicroBreakContrast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("page.history.contrast.title"))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            contrastRow(L("page.history.contrast.with"), contrast.withMicroBreaks)
            contrastRow(L("page.history.contrast.without"), contrast.withoutMicroBreaks)
            Text(L("page.history.contrast.caveat"))
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(NotchTokens.Surface.fill)
        )
    }

    private func contrastRow(_ label: String, _ group: PomodoroMicroBreakContrast.Group) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .frame(width: 58, alignment: .leading)
            if let average = group.averageRating {
                Text(LF("page.history.contrast.score", average))
                    .font(NotchTokens.Text.system(11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NotchTokens.Foreground.body)
            } else {
                Text("—")
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.placeholder)
            }
            Spacer(minLength: 4)
            if let rate = group.completionRate {
                Text(LF("page.history.contrast.completion", Int((rate * 100).rounded())))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
            }
            Text(LF("page.history.sessionsShort", group.sessionCount))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.placeholder)
        }
    }

    /// 微休息结束方式分布（"被打断比例"的原始事实）；无记录时整行不出现。
    @ViewBuilder
    private func microBreakOutcomeLine(_ counts: [PomodoroMicroBreak.Outcome: Int]) -> some View {
        let natural = counts[.natural] ?? 0
        let skipped = counts[.skippedByUser] ?? 0
        let aborted = counts[.aborted] ?? 0
        if natural + skipped + aborted > 0 {
            let parts = [
                "\(L("page.history.outcome.natural")) \(natural)",
                "\(L("page.history.outcome.skipped")) \(skipped)",
                "\(L("page.history.outcome.aborted")) \(aborted)",
            ]
            Text(parts.joined(separator: " · "))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
        }
    }

    // MARK: 脚注

    /// 旧数据迁移与记录上限的说明（无对应事实时整块不出现）。
    @ViewBuilder
    private var footnotes: some View {
        let overview = review.overview
        VStack(alignment: .leading, spacing: 3) {
            if overview.legacyDayCount > 0 {
                sectionNote(LF("page.history.legacy", overview.legacyDayCount))
            }
            if review.isAtRecordLimit {
                sectionNote(L("page.history.trimmed"))
            }
        }
    }

    // MARK: 排版基元

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(12, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.secondary)
    }

    private func sectionNote(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(10))
            .foregroundStyle(NotchTokens.Foreground.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 复盘派生数据快照

/// 复盘区一次算好的派生量（构造时就地全量扫一遍明细）。
struct PomodoroReviewSnapshot {
    /// 今日 8 个 3 小时时段的完成数。
    let todayBuckets: [Int]
    /// 今日完成总数（含迁移来的日汇总兜底）。
    let todayTotal: Int
    /// 近 7 天完成数（含今天），日期升序。
    let week: [PomodoroDayCount]
    let overview: PomodoroHistoryOverview
    let contrast: PomodoroMicroBreakContrast
    let outcomeCounts: [PomodoroMicroBreak.Outcome: Int]
    /// 明细是否已触顶（再写会丢最旧）。
    let isAtRecordLimit: Bool

    init(history: PomodoroHistory, now: Date) {
        let today = PomodoroHistoryAnalysis.dayString(now)
        let hours = PomodoroHistoryAnalysis.hourlyCompleted(onDay: today, history: history)
        todayBuckets = stride(from: 0, to: 24, by: 3).map { start in
            hours[start..<min(start + 3, 24)].reduce(0, +)
        }
        todayTotal = hours.reduce(0, +) + (history.dailyFallbacks[today] ?? 0)
        week = PomodoroHistoryAnalysis.dailyCompleted(history: history, days: 7, now: now)
        overview = PomodoroHistoryAnalysis.overview(history: history)
        contrast = PomodoroHistoryAnalysis.microBreakContrast(history: history)
        outcomeCounts = PomodoroHistoryAnalysis.microBreakOutcomeCounts(history: history)
        isAtRecordLimit = history.totalRecords >= PomodoroHistory.maxRecords
    }
}

// MARK: - 评分条（整页与抽屉块共用）

/// 待评价专注的评分条。
///
/// 「不可跳过、不可补评」（Agent Note 2026-09-10-plugin-page-blocks §9）：
/// 只有**打分**与**删除本次记录**两个出口。`showsDetail` 控制是否展示提示语
/// 与本次微休息次数——抽屉块最小高度只有 120pt，一行脸就是全部预算。
struct PomodoroRatingBar: View {
    let pending: PomodoroPendingRating
    let diameter: CGFloat
    let showsDetail: Bool
    let isDisabled: Bool
    let onRate: (Int) -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsDetail {
                Text(L("rating.prompt"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { score in
                    PomodoroMoodButton(
                        score: score,
                        diameter: diameter,
                        isDisabled: isDisabled,
                        action: onRate
                    )
                }
                Spacer(minLength: 8)
                Button {
                    onDiscard()
                } label: {
                    IconCircleBadge(systemImage: "trash", diameter: diameter * 0.84)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
                .help(L("rating.delete"))
                .accessibilityLabel(L("rating.delete"))
            }
            if showsDetail {
                Text(LF("rating.microBreaks", pending.microBreakCount))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .lineLimit(1)
            }
        }
    }
}

/// 单档情绪按钮（悬停增亮 + 微放大；禁用态整体压暗）。
private struct PomodoroMoodButton: View {
    let score: Int
    let diameter: CGFloat
    let isDisabled: Bool
    let action: (Int) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            action(score)
        } label: {
            PomodoroMoodFace(
                score: score,
                diameter: diameter,
                isHighlighted: isHovering && !isDisabled
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .scaleEffect(isHovering && !isDisabled ? 1.12 : 1)
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help(L("rating.mood\(score)"))
        .accessibilityLabel(L("rating.mood\(score)"))
    }
}

/// 5 档情绪脸：圆形 + 双眼 + 一条曲率随分数从皱眉到上扬的嘴。
///
/// 自绘而非用 SF Symbol——SF Symbols 没有成体系的 5 档表情，拿同一个笑脸
/// 换颜色既不可读也难分辨顺序。
struct PomodoroMoodFace: View {
    /// 1...5（3 = 平嘴）。
    let score: Int
    let diameter: CGFloat
    var isHighlighted = false

    var body: some View {
        let radius = diameter / 2
        let tension = CGFloat(score - 3) / 2
        let mouthY = radius * 1.25
        let mouthHalfWidth = radius * 0.43
        let controlY = mouthY + tension * radius * 0.64
        let inkOpacity = isHighlighted ? 0.92 : 0.66
        return ZStack {
            Circle().fill(.white.opacity(isHighlighted ? 0.16 : 0.05))
            Circle().stroke(.white.opacity(isHighlighted ? 0.85 : 0.35), lineWidth: 1)
            eye(radius: radius, offsetX: -radius * 0.30, opacity: inkOpacity)
            eye(radius: radius, offsetX: radius * 0.30, opacity: inkOpacity)
            Path { path in
                path.move(to: CGPoint(x: radius - mouthHalfWidth, y: mouthY))
                path.addQuadCurve(
                    to: CGPoint(x: radius + mouthHalfWidth, y: mouthY),
                    control: CGPoint(x: radius, y: controlY)
                )
            }
            .stroke(
                .white.opacity(inkOpacity),
                style: StrokeStyle(lineWidth: max(1.3, radius * 0.10), lineCap: .round)
            )
        }
        .frame(width: diameter, height: diameter)
    }

    private func eye(radius: CGFloat, offsetX: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(.white.opacity(opacity))
            .frame(width: radius * 0.17, height: radius * 0.17)
            .offset(x: offsetX, y: -radius * 0.24)
    }
}
