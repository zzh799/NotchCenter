import NotchCenterKit
import XCTest
@testable import SystemMonitorPlugin

/// SystemMonitorPlugin 回归：差分与守卫（计数器回绕钳 0）、内存压力等级映射、
/// 阈值与钳制、单位换档、滑窗与归一化、网络排除聚合、历史裁剪、实例配置
/// 持久化与隔离、store 节奏与生命周期（挂起/移除/可见性）。全部注入假数据源，
/// 绝不触碰真实系统（CPU/磁盘/网络采集器本体不在测试范围）。
@MainActor
final class SystemMonitorTests: XCTestCase {
    // MARK: 夹具

    /// 恒定快照数据源：供生命周期类测试（不关心采集内容）。
    private struct FakeProvider: SystemMetricsProviding {
        var raw = SystemRawSample()
        func collect() -> SystemRawSample { raw }
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func raw(
        at timestamp: Date,
        cpuBusy: UInt64 = 0,
        cpuTotal: UInt64 = 0,
        memUsed: UInt64 = 4 << 30,
        memTotal: UInt64 = 16 << 30,
        pressure: Int = 1,
        diskRead: UInt64 = 0,
        diskWrite: UInt64 = 0,
        diskAvailable: Bool = true,
        net: [String: NetCumulative] = [:]
    ) -> SystemRawSample {
        var sample = SystemRawSample(timestamp: timestamp)
        sample.cpuBusyTicks = cpuBusy
        sample.cpuTotalTicks = cpuTotal
        sample.memoryUsedBytes = memUsed
        sample.memoryTotalBytes = memTotal
        sample.memoryPressureLevel = pressure
        sample.diskReadBytes = diskRead
        sample.diskWriteBytes = diskWrite
        sample.diskAvailable = diskAvailable
        sample.netInterfaces = net
        return sample
    }

