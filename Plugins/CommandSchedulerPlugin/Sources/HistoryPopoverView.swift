import Combine
import NotchCenterKit
import SwiftUI

// MARK: - 历史浮窗：run 列表 + 输出（决策 7 / 9）
//
// 块内不该塞日志——`BlockPopover` 卡片尺寸受块尺寸约束（决策 9），块只负责
// 任务列表，完整历史进这里。左侧 run 列表、右侧选中 run 的输出，顶部一行
// 元信息 + 动作（立即运行 / 编辑）。
//
// 运行中的 run 边跑边读文件尾（决策 5 的副产品：watch 语义），跑完读文件
// 头尾投影（`RunStore.runOutput`）。
struct HistoryPopoverView: View {
    let taskID: String
    let cardSize: CGSize
    let onEdit: () -> Void
    let onClose: () -> Void

    @ObservedObject private var core = SchedulerCore.shared
    @State private var selectedRunID: String?
    /// 运行中时轮询读到的输出（避免在 body 里直接做文件 IO）。
    @State private var liveOutput: RunOutput?

    private let tick = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    private var task: ScheduledTask? { core.tasks.first { $0.id == taskID } }
    private var runs: [TaskRun] { core.runs(taskID: taskID) }
    private var selectedRun: TaskRun? {
        if let selectedRunID, let match = runs.first(where: { $0.id == selectedRunID }) {
            return match
        }
        return runs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(spacing: 0) {
                runList
                    .frame(width: listWidth)
                Rectangle()
                    .fill(NotchTokens.Hairline.divider)
                    .frame(width: 1)
                detail
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .onReceive(tick) { _ in refreshLiveOutput() }
        .onAppear { refreshLiveOutput() }
        // 选中项变了要立刻刷新一次，否则轮询间隔内会短暂显示上一条的输出。
        .onChange(of: selectedRun?.id) { _, _ in refreshLiveOutput() }
    }

    /// 左栏宽度：窄卡片下也要给输出留够地方（卡片最窄约 432pt）。
    private var listWidth: CGFloat {
        min(max(cardSize.width * 0.34, 148), 240)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task?.name.isEmpty == false
                     ? task!.name
                     : L("scheduler.task.untitled"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                if let task {
                    Text(subtitle(for: task))
                        .font(NotchTokens.Text.caption)
                        .foregroundStyle(NotchTokens.Foreground.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            actionButton(symbol: "play.fill", help: L("scheduler.action.runNow")) {
                core.runNow(taskID: taskID)
            }
            .disabled(core.runningRunIDs[taskID] != nil)
            actionButton(symbol: "pencil", help: L("scheduler.action.edit")) { onEdit() }
            actionButton(symbol: "xmark", help: L("scheduler.action.close")) { onClose() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 副标题 = 调度摘要 + 近 24h 错过留痕（决策 4：聚合成一行，不塞流水）。
    private func subtitle(for task: ScheduledTask) -> String {
        let counts = core.skipCounts(taskID: task.id)
        var parts = [ScheduleText.summary(for: task.rule)]
        if counts.skipped > 0 {
            parts.append(LF("scheduler.skip.skippedCount", counts.skipped))
        }
        if counts.missed > 0 {
            parts.append(LF("scheduler.skip.missedCount", counts.missed))
        }
        return parts.joined(separator: " · ")
    }

    private func actionButton(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(10, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 左栏（run 列表）

    @ViewBuilder
    private var runList: some View {
        if runs.isEmpty {
            placeholder(L("scheduler.history.empty"))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(runs) { run in
                        runListItem(run)
                    }
                }
                .padding(6)
            }
        }
    }

    private func runListItem(_ run: TaskRun) -> some View {
        let selected = run.id == selectedRun?.id
        return Button {
            selectedRunID = run.id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(SchedulerPalette.color(for: run.status))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RunText.timestamp(run.startedAt))
                        .font(NotchTokens.Text.system(10, weight: .medium))
                        .foregroundStyle(NotchTokens.Foreground.body)
                    Text("\(RunText.status(run.status)) · \(RunText.duration(run.duration))")
                        .font(NotchTokens.Text.caption)
                        .foregroundStyle(NotchTokens.Foreground.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if run.trigger == .manual {
                    Image(systemName: "hand.tap")
                        .font(NotchTokens.Text.system(8, weight: .semibold))
                        .foregroundStyle(NotchTokens.Foreground.disabled)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                    .fill(selected ? NotchTokens.Surface.fillHighlighted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 右栏（输出）

    @ViewBuilder
    private var detail: some View {
        if let run = selectedRun {
            VStack(alignment: .leading, spacing: 6) {
                metaLine(run)
                commandBox(run)
                outputBox(run)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            placeholder(L("scheduler.history.noSelection"))
        }
    }

    private func metaLine(_ run: TaskRun) -> some View {
        HStack(spacing: 6) {
            Text(RunText.status(run.status))
                .font(NotchTokens.Text.system(10, weight: .semibold))
                .foregroundStyle(SchedulerPalette.color(for: run.status))
            Text("· \(RunText.exitCode(run.exitCode))")
            Text("· \(RunText.duration(run.duration))")
            if run.truncated {
                Text("· \(L("scheduler.output.truncated"))")
                    .foregroundStyle(SchedulerPalette.timeout)
            }
            Spacer(minLength: 0)
        }
        .font(NotchTokens.Text.caption)
        .foregroundStyle(NotchTokens.Foreground.muted)
        .lineLimit(1)
    }

    /// 命令快照：任务定义会改，历史必须自带"当时跑的是什么"。
    private func commandBox(_ run: TaskRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.snapshot.command)
                .font(NotchTokens.Text.system(10, design: .monospaced))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let directory = run.snapshot.workingDirectory, !directory.isEmpty {
                Text(directory)
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                .fill(NotchTokens.Surface.fill)
        )
    }

    @ViewBuilder
    private func outputBox(_ run: TaskRun) -> some View {
        let output = currentOutput(for: run)
        if output.missing {
            Text(L("scheduler.output.missing"))
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if output.text.isEmpty {
            Text(run.status == .running
                 ? L("scheduler.output.waiting")
                 : L("scheduler.output.empty"))
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                Text(ANSIText.stripped(output.text))
                    .font(NotchTokens.Text.system(10, design: .monospaced))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func currentOutput(for run: TaskRun) -> RunOutput {
        if run.status == .running, let liveOutput, liveOutput.missing == false {
            return liveOutput
        }
        return core.output(for: run)
    }

    /// 运行中才轮询；已结束的 run 读一次就够（避免每秒无谓的文件 IO）。
    private func refreshLiveOutput() {
        guard let run = selectedRun, run.status == .running else {
            liveOutput = nil
            return
        }
        liveOutput = core.output(for: run)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.caption)
            .foregroundStyle(NotchTokens.Foreground.disabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
    }

    private var hairline: some View {
        Rectangle()
            .fill(NotchTokens.Hairline.divider)
            .frame(height: 1)
    }
}
