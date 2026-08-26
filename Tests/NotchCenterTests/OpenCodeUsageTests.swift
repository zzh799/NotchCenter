import XCTest
import NotchCenterKit

@testable import OpenCodeUsagePlugin

/// OpenCodeUsagePlugin 纯逻辑测试：cookie 归一化、SSR HTML 解析、
/// 时长短语解析。不发真实网络请求，不触碰 opencode.ai。
final class OpenCodeUsageTests: XCTestCase {
    // MARK: cookie 归一化（对齐 config.ts normalizeCookie）

    func testNormalizeCookieBareToken() throws {
        XCTAssertEqual(
            OpenCodeUsageConfigLogic.normalizeCookie("Fe26.2*abcDEF123"),
            "auth=Fe26.2*abcDEF123; oc_locale=en"
        )
    }

    func testNormalizeCookieFullHeaderKeepsExtrasAndAddsLocale() {
        XCTAssertEqual(
            OpenCodeUsageConfigLogic.normalizeCookie("c_locale=zh; auth=TOKEN123; x=1"),
            "auth=TOKEN123; c_locale=zh; x=1; oc_locale=en"
        )
    }

    func testNormalizeCookieTwoSegmentsKeepsExistingLocale() {
        XCTAssertEqual(
            OpenCodeUsageConfigLogic.normalizeCookie("TOKEN; oc_locale=zh"),
            "auth=TOKEN; oc_locale=zh"
        )
    }

    func testNormalizeCookieExplicitAuthOnly() {
        XCTAssertEqual(
            OpenCodeUsageConfigLogic.normalizeCookie("auth=TOKEN"),
            "auth=TOKEN; oc_locale=en"
        )
    }

    func testNormalizeCookieRejectsPairsWithoutAuth() {
        XCTAssertNil(OpenCodeUsageConfigLogic.normalizeCookie("a=b; c=d"))
        XCTAssertNil(OpenCodeUsageConfigLogic.normalizeCookie("   "))
        XCTAssertNil(OpenCodeUsageConfigLogic.normalizeCookie(nil))
    }

    // MARK: 掩码

    func testMaskedSecretShowsTail4() {
        XCTAssertEqual(OpenCodeUsageConfigLogic.maskedSecret("abcdefgh"), .init(isSet: true, tail: "efgh"))
        XCTAssertEqual(OpenCodeUsageConfigLogic.maskedSecret("abc"), .init(isSet: true, tail: "abc"))
        XCTAssertEqual(OpenCodeUsageConfigLogic.maskedSecret(nil), .init(isSet: false, tail: ""))
    }

    // MARK: 配置派生值

