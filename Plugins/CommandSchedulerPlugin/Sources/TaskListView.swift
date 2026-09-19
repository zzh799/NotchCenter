import NotchCenterKit
import SwiftUI

// MARK: - 抽屉大块：任务列表（决策 7）
//
// 块内只有一层——任务列表。导航两层：块内列表 → 浮窗（run/history）。
// 启停与「立即运行」内联在行上**不经浮窗**：它们是运行控制而非配置编辑，
// 「配置去浮窗、控制留块内」这条线要划清楚。点行开历史浮窗，长按直接进编辑表单。
struct TaskListView: View {
    let context: BlockContext

    @ObservedObject private var core = SchedulerCore.shared
    /// 块在宿主窗口坐标系中的 frame（SwiftUI `.global`），浮窗锚点。
    ///
    /// **不能用 `context.layoutInfo.frame`**：宿主在正常渲染路径填的是
    /// `layoutEngine.frame(for:)`（网格本地坐标），只有编辑模式的齿轮设置路径
    /// 才传真全局 frame，同一字段两义（见 Agent Note 决策 9）。
    @State private var blockFrame: CGRect = .zero

    var body: some View {
        BlockCard { _ in
            VStack(alignment: .leading, spacing: SchedulerMetrics.toolbarSpacing) {
                toolbar
                listOrEmptyState
            }
            .padding(SchedulerMetrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(BlockGlobalFrameReader { blockFrame = $0 })
    }

    // MARK: 工具行

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(L("scheduler.block.title"))
                .font(NotchTokens.Text.toolbarSmall)
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Text("\(core.tasks.count)")
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
            Spacer(minLength: 0)
            toolbarButton(symbol: "plus", help: L("scheduler.action.newTask")) {
                presentEditor(for: nil)
            }
            toolbarButton(symbol: "gearshape", help: L("scheduler.action.settings")) {
                presentGlobalSettings()
            }
        }
        .frame(height: SchedulerMetrics.toolbarHeight)
    }

    private func toolbarButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(11, weight: .semibold))
                .foregroundStyle(NotchTokens.Foreground.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
        let size = popoverCardSize(ideal: Self.historyIdealSize)
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
    /// 入口有两处，共用同一份表单：这里（块内长按 / 新建按钮）与宿主编辑模式
    /// 齿轮（插件级 `settingsView`）。宿主对 `settingsView` 的标准触发点是
    /// 「编辑模式下抽屉块左上角的齿轮」——让用户为了改一个命令先切进布局编辑
    /// 模式是错的，所以块内必须有直达入口。
    private func presentEditor(for task: ScheduledTask?) {
        guard blockFrame != .zero else { return }
        SettingPopover.shared.present(
            anchoredTo: blockFrame,
            cardSize: popoverCardSize(ideal: Self.formIdealSize),
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

    /// 插件级设置（全局守卫超时默认值 + 维护动作）。
    private func presentGlobalSettings() {
        guard blockFrame != .zero else { return }
        SettingPopover.shared.present(
            anchoredTo: blockFrame,
            cardSize: popoverCardSize(ideal: CGSize(width: 340, height: 260)),
            title: L("scheduler.settings.title")
        ) {
            SchedulerSettingsView()
        }
    }

    /// 卡片尺寸 = 块渲染尺寸 − `BlockPopover.cardInset`（决策 9）。
    ///
    /// 这么算出来的卡片让**浮窗窗口恰好与块矩形重合**（窗口 = 卡片 + 留白），
    /// 于是卡片既不越出块、透明留白也正好压在块边界上：鼠标无论停在卡片哪里
    /// 都在抽屉的「停留区」内，浮窗不会被抽屉收起带走。下限 320×200 只为
    /// 极端退化尺寸兜底（块最小 480×340，正常路径不会触到）。
    private func popoverCardSize(ideal: CGSize) -> CGSize {
        let available = CGSize(
            width: blockFrame.width - BlockPopover.cardInset,
            height: blockFrame.height - BlockPopover.cardInset
        )
        return CGSize(
            width: max(min(ideal.width, available.width), 320),
            height: max(min(ideal.height, available.height), 200)
        )
    }

    /// 历史浮窗理想尺寸（上限；实际取块尺寸与它的较小者）。
    static let historyIdealSize = CGSize(width: 860, height: 660)
    /// 编辑表单理想尺寸：够放"命令多行 + cwd + env + 调度 + 超时"一屏不滚。
    static let formIdealSize = CGSize(width: 460, height: 560)
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
