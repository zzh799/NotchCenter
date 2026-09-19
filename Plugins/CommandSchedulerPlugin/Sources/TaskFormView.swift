import NotchCenterKit
import SwiftUI

// MARK: - 任务编辑表单（决策 6：走宿主 SettingPopover）
//
// 同一份表单挂在两个入口上——块内长按/新建（插件自己调
// `SettingPopover.shared.present`）与宿主编辑模式齿轮（插件级 `settingsView`）。
// 一份表单两个入口，避免把同一 schema 渲染两遍。
//
// 保存时**不校验 cwd 是否存在**：定时任务跑在未来，那时外挂卷可能才挂载好，
// 现在拦下来是错的；运行时失败并如实记录才是对的。
struct TaskFormView: View {
    let task: ScheduledTask?
    let onCancel: () -> Void
    let onSave: (ScheduledTask) -> Void
    let onDelete: (() -> Void)?

    /// 调度档位。与 `ScheduleRule` 的五个 case 一一对应（编辑时必须先选档，
    /// 再填该档的参数，否则会出现"改了分钟但档位还是每天"的悬空状态）。
    private enum RuleKind: String, CaseIterable, Identifiable {
        case everyMinutes, hourly, daily, weekly, monthly
        var id: String { rawValue }

        var label: String {
            switch self {
            case .everyMinutes: return L("scheduler.kind.everyMinutes")
            case .hourly: return L("scheduler.kind.hourly")
            case .daily: return L("scheduler.kind.daily")
            case .weekly: return L("scheduler.kind.weekly")
            case .monthly: return L("scheduler.kind.monthly")
            }
        }

        static func of(_ rule: ScheduleRule) -> RuleKind {
            switch rule {
            case .everyMinutes: return .everyMinutes
            case .hourlyAt: return .hourly
            case .dailyAt: return .daily
            case .weeklyAt: return .weekly
            case .monthlyAt: return .monthly
            }
        }
    }