    /// 隔离临时存储。
    private func makeStateStore() -> StateStore {
        StateStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SystemMonitorTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func makeRunningStore(
        provider: SystemMetricsProviding = FakeProvider()
    ) -> SystemMonitorStore {
        let store = SystemMonitorStore(provider: provider)
        store.attach()
        store.viewDidAppear(placementID: "placement-1")
        return store
    }

    // MARK: 差分

    func testFirstSampleYieldsZeroRatesAndValidMemory() {
        let sample = SystemMetricsLogic.differential(
            from: nil, to: raw(at: t0, memUsed: 8 << 30, memTotal: 16 << 30)
        )
        XCTAssertEqual(sample.cpuUsage, 0)
        XCTAssertEqual(sample.diskReadRate, 0)
        XCTAssertEqual(sample.diskWriteRate, 0)
        XCTAssertTrue(sample.netInterfaceRates.isEmpty)
        XCTAssertEqual(sample.memoryUsage, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sample.memoryPressure, .normal)
        XCTAssertTrue(sample.diskAvailable)
    }

    func testDifferentialComputesCpuDiskAndPerInterfaceRates() {
        let previous = raw(
            at: t0,
            cpuBusy: 40, cpuTotal: 100,
            diskRead: 100, diskWrite: 50,
            net: ["en0": NetCumulative(down: 1_000, up: 500)]
        )
        let current = raw(
            at: t0.addingTimeInterval(2),
            cpuBusy: 100, cpuTotal: 200,
            diskRead: 300, diskWrite: 50,
            net: ["en0": NetCumulative(down: 1_200, up: 500)]
        )

        let sample = SystemMetricsLogic.differential(from: previous, to: current)

        XCTAssertEqual(sample.cpuUsage, 0.6, accuracy: 0.0001)
        XCTAssertEqual(sample.diskReadRate, 100, accuracy: 0.0001)
        XCTAssertEqual(sample.diskWriteRate, 0, accuracy: 0.0001)
        XCTAssertEqual(sample.netInterfaceRates["en0"]?.down ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(sample.netInterfaceRates["en0"]?.up ?? -1, 0, accuracy: 0.0001)
    }

    func testCounterResetAndTimeRegressClampToZero() {
        // 计数器回绕（设备重挂/重启）：delta 为负按 0。
        let reset = SystemMetricsLogic.differential(
            from: raw(at: t0, diskRead: 9_999, net: ["en0": NetCumulative(down: 9_999, up: 0)]),
            to: raw(at: t0.addingTimeInterval(1), diskRead: 5, net: ["en0": NetCumulative(down: 1, up: 0)])
        )
        XCTAssertEqual(reset.diskReadRate, 0)
        XCTAssertEqual(reset.netInterfaceRates["en0"]?.down ?? -1, 0)

        // 时间倒退（NTP 校时）：不产生速率。
        let regressed = SystemMetricsLogic.differential(
            from: raw(at: t0.addingTimeInterval(10), cpuBusy: 100, cpuTotal: 200),
            to: raw(at: t0, cpuBusy: 150, cpuTotal: 300)
        )
        XCTAssertEqual(regressed.cpuUsage, 0)
    }

    func testDifferentialKeepsAbsoluteMemoryAndPressureFromCurrent() {
        let previous = raw(at: t0, memUsed: 4 << 30, pressure: 2)
        let current = raw(at: t0.addingTimeInterval(2), memUsed: 12 << 30, pressure: 4)
        let sample = SystemMetricsLogic.differential(from: previous, to: current)
        XCTAssertEqual(sample.memoryUsage, 0.75, accuracy: 0.0001)
        XCTAssertEqual(sample.memoryPressure, .critical)
    }

    // MARK: 内存压力映射

    func testMemoryPressureLevelMapping() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertEqual(MemoryPressure(level: 0), .normal, "未知等级兜底 normal")
        XCTAssertEqual(SystemMetricsLogic.level(of: .normal), .normal)
        XCTAssertEqual(SystemMetricsLogic.level(of: .warning), .elevated)
        XCTAssertEqual(SystemMetricsLogic.level(of: .critical), .high)
    }

    // MARK: 阈值与等级

    func testThresholdLevelBoundaries() {
        let thresholds = MetricThresholds(yellow: 0.7, red: 0.9)
        XCTAssertEqual(SystemMetricsLogic.level(0.69, thresholds: thresholds), .normal)
        XCTAssertEqual(SystemMetricsLogic.level(0.7, thresholds: thresholds), .elevated, "触线即黄")
        XCTAssertEqual(SystemMetricsLogic.level(0.89, thresholds: thresholds), .elevated)
        XCTAssertEqual(SystemMetricsLogic.level(0.9, thresholds: thresholds), .high, "触线即红")
    }

    func testEffectiveThresholdsUseDefaultsAndClampInversion() {
        // 无覆盖 → 内置默认。
        XCTAssertEqual(
            InstanceConfigLogic.effectiveThresholds(kind: .cpu, config: SingleBlockConfig()),
            SystemMetricsLogic.defaultThresholds(for: .cpu)
        )
        // 黄线高于红线 → 红线被钳到黄线。
        let inverted = InstanceConfigLogic.effectiveThresholds(
            kind: .network,
            config: SingleBlockConfig(yellow: 20_000_000, red: 5_000_000)
        )
        XCTAssertEqual(inverted.yellow, 20_000_000)
        XCTAssertEqual(inverted.red, 20_000_000)
        // 负黄线钳 0。
        let negative = InstanceConfigLogic.effectiveThresholds(
            kind: .disk,
            config: SingleBlockConfig(yellow: -1, red: nil)
        )
        XCTAssertEqual(negative.yellow, 0)
    }

    // MARK: 单位换档

    func testRateStringAutoScales() {
        XCTAssertEqual(SystemMetricsLogic.rateString(0, unit: .auto), "0 KB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(812_400, unit: .auto), "812 KB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(1_500_000, unit: .auto), "1.5 MB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(12_340_000, unit: .auto), "12 MB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(2_400_000_000, unit: .auto), "2.4 GB/s")
    }

    func testRateStringFixedUnitsIgnoreMagnitude() {
        XCTAssertEqual(SystemMetricsLogic.rateString(1_500_000, unit: .kb), "1500 KB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(500, unit: .mb), "0.0 MB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(1_500_000, unit: .gb), "0.0 GB/s")
        XCTAssertEqual(SystemMetricsLogic.rateString(-5, unit: .auto), "0 KB/s", "负值钳 0")
    }

    func testPercentStringRounds() {
        XCTAssertEqual(SystemMetricsLogic.percentString(0), "0%")
        XCTAssertEqual(SystemMetricsLogic.percentString(0.734), "73%")
        XCTAssertEqual(SystemMetricsLogic.percentString(0.999), "100%")
        XCTAssertEqual(SystemMetricsLogic.percentString(1.2), "120%", "不做钳制（钳制在归一化层）")
    }

    // MARK: 滑窗与归一化

    func testWindowSeriesSlicesByCutoff() {
        let history = (0..<10).map { index in
            let sample = MetricSample(timestamp: t0.addingTimeInterval(Double(index)))
            return sample
        }
        let all = SystemMetricsLogic.windowSeries(history, windowSeconds: 60, now: t0.addingTimeInterval(9)) { _ in 1 }
        XCTAssertEqual(all.count, 10)
        let recent = SystemMetricsLogic.windowSeries(history, windowSeconds: 3, now: t0.addingTimeInterval(9)) { _ in 1 }
        XCTAssertEqual(recent.count, 4, "cutoff ≥ t6 → 6/7/8/9 四个点")
    }

    func testNormalizationFixedRangeClampsAndPeakScales() {
        XCTAssertEqual(
            SystemMetricsLogic.normalized([-0.2, 0.5, 1.4], fixedRange: true),
            [0, 0.5, 1]
        )
        let peakScaled = SystemMetricsLogic.normalized([10, 20, 40], fixedRange: false)
        XCTAssertEqual(peakScaled.count, 3)
        XCTAssertEqual(peakScaled[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(peakScaled[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(peakScaled[2], 1, accuracy: 0.0001)
        XCTAssertEqual(
            SystemMetricsLogic.normalized([0, 0], fixedRange: false),
            [0, 0], "全零序列不除零"
        )
    }

    // MARK: 网络聚合

    func testAggregateNetExcludesVirtualPrefixesByDefault() {
        let rates = [
            "en0": NetRate(down: 100, up: 10),
            "en5": NetRate(down: 50, up: 5),
            "utun3": NetRate(down: 999, up: 999),
            "awdl0": NetRate(down: 7, up: 7),
            "bridge100": NetRate(down: 8, up: 8),
            "lo0": NetRate(down: 1, up: 1),
        ]
        let total = SystemMetricsLogic.aggregateNet(rates, exclusions: SystemMetricsLogic.defaultNetExclusions)
        XCTAssertEqual(total.down, 150, accuracy: 0.0001)
        XCTAssertEqual(total.up, 15, accuracy: 0.0001)
    }

    func testAggregateNetCustomExclusionsReplaceDefaults() {
        let rates = [
            "en0": NetRate(down: 100, up: 10),
            "utun3": NetRate(down: 999, up: 999),
        ]
        // 自定义表整体替换默认表：只排 en0，utun 反而计入（看 VPN 流量的用法）。
        let total = SystemMetricsLogic.aggregateNet(rates, exclusions: ["en0"])
        XCTAssertEqual(total.down, 999, accuracy: 0.0001)
        XCTAssertEqual(total.up, 999, accuracy: 0.0001)
    }

    // MARK: 历史裁剪

    func testHistoryTrimsToCapacity() {
        var history: [MetricSample] = []
        for index in 0..<5 {
            history = MetricHistory.appending(
                MetricSample(timestamp: t0.addingTimeInterval(Double(index))),
                to: history,
                capacity: 3
            )
        }
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first?.timestamp, t0.addingTimeInterval(2), "丢弃最旧")
        XCTAssertEqual(history.last?.timestamp, t0.addingTimeInterval(4))
    }

    // MARK: 实例配置

    func testExclusionsParseAndFormat() {
        XCTAssertEqual(
            InstanceConfigLogic.parseExclusions("utun, awdl0  gif\nstf"),
            ["utun", "awdl0", "gif", "stf"]
        )
        XCTAssertEqual(InstanceConfigLogic.parseExclusions(" , "), [])
        XCTAssertEqual(
            InstanceConfigLogic.formatExclusions(["utun", "awdl0"]),
            "utun, awdl0"
        )
    }

    func testSanitizeWindowSnapsToAllowed() {
        XCTAssertEqual(InstanceConfigLogic.sanitizeWindow(60), 60)
        XCTAssertEqual(InstanceConfigLogic.sanitizeWindow(50), 60)
        XCTAssertEqual(InstanceConfigLogic.sanitizeWindow(999), 300)
        XCTAssertEqual(InstanceConfigLogic.sanitizeWindow(1), 30)
    }

    func testSingleConfigPersistsPerPlacement() {
        let store = makeStateStore()
        // 与注册表同构：模型拿到的是 placementScope 派生的实例私有存储。
        let first = SystemMonitorInstanceModel(
            placementID: "p1", blockID: "system.cpu",
            store: store.placementScope(placementID: "p1")
        )
        var config = first.single
        config.windowSeconds = 120
        config.yellow = 0.5
        config.red = 0.8
        config.rateUnit = .mb
        first.update(config)

        // 同 placement 重载读取持久化值；不同 placement 得到默认（实例隔离）。
        let reloaded = SystemMonitorInstanceModel(
            placementID: "p1", blockID: "system.cpu",
            store: store.placementScope(placementID: "p1")
        )
        XCTAssertEqual(reloaded.single.windowSeconds, 120)
        XCTAssertEqual(reloaded.single.yellow, 0.5)
        XCTAssertEqual(reloaded.single.rateUnit, .mb)
        let other = SystemMonitorInstanceModel(
            placementID: "p2", blockID: "system.cpu",
            store: store.placementScope(placementID: "p2")
        )
        XCTAssertEqual(other.single.windowSeconds, 60)
        XCTAssertNil(other.single.yellow)
    }

    func testOverviewConfigPersistsAndRefusesEmptyMetrics() {
        let store = makeStateStore()
        let model = SystemMonitorInstanceModel(placementID: "p1", blockID: "system.overview", store: store)
        var config = model.overview
        config.windowSeconds = 300
        config.enabled = [.cpu]
        model.update(config)

        let reloaded = SystemMonitorInstanceModel(placementID: "p1", blockID: "system.overview", store: store)
        XCTAssertEqual(reloaded.overview.windowSeconds, 300)
        XCTAssertEqual(reloaded.overview.enabled, [.cpu])

        // 全关兜底回全开。
        var emptied = reloaded.overview
        emptied.enabled = []
        reloaded.update(emptied)
        XCTAssertEqual(reloaded.overview.enabled, Set(MetricKind.allCases))
    }

    func testRegistryCachesAndDiscards() {
        let store = makeStateStore()
        let registry = SystemMonitorInstanceRegistry()
        let first = registry.model(placementID: "p1", blockID: "system.cpu", stateStore: store)
        XCTAssertTrue(first === registry.model(placementID: "p1", blockID: "system.memory", stateStore: store))
        registry.discard(placementID: "p1")
        XCTAssertFalse(first === registry.model(placementID: "p1", blockID: "system.cpu", stateStore: store))
    }

    // MARK: 块声明合法性

    func testBlockDeclarationsValidateAndStayUnique() {
        let blocks = SystemMonitorPlugin.blocks
        XCTAssertEqual(blocks.count, 5)
        let ids = blocks.map(\.id)
        XCTAssertEqual(Set(ids).count, 5)
        for block in blocks {
            XCTAssertNil(block.validationError, block.id)
            XCTAssertEqual(block.kind, .drawer)
            XCTAssertEqual(block.scrollUsage, .none, "静态监控卡必须显式声明不消费横向滚动")
        }
        let overview = blocks.first { $0.id == "system.overview" }
        XCTAssertEqual(overview?.supportedSpans, [
            GridSpan(columns: 2, rows: 2),
            GridSpan(columns: 4, rows: 2),
            GridSpan(columns: 4, rows: 3),
            GridSpan(columns: 4, rows: 4),
        ])
        let single = blocks.first { $0.id == "system.cpu" }
        XCTAssertEqual(single?.supportedSpans, [
            GridSpan(columns: 1, rows: 1),
            GridSpan(columns: 2, rows: 1),
        ])
    }

    // MARK: store 节奏与生命周期

    func testIdleIntervalWithoutVisibleWindow() {
        let store = makeRunningStore()
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.idleInterval, "抽屉收起（无可见窗口）→ 10s")
        store.suspend()
    }

    func testVisibleWindowSwitchesToActiveInterval() {
        let store = makeRunningStore()
        let windowID = ObjectIdentifier(NSObject())
        store.probeAttached(windowID: windowID, isVisible: true)
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.activeInterval)
        store.probeVisibilityChanged(windowID: windowID, isVisible: false)
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.idleInterval)
        store.probeVisibilityChanged(windowID: windowID, isVisible: true)
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.activeInterval)
        store.suspend()
    }

