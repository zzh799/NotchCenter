import NotchCenterKit
import SwiftUI

// MARK: - 放置实例设置（块齿轮 → SettingPopover，每实例单独设置）
//
// 上半部分是该实例私有的外观设置（显示样式 / 峰谷倒计时开关），写入该
// 实例的 placementStore；下半部分是插件级共享账户配置（cookie / workspace /
// baseURL），与插件管理窗口里的 OpenCodeUsageSettingsView 完全同源。

struct OpenCodeUsageInstanceSettingsView: View {
    /// 被编辑实例的共享模型：改这里，抽屉里该实例的多屏副本即时同步。
    @ObservedObject var instance: OpenCodeUsageInstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            appearanceSection
            Divider().overlay(Color.white.opacity(0.08))
            OpenCodeUsageSettingsView()
        }
    }

    // MARK: 外观节

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.section.appearance"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))

            Picker(L("settings.displayStyle"), selection: styleBinding) {
                ForEach(OpenCodeUsageDisplayStyle.allCases, id: \.self) { style in
                    Text(L(style.localizationKey)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Toggle(isOn: countdownBinding) {
                Text(L("settings.phaseCountdown"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.66))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var styleBinding: Binding<OpenCodeUsageDisplayStyle> {
        Binding(
            get: { instance.appearance.style },
            set: { newValue in
                var appearance = instance.appearance
                appearance.style = newValue
                instance.update(appearance)
            }
        )
    }

    private var countdownBinding: Binding<Bool> {
        Binding(
            get: { instance.appearance.showsPhaseCountdown },
            set: { newValue in
                var appearance = instance.appearance
                appearance.showsPhaseCountdown = newValue
                instance.update(appearance)
            }
        )
    }
}
