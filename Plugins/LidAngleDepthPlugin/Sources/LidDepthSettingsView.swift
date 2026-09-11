import NotchCenterKit
import SwiftUI

/// 插件设置界面(嵌入插件管理窗口,插件开发指南 §4.7)。
///
/// 参数与上游 Mac-Duo 的设置面板一一对应;诊断区显示传感器档位与实时流状态——
/// 这两项是排查"效果没出来"的第一现场。
struct LidDepthSettingsView: View {
    @ObservedObject var preferences: LidDepthPreferences
    @ObservedObject var controller: LidDepthController
    let settingsContext: PluginSettingsContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.isSensorAvailable {
                unsupportedNotice
            }
            masterSwitch
            Divider().overlay(NotchTokens.Hairline.divider)
            triggerSection
            Divider().overlay(NotchTokens.Hairline.divider)
            appearanceSection
            Divider().overlay(NotchTokens.Hairline.divider)
            captureSection
            Divider().overlay(NotchTokens.Hairline.divider)
            diagnostics
            HStack {
                Spacer()
                Button(L("settings.reset")) { preferences.resetToFactoryDefaults() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分节

    private var unsupportedNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(NotchTokens.Semantic.unavailable)
            Text(L("settings.unsupported"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var masterSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $preferences.isEnabled) {
                Text(L("settings.enable"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!controller.isSensorAvailable)

            Text(L("settings.enable.detail"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("settings.trigger.section"))
            slider(
                L("settings.threshold"), value: $preferences.thresholdAngle,
                range: 30...140, step: 1, format: "%.0f°",
                help: L("settings.threshold.help")
            )
            slider(
                L("settings.blurSpan"), value: $preferences.blurSpan,
                range: 10...90, step: 1, format: "%.0f°",
                help: L("settings.blurSpan.help")
            )
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("settings.appearance.section"))
            slider(
                L("settings.maxBlur"), value: $preferences.maxBlurRadius,
                range: 0...200, step: 5, format: "%.0f pt",
                help: L("settings.maxBlur.help")
            )
            slider(
                L("settings.maxDim"), value: $preferences.maxDim,
                range: 0...1, step: 0.05, format: "%.2f",
                help: L("settings.maxDim.help")
            )
            slider(
                L("settings.dimReach"), value: $preferences.dimReach,
                range: 0.05...1, step: 0.05, format: "%.2f",
                help: L("settings.dimReach.help")
            )
            slider(
                L("settings.viewingDistance"), value: $preferences.viewingDistance,
                range: 1...12, step: 0.1, format: "%.1f×",
                help: L("settings.viewingDistance.help")
            )
            slider(
                L("settings.recession"), value: $preferences.recession,
                range: 0...3, step: 0.05, format: "%.2f×",
                help: L("settings.recession.help")
            )
            slider(
                L("settings.blurEvenness"), value: $preferences.blurEvenness,
                range: 0...1, step: 0.05, format: "%.2f",
                help: L("settings.blurEvenness.help")
            )
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("settings.capture.section"))
            Toggle(isOn: $preferences.isLivePicture) {
                Text(L("settings.live"))
                    .font(NotchTokens.Text.system(11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(L("settings.live.detail"))
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
                .fixedSize(horizontal: false, vertical: true)

            // 屏幕录制是两档画面的公共前提(实时流与单帧都要抓屏)。缺了就只在这里
            // 给引导按钮,不在装载/启动期无条件弹窗——权限申请由用户在弹窗内显式发起。
            if controller.isSensorAvailable, !controller.hasScreenCapturePermission {
                Text(L("settings.permission.missing"))
                    .font(NotchTokens.Text.system(10))
                    .foregroundStyle(NotchTokens.Semantic.unavailable)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("settings.openPermission")) {
                    settingsContext.hostController.presentPermissions([.screenRecording])
                }
                .controlSize(.small)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(L("settings.diagnostics.section"))
            diagnosticRow(L("settings.diag.sensor"), sensorDescription)
            diagnosticRow(L("settings.diag.capture"), captureDescription)
            diagnosticRow(L("settings.diag.effect"), controller.isPlayingEffect ? L("common.on") : L("common.off"))
            Button(L("settings.preview")) { controller.runPreview() }
                .controlSize(.small)
                .disabled(!controller.isSensorAvailable || controller.isPlayingEffect)
        }
    }

    private var sensorDescription: String {
        guard controller.isSensorAvailable else { return L("settings.diag.sensor.none") }
        return L("settings.diag.sensor.ready")
    }

    /// 画面来源。缺权限时两档都拿不到内容，不能报"静帧"骗人。
    private var captureDescription: String {
        if controller.isStreaming { return L("settings.diag.capture.live") }
        return controller.hasScreenCapturePermission
            ? L("settings.diag.capture.still")
            : L("settings.diag.capture.none")
    }

    // MARK: 构件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(NotchTokens.Text.system(11, weight: .semibold))
            .foregroundStyle(NotchTokens.Foreground.secondary)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(NotchTokens.Text.system(10))
                .foregroundStyle(NotchTokens.Foreground.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(NotchTokens.Text.system(10, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.body)
        }
    }

    /// 一行「标题 + 滑杆 + 数值」。数值用等宽数字,拖动时不会左右抖。
    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.body)
                Spacer(minLength: 4)
                Text(String(format: format, value.wrappedValue))
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(help)
                .font(NotchTokens.Text.system(9))
                .foregroundStyle(NotchTokens.Foreground.disabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