    func testMultipleProbesOnSameWindowDeduplicate() {
        let store = makeRunningStore()
        let windowID = ObjectIdentifier(NSObject())
        store.probeAttached(windowID: windowID, isVisible: true)
        store.probeAttached(windowID: windowID, isVisible: true)
        store.probeDetached(windowID: windowID)
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.activeInterval, "同窗另一块仍在，窗口还算可见")
        store.probeDetached(windowID: windowID)
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.idleInterval)
        store.suspend()
    }

    func testPlacementRemovalStopsSampling() {
        let store = makeRunningStore()
        store.placementRemoved(placementID: "placement-1")
        XCTAssertFalse(store.isObserved)
        XCTAssertNil(store.currentInterval, "最后一个实例移除 → 停表")
    }

    func testViewDisappearStopsWhenLastInstanceLeaves() {
        let store = makeRunningStore()
        store.viewDidDisappear(placementID: "placement-1")
        XCTAssertNil(store.currentInterval)
        store.viewDidAppear(placementID: "placement-1")
        XCTAssertNotNil(store.currentInterval)
        store.suspend()
    }

    func testSuspendStopsAndDiscardsIngest() {
        let provider = FakeProvider()
        let store = makeRunningStore(provider: provider)
        store.ingest(raw(at: t0))
        XCTAssertEqual(store.history.count, 1)

        store.suspend()
        XCTAssertFalse(store.isObserved)
        XCTAssertNil(store.currentInterval)
        XCTAssertEqual(store.currentInterval, nil)

        // 禁用后的在途回调：不得复活历史。
        store.ingest(raw(at: t0.addingTimeInterval(2)))
        XCTAssertEqual(store.history.count, 1)
    }

    func testReattachAfterSuspendResumesIdleCadence() {
        let store = makeRunningStore()
        store.suspend()
        store.attach()
        XCTAssertFalse(store.isObserved, "挂起清空实例登记，重新启用需视图重新出现")
        XCTAssertNil(store.currentInterval)
        store.viewDidAppear(placementID: "placement-2")
        XCTAssertEqual(store.currentInterval, SystemMonitorStore.idleInterval)
        store.suspend()
    }

    func testIngestAppendsDifferentialInOrder() {
        let store = SystemMonitorStore(provider: FakeProvider())
        store.attach() // 无实例：不起表、不自动轮询，直接手工灌入保持确定性。
        store.ingest(raw(at: t0, memUsed: 4 << 30, diskRead: 0, net: ["en0": NetCumulative(down: 0, up: 0)]))
        store.ingest(raw(
            at: t0.addingTimeInterval(2),
            memUsed: 8 << 30,
            diskRead: 200,
            net: ["en0": NetCumulative(down: 400, up: 0)]
        ))
        store.ingest(raw(
            at: t0.addingTimeInterval(4),
            memUsed: 8 << 30,
            diskRead: 600,
            net: ["en0": NetCumulative(down: 800, up: 0)]
        ))

        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(store.history[1].diskReadRate, 100, accuracy: 0.0001)
        XCTAssertEqual(store.history[2].diskReadRate, 200, accuracy: 0.0001)
        XCTAssertEqual(store.history[2].netInterfaceRates["en0"]?.down ?? -1, 200, accuracy: 0.0001)
        XCTAssertEqual(store.history[2].memoryUsage, 0.5, accuracy: 0.0001)
    }
}
