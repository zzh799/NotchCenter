import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 插件级设置（全局选项 + 维护动作）
//
// 挂在插件级 `settingsView` 上（宿主块左上角齿轮入口：悬停即出现）。块内不再有
// 齿轮按钮，这块设置只有宿主齿轮一个入口。任务本身的配置在 `TaskFormView`，
// 这里只放跨任务的东西。
struct SchedulerSettingsView: View {
    @ObservedObject private var core = SchedulerCore.shared
    @State private var cleared = false

    /// 直接读写 `core.defaultTimeout`（分钟展示），不另存一份 `@State`：
    /// 否则重开设置页会拿静态默认值把用户持久化的超时盖掉。
    private var timeoutMinutes: Binding<Int> {
        Binding(
            get: { max(core.defaultTimeout / 60, 1) },
            set: { core.setDefaultTimeout($0 * 60) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("scheduler.settings.description"))
                .font(NotchTokens.Text.caption)
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("scheduler.settings.defaultTimeout"))
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(NotchTokens.Foreground.muted)
                HStack(spacing: 4) {
                    Stepper(value: timeoutMinutes, in: 1...1440) {
                        Text(LF("scheduler.settings.minutes", timeoutMinutes.wrappedValue))
                            .font(NotchTokens.Text.system(11))
                    }
                    .controlSize(.small)
                }
                Text(L("scheduler.settings.defaultTimeoutHint"))
                    .font(NotchTokens.Text.caption)
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(LF("scheduler.settings.taskCount", core.tasks.count))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)

            HStack(spacing: 8) {
                Button(L("scheduler.settings.revealOutput")) {
                    guard let directory = core.outputDirectory else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .controlSize(.small)

                Button(cleared ? L("scheduler.settings.cleared") : L("scheduler.settings.clearOutput")) {
                    core.clearAllOutput()
                    cleared = true
                }
                .controlSize(.small)
                .disabled(cleared)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
