import NotchCenterKit
import SwiftUI

// MARK: - 设置界面（计时设置 / 随机提示音 / 声音效果）

struct PomodoroSettingsView: View {
    @ObservedObject private var store = PomodoroStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("settings.section.timer")) {
                sliderRow(
                    L("settings.focusMinutes"),
                    value: configBinding(\.focusMinutes),
                    range: PomodoroConfigLogic.focusRange,
                    unit: minutesText
                )
                sliderRow(
                    L("settings.restMinutes"),
                    value: configBinding(\.restMinutes),
                    range: PomodoroConfigLogic.restRange,
                    unit: minutesText
                )
            }

            section(L("settings.section.reminder")) {
                sliderRow(
                    L("settings.reminderMin"),
                    value: configBinding(\.reminderMinMinutes),
                    range: PomodoroConfigLogic.reminderMinRange,
                    unit: minutesText
                )
                sliderRow(
                    L("settings.reminderMax"),
                    value: configBinding(\.reminderMaxMinutes),
                    range: PomodoroConfigLogic.reminderMaxRange,
                    unit: minutesText
                )
                sliderRow(
                    L("settings.microBreakDuration"),
                    value: configBinding(\.microBreakSeconds),
                    range: PomodoroConfigLogic.microBreakRange,
                    step: 5,
                    unit: secondsText
                )
            }

            section(L("settings.section.sound")) {
                soundRow(L("settings.sound.microBreak"), value: soundBinding(\.microBreakSound))
                soundRow(L("settings.sound.start"), value: soundBinding(\.startSound))
                soundRow(L("settings.sound.end"), value: soundBinding(\.endSound))
            }

            Text(L("settings.explanation"))
                .font(NotchTokens.Text.system( 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分节与行

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(NotchTokens.Text.system( 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: (Int) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(NotchTokens.Text.system( 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 72, alignment: .leading)
            // macOS 14 的 Slider 没有 Int 泛型重载：Int 值经 Double 桥接，
            // 步进在 setter 内量化。
            Slider(
                value: Binding<Double>(
                    get: { Double(value.wrappedValue) },
                    set: { newValue in
                        let stepped = (newValue / Double(step)).rounded() * Double(step)
                        value.wrappedValue = Int(stepped)
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .controlSize(.small)
            Text(unit(value.wrappedValue))
                .font(NotchTokens.Text.system( 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func soundRow(_ title: String, value: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(NotchTokens.Text.system( 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 72, alignment: .leading)
            Picker("", selection: value) {
                Text(L("sound.none")).tag(PomodoroSoundCatalog.noneID)
                ForEach(PomodoroSoundCatalog.names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)
            Button {
                store.preview(value.wrappedValue)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(NotchTokens.Text.system( 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(L("settings.preview"))
        }
    }

    // MARK: 绑定

    private func configBinding(_ keyPath: WritableKeyPath<PomodoroConfig, Int>) -> Binding<Int> {
        Binding(
            get: { store.config[keyPath: keyPath] },
            set: { newValue in store.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func soundBinding(_ keyPath: WritableKeyPath<PomodoroConfig, String>) -> Binding<String> {
        Binding(
            get: { store.config[keyPath: keyPath] },
            set: { newValue in store.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func minutesText(_ minutes: Int) -> String {
        LF("unit.minutes", minutes)
    }

    private func secondsText(_ seconds: Int) -> String {
        LF("unit.seconds", seconds)
    }
}
