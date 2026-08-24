import Foundation

// MARK: - SSR 页面解析（纯函数，从 dsh-opencode-usage 的 api.ts 移植）
//
// opencode.ai 没有公开的 Zen/Go 余额 API，唯一的 cookie 鉴权读取方式是抓取
// dashboard 的 SolidStart SSR HTML：用量与余额都在 `data-slot` 块里，带
// `<!--$-->` 注释标记。优先解析稳定的 HTML 展示层，再从内联的
// `$R[<n>]={...}` 流式状态对象里取精确的 resetInSec。
enum OpenCodeUsageParser {
    // MARK: Go 用量页（/workspace/<id>/go）

    struct GoPageResult: Equatable, Sendable {
        var windows: [UsageWindowKind: UsageWindow] = [:]
    }

    /// 解析 Go 用量页：三个窗口的 label / percent / reset 文本，
    /// resetInSec 优先用内联状态对象里的精确值。
    static func parseGoPage(_ html: String) -> GoPageResult {
        var result = GoPageResult()
        let starts = allMatchLocations("<div[^>]*data-slot=\"usage-item\"", in: html)
        let inlineReset = Dictionary(uniqueKeysWithValues: UsageWindowKind.allCases.map { kind in
            (kind, inlineResetInSec(html, key: kind.inlineStateKey))
        })

        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : (html as NSString).length
            guard let blockRange = Range(NSRange(location: start, length: end - start), in: html) else {
                continue
            }
            let block = String(html[blockRange])

            // label：<span data-slot="usage-label" ...>Rolling usage</span>
            guard let label = groups("data-slot=\"usage-label\"[^>]*>([^<]+)<", in: block)?.last,
                  let kind = labelToKind(label),
                  // value：<!--$-->42<!--/-->
                  let percentText = groups(
                      "data-slot=\"usage-value\"[\\s\\S]*?<!--\\$-->\\s*(\\d+)\\s*<!--/-->",
                      in: block
                  )?.last,
                  let percent = Int(percentText)
            else { continue }

            // reset 文本：Resets in<!--/--> 2 hours 29 minutes<!--/-->
            let resetsIn = groups(
                "data-slot=\"reset-time\"[\\s\\S]*?Resets in(?:<!--/-->\\s*)?([\\s\\S]*?)(?:<!--/-->|</span>)",
                in: block
            ).map { stripHTMLComments($0.last ?? "") } ?? ""

            result.windows[kind] = UsageWindow(
                percent: clampPercent(percent),
                // 内联状态的精确秒数优先，人类可读短语兜底。
                resetInSec: (inlineReset[kind] ?? nil) ?? parseDurationToSec(resetsIn)
            )
        }
        return result
    }

    /// 把 usage-item 的 label 映射回窗口身份；无法识别返回 nil。
    private static func labelToKind(_ label: String) -> UsageWindowKind? {
        let lower = label.lowercased()
        if lower.hasPrefix("rolling") { return .rolling }
        if lower.hasPrefix("weekly") { return .weekly }
        if lower.hasPrefix("monthly") { return .monthly }
        return nil
    }

    /// 从内联 `<key>:$R[<n>]={...}` 状态对象里读精确的 resetInSec。
    static func inlineResetInSec(_ html: String, key: String) -> Int? {
        guard let state = groups(key + ":\\$R\\[\\d+\\]=\\{([^{}]*)\\}", in: html)?.last,
              let seconds = groups("resetInSec:(\\d+)", in: state)?.last
        else { return nil }
        return Int(seconds)
    }

    // MARK: Zen workspace 页（/workspace/<id>）

    /// 解析 workspace 页：余额走 HTML 展示层（可靠），其余字段从内联状态对象取。
    static func parseZenPage(_ html: String) -> ZenState {
        // 展示层：<b>$<!--$-->12.34<!--/-->
        let balanceHTML = groups(
            "data-slot=\"balance\"[\\s\\S]*?<b>\\$<!--\\$-->\\s*([0-9,.]+)\\s*<!--/-->",
            in: html
        )?.last.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
        // 内联兜底：balance:12.34 或 balance:$R[2]=12.34
        let balanceState = numMatch(html, key: "balance")
        let balance = balanceState ?? balanceHTML

        let reloadBlock = groups("reload:(\\{[^{}]*\\}|null)", in: html)?.last
        return ZenState(
            balance: balance,
            autoReload: reloadBlock.map { $0 != "null" },
            reloadAmount: numMatch(html, key: "reloadAmount"),
            reloadTrigger: numMatch(html, key: "reloadTrigger"),
            monthlyLimit: stringMatch(html, key: "monthlyLimit").flatMap { $0 == "null" ? nil : Double($0) },
            paymentMethodType: stringMatch(html, key: "paymentMethodType"),
            subscriptionPlan: stringMatch(html, key: "subscriptionPlan")
        )
    }

    /// Go 页与 Zen 页都解析不出任何已知字段时视为空结果
    /// （页面 302 跳登录页时就是这种形态，等价于 cookie 失效）。
    static func isParsedEmpty(go: GoPageResult, zen: ZenState) -> Bool {
        go.windows.isEmpty && zen.balance == nil
    }

    // MARK: 时长短语 → 秒

    /// 把人类可读时长解析为秒："2 hours 29 minutes" → 8940、
    /// "45 minutes" → 2700、"5 days" → 432000。无法识别返回 0。
    static func parseDurationToSec(_ phrase: String) -> Int {
        let cleaned = stripHTMLComments(phrase)
        guard !cleaned.isEmpty else { return 0 }
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*(second|minute|hour|day|week|month|year)s?") else {
            return 0
        }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        var total = 0
        for match in regex.matches(in: cleaned, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: cleaned),
                  let unitRange = Range(match.range(at: 2), in: cleaned),
                  let number = Int(cleaned[numberRange])
            else { continue }
            switch cleaned[unitRange] {
            case "second": total += number
            case "minute": total += number * 60
            case "hour": total += number * 3600
            case "day": total += number * 86400
            case "week": total += number * 604800
            case "month": total += number * 2592000
            case "year": total += number * 31536000
            default: break
            }
        }
        return total
    }

    static func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    // MARK: 展示辅助

    /// 秒数 → 紧凑时长文案（"2hr 29min" / "45min" / "5d"）。
    /// 固定 POSIX 区域：块内 UI 文案约定英文，不随系统语言变化。
    static func formatReset(seconds: Int) -> String {
        guard seconds > 0 else { return "soon" }
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            return calendar
        }()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    // MARK: 正则工具

    /// 第一个匹配的全部捕获组（最后一个元素即第 1 捕获组）。
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// 内联状态对象里的 `key:<number>`（容忍 `key:$R[n]=` 前缀）。
    private static func numMatch(_ html: String, key: String) -> Double? {
        guard let raw = groups(key + ":(?:\\$R\\[\\d+\\]=)?(\\d+(?:\\.\\d+)?)", in: html)?.last else {
            return nil
        }
        return Double(raw)
    }

    /// 内联状态对象里的 `key:"value"`。
    private static func stringMatch(_ html: String, key: String) -> String? {
        groups(key + ":\"((?:[^\"\\\\]|\\\\.)*)\"", in: html)?.last
    }

    private static func allMatchLocations(_ pattern: String, in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map(\.range.location)
    }

    /// 剥掉 SolidStart 的 `<!-- ... -->` 注释并修剪空白。
    static func stripHTMLComments(_ source: String) -> String {
        source.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
