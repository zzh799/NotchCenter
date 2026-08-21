import Foundation

// MARK: - API 版本校验（文档 §9.1）

/// 语义化版本号（`major.minor.patch`）。
public struct SemanticVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 解析 `"1"`、`"1.2"`、`"1.2.3"`、`"v1.2.3"`（可选 `v` 前缀，前后空白忽略）。
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.init(
            major: numbers[0]!,
            minor: numbers.count > 1 ? numbers[1]! : 0,
            patch: numbers.count > 2 ? numbers[2]! : 0
        )
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// 插件声明的 API 兼容范围（文档 §9.1），如 `"2.0..<3.0"`（含上界需 `...`）。
public struct APIVersionRange: Sendable, CustomStringConvertible, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `"1.2.3"` — 精确匹配。
        case exact(SemanticVersion)
        /// `"1.0..<2.0"` — 半开区间 [lower, upper)。
        case halfOpen(lower: SemanticVersion, upper: SemanticVersion)
        /// `"1.0...2.0"` — 闭区间 [lower, upper]。
        case closed(lower: SemanticVersion, upper: SemanticVersion)
    }

    public let kind: Kind

    /// 解析范围字符串：`"1.2.3"`、`"1.0..<2.0"`、`"1.0...2.0"`（忽略空白）。
    /// 区间两端可省略 patch（`"2.0"` 即 `2.0.0`）。
    public init?(string: String) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "..<") {
            let lower = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let upper = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let lowerVersion = SemanticVersion(string: lower),
                  let upperVersion = SemanticVersion(string: upper),
                  lowerVersion < upperVersion else {
                return nil
            }
            self.kind = .halfOpen(lower: lowerVersion, upper: upperVersion)
        } else if let range = value.range(of: "...") {
            let lower = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let upper = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let lowerVersion = SemanticVersion(string: lower),
                  let upperVersion = SemanticVersion(string: upper),
                  lowerVersion <= upperVersion else {
                return nil
            }
            self.kind = .closed(lower: lowerVersion, upper: upperVersion)
        } else if let version = SemanticVersion(string: value) {
            self.kind = .exact(version)
        } else {
            return nil
        }
    }

    /// 当前核心 API 版本是否落在该范围内。
    public func contains(_ version: SemanticVersion) -> Bool {
        switch kind {
        case let .exact(expected):
            return version == expected
        case let .halfOpen(lower, upper):
            return version >= lower && version < upper
        case let .closed(lower, upper):
            return version >= lower && version <= upper
        }
    }

    public var description: String {
        switch kind {
        case let .exact(version):
            return version.description
        case let .halfOpen(lower, upper):
            return "\(lower)..<\(upper)"
        case let .closed(lower, upper):
            return "\(lower)...\(upper)"
        }
    }
}

/// 当前核心 API 版本（文档 §9.1：「核心当前 API 版本为 NotchCenterKit 中定义的 currentVersion」）。
public enum NotchCenterKitAPI {
    /// 第一阶段基线版本。
    public static let currentVersion = SemanticVersion(major: 1, minor: 0, patch: 0)
}