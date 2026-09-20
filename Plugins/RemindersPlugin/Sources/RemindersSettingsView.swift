import NotchCenterKit
import SwiftUI

// MARK: - 放置实例设置（编辑模式块齿轮 → SettingPopover，每实例单独生效）
//
// 正式的选择入口（块内右上角角标是快速切换入口，两者写同一份 placementStore）。
// 走宿主齿轮是因为角标浮窗被夹在块矩形内，块小的时候它很挤；设置浮窗没有这个约束。

struct RemindersInstanceSettingsView: View {
    @ObservedObject var instance: RemindersInstanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.section.source"))
                    .font(NotchTokens.Text.system(10, weight: .medium))
                    .foregroundStyle(NotchTokens.Foreground.muted)
                Picker(L("settings.section.source"), selection: sourceBinding) {
                    Section(L("source.section.smart")) {
                        ForEach(RemindersSource.SmartList.allCases, id: \.self) { smart in
                            Text(RemindersSourceText.title(for: smart))
                                .tag(RemindersSource.smart(smart))
                        }
                    }
                    if !instance.lists.isEmpty {
                        Section(L("source.section.lists")) {
                            ForEach(instance.lists) { list in
                                Text(list.title)
                                    .tag(RemindersSource.list(list.id))
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                Text(L("settings.source.hint"))
                    .font(NotchTokens.Text.system(9))
                    .foregroundStyle(NotchTokens.Foreground.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(LF("settings.outstanding", instance.items.count))
                .font(NotchTokens.Text.system(11, weight: .medium))
                .foregroundStyle(NotchTokens.Foreground.secondary)

            if !instance.permission.isUsable {
                Button(L("gate.openSettings")) {
                    RemindersCore.shared.presentPermissionGuide()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceBinding: Binding<RemindersSource> {
        Binding(
            get: { instance.source },
            set: { instance.updateSource($0) })
    }
}
