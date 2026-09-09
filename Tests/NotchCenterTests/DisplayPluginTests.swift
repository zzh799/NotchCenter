import CoreGraphics
import Foundation
import NotchCenterKit
import XCTest
@testable import DisplayPlugin

/// DisplayPlugin 纯逻辑回归：DDC/CI 帧编解码（m1ddc/ddcctl 布局对照）、
/// 写入合并状态机、百分比 ↔ DDC 值映射、外接屏候选过滤、块版式形态映射
///（跨度 → 1×1 紧凑 / 行式），以及经假后端驱动的初值回退 / 连续失败隐藏 /
/// 合并收敛。不触碰真实 IOKit。
final class DisplayPluginTests: XCTestCase {
    // MARK: 帧编解码

    func testChecksumMatchesReferenceLayout() {
        // 校验和 = 0x6E ^ 0x51 ^ 消息逐字节异或（m1ddc prepareDDCWrite/prepareDDCRead 同款）：
        // Set 亮度 37 → 0x8D；Get 亮度 → 0xAC。
        XCTAssertEqual(DDCPacketCodec.checksum(DDCPacketCodec.setMessage(vcp: 0x10, value: 37)), 0x8D)
        XCTAssertEqual(DDCPacketCodec.checksum(DDCPacketCodec.getMessage(vcp: 0x10)), 0xAC)
    }

    func testAVServiceBufferLayout() {
        // IOAVService 路线：0x51 走函数参数，缓冲区 = 消息 + 校验和，无前导。
        XCTAssertEqual(
            DDCPacketCodec.avServiceBuffer([0x84, 0x03, 0x10, 0x00, 0x25]),
            [0x84, 0x03, 0x10, 0x00, 0x25, 0x8D])
    }

    func testI2CBufferLayout() {
        // Intel 路线：0x51 前导进发送缓冲区（ddcctl 同款 7 字节写帧 / 5 字节读帧）。
        XCTAssertEqual(
            DDCPacketCodec.i2cBuffer([0x84, 0x03, 0x10, 0x00, 0x25]),
            [0x51, 0x84, 0x03, 0x10, 0x00, 0x25, 0x8D])
        XCTAssertEqual(
            DDCPacketCodec.i2cBuffer([0x82, 0x01, 0x10]),
            [0x51, 0x82, 0x01, 0x10, 0xAC])
    }

