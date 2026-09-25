import NotchCenterKit
import SwiftUI

// MARK: - 自动清理设置（全局设置，两个齿轮入口共用同一行）
//
// 历史是插件级共享的，所以清理档位只有一份。而设置浮窗有两个入口：抽屉块齿轮开的是
// **实例**设置（显示条数按实例），库页块齿轮开的是**插件级** `settingsView`。两个入口
// 都得能到达这一项，因此行视图提出来共用，状态读写全部落在 `ClipboardHistoryStore.shared`
// （决策记录 `2026-09-25-clipboard-auto-cleanup` 的 D8）。

/// 设置浮窗里的小节：小号标题 + 内容（与 Pomodoro / Scheduler 设置同款版式）。
struct ClipboardSettingsSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(NotchTokens.Text.system(10, weight: .bold))
                .foregroundStyle(NotchTokens.Foreground.headingMarker)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 自动清理档位行（标签 + 下拉）。作用域是全局，与打开它的入口无关。
struct ClipboardAutoCleanupSettingsRow: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        HStack {
            Text(L("settings.autoCleanup"))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)
            Spacer()
            Picker(L("settings.autoCleanup"), selection: periodBinding) {
                ForEach(ClipboardAutoCleanupPeriod.selectable, id: \.self) { period in
                    Text(L(period.localizationKey)).tag(period)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodBinding: Binding<ClipboardAutoCleanupPeriod> {
        Binding(
            get: { store.autoCleanupPeriod },
            set: { store.setAutoCleanupPeriod($0) }
        )
    }
}

/// 档位后果的说明。清理是**静默执行**（不弹确认、不发通知），后果只能写在明面上
/// （决策记录 D9），所以这一行是设置项的组成部分而非装饰。
struct ClipboardAutoCleanupNote: View {
    var body: some View {
        Text(L("settings.autoCleanup.note"))
            .font(NotchTokens.Text.system(10))
            .foregroundStyle(NotchTokens.Foreground.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 插件级设置视图（库页块齿轮入口，经宿主 `settingsView`）。
///
/// 本插件唯一的全局设置就是自动清理，所以不再套小节标题——设置卡片的标题行已经
/// 写着插件名。
struct ClipboardPluginSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipboardAutoCleanupSettingsRow()
            ClipboardAutoCleanupNote()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
