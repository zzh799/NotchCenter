import NotchCenterKit
import SwiftUI

// MARK: - 抽屉大块：任务列表（决策 7）
//
// 块内只有一层——任务列表。导航两层：块内列表 → 浮窗（run/history）。
// 启停与「立即运行」内联在行上**不经浮窗**：它们是运行控制而非配置编辑，
// 「配置去浮窗、控制留块内」这条线要划清楚。点行开历史浮窗，长按直接进编辑表单。
//
// 块内无工具行：新建入口是右上角悬浮浮出的圆形「+」（与 ClipboardHistory /
// CameraMirror 的块内角标同一套交互），插件设置改由宿主齿轮入口
// （`settingsView` + `DrawerBlockContainer` 的左上角齿轮）承担。
struct TaskListView: View {
    let context: BlockContext

    @ObservedObject private var core = SchedulerCore.shared
    /// 块在宿主窗口坐标系中的 frame（SwiftUI `.global`），浮窗锚点。
    ///
    /// **不能用 `context.layoutInfo.frame`**：宿主在正常渲染路径填的是
    /// `layoutEngine.frame(for:)`（网格本地坐标），只有编辑模式的齿轮设置路径
    /// 才传真全局 frame，同一字段两义（见 Agent Note 决策 9）。
    @State private var blockFrame: CGRect = .zero
    /// 指针是否在块上：决定右上角「+」的浮出。
    @State private var isHovering = false

    var body: some View {
        BlockCard { _ in
            listOrEmptyState
                .padding(SchedulerMetrics.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 新建钮：与 ClipboardHistory / CameraMirror 的块内角标同一套交互——
        // 默认隐藏，鼠标悬浮组件才浮出，落位与宿主编辑角标同一环（`padding(6)`）。
        .overlay(alignment: .topTrailing) {
            if isHovering {
                addButton
                    .padding(SchedulerMetrics.controlInset)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(NotchTokens.Motion.hover, value: isHovering)
        .background(BlockGlobalFrameReader { blockFrame = $0 })
    }

    // MARK: 新建钮

    /// 右上角「+」：组件默认圆形按钮（Kit `IconCircleButton`，直径 22、自带
    /// 悬停增亮 / 手型光标 / help / a11y），打开空表单。
    private var addButton: some View {
        IconCircleButton(
            systemImage: "plus",
            helpText: L("scheduler.action.newTask")
        ) {
            presentEditor(for: nil)
        }
        // 过渡副本护栏：滑动切页的预览副本不得真的弹浮窗（同 CameraMirror）。
        .disabled(context.layoutInfo.isPreview)
    }

    // MARK: 列表

    @ViewBuilder
    private var listOrEmptyState: some View {
        if core.tasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(NotchTokens.Text.system(18, weight: .regular))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                Text(L("scheduler.empty.title"))
                    .font(NotchTokens.Text.system(11, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Text(L("scheduler.empty.hint"))
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SchedulerMetrics.emptyStateHeight)
        } else {
            // 块内自带滚动（与 ClipboardHistory / QuickButtonBox 同款）：任务数
            // 超出块高时在块内滚动，不把块撑破。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: SchedulerMetrics.rowSpacing) {
                    ForEach(core.tasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        let running = core.runningRunIDs[task.id] != nil
        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: task))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name.isEmpty ? L("scheduler.task.untitled") : task.name)
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(ScheduleText.summary(for: task.rule))
                    Text("·")
                    Text(nextFireText(for: task))
                    if let run = core.latestRuns[task.id] {
                        Text("·")
                        Text(RunText.status(run.status))
                    }
                }
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            Button {
                core.runNow(taskID: task.id)
            } label: {
                Image(systemName: running ? "hourglass" : "play.fill")
                    .font(NotchTokens.Text.system(10, weight: .semibold))
                    .foregroundStyle(running
                        ? NotchTokens.Foreground.disabled
                        : NotchTokens.Foreground.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(running)
            .help(L("scheduler.action.runNow"))

            Toggle("", isOn: enabledBinding(task))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(L("scheduler.action.toggle"))
        }
        .padding(.horizontal, 8)
        .frame(height: SchedulerMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: NotchTokens.Radius.button, style: .continuous)
                .fill(NotchTokens.Surface.fill)
        )
        .opacity(task.isEnabled ? 1 : 0.55)
        // 行的点击走 Kit 的触发器管线（拖手势驱动），不用裸 TapGesture——
        // 后者在宿主面板里真机不回调（见「触发器手势」约定）。行的 frame 忽略，
        // 浮窗一律锚定块矩形，这样卡片必然落在鼠标「停留区」内。
        .blockPopoverTrigger(
            onTap: { _ in presentHistory(for: task) },
            onLongPress: { _ in presentEditor(for: task) },
            cornerRadius: NotchTokens.Radius.button
        )
    }

    private func enabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { task.isEnabled },
            set: { core.setEnabled($0, taskID: task.id) }
        )
    }