    func testDecodeReplyExtractsMaxAndCurrent() {
        // 11 字节 Get VCP 回复：max=100、当前=42，校验和 = 0x6F ^ 0x51 ^ [1...9] = 0xEA。
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A, 0xEA]
        XCTAssertEqual(try? DDCPacketCodec.decodeReply(reply, vcp: 0x10), LuminanceReading(value: 42, max: 100))
    }

    func testDecodeReplyRejectsCorruptedFrames() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2A, 0xEA]
        XCTAssertNoThrow(try DDCPacketCodec.decodeReply(reply, vcp: 0x10))

        reply[10] ^= 0xFF // 校验和坏
        XCTAssertThrowsError(try DDCPacketCodec.decodeReply(reply, vcp: 0x10))
        reply[10] ^= 0xFF
        reply[0] = 0x51 // 源地址坏
        XCTAssertThrowsError(try DDCPacketCodec.decodeReply(reply, vcp: 0x10))
        reply[0] = 0x6E
        reply[2] = 0x03 // 命令不是 Get Reply
        XCTAssertThrowsError(try DDCPacketCodec.decodeReply(reply, vcp: 0x10))
        reply[2] = 0x02
        reply[4] = 0x12 // 特征码不符
        XCTAssertThrowsError(try DDCPacketCodec.decodeReply(reply, vcp: 0x10))
        XCTAssertThrowsError(try DDCPacketCodec.decodeReply(Array(reply.prefix(9)), vcp: 0x10))
    }

    // MARK: 写入合并状态机

    func testCoalescerKeepsOnlyLatestPendingValue() {
        var machine = CoalescedWriteStateMachine()
        XCTAssertTrue(machine.submit(10), "空闲时首个提交驱动写入")
        XCTAssertFalse(machine.submit(20))
        XCTAssertFalse(machine.submit(30), "在途期间只保留最新待写值")
        XCTAssertEqual(machine.finishFlight(), 30)
        XCTAssertEqual(machine.finishFlight(), nil, "队列清空后回到空闲")
        XCTAssertTrue(machine.submit(40))
    }

    // MARK: 值映射

    func testPercentToDDCMappingClampsToRange() {
        XCTAssertEqual(BrightnessController.ddcValue(percent: 50, upperBound: 100), 50)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 33.4, upperBound: 255), 85)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 150, upperBound: 100), 100)
        XCTAssertEqual(BrightnessController.ddcValue(percent: -5, upperBound: 100), 0)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 50, upperBound: 0), 0, "量程非法按 0")
    }

    func testDDCToPercentMapping() {
        XCTAssertEqual(BrightnessController.percent(value: 42, upperBound: 100), 42, accuracy: 0.001)
        XCTAssertEqual(BrightnessController.percent(value: 0, upperBound: 100), 0)
        XCTAssertEqual(BrightnessController.percent(value: 255, upperBound: 255), 100)
        XCTAssertEqual(BrightnessController.percent(value: 10, upperBound: 0), 0)
    }

    // MARK: DDC 写入区间映射（UI 百分比 ↔ 自定义区间）

    func testRangedPercentToDDCMapping() {
        XCTAssertEqual(BrightnessController.ddcValue(percent: 0, lowerBound: 20, upperBound: 80), 20)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 100, lowerBound: 20, upperBound: 80), 80)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 50, lowerBound: 20, upperBound: 80), 50)
        XCTAssertEqual(BrightnessController.ddcValue(percent: 150, lowerBound: 20, upperBound: 80), 80)
        XCTAssertEqual(BrightnessController.ddcValue(percent: -5, lowerBound: 20, upperBound: 80), 20)
    }

    func testRangedDDCToPercentMapping() {
        XCTAssertEqual(
            BrightnessController.percent(value: 20, lowerBound: 20, upperBound: 80), 0, accuracy: 0.001)
        XCTAssertEqual(
            BrightnessController.percent(value: 80, lowerBound: 20, upperBound: 80), 100, accuracy: 0.001)
        XCTAssertEqual(
            BrightnessController.percent(value: 50, lowerBound: 20, upperBound: 80), 50, accuracy: 0.001)
        XCTAssertEqual(
            BrightnessController.percent(value: 10, lowerBound: 20, upperBound: 80), 0, accuracy: 0.001)
        XCTAssertEqual(
            BrightnessController.percent(value: 90, lowerBound: 20, upperBound: 80), 100, accuracy: 0.001)
    }

    func testRangeSanitizeClampsAndRejectsDegenerate() {
        var bounds = DDCLuminanceRangeLogic.sanitize(min: 20, max: 80, maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 20)
        XCTAssertEqual(bounds.upper, 80)
        bounds = DDCLuminanceRangeLogic.sanitize(min: 80, max: 20, maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 20)
        XCTAssertEqual(bounds.upper, 80)
        bounds = DDCLuminanceRangeLogic.sanitize(min: -10, max: 200, maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 0)
        XCTAssertEqual(bounds.upper, 100)
        bounds = DDCLuminanceRangeLogic.sanitize(min: 50, max: 50, maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 0)
        XCTAssertEqual(bounds.upper, 100)
        bounds = DDCLuminanceRangeLogic.effectiveRange(custom: nil, maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 0)
        XCTAssertEqual(bounds.upper, 100)
        bounds = DDCLuminanceRangeLogic.effectiveRange(
            custom: DDCLuminanceRange(min: 20, max: 80), maxLuminance: 100)
        XCTAssertEqual(bounds.lower, 20)
        XCTAssertEqual(bounds.upper, 80)
    }

    // MARK: 外接屏候选过滤

    func testExternalCandidatesFilter() {
        let builtin = CGDirectDisplayID(1)
        let main = CGDirectDisplayID(2)
        let mirrored = CGDirectDisplayID(3)
        let normal = CGDirectDisplayID(4)
        let candidates = DisplayListFilter.externalCandidates([
            (id: builtin, isBuiltin: true, isMirrored: false, isMain: false),
            (id: main, isBuiltin: false, isMirrored: true, isMain: true),
            (id: mirrored, isBuiltin: false, isMirrored: true, isMain: false),
            (id: normal, isBuiltin: false, isMirrored: false, isMain: false),
        ])
        XCTAssertEqual(candidates, [main, normal], "内建屏排除，镜像组只留主屏")
    }

    // MARK: 通道与控制器（假后端，不触碰真实 IOKit）

    private let testDisplay = ExternalDisplay(id: CGDirectDisplayID(7), name: "Test Panel")

    /// 初值探针是异步任务：轮询等待其落定（假后端即时返回，2s 超时兜底）。
    @MainActor
    private func waitForProbe(_ controller: BrightnessController) async throws {
        for _ in 0..<100 {
            if controller.rows.first?.state == .ready { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("初值回读未在 2s 内完成")
    }

    /// 多屏场景：等待全部行的初值探针落定（各行探针是独立异步任务）。
    @MainActor
    private func waitForAllProbes(_ controller: BrightnessController) async throws {
        for _ in 0..<100 {
            if !controller.rows.isEmpty, controller.rows.allSatisfy({ $0.state == .ready }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("初值回读未在 2s 内完成")
    }

    private final class FakeBackend: DisplayDDCBackend, @unchecked Sendable {
        private let lock = NSLock()
        /// 当前在线显示器列表：测试可改写以模拟拔插。
        var displays: [ExternalDisplay]
        private let readError: DDCError?
        private let writeError: DDCError?
        private var readCalls: [ExternalDisplay] = []
        private var writeCalls: [(display: ExternalDisplay, value: Int)] = []

        init(
            displays: [ExternalDisplay],
            readError: DDCError? = nil,
            writeError: DDCError? = nil
        ) {
            self.displays = displays
            self.readError = readError
            self.writeError = writeError
        }

        var reads: [ExternalDisplay] {
            lock.lock(); defer { lock.unlock() }
            return readCalls
        }

        var writes: [(display: ExternalDisplay, value: Int)] {
            lock.lock(); defer { lock.unlock() }
            return writeCalls
        }

        func listDisplays() -> [ExternalDisplay] { displays }

        func readLuminance(_ display: ExternalDisplay) throws -> LuminanceReading {
            lock.lock()
            readCalls.append(display)
            lock.unlock()
            if let readError { throw readError }
            return LuminanceReading(value: 42, max: 100)
        }

        func writeLuminance(_ display: ExternalDisplay, value: Int) throws {
            lock.lock()
            writeCalls.append((display, value))
            lock.unlock()
            if let writeError { throw writeError }
        }
    }

    @MainActor
    func testProbeAppliesReadValueAndMax() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)

        let model = try XCTUnwrap(controller.rows.first, "初值就绪的屏出现在展示行")
        XCTAssertEqual(model.percent, 42, accuracy: 0.001)
        XCTAssertEqual(model.maxLuminance, 100)
        XCTAssertEqual(backend.reads.count, 1, "初值只回读一次")
    }

    @MainActor
    func testProbeFallsBackToHalfWhenReadFails() async throws {
        let backend = FakeBackend(displays: [testDisplay], readError: .transportFailed(code: -1))
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)

        let model = try XCTUnwrap(controller.rows.first, "回读失败不隐藏滑杆行（部分屏不支持回读）")
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.percent, 50, accuracy: 0.001, "无缓存时回退 50%")
    }

    @MainActor
    func testConsecutiveWriteFailuresHideRow() async throws {
        let backend = FakeBackend(displays: [testDisplay], writeError: .transportFailed(code: -1))
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)

        controller.requestWrite(model, percent: 30)
        for _ in 0..<100 where backend.writes.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(backend.writes.count, 1, "第一次写入已投递")
        XCTAssertEqual(controller.rows.count, 1, "首次写入失败只计数")

        controller.requestWrite(model, percent: 40)
        for _ in 0..<100 where backend.writes.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 后端落笔（writes 计数）先于控制器 Task 的失败计数与行隐藏：
        // 轮询等行落定再断言，否则是写入计数与 UI 状态的竞态（flaky）。
        for _ in 0..<100 where !controller.rows.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(controller.rows.isEmpty, "连续两次失败判定不可调节，行隐藏")
    }

    @MainActor
    func testChannelWritesConvergeToLatestValue() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)

        for percent in stride(from: 10.0, through: 90.0, by: 10.0) {
            controller.requestWrite(model, percent: percent)
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let writes = backend.writes
        XCTAssertFalse(writes.isEmpty)
        XCTAssertEqual(writes.last?.value, 90, "最终收敛到最新值")
        XCTAssertLessThan(writes.count, 9, "拖动连发被合并（至多写入首末等少数几笔）")
    }

    // MARK: 显示器热插拔刷新（DisplayPlugin 监听 didChangeScreenParameters
    // Notification 后调用 refresh()；此处直接驱动控制器验证差量语义）

    @MainActor
    func testRefreshRemovesUnpluggedDisplay() async throws {
        let second = ExternalDisplay(id: CGDirectDisplayID(8), name: "Second Panel")
        let backend = FakeBackend(displays: [testDisplay, second])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForAllProbes(controller)
        XCTAssertEqual(controller.rows.count, 2)

        backend.displays = [testDisplay] // 拔出第二台屏
        await controller.refresh()
        XCTAssertEqual(
            controller.rows.map(\.display.id), [testDisplay.id],
            "拔出屏的滑杆行消失，存活屏保留")
        XCTAssertTrue(controller.models[second.id] == nil, "消失屏的模型被移除")
    }

    @MainActor
    func testRefreshKeepsSurvivingDisplayStateAndSkipsReprobe() async throws {
        let second = ExternalDisplay(id: CGDirectDisplayID(8), name: "Second Panel")
        let backend = FakeBackend(displays: [testDisplay, second])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForAllProbes(controller)
        let readsBefore = backend.reads.count
        XCTAssertEqual(readsBefore, 2, "两屏各回读一次")

        backend.displays = [testDisplay]
        await controller.refresh()
        let survivor = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(survivor.display.id, testDisplay.id)
        XCTAssertEqual(survivor.state, .ready)
        XCTAssertEqual(survivor.percent, 42, accuracy: 0.001, "存活屏状态（百分比）保留")
        XCTAssertEqual(backend.reads.count, readsBefore, ".ready 屏不重复回读")
    }

    @MainActor
    func testRefreshWhileSuspendedIsNoOp() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        XCTAssertEqual(controller.rows.count, 1)

        controller.suspend()
        backend.displays = []
        await controller.refresh()
        XCTAssertEqual(controller.rows.count, 1, "插件禁用（暂停）期间刷新是空操作，不枚举")
    }

    @MainActor
    func testWriteToRemovedDisplayIsDropped() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)
        let writesBefore = backend.writes.count

        backend.displays = []
        await controller.refresh()
        XCTAssertTrue(controller.rows.isEmpty)

        controller.requestWrite(model, percent: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.writes.count, writesBefore, "对已移除屏的尾随写入被丢弃")
    }

    // MARK: 自定义区间：保持硬件连续 + 写入映射 + 持久化

    @MainActor
    func testSetRangeKeepsHardwareValue() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(model.percent, 42, accuracy: 0.001, "假后端回读 42/100")

        controller.setRange(for: testDisplay.id, min: 20, max: 80)
        XCTAssertEqual(
            model.percent, 36.666, accuracy: 0.01,
            "同硬件值 42 按新区间 20...80 重算百分比，滑杆不跳变")
        XCTAssertTrue(controller.customRanges[testDisplay.id] == DDCLuminanceRange(min: 20, max: 80))
    }

    @MainActor
    func testWriteUsesCustomRange() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)
        controller.setRange(for: testDisplay.id, min: 20, max: 80)

        controller.requestWrite(model, percent: 0)
        controller.requestWrite(model, percent: 100)
        for _ in 0..<100 where backend.writes.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(backend.writes.first?.value, 20, "0% 下发区间下界")
        XCTAssertEqual(backend.writes.last?.value, 80, "100% 下发区间上界")
    }

    @MainActor
    func testClearRangeRestoresFullRange() async throws {
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)
        controller.setRange(for: testDisplay.id, min: 20, max: 80)
        controller.clearRange(for: testDisplay.id)
        XCTAssertNil(controller.customRanges[testDisplay.id])
        XCTAssertEqual(model.percent, 42, accuracy: 0.001, "回全量程后百分比回到硬件值")
    }

    @MainActor
    func testRangePersistsThroughStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DDCRangeTests-\(UUID().uuidString)", isDirectory: true)
        let store = StateStore(rootDirectory: root)
        DDCLuminanceRangeLogic.saveAll(["7": DDCLuminanceRange(min: 20, max: 80)], to: store)
        let loaded = DDCLuminanceRangeLogic.loadAll(from: store)
        XCTAssertEqual(loaded["7"], DDCLuminanceRange(min: 20, max: 80))

        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        controller.configure(store: store)
        XCTAssertEqual(controller.customRanges[testDisplay.id], DDCLuminanceRange(min: 20, max: 80))
    }

    // MARK: 版式形态映射（跨度 → 1×1 紧凑 / 行式）

    func testArrangementSelectsCompactOnlyFor1By1Span() {
        XCTAssertEqual(
            BrightnessSliderArrangement.forSpan(widthColumns: 1, heightRows: 1),
            .compact)
        XCTAssertEqual(
            BrightnessSliderArrangement.forSpan(widthColumns: 2, heightRows: 1),
            .rows)
        XCTAssertEqual(
            BrightnessSliderArrangement.forSpan(widthColumns: 4, heightRows: 2),
            .rows)
        XCTAssertEqual(
            BrightnessSliderArrangement.forSpan(widthColumns: 1, heightRows: 2),
            .rows,
            "未声明 1 列 × 多行的跨度；即便出现也不回退紧凑（防回归）")
    }

    func testArrangementSpanlessFallbackUsesRows() {
        // 目录预览等无 span 上下文的防御回退：按推荐 2×1 的行式形态。
        XCTAssertEqual(
            BrightnessSliderArrangement.forSpan(widthColumns: nil, heightRows: nil),
            .rows)
    }

    // MARK: 单屏条形态映射（跨度 + 推导单元 → 启动器 / 小 fill / 大药丸）

    func testSinglePresentationLauncherFor1x1() {
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 1, rows: 1, cellWidth: 150, cellHeight: 120),
            .launcher)
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 1, rows: 1, cellWidth: 75, cellHeight: 60),
            .launcher,
            "1×1 在任何单元下都恒为启动器")
    }

    func testSinglePresentationSmallCellUsesFill() {
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 1, rows: 2, cellWidth: 75, cellHeight: 60),
            .compactFill(vertical: true))
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 2, rows: 1, cellWidth: 75, cellHeight: 60),
            .compactFill(vertical: false))
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 2, rows: 2, cellWidth: 75, cellHeight: 60),
            .compactFill(vertical: false),
            "等边走横向（列 >= 行）")
    }

    func testSinglePresentationLargeCellUsesDetailed() {
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 1, rows: 2, cellWidth: 150, cellHeight: 120),
            .detailed(vertical: true))
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 2, rows: 1, cellWidth: 150, cellHeight: 120),
            .detailed(vertical: false))
        // 任一轴超 100 即大；等于阈值不算。
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 2, rows: 1, cellWidth: 101, cellHeight: 60),
            .detailed(vertical: false))
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 1, rows: 2, cellWidth: 75, cellHeight: 101),
            .detailed(vertical: true))
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: 2, rows: 1, cellWidth: 100, cellHeight: 60),
            .compactFill(vertical: false))
    }

    func testSinglePresentationSpanlessFallback() {
        // 无 span 上下文：按推荐尺寸（150×240 竖条）的形态兜底。
        XCTAssertEqual(
            SingleBrightnessPresentation.resolve(columns: nil, rows: nil, cellWidth: nil, cellHeight: nil),
            .detailed(vertical: true))
    }

    func testSingleCellSizeDerivation() {
        // 2×1 在默认格 + 间距下的 frame（2×150 + 12）：推导单元 156×120。
        let cell = SingleBrightnessPresentation.cellSize(
            frame: CGSize(width: 312, height: 120), columns: 2, rows: 1)
        XCTAssertEqual(cell.width, 156)
        XCTAssertEqual(cell.height, 120)
    }

    // MARK: 无屏空态分级（可用 frame 高度 → 三档，只降信息密度）

    func testEmptyPresentationIconOnlyForShortestBlock() {
        // 最小单元 75x60：旧固定空态在此高度下必切文本，只剩图标。
        XCTAssertEqual(
            BrightnessEmptyPresentation.resolve(frame: CGSize(width: 75, height: 60)),
            .iconOnly)
    }

    func testEmptyPresentationCompactForDefaultCellHeight() {
        // 默认单元高 120（1×1 默认 / sliders 推荐 300x120）：小图标 + 短文案。
        XCTAssertEqual(
            BrightnessEmptyPresentation.resolve(frame: CGSize(width: 150, height: 120)),
            .compact)
        XCTAssertEqual(
            BrightnessEmptyPresentation.resolve(frame: CGSize(width: 300, height: 120)),
            .compact)
    }

    func testEmptyPresentationCompactForNarrowTallBlock() {
        // 单列窄块纵使够高也放不下完整长文案，走紧凑态。
        XCTAssertEqual(
            BrightnessEmptyPresentation.resolve(frame: CGSize(width: 75, height: 200)),
            .compact)
    }

    func testEmptyPresentationFullForTallBlock() {
        // single 推荐 150x240：完整空态。
        XCTAssertEqual(
            BrightnessEmptyPresentation.resolve(frame: CGSize(width: 150, height: 240)),
            .full)
    }

    // MARK: 横向 scrub 换算（x/width → 百分比，AppKit 条与竖向手势各用各的）

    func testHorizontalScrubPercentMapsXToPercent() {
        XCTAssertEqual(HorizontalScrubMath.percent(atX: 0, width: 200), 0, accuracy: 1e-9)
        XCTAssertEqual(HorizontalScrubMath.percent(atX: 100, width: 200), 50, accuracy: 1e-9)
        XCTAssertEqual(HorizontalScrubMath.percent(atX: 200, width: 200), 100, accuracy: 1e-9)
    }

    func testHorizontalScrubPercentClampsOutsideBounds() {
        // 跟踪循环里拖出边界仍归本次 scrub：越界钳制，与旧 SwiftUI 手势
        //（location 越界 → scrubSingleBrightness 内钳制）同语义。
        XCTAssertEqual(HorizontalScrubMath.percent(atX: -10, width: 200), 0, accuracy: 1e-9)
        XCTAssertEqual(HorizontalScrubMath.percent(atX: 250, width: 200), 100, accuracy: 1e-9)
    }

    func testHorizontalScrubPercentZeroWidthIsSafe() {
        // 零宽接不到命中；回 0 防 NaN，不崩。
        XCTAssertEqual(HorizontalScrubMath.percent(atX: 10, width: 0), 0, accuracy: 1e-9)
    }

    // MARK: 单屏条实例配置（放置实例 → 绑定显示器）

    @MainActor
    func testSingleDisplayConfigDefaultsToFollowFirst() {
        XCTAssertNil(SingleDisplayInstanceConfigLogic.load(from: nil).displayID)
    }

    @MainActor
    func testSingleDisplayConfigRoundTripsThroughStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleDisplayTests-\(UUID().uuidString)", isDirectory: true)
        let store = StateStore(rootDirectory: root)
        let placement = store.placementScope(placementID: "p1")
        SingleDisplayInstanceConfigLogic.save(SingleDisplayInstanceConfig(displayID: 42), to: placement)
        XCTAssertEqual(
            SingleDisplayInstanceConfigLogic.load(from: placement).displayID, 42)
        SingleDisplayInstanceConfigLogic.save(SingleDisplayInstanceConfig(displayID: nil), to: placement)
        XCTAssertNil(SingleDisplayInstanceConfigLogic.load(from: placement).displayID)
    }
}
