import Foundation

// MARK: - 用量数据类型（对应 dsh-opencode-usage 的 types.ts）

/// 一个用量窗口的身份：5 小时滚动 / 每周 / 每月。
enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case rolling
    case weekly
    case monthly

    /// 块内图例的短标签（rolling 的 "5h" 是技术缩写，不随语言变）。
    var shortLabel: String {
        switch self {
        case .rolling: return "5h"
        case .weekly: return L("windows.weekly")
        case .monthly: return L("windows.monthly")
        }
    }

    /// 内联 `$R[<n>]` 状态对象里对应的字段名（SSR 解析用）。
    var inlineStateKey: String {
        switch self {
        case .rolling: return "rollingUsage"
        case .weekly: return "weeklyUsage"
        case .monthly: return "monthlyUsage"
        }
    }
}

/// 一个用量窗口：已用百分比 + 距重置秒数。
struct UsageWindow: Codable, Equatable, Sendable {
    /// 0–100 整数百分比。
    let percent: Int
    /// 距窗口重置的秒数。
    let resetInSec: Int
    /// 窗口耗尽即被限流。
    var isRateLimited: Bool { percent >= 100 }
}

/// 从 workspace 页面解析出的 Zen 账户状态。字段缺失时为 nil（新账户 / 无订阅）。
struct ZenState: Codable, Equatable, Sendable {
    /// 当前余额（美元）。
    let balance: Double?
    /// 自动充值是否开启。
    let autoReload: Bool?
    /// 自动充值金额（美元）。
    let reloadAmount: Double?
    /// 自动充值触发阈值（美元）。
    let reloadTrigger: Double?
    /// 可选的月度消费上限（美元）。
    let monthlyLimit: Double?
    /// 支付方式简称（如 "alipay"）。
    let paymentMethodType: String?
    /// 订阅套餐（Go / Zen 等）。
    let subscriptionPlan: String?
}

/// 一次成功抓取后的完整快照。
struct UsageSnapshot: Codable, Equatable, Sendable {
    /// 最后一次成功抓取的时间戳（epoch 秒），用于展示数据新鲜度。
    let updatedAt: Date
    let zen: ZenState?
    let windows: [UsageWindowKind: UsageWindow]

    /// 任一窗口或余额至少有一项才算有效数据。
    var isEmpty: Bool {
        windows.isEmpty && (zen?.balance == nil)
    }
}
