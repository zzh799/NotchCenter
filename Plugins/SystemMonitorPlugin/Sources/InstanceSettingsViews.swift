import NotchCenterKit
import SwiftUI

// MARK: - 放置实例设置（编辑模式块齿轮 → SettingPopover，每实例单独生效）
//
// 单指标块：历史窗 / 黄红阈值（内存块无阈值） / 吞吐单位（磁盘·网络） /
// 网络排除前缀（网络块）；All-in-one：历史窗 + 四指标开关（不可全关）。
// 写入走实例模型的 update（placementStore 持久化，多屏副本同步）。

struct SingleInstanceSettingsView: View {
    let kind: MetricKind
    @ObservedObject var instance: SystemMonitorInstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("settings.section.general")) {
                windowPicker
                if kind == .network {
                    exclusionsField
                }
            }
            if kind != .memory {
                section(L("settings.section.thresholds")) {
                    thresholdFields
                    if kind == .disk || kind == .network {
                        unitPicker
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 通用节

    private var windowPicker: some View {
        row(L("settings.window")) {
            Picker(L("settings.window"), selection: windowBinding) {
                ForEach(InstanceConfigLogic.allowedWindows, id: \.self) { seconds in
                    Text(L(windowKey(seconds))).tag(seconds)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var exclusionsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("settings.network.exclusions"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            TextField(
                L("settings.network.exclusions"),
                text: exclusionsBinding
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 10))
            Text(L("settings.network.exclusions.hint"))
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    // MARK: 阈值节

    @ViewBuilder
    private var thresholdFields: some View {
        let unitKey = kind == .cpu
            ? "settings.threshold.unit.percent"
            : "settings.threshold.unit.rate"
        HStack(spacing: 8) {
            thresholdField(
                title: "\(L("settings.threshold.yellow")) (\(L(unitKey)))",
                binding: yellowBinding
            )
            thresholdField(
                title: "\(L("settings.threshold.red")) (\(L(unitKey)))",
                binding: redBinding
            )
        }
    }

    private func thresholdField(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            TextField(title, value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 10))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
    }

    private var unitPicker: some View {
        row(L("settings.unit")) {
            Picker(L("settings.unit"), selection: unitBinding) {
                ForEach(RateUnitPreference.allCases, id: \.self) { unit in
                    Text(L(unit.localizationKey)).tag(unit)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: 绑定（显示单位 ↔ 存储单位换算）

    private var windowBinding: Binding<Int> {
        Binding(
            get: { instance.single.windowSeconds },
            set: { newValue in
                var config = instance.single
                config.windowSeconds = newValue
                instance.update(config)
            }
        )
    }

    private var unitBinding: Binding<RateUnitPreference> {
        Binding(
            get: { instance.single.rateUnit },
            set: { newValue in
                var config = instance.single
                config.rateUnit = newValue
                instance.update(config)
            }
        )
    }

    private var exclusionsBinding: Binding<String> {
        Binding(
            get: {
                InstanceConfigLogic.formatExclusions(
                    InstanceConfigLogic.effectiveNetExclusions(instance.single)
                )
            },
            set: { text in
                var config = instance.single
                let parsed = InstanceConfigLogic.parseExclusions(text)
                config.networkExclusions = parsed == SystemMetricsLogic.defaultNetExclusions ? nil : parsed
                instance.update(config)
            }
        )
    }

    /// 黄线阈值（显示单位：CPU 百分比 0…100，磁盘/网络 MB/s）。
    private var yellowBinding: Binding<Double> {
        thresholdBinding(
            get: { effective($0.yellow) },
            set: { config, value in config.yellow = clamped(value) }
        )
    }

    private var redBinding: Binding<Double> {
        thresholdBinding(
            get: { effective($0.red) },
            set: { config, value in config.red = clamped(value) }
        )
    }

    private func thresholdBinding(
        get: @escaping (MetricThresholds) -> Double,
        set: @escaping (inout SingleBlockConfig, Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: {
                get(InstanceConfigLogic.effectiveThresholds(kind: kind, config: instance.single))
            },
            set: { displayValue in
                var config = instance.single
                set(&config, toStored(displayValue))
                instance.update(config)
            }
        )
    }

    /// 存储值（占比 / 字节每秒）→ 显示值（百分比 / MB/s）。
    private func effective(_ stored: Double?) -> Double {
        let value = stored ?? SystemMetricsLogic.defaultThresholds(for: kind).yellow
        return kind == .cpu ? value * 100 : value / 1_000_000
    }

    /// 显示值 → 存储值；CPU 钳到 1…100%，吞吐钳到 0.1…10⁵ MB/s。
    private func toStored(_ display: Double) -> Double {
        if kind == .cpu {
            return min(max(display, 1), 100) / 100
        }
        return min(max(display, 0.1), 100_000) * 1_000_000
    }

    /// 显示字段的钳制（保持输入框数值合理）。
    private func clamped(_ display: Double) -> Double { display }

    // MARK: 版式小件

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            content()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
            content()
        }
    }

    private func windowKey(_ seconds: Int) -> String {
        switch seconds {
        case 30: return "settings.window.30"
        case 60: return "settings.window.60"
        case 120: return "settings.window.120"
        default: return "settings.window.300"
        }
    }
}

// MARK: - All-in-one 实例设置

struct OverviewInstanceSettingsView: View {
    @ObservedObject var instance: SystemMonitorInstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.section.general"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
            Picker(L("settings.window"), selection: windowBinding) {
                ForEach(InstanceConfigLogic.allowedWindows, id: \.self) { seconds in
                    Text(L(windowKey(seconds))).tag(seconds)
                }
            }
            .controlSize(.small)

            Text(L("settings.section.metrics"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
            ForEach(MetricKind.allCases, id: \.self) { kind in
                Toggle(isOn: toggleBinding(kind)) {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 10))
                        Text(L(kind.displayNameKey))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var windowBinding: Binding<Int> {
        Binding(
            get: { instance.overview.windowSeconds },
            set: { newValue in
                var config = instance.overview
                config.windowSeconds = newValue
                instance.update(config)
            }
        )
    }

    /// 全关会被模型层兜底回全开；这里在 UI 层就拦住最后一项的关闭。
    private func toggleBinding(_ kind: MetricKind) -> Binding<Bool> {
        Binding(
            get: { instance.overview.enabled.contains(kind) },
            set: { isOn in
                var config = instance.overview
                if isOn {
                    config.enabled.insert(kind)
                } else {
                    guard config.enabled.count > 1 else { return }
                    config.enabled.remove(kind)
                }
                instance.update(config)
            }
        )
    }

    private func windowKey(_ seconds: Int) -> String {
        switch seconds {
        case 30: return "settings.window.30"
        case 60: return "settings.window.60"
        case 120: return "settings.window.120"
        default: return "settings.window.300"
        }
    }
}
