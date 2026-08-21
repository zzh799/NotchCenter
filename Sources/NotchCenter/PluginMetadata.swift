import Foundation
import NotchCenterKit

/// 插件元数据（文档 §3.2 / §3.3）：从 bundle Info.plist 解析。
struct PluginMetadata: Equatable, Sendable {
    static let principalClassKey = "NSPrincipalClass"
    static let pluginIDKey = "NotchCenterPluginID"
    static let pluginVersionKey = "NotchCenterPluginVersion"
    static let apiVersionKey = "NotchCenterPluginAPIVersion"
    static let displayNameKey = "NotchCenterPluginDisplayName"
    static let descriptionKey = "NotchCenterPluginDescription"

    let bundleURL: URL
    let pluginID: String
    let pluginVersion: String
    let apiVersion: String
    let displayName: String
    let pluginDescription: String?
    let principalClassName: String
    let isBuiltIn: Bool

    /// 从 bundle 的 Info.plist 字典解析元数据；缺必需键或为空时抛出。
    init(bundleURL: URL, infoDictionary: [String: Any], isBuiltIn: Bool) throws {
        let requiredStrings: [(String, String)] = [
            (Self.principalClassKey, "NSPrincipalClass"),
            (Self.pluginIDKey, "NotchCenterPluginID"),
            (Self.pluginVersionKey, "NotchCenterPluginVersion"),
            (Self.apiVersionKey, "NotchCenterPluginAPIVersion"),
            (Self.displayNameKey, "NotchCenterPluginDisplayName")
        ]

        var parsed: [String: String] = [:]
        for (key, label) in requiredStrings {
            guard let value = infoDictionary[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginMetadataError.missingRequiredKey(bundleURL: bundleURL, key: label)
            }
            parsed[key] = value
        }

        self.bundleURL = bundleURL
        self.pluginID = parsed[Self.pluginIDKey]!
        self.pluginVersion = parsed[Self.pluginVersionKey]!
        self.apiVersion = parsed[Self.apiVersionKey]!
        self.displayName = parsed[Self.displayNameKey]!
        self.pluginDescription = infoDictionary[Self.descriptionKey] as? String
        self.principalClassName = parsed[Self.principalClassKey]!
        self.isBuiltIn = isBuiltIn
    }

    /// 解析声明 API 范围；无法解析视为不兼容。
    var apiVersionRange: APIVersionRange? {
        APIVersionRange(string: apiVersion)
    }

    /// 声明范围是否包含当前核心 API 版本（文档 §9.1）。
    var isAPICompatible: Bool {
        guard let range = apiVersionRange else { return false }
        return range.contains(NotchCenterKitAPI.currentVersion)
    }
}

enum PluginMetadataError: Error, LocalizedError {
    case missingRequiredKey(bundleURL: URL, key: String)

    var errorDescription: String? {
        switch self {
        case let .missingRequiredKey(bundleURL, key):
            return "Bundle at \(bundleURL.path) is missing required Info.plist key: \(key)"
        }
    }
}