    private enum TimeoutMode: String, CaseIterable, Identifiable {
        case useDefault, off, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .useDefault: return L("scheduler.timeout.useDefault")
            case .off: return L("scheduler.timeout.off")
            case .custom: return L("scheduler.timeout.custom")
            }
        }
    }

    @State private var name: String
    @State private var command: String
    @State private var workingDirectory: String
    @State private var environmentText: String
    @State private var enabled: Bool
    @State private var kind: RuleKind
    @State private var minutes: Int
    @State private var minute: Int
    @State private var hour: Int
    @State private var day: Int
    @State private var weekdays: Set<Int>
    @State private var timeoutMode: TimeoutMode
    @State private var timeoutSeconds: Int

    /// 打开表单即把光标放进名称框：浮窗以 `focusContent: true` 取得键盘焦点，
    /// 这里再请求首个输入框的焦点，省掉"先点一下输入框"。
    @FocusState private var nameFocused: Bool

    init(
        task: ScheduledTask?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ScheduledTask) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.task = task
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete

        let existing = task ?? ScheduledTask.make(name: "", command: "")
        _name = State(initialValue: existing.name)
        _command = State(initialValue: existing.command)
        _workingDirectory = State(initialValue: existing.workingDirectory ?? "")
        _environmentText = State(initialValue: Self.encodeEnvironment(existing.environment))
        _enabled = State(initialValue: existing.isEnabled)
        _kind = State(initialValue: RuleKind.of(existing.rule))

        // 各档参数都从规则里取"当前值"，于是切换档位不会丢掉已经填过的数字。
        let rule = existing.rule.normalized()
        var initialMinutes = 30
        var initialMinute = 0
        var initialHour = 9
        var initialDay = 1
        var initialWeekdays: Set<Int> = [2]
        switch rule {
        case let .everyMinutes(value): initialMinutes = value
        case let .hourlyAt(value): initialMinute = value
        case let .dailyAt(h, m): initialHour = h; initialMinute = m
        case let .weeklyAt(days, h, m): initialWeekdays = Set(days); initialHour = h; initialMinute = m
        case let .monthlyAt(d, h, m): initialDay = d; initialHour = h; initialMinute = m
        }
        _minutes = State(initialValue: initialMinutes)
        _minute = State(initialValue: initialMinute)
        _hour = State(initialValue: initialHour)
        _day = State(initialValue: initialDay)
        _weekdays = State(initialValue: initialWeekdays)

        switch existing.timeoutSeconds {
        case .none: _timeoutMode = State(initialValue: .useDefault); _timeoutSeconds = State(initialValue: SchedulerCore.defaultTimeoutSeconds)
        case .some(0): _timeoutMode = State(initialValue: .off); _timeoutSeconds = State(initialValue: SchedulerCore.defaultTimeoutSeconds)
        case let .some(value): _timeoutMode = State(initialValue: .custom); _timeoutSeconds = State(initialValue: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled(L("scheduler.form.name")) {
                fieldBox {
                    TextField(L("scheduler.form.namePlaceholder"), text: $name)
                        .focused($nameFocused)
                }
            }
            labeled(L("scheduler.form.command")) {
                fieldBox {
                    TextEditor(text: $command)
                        .font(NotchTokens.Text.system(11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 64)
                }
            }
            labeled(L("scheduler.form.workdir")) {
                fieldBox { TextField("$HOME", text: $workingDirectory) }
            }
            labeled(L("scheduler.form.env")) {
                fieldBox {
                    TextEditor(text: $environmentText)
                        .font(NotchTokens.Text.system(11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44)
                }
            }
            labeled(L("scheduler.form.schedule")) { scheduleEditor }
            labeled(L("scheduler.form.timeout")) { timeoutEditor }
            Toggle(L("scheduler.form.enabled"), isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(NotchTokens.Text.system(11))
            footer
        }
        .onAppear { nameFocused = true }
    }

    // MARK: 调度编辑

    private var scheduleEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $kind) {
                ForEach(RuleKind.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            HStack(spacing: 6) {
                switch kind {
                case .everyMinutes:
                    stepper(value: $minutes, range: ScheduleRule.minuteStepRange, unit: L("scheduler.unit.minutes"))
                case .hourly:
                    stepper(value: $minute, range: 0...59, unit: L("scheduler.unit.minuteOfHour"))
                case .daily:
                    timeSteppers
                case .weekly:
                    timeSteppers
                    weekdayPicker
                case .monthly:
                    timeSteppers
                    stepper(value: $day, range: ScheduleRule.dayOfMonthRange, unit: L("scheduler.unit.day"))
                }
                Spacer(minLength: 0)
            }

            Text(LF("scheduler.form.nextFire", nextFirePreview))
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
            if composedRule().maySkipMonths {
                Text(L("scheduler.form.monthlyWarning"))
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(SchedulerPalette.timeout)
            }
        }
    }

    /// 下次触发的实时预览——调度编辑没有即时反馈就是在盲填。
    private var nextFirePreview: String {
        guard let next = ScheduleModel.next(after: Date(), rule: composedRule()) else {
            return L("scheduler.next.never")
        }
        return RunText.timestamp(next)
    }

    private var timeSteppers: some View {
        HStack(spacing: 4) {
            stepper(value: $hour, range: 0...23, unit: L("scheduler.unit.hour"))
            Text(":").foregroundStyle(NotchTokens.Foreground.muted)
            stepper(value: $minute, range: 0...59, unit: L("scheduler.unit.minute"))
        }
    }

    private func stepper(value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .frame(width: 34)
                .multilineTextAlignment(.trailing)
                .font(NotchTokens.Text.system(11, design: .monospaced))
                .onChange(of: value.wrappedValue) { _, newValue in
                    value.wrappedValue = newValue.clamped(to: range)
                }
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.mini)
            Text(unit)
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 3) {
            ForEach(ScheduleText.weekdaySymbols(locale: .current), id: \.weekday) { item in
                let selected = weekdays.contains(item.weekday)
                Button {
                    if selected {
                        // 不允许清空：空集合会让规则永不触发，且无法在 UI 上解释。
                        if weekdays.count > 1 { weekdays.remove(item.weekday) }
                    } else {
                        weekdays.insert(item.weekday)
                    }
                } label: {
                    Text(item.symbol)
                        .font(NotchTokens.Text.caption)
                        .foregroundStyle(selected
                            ? NotchTokens.Foreground.selected
                            : NotchTokens.Foreground.muted)
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                                .fill(selected ? NotchTokens.Surface.fillHighlighted : NotchTokens.Surface.fill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                                .strokeBorder(
                                    selected ? NotchTokens.Hairline.chipSelected : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeoutEditor: some View {
        HStack(spacing: 6) {
            Picker("", selection: $timeoutMode) {
                ForEach(TimeoutMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            if timeoutMode == .custom {
                stepper(value: $timeoutSeconds, range: 10...86_400, unit: L("scheduler.unit.seconds"))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 底部动作

    private var footer: some View {
        HStack(spacing: 8) {
            if let onDelete {
                Button(L("scheduler.form.delete"), role: .destructive, action: onDelete)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button(L("scheduler.form.cancel"), action: onCancel)
                .controlSize(.small)
            Button(L("scheduler.form.save")) {
                onSave(composedTask())
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: 组装

    private func composedRule() -> ScheduleRule {
        switch kind {
        case .everyMinutes: return .everyMinutes(minutes: minutes)
        case .hourly: return .hourlyAt(minute: minute)
        case .daily: return .dailyAt(hour: hour, minute: minute)
        case .weekly: return .weeklyAt(weekdays: weekdays.sorted(), hour: hour, minute: minute)
        case .monthly: return .monthlyAt(day: day, hour: hour, minute: minute)
        }
    }

    private func composedTask() -> ScheduledTask {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout: Int?
        switch timeoutMode {
        case .useDefault: timeout = nil
        case .off: timeout = 0
        case .custom: timeout = timeoutSeconds
        }
        let base = task ?? ScheduledTask.make(name: "", command: "")
        return ScheduledTask(
            id: base.id,
            name: trimmedName.isEmpty ? Self.fallbackName(for: command) : trimmedName,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            environment: Self.decodeEnvironment(environmentText),
            rule: composedRule().normalized(),
            timeoutSeconds: timeout,
            isEnabled: enabled,
            createdAt: base.createdAt
        )
    }

    /// 名字留空时用命令首行兜底（列表里总得有个可辨识的标题）。
    private static func fallbackName(for command: String) -> String {
        let first = command.split(separator: "\n").first.map(String.init) ?? command
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("scheduler.task.untitled") : String(trimmed.prefix(40))
    }

    // MARK: 环境变量文本互转（每行 KEY=VALUE）
    //
    // 纯文本变换，`nonisolated`：不该为了测试它而把测试拖进主执行者上下文。

    nonisolated static func encodeEnvironment(_ environment: [String: String]) -> String {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    nonisolated static func decodeEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    // MARK: 版式辅助

    @ViewBuilder
    private func labeled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
            content()
        }
    }

    @ViewBuilder
    private func fieldBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(NotchTokens.Text.system(11))
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                    .fill(NotchTokens.Surface.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NotchTokens.Radius.chip, style: .continuous)
                    .strokeBorder(NotchTokens.Hairline.drawerEdge, lineWidth: 1)
            )
    }
}
