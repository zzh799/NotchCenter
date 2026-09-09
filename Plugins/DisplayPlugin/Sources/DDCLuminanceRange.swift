import CoreGraphics
import Foundation
import NotchCenterKit
import SwiftUI

// MARK: - DDC 写入值区间（按屏全局）
//
// 部分屏全量程两端不可用（0 附近黑屏、顶端刺眼），用户把 UI 百分比 0...100
// 映射到更小的 DDC 原始值区间再下发。区间是屏的全局属性：两块共用同一
// BrightnessController 单例与同一 percent，若按放置实例存，同屏两实例会对
// 同一硬件值算出不同百分比，自相矛盾，故按 displayID 全局存一份。

/// 用户设置的 DDC 原始值区间（存盘值，尚未按屏最大量程净化）。
struct DDCLuminanceRange: Codable, Equatable, Sendable {
    var min: Int
    var max: Int
}

enum DDCLuminanceRangeLogic {
    static let storeKey = "ddc.ranges"

    /// 按屏最大量程净化存盘区间：两端钳 0...maxLuminance 且 min<=max。
    /// 量程非法（maxLuminance<=0）或退化（min==max）回全量程，避免除零与单点锁定。
    static func sanitize(min: Int, max: Int, maxLuminance: Int) -> (lower: Int, upper: Int) {
        guard maxLuminance > 0 else { return (0, 0) }
        var lower = Swift.min(Swift.max(min, 0), maxLuminance)
        var upper = Swift.min(Swift.max(max, 0), maxLuminance)
        if lower > upper { swap(&lower, &upper) }
        if lower == upper { return (0, maxLuminance) }
        return (lower, upper)
    }

    /// 有效区间：无自定义即全量程，有自定义按当前屏最大量程净化。
    static func effectiveRange(custom: DDCLuminanceRange?, maxLuminance: Int) -> (lower: Int, upper: Int) {
        guard let custom else {
            return (0, Swift.max(maxLuminance, 0))
        }
        return sanitize(min: custom.min, max: custom.max, maxLuminance: maxLuminance)
    }

    /// 读插件级存储的全部区间（key 为 String(displayID)）；解码失败回空字典。
    @MainActor
    static func loadAll(from store: StateStore?) -> [String: DDCLuminanceRange] {
        guard let store else { return [:] }
        return store.object([String: DDCLuminanceRange].self, forKey: storeKey) ?? [:]
    }

    @MainActor
    static func saveAll(_ ranges: [String: DDCLuminanceRange], to store: StateStore?) {
        try? store?.setObject(ranges, forKey: storeKey)
    }

    static func key(for displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}

// MARK: - 区间编辑器（两块设置界面共用）
//
// 编辑的是按屏全局区间（见文件头）：single 与 sliders 两处写同一份值，
// 故 sliders 无需另存，设好即两边生效。

struct DDCRangeEditor: View {
    @ObservedObject var model: BrightnessDisplayModel
    @ObservedObject private var controller = BrightnessController.shared

    private var maxLuminance: Int { max(model.maxLuminance, 1) }
    private var bounds: (lower: Int, upper: Int) {
        controller.effectiveBounds(for: model.display.id, maxLuminance: model.maxLuminance)
    }
    private var isCustom: Bool { controller.customRanges[model.display.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("range.section"))
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(NotchTokens.Foreground.secondary)
                Spacer()
                if isCustom {
                    Button(L("range.reset")) {
                        controller.clearRange(for: model.display.id)
                    }
                    .buttonStyle(.link)
                    .font(NotchTokens.Text.system(11))
                }
            }
            HStack(spacing: 12) {
                Stepper(
                    "\(L("range.min")) \(bounds.lower)",
                    value: Binding(
                        get: { bounds.lower },
                        set: { controller.setRange(for: model.display.id, min: $0, max: bounds.upper) }),
                    in: 0...bounds.upper
                )
                .controlSize(.small)
                Stepper(
                    "\(L("range.max")) \(bounds.upper)",
                    value: Binding(
                        get: { bounds.upper },
                        set: { controller.setRange(for: model.display.id, min: bounds.lower, max: $0) }),
                    in: bounds.lower...maxLuminance
                )
                .controlSize(.small)
            }
            .font(NotchTokens.Text.system(11))
            .foregroundStyle(NotchTokens.Foreground.body)
        }
    }
}
