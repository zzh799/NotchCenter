import Foundation

// MARK: - 配置（对应 dsh-opencode-usage 的 config.ts，持久化走 StateStore）

/// 持久化的插件配置。cookie 绝不写日志；settingsView 只展示尾 4 位掩码。
struct OpenCodeUsageConfig: Codable, Equatable, Sendable {
    /// 完整 `Cookie:` 头的值（经 normalizeCookie 归一化）。
    var cookie: String?
    /// OpenCode workspace id（如 `wrk_01...`）。
    var workspaceID: String?
    /// Provider 基地址；nil 用默认值。
    var baseURL: String?
    /// 缓存 TTL 秒数；nil 用默认值，读取时钳制到 [60, 3600]。
    var cacheTTLSeconds: Int?
}

enum OpenCodeUsageConfigLogic {
    static let defaultBaseURL = "https://opencode.ai"
    static let defaultCacheTTL: TimeInterval = 300
    static let minCacheTTL: TimeInterval = 60
    static let maxCacheTTL: TimeInterval = 3600

    /// StateStore 里配置对象的键。
    static let storeKey = "config"

    static func effectiveBaseURL(_ config: OpenCodeUsageConfig) -> URL? {
        if let raw = config.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: defaultBaseURL)
    }

    static func effectiveCacheTTL(_ config: OpenCodeUsageConfig) -> TimeInterval {
        guard let ttl = config.cacheTTLSeconds, ttl > 0 else { return defaultCacheTTL }
        return min(max(TimeInterval(ttl), minCacheTTL), maxCacheTTL)
    }

    /// 配置是否齐备到可以发起抓取。
    static func isConfigured(_ config: OpenCodeUsageConfig) -> Bool {
        guard let cookie = config.cookie, !cookie.isEmpty,
              let workspaceID = config.workspaceID, !workspaceID.isEmpty
        else { return false }
        return true
    }

    // MARK: 掩码视图（绝不外泄完整 cookie）

    struct MaskedSecret: Equatable, Sendable {
        let isSet: Bool
        /// 值的最后 4 位（长度 ≤ 4 时是完整值）。
        let tail: String
    }

    static func maskedSecret(_ value: String?) -> MaskedSecret {
        guard let value, !value.isEmpty else { return MaskedSecret(isSet: false, tail: "") }
        let tail = value.count <= 4 ? value : String(value.suffix(4))
        return MaskedSecret(isSet: true, tail: tail)
    }

    // MARK: cookie 归一化（从 config.ts 的 normalizeCookie 移植）
    //
    // 接受三种粘贴形态：
    //   1. 完整头："c_locale=zh; auth=Fe26.2*..."      （原样保留其余键值对）
    //   2. 仅 auth："Fe26.2*..."                        （自动加 "auth=" 前缀）
    //   3. 两段式："Fe26.2*...; oc_locale=zh"           （同上）
    // 识别规则：不含 '=' 的段就是裸 auth token；auth 是唯一必需项，
    // 其余 locale 类 cookie 可选，缺失时补 oc_locale=en。
    static func normalizeCookie(_ input: String?) -> String? {
        var trimmed = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.contains("  ") {
            trimmed = trimmed.replacingOccurrences(of: "  ", with: " ")
        }

        let segments = trimmed
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 无 '=' 的段视为裸 auth token；否则找显式的 auth= 段。
        let bareToken = segments.first { !$0.contains("=") && !$0.isEmpty }
        let authValue: String?
        if let bareToken {
            authValue = bareToken
        } else if let authSegment = segments.first(where: { $0.hasPrefix("auth=") }) {
            authValue = authSegment.dropFirst("auth=".count).trimmingCharacters(in: .whitespaces)
        } else {
            authValue = nil
        }
        guard let authValue, !authValue.isEmpty else { return nil }

        // 保留 auth 之外的 key=value cookie。
        var extras = segments.filter { $0.contains("=") && !$0.hasPrefix("auth=") }
        if !extras.contains(where: { $0.hasPrefix("oc_locale=") }) {
            extras.append("oc_locale=en")
        }
        if extras.isEmpty {
            return "auth=\(authValue)"
        }
        return "auth=\(authValue); \(extras.joined(separator: "; "))"
    }
}