    private func statusColor(for task: ScheduledTask) -> Color {
        guard task.isEnabled else { return SchedulerPalette.disabled }
        guard let run = core.latestRuns[task.id] else { return SchedulerPalette.neutral }
        return SchedulerPalette.color(for: run.status)
    }

    private func nextFireText(for task: ScheduledTask) -> String {
        guard task.isEnabled else { return L("scheduler.next.disabled") }
        guard let next = core.nextFireDate(for: task) else { return L("scheduler.next.never") }
        let seconds = next.timeIntervalSinceNow
        guard seconds >= 60 else { return L("scheduler.next.imminent") }
        return LF("scheduler.next.in", RunText.duration(seconds))
    }

    // MARK: 浮窗呈现

    /// 历史浮窗（run 列表 + 输出）。
    private func presentHistory(for task: ScheduledTask) {
        guard blockFrame != .zero else { return }
        let size = popoverCardSize(ideal: SchedulerPopoverMetrics.historyIdeal)
        BlockPopover.shared.present(
            anchoredTo: blockFrame,
            cardSize: size,
            placement: .overlay
        ) {
            HistoryPopoverView(
                taskID: task.id,
                cardSize: size,
                // 浮窗内也放编辑：盯着一次失败的历史想改命令，不该先关浮窗回块里找。
                // `present` 内部先 dismiss 旧窗，所以这里直接换一张卡即可。
                onEdit: { presentEditor(for: task) },
                onClose: { BlockPopover.shared.dismiss() }
            )
        }
    }

    /// 任务编辑表单（决策 6：走宿主的 `SettingPopover`）。
    ///
    /// 入口有两处，共用同一份表单：这里（块内长按行 / 右上角悬浮「+」）与宿主
    /// 块左上角的齿轮（插件级 `settingsView`，呈现同一份插件设置）。块内的新建
    /// 入口是必需的——行的长按触发器挂在行上，空态与卡片空白区没有触发器，
    /// 没有右上角「+」就无从创建第一条任务。
    private func presentEditor(for task: ScheduledTask?) {
        guard blockFrame != .zero else { return }
        SettingPopover.shared.present(
            anchoredTo: blockFrame,
            cardSize: popoverCardSize(ideal: SchedulerPopoverMetrics.formIdeal),
            // 表单就是拿来填的：打开即聚焦名称框，不必先点一下输入框。
            focusContent: true,
            title: task == nil ? L("scheduler.form.newTitle") : L("scheduler.form.editTitle")
        ) {
            TaskFormView(
                task: task,
                onCancel: { SettingPopover.shared.dismiss() },
                onSave: { edited in
                    if task == nil {
                        core.addTask(edited)
                    } else {
                        core.updateTask(edited)
                    }
                    SettingPopover.shared.dismiss()
                },
                onDelete: task.map { existing in
                    { core.deleteTask(id: existing.id); SettingPopover.shared.dismiss() }
                }
            )
        }
    }

    /// 卡片尺寸 = 块渲染尺寸 − `BlockPopover.cardInset`（决策 9）。
    ///
    /// 这么算出来的卡片让**浮窗窗口恰好与块矩形重合**（窗口 = 卡片 + 留白），
    /// 于是卡片既不越出块、透明留白也正好压在块边界上：鼠标无论停在卡片哪里
    /// 都在抽屉的「停留区」内，浮窗不会被抽屉收起带走。尺寸数学收敛在
    /// `SchedulerPopoverMetrics.cardSize`（纯函数、单测覆盖），这里只负责喂块尺寸。
    private func popoverCardSize(ideal: CGSize) -> CGSize {
        SchedulerPopoverMetrics.cardSize(ideal: ideal, blockSize: blockFrame.size)
    }
}

// MARK: - 块全局 frame 捕获

/// 捕获被挂载视图在宿主窗口坐标系中的 frame（SwiftUI `.global`）。
///
/// 宿主自己的 `GlobalFrameReader` 是宿主 target 内的 internal 类型，插件拿不到；
/// 这里按同一实现复制一份（`GeometryReader` + `.onChange`，`.global` 在
/// `NSHostingView` 里即宿主窗口坐标）。
struct BlockGlobalFrameReader: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in onChange(frame) }
        }
    }
}
