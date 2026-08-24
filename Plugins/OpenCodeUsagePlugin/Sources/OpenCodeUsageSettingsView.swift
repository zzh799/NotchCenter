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
                Text("Workspace ID")
                    .font(.system(size: 12, weight: .semibold))
            }

            LabeledContent {
                SecureField(maskedCookiePlaceholder, text: $cookieDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
            } label: {
                Text("Cookie")
                    .font(.system(size: 12, weight: .semibold))
            }
            .help("Paste the raw auth token, a full Cookie header, or anything in between.")

            LabeledContent {
                TextField(OpenCodeUsageConfigLogic.defaultBaseURL, text: $baseURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
            } label: {
                Text("Base URL")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 8) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if store.isConfigured {
                    Text("Cookie set (\(store.maskedCookie.tail)) · workspace \(workspaceSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Text("Usage is scraped from the opencode.ai dashboard pages (no public API). Cached for 5 minutes; failed fetches cool down for 60 seconds. The cookie is never logged.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(message.hasPrefix("Saved") ? Color.green.opacity(0.9) : .red.opacity(0.9))
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
        return masked.isSet ? "set" : "not set"
    }

    private var maskedCookiePlaceholder: String {
        let masked = store.maskedCookie
        return masked.isSet ? "Leave blank to keep (…\(masked.tail))" : "auth=…"
    }

    private func save() {
        if let error = store.saveConfig(
            cookie: cookieDraft.isEmpty ? nil : cookieDraft,
            workspaceID: workspaceDraft,
            baseURL: baseURLDraft
        ) {
            message = error
        } else {
            message = "Saved. Refreshing usage…"
            cookieDraft = ""
        }
    }
}
