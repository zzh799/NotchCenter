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
}
