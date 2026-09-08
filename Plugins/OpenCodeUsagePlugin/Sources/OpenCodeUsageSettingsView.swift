import NotchCenterKit
import SwiftUI

// MARK: - 设置界面（嵌入插件管理窗口，文档 §4.7）
//
// cookie 只展示尾 4 位掩码；输入框留空表示保留现值，避免已保存的
// token 在界面上回显完整明文。

struct OpenCodeUsageSettingsView: View {
    @ObservedObject private var store = OpenCodeUsageStore.shared
    @State private var workspaceDraft = ""
    @State private var baseURLDraft = ""
    @State private var cookieDraft = ""
    @State private var message: String?
    /// 最近一次保存是否成功（决定状态文字颜色，与语言无关）。
    @State private var messageIsError = false
    @State private var didLoadCurrentValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Workspace ID 非敏感，直接回显当前值。
            LabeledContent {
                TextField("wrk_...", text: $workspaceDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
            } label: {
                Text(L("settings.workspaceID"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
            }

            LabeledContent {
                SecureField(maskedCookiePlaceholder, text: $cookieDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
            } label: {
                Text(L("settings.cookie"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
            }
            .help(L("settings.cookieHelp"))

            LabeledContent {
                TextField(OpenCodeUsageConfigLogic.defaultBaseURL, text: $baseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
            } label: {
                Text(L("settings.baseURL"))
                    .font(NotchTokens.Text.system(12, weight: .semibold))
            }

            HStack(spacing: 8) {
                Button(L("common.save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if store.isConfigured {
                    Text(LF("settings.statusConfigured", store.maskedCookie.tail, workspaceSummary))
                        .font(NotchTokens.Text.system(11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Text(L("settings.explanation"))
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(NotchTokens.Text.system(11))
                    // 成功/失败用显式状态区分：不再用文案前缀判断（本地化后前缀随语言变）。
                    .foregroundStyle(messageIsError ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 只在首次出现时回填草稿；之后以用户编辑为准。
            guard !didLoadCurrentValues else { return }
            didLoadCurrentValues = true
            workspaceDraft = store.config.workspaceID ?? ""
            baseURLDraft = store.config.baseURL ?? ""
        }
    }

    private var workspaceSummary: String {
        let masked = store.maskedWorkspaceID
        return masked.isSet ? L("common.set") : L("common.notSet")
    }

    private var maskedCookiePlaceholder: String {
        let masked = store.maskedCookie
        return masked.isSet ? LF("settings.cookiePlaceholderKeep", masked.tail) : "auth=…"
    }

    private func save() {
        if let error = store.saveConfig(
            cookie: cookieDraft.isEmpty ? nil : cookieDraft,
            workspaceID: workspaceDraft,
            baseURL: baseURLDraft
        ) {
            message = error
            messageIsError = true
        } else {
            message = L("settings.saved")
            messageIsError = false
            cookieDraft = ""
        }
    }
}