    func testCacheTTLClampedToRange() {
        var config = OpenCodeUsageConfig()
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveCacheTTL(config), 300)
        config.cacheTTLSeconds = 5
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveCacheTTL(config), 60)
        config.cacheTTLSeconds = 99_999
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveCacheTTL(config), 3600)
    }

    func testBaseURLFallback() {
        var config = OpenCodeUsageConfig()
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveBaseURL(config)?.absoluteString, "https://opencode.ai")
        config.baseURL = "  "
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveBaseURL(config)?.absoluteString, "https://opencode.ai")
        config.baseURL = "https://example.com"
        XCTAssertEqual(OpenCodeUsageConfigLogic.effectiveBaseURL(config)?.absoluteString, "https://example.com")
    }

    // MARK: 时长短语 → 秒（对齐 api.ts parseDurationToSec）

    func testParseDurationToSec() {
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("2 hours 29 minutes"), 8940)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("45 minutes"), 2700)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("5 days"), 432000)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("30 seconds"), 30)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("1 week"), 604800)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec("garbage"), 0)
        XCTAssertEqual(OpenCodeUsageParser.parseDurationToSec(""), 0)
    }

    // MARK: Go 用量页解析

    private let goFixture = """
    <html><body>
    <div data-slot="usage-item">
      <span data-slot="usage-label">Rolling usage</span>
      <div data-slot="usage-value"><!--$-->42<!--/-->
        <span data-slot="reset-time">Resets in<!--/--> 2 hours 29 minutes<!--/--></span>
      </div>
    </div>
    <div data-slot="usage-item">
      <span data-slot="usage-label">Weekly usage</span>
      <div data-slot="usage-value"><!--$-->100<!--/-->
        <span data-slot="reset-time">Resets in<!--/--> 5 days<!--/--></span>
      </div>
    </div>
    <div data-slot="usage-item">
      <span data-slot="usage-label">Monthly usage</span>
      <div data-slot="usage-value"><!--$-->3<!--/-->
        <span data-slot="reset-time">Resets in<!--/--> 25 days<!--/--></span>
      </div>
    </div>
    <script>rollingUsage:$R[3]={status:"ok",resetInSec:8900,usagePercent:42}</script>
    </body></html>
    """

    func testParseGoPageWindowsAndInlineResetPrecedence() {
        let result = OpenCodeUsageParser.parseGoPage(goFixture)
        XCTAssertEqual(result.windows.count, 3)

        // 内联 $R 状态的精确 resetInSec（8900）优先于短语解析结果（8940）。
        let rolling = try! XCTUnwrap(result.windows[.rolling])
        XCTAssertEqual(rolling.percent, 42)
        XCTAssertEqual(rolling.resetInSec, 8900)
        XCTAssertFalse(rolling.isRateLimited)

        // 耗尽的窗口标记限流；无内联状态时回退短语解析。
        let weekly = try! XCTUnwrap(result.windows[.weekly])
        XCTAssertTrue(weekly.isRateLimited)
        XCTAssertEqual(weekly.resetInSec, 432000)

        let monthly = try! XCTUnwrap(result.windows[.monthly])
        XCTAssertEqual(monthly.percent, 3)
    }

    func testParseGoPageWithoutInlineStateUsesPhrase() {
        let html = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Rolling usage</span>
          <div data-slot="usage-value"><!--$-->7<!--/-->
            <span data-slot="reset-time">Resets in<!--/--> 45 minutes<!--/--></span>
          </div>
        </div>
        """
        let result = OpenCodeUsageParser.parseGoPage(html)
        XCTAssertEqual(result.windows[.rolling]?.resetInSec, 2700)
    }

    func testParseGoPageIgnoresUnknownLabels() {
        let html = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Something else</span>
          <div data-slot="usage-value"><!--$-->50<!--/--></div>
        </div>
        """
        XCTAssertTrue(OpenCodeUsageParser.parseGoPage(html).windows.isEmpty)
    }

    func testInlineResetInSecKeyMismatchReturnsNil() {
        XCTAssertNil(OpenCodeUsageParser.inlineResetInSec(goFixture, key: "weeklyUsage"))
        XCTAssertEqual(OpenCodeUsageParser.inlineResetInSec(goFixture, key: "rollingUsage"), 8900)
    }

    // MARK: Go 用量页解析（2025-08 改版后的真实 SSR 形态）

    /// 实测改版页：标签改为 "<N> Usage"、百分比带小数、内联 $R 状态对象齐全
    /// （5-hour 0%、Weekly 3.7%、Monthly 65.8%，status 均为 ok）。
    private let modernGoFixture = """
    <html><body>
    <div data-slot="usage-item">
      <span data-slot="usage-label">5-hour Usage</span>
      <div data-slot="usage-value"><!--$-->0%<!--/-->
        <div role="progressbar" aria-valuenow="0"></div>
        <span data-slot="reset-time">Resets in<!--/--> 5 hours<!--/--></span>
      </div>
    </div>
    <div data-slot="usage-item">
      <span data-slot="usage-label">Weekly Usage</span>
      <div data-slot="usage-value"><!--$-->3.7%<!--/-->
        <div role="progressbar" aria-valuenow="3.7"></div>
        <span data-slot="reset-time">Resets in<!--/--> 4 days 12 hours<!--/--></span>
      </div>
    </div>
    <div data-slot="usage-item">
      <span data-slot="usage-label">Monthly Usage</span>
      <div data-slot="usage-value"><!--$-->65.8%<!--/-->
        <div role="progressbar" aria-valuenow="65.8"></div>
        <span data-slot="reset-time">Resets in<!--/--> 24 days 2 hours<!--/--></span>
      </div>
    </div>
    <div>© 2026 OpenCode</div>
    <script>rollingUsage:$R[36]={status:"ok",resetInSec:18000,usagePercent:0},weeklyUsage:$R[37]={status:"ok",resetInSec:388800,usagePercent:3.7},monthlyUsage:$R[38]={status:"ok",resetInSec:2086526,usagePercent:65.8}</script>
    </body></html>
    """

    func testParseGoPageModernLayoutAllThreeWindows() throws {
        let result = OpenCodeUsageParser.parseGoPage(modernGoFixture)
        XCTAssertEqual(result.windows.count, 3)

        let rolling = try XCTUnwrap(result.windows[.rolling])
        XCTAssertEqual(rolling.percent, 0)
        XCTAssertEqual(rolling.resetInSec, 18000)
        XCTAssertFalse(rolling.isRateLimited)

        let weekly = try XCTUnwrap(result.windows[.weekly])
        XCTAssertEqual(weekly.percent, 3.7, accuracy: 0.001)
        XCTAssertEqual(weekly.resetInSec, 388800)

        let monthly = try XCTUnwrap(result.windows[.monthly])
        // 小数不再失配错抓（旧正则会跳过 65.8 抓到年份 2026 → 钳位成 100%）。
        XCTAssertEqual(monthly.percent, 65.8, accuracy: 0.001)
        XCTAssertFalse(monthly.isRateLimited)
        XCTAssertEqual(monthly.resetInSec, 2086526)
    }

    func testParseGoPageInlineStateWinsOverDisplayLayer() {
        // 展示层是过期的整数文本，内联状态的小数与精确秒数必须胜出。
        let html = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">5-hour Usage</span>
          <div data-slot="usage-value"><!--$-->1%<!--/-->
            <span data-slot="reset-time">Resets in<!--/--> 45 minutes<!--/--></span>
          </div>
        </div>
        <script>rollingUsage:$R[4]={status:"ok",resetInSec:7200,usagePercent:12.5}</script>
        """
        let result = OpenCodeUsageParser.parseGoPage(html)
        let rolling = try! XCTUnwrap(result.windows[.rolling])
        XCTAssertEqual(rolling.percent, 12.5, accuracy: 0.001)
        XCTAssertEqual(rolling.resetInSec, 7200)
    }

    func testParseGoPageRecoversWindowFromInlineStateWhenLabelUnknown() {
        // 标签再次改名也不丢窗口：内联状态对象不受展示层影响。
        let html = #"<script>rollingUsage:$R[9]={status:"ok",resetInSec:7200,usagePercent:12.5}</script>"#
        let result = OpenCodeUsageParser.parseGoPage(html)
        XCTAssertEqual(result.windows[.rolling]?.percent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(result.windows[.rolling]?.resetInSec, 7200)
    }

    func testParseGoPageDisplayLayerFallbacks() {
        // 无内联状态时：aria-valuenow 优先，注释包裹小数文本次之，短语兜底 reset。
        let ariaOnly = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Monthly Usage</span>
          <div role="progressbar" aria-valuenow="65.8"></div>
          <span data-slot="reset-time">Resets in<!--/--> 25 days<!--/--></span>
        </div>
        """
        let fromAria = OpenCodeUsageParser.parseGoPage(ariaOnly)
        XCTAssertEqual(fromAria.windows[.monthly]?.percent ?? -1, 65.8, accuracy: 0.001)
        XCTAssertEqual(fromAria.windows[.monthly]?.resetInSec, 2160000)

        let commentOnly = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Weekly usage</span>
          <div data-slot="usage-value"><!--$-->3.7%<!--/-->
            <span data-slot="reset-time">Resets in<!--/--> 90 minutes<!--/--></span>
          </div>
        </div>
        """
        let fromComment = OpenCodeUsageParser.parseGoPage(commentOnly)
        XCTAssertEqual(fromComment.windows[.weekly]?.percent ?? -1, 3.7, accuracy: 0.001)
        XCTAssertEqual(fromComment.windows[.weekly]?.resetInSec, 5400)
    }

    func testInlineUsageStateParsesAllFields() {
        let state = try! XCTUnwrap(OpenCodeUsageParser.inlineUsageState(modernGoFixture, key: "monthlyUsage"))
        XCTAssertEqual(state.status, "ok")
        XCTAssertEqual(state.resetInSec, 2086526)
        XCTAssertEqual(state.usagePercent ?? -1, 65.8, accuracy: 0.001)
        XCTAssertNil(OpenCodeUsageParser.inlineUsageState(modernGoFixture, key: "dailyUsage"))
    }

    func testPercentTextDropsTrailingZero() {
        XCTAssertEqual(UsageWindow(percent: 65.8, resetInSec: 10).percentText, "65.8")
        XCTAssertEqual(UsageWindow(percent: 42, resetInSec: 10).percentText, "42")
        XCTAssertEqual(UsageWindow(percent: 100, resetInSec: 10).percentText, "100")
    }

    // MARK: Zen workspace 页解析

    private let zenFixture = """
    <html><body>
    <div data-slot="balance"><span><!--$-->Current balance<!--/--></span> <b>$<!--$-->12.34<!--/--></b></div>
    <script>$R[1]={balance:12.34,reload:null,reloadAmount:20,reloadTrigger:10,monthlyLimit:null,paymentMethodType:"alipay",subscriptionPlan:"go"}</script>
    </body></html>
    """

    func testParseZenPageFullState() {
        let zen = OpenCodeUsageParser.parseZenPage(zenFixture)
        XCTAssertEqual(zen.balance, 12.34)
        XCTAssertEqual(zen.autoReload, false)
        XCTAssertEqual(zen.reloadAmount, 20)
        XCTAssertEqual(zen.reloadTrigger, 10)
        XCTAssertNil(zen.monthlyLimit)
        XCTAssertEqual(zen.paymentMethodType, "alipay")
        XCTAssertEqual(zen.subscriptionPlan, "go")
    }

    func testParseZenPageBalanceHTMLFallback() {
        // 无内联状态对象时回退 HTML 展示层（含千分位逗号）。
        let html = #"<div data-slot="balance"><b>$<!--$-->1,234.56<!--/--></b></div>"#
        let zen = OpenCodeUsageParser.parseZenPage(html)
        XCTAssertEqual(zen.balance, 1234.56)
        XCTAssertNil(zen.autoReload)
    }

    // MARK: 空结果判定（等价 cookie 失效被 302 到登录页）

    func testParsedEmptyDetection() {
        let emptyZen = OpenCodeUsageParser.parseZenPage("<html><body>login</body></html>")
        XCTAssertTrue(emptyZen.balance == nil)
        let emptyGo = OpenCodeUsageParser.parseGoPage("<html><body>login</body></html>")
        XCTAssertTrue(OpenCodeUsageParser.isParsedEmpty(go: emptyGo, zen: emptyZen))
        XCTAssertFalse(OpenCodeUsageParser.isParsedEmpty(go: OpenCodeUsageParser.parseGoPage(goFixture), zen: emptyZen))
    }

    // MARK: 展示辅助

    func testFormatReset() {
        XCTAssertEqual(OpenCodeUsageParser.formatReset(seconds: 0), "soon")
        XCTAssertEqual(OpenCodeUsageParser.formatReset(seconds: 8940), "2h 29m")
        XCTAssertEqual(OpenCodeUsageParser.formatReset(seconds: 432000), "5d")
    }
}

/// 放置实例外观（每块单独设置）的纯逻辑测试：默认值、容错解码、
/// placementStore 持久化往返与实例隔离。不发网络请求。
@MainActor
final class OpenCodeUsageAppearanceTests: XCTestCase {
    private func makePluginStore() throws -> (StateStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        return (StateStore(rootDirectory: directory), directory)
    }

    func testDefaultAppearanceMatchesLegacyLook() {
        // 缺省 = 余量环 + 峰谷倒计时：老布局零迁移，视觉与单实例时代一致。
        XCTAssertEqual(OpenCodeUsageAppearance.default, .init(style: .rings, footer: .phaseCountdown))
    }

    func testDecodingToleratesMissingFieldsAndGarbage() throws {
        let appearance = try JSONDecoder().decode(OpenCodeUsageAppearance.self, from: Data("{}".utf8))
        XCTAssertEqual(appearance, .default)

        let partial = try JSONDecoder().decode(
            OpenCodeUsageAppearance.self,
            from: Data(#"{"style":"peakClock"}"#.utf8)
        )
        XCTAssertEqual(partial.style, .peakClock)
        XCTAssertEqual(partial.footer, .phaseCountdown)

        // 未知样式 / 损坏文件 → load 回退默认值（自愈，不崩溃）。
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeUsageAppearance.self, from: Data(#"{"style":"hologram"}"#.utf8)))
        XCTAssertEqual(OpenCodeUsageAppearanceLogic.load(from: nil), .default)
    }

    func testLegacyBooleanCountdownMigratesToFooter() throws {
        // 旧版 showsPhaseCountdown 布尔开关 → 新 footer 枚举的读取迁移。
        let legacyOn = try JSONDecoder().decode(
            OpenCodeUsageAppearance.self,
            from: Data(#"{"showsPhaseCountdown":true}"#.utf8)
        )
        XCTAssertEqual(legacyOn.footer, .phaseCountdown)

        let legacyOff = try JSONDecoder().decode(
            OpenCodeUsageAppearance.self,
            from: Data(#"{"showsPhaseCountdown":false}"#.utf8)
        )
        XCTAssertEqual(legacyOff.footer, .none)

        // 新字段优先于旧字段。
        let both = try JSONDecoder().decode(
            OpenCodeUsageAppearance.self,
            from: Data(#"{"footer":"zenBalance","showsPhaseCountdown":false}"#.utf8)
        )
        XCTAssertEqual(both.footer, .zenBalance)

        // 未知枚举值同样自愈回默认。
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeUsageAppearance.self, from: Data(#"{"footer":"stockTicker"}"#.utf8)))
    }

    func testSaveLoadRoundTripThroughPlacementScope() throws {
        let (pluginStore, directory) = try makePluginStore()
        defer { cleanUpIfPossible(directory) }

        let placementID = "PLCT0001-2222-3333-4444-555566667777"
        let otherID = "PLCT0002-2222-3333-4444-555566667777"
        // 注册表是进程级单例：先清掉可能残留的缓存，确保模型绑定本次的 store。
        OpenCodeUsageInstanceRegistry.shared.discard(placementID: placementID)
        OpenCodeUsageInstanceRegistry.shared.discard(placementID: otherID)

        guard let scope = pluginStore.placementScope(placementID: placementID) else {
            return XCTFail("合法 placementID 必须可派生作用域")
        }

        var appearance = OpenCodeUsageAppearance()
        appearance.style = .meters
        appearance.footer = .zenBalance
        OpenCodeUsageAppearanceLogic.save(appearance, to: scope)
        XCTAssertEqual(OpenCodeUsageAppearanceLogic.load(from: scope), appearance)

        // 注册表经插件级 store 取同一实例时读到相同配置；另一实例互不影响。
        let model = OpenCodeUsageInstanceRegistry.shared.model(placementID: placementID, stateStore: pluginStore)
        XCTAssertEqual(model.appearance, appearance)

        let otherModel = OpenCodeUsageInstanceRegistry.shared.model(placementID: otherID, stateStore: pluginStore)
        XCTAssertEqual(otherModel.appearance, .default)

        // 更新走模型入口：内存 @Published 与持久化文件同步变化。
        model.update(.default)
        XCTAssertEqual(model.appearance, .default)
        let reloadedScope = StateStore(rootDirectory: directory).placementScope(placementID: placementID)
        XCTAssertEqual(OpenCodeUsageAppearanceLogic.load(from: reloadedScope), .default)

        OpenCodeUsageInstanceRegistry.shared.discard(placementID: placementID)
        OpenCodeUsageInstanceRegistry.shared.discard(placementID: otherID)
    }

    /// 测试目录可能因断言失败未被 defer 清理；尽力兜底。
    private func cleanUpIfPossible(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 峰谷时钟纯逻辑测试（固定 UTC 偏移，不依赖运行机器时区）。
final class PeakClockLogicTests: XCTestCase {
    /// 2024-01-15 HH:mm UTC 的固定时刻。
    private func utc(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 15
        components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private let utcTZ = 0
    private let plus8TZ = 8 * 3600

    func testPeakWindowsUTC() {
        XCTAssertTrue(PeakClockLogic.isPeak(utc(1)))
        XCTAssertTrue(PeakClockLogic.isPeak(utc(3, 59)))
        XCTAssertFalse(PeakClockLogic.isPeak(utc(4)))
        XCTAssertTrue(PeakClockLogic.isPeak(utc(6)))
        XCTAssertTrue(PeakClockLogic.isPeak(utc(9, 59)))
        XCTAssertFalse(PeakClockLogic.isPeak(utc(10)))
        XCTAssertFalse(PeakClockLogic.isPeak(utc(0, 30)))
    }

    func testPhaseRemaining() {
        // 峰时内：距峰末。
        XCTAssertEqual(PeakClockLogic.phaseRemainingSeconds(utc(2)), 2 * 3600)
        XCTAssertEqual(PeakClockLogic.phaseRemainingSeconds(utc(7, 30)), 2 * 3600 + 1800)
        // 谷时：距下一个峰时起点；10 点后跨零点到次日 01:00。
        XCTAssertEqual(PeakClockLogic.phaseRemainingSeconds(utc(5)), 3600)
        XCTAssertEqual(PeakClockLogic.phaseRemainingSeconds(utc(12)), 13 * 3600)
    }

    func testPeakArcsUTCAndPlusEight() {
        // UTC 时区：01:00-04:00 → 15°..60°，06:00-10:00 → 90°..150°。
        XCTAssertEqual(
            PeakClockLogic.peakArcs(utc(12), utcOffsetSeconds: utcTZ),
            [
                PeakClockLogic.ClockArc(startDegree: 15, endDegree: 60),
                PeakClockLogic.ClockArc(startDegree: 90, endDegree: 150),
            ]
        )
        // UTC+8：窗口整体 +480 分钟 → 09:00-12:00 (135°..180°) 与 15:00-18:00 (225°..270°)。
        XCTAssertEqual(
            PeakClockLogic.peakArcs(utc(12), utcOffsetSeconds: plus8TZ),
            [
                PeakClockLogic.ClockArc(startDegree: 135, endDegree: 180),
                PeakClockLogic.ClockArc(startDegree: 210, endDegree: 270),
            ]
        )
    }

    func testOffPeaksAreComplement() {
        let peaks = PeakClockLogic.peakArcs(utc(12), utcOffsetSeconds: utcTZ)
        XCTAssertEqual(
            PeakClockLogic.offPeakArcs(of: peaks),
            [
                PeakClockLogic.ClockArc(startDegree: 0, endDegree: 15),
                PeakClockLogic.ClockArc(startDegree: 60, endDegree: 90),
                PeakClockLogic.ClockArc(startDegree: 150, endDegree: 360),
            ]
        )
    }

    func testHandAngleFullDay() {
        var timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PeakClockLogic.handAngle(utc(6), timeZone: timeZone), 90)
        XCTAssertEqual(PeakClockLogic.handAngle(utc(12), timeZone: timeZone), 180)
        // 东八区本地 6 点 = UTC 22:00 前一天，但表盘读的是本地钟面。
        timeZone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(PeakClockLogic.handAngle(utc(22), timeZone: timeZone), 90)
    }

    func testFormatCountdown() {
        XCTAssertEqual(PeakClockLogic.formatCountdown(8940), "02:29:00")
        XCTAssertEqual(PeakClockLogic.formatCountdown(0), "00:00:00")
        XCTAssertEqual(PeakClockLogic.formatCountdown(-5), "00:00:00")
    }
}
