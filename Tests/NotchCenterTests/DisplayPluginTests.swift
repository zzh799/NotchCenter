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

    // MARK: 显示器候选过滤（两条通道各取所需）

    func testExternalCandidatesFilter() {
        let builtin = CGDirectDisplayID(1)
        let main = CGDirectDisplayID(2)
        let mirrored = CGDirectDisplayID(3)
        let normal = CGDirectDisplayID(4)
        let candidates = DisplayListFilter.externalCandidates([
            DisplayDescriptor(id: builtin, isBuiltin: true, isMirrored: false, isMain: true),
            DisplayDescriptor(id: main, isBuiltin: false, isMirrored: true, isMain: true),
            DisplayDescriptor(id: mirrored, isBuiltin: false, isMirrored: true, isMain: false),
            DisplayDescriptor(id: normal, isBuiltin: false, isMirrored: false, isMain: false),
        ])
        XCTAssertEqual(candidates, [main, normal], "内建屏排除，镜像组只留主屏")
    }

    func testBuiltinCandidatesPickOnlyBuiltin() {
        let builtin = CGDirectDisplayID(1)
        let external = CGDirectDisplayID(2)
        let candidates = DisplayListFilter.builtinCandidates([
            DisplayDescriptor(id: builtin, isBuiltin: true, isMirrored: false, isMain: true),
            DisplayDescriptor(id: external, isBuiltin: false, isMirrored: false, isMain: false),
        ])
        XCTAssertEqual(candidates, [builtin], "系统通道只认内建屏，外接屏仍归 DDC")
    }

    func testBuiltinCandidatesDropMirroredNonMain() {
        let builtin = CGDirectDisplayID(1)
        let mainExternal = CGDirectDisplayID(2)
        let candidates = DisplayListFilter.builtinCandidates([
            DisplayDescriptor(id: builtin, isBuiltin: true, isMirrored: true, isMain: false),
            DisplayDescriptor(id: mainExternal, isBuiltin: false, isMirrored: true, isMain: true),
        ])
        XCTAssertTrue(candidates.isEmpty, "镜像组只保留主屏，非主的内建屏不出行")
    }

    func testBuiltinCandidatesEmptyWithoutBuiltinDisplay() {
        // Mac mini / Mac Studio 类无内建屏的机器：候选为空，插件只列外接屏。
        XCTAssertTrue(
            DisplayListFilter.builtinCandidates([
                DisplayDescriptor(
                    id: CGDirectDisplayID(2), isBuiltin: false, isMirrored: false, isMain: true)
            ]).isEmpty)
    }

    // MARK: 内建屏数值换算与通知值解析（纯逻辑）

    func testSystemBrightnessMathRoundTripsFloatAndPercent() {
        XCTAssertEqual(SystemBrightnessMath.raw(fromBrightness: 0.4375), 44)
        XCTAssertEqual(SystemBrightnessMath.raw(fromBrightness: 1), 100)
        XCTAssertEqual(SystemBrightnessMath.raw(fromBrightness: 0), 0)
        XCTAssertEqual(SystemBrightnessMath.raw(fromBrightness: -1), 0, "越界钳制")
        XCTAssertEqual(SystemBrightnessMath.raw(fromBrightness: 2), 100, "越界钳制")
        XCTAssertEqual(
            SystemBrightnessMath.brightness(fromRaw: 44), 0.44, accuracy: 1e-9)
        XCTAssertEqual(SystemBrightnessMath.brightness(fromRaw: -5), 0)
        XCTAssertEqual(SystemBrightnessMath.brightness(fromRaw: 150), 1)
    }

    func testSystemBrightnessNotificationValueParsing() {
        // 真机实测 userInfo 里是字符串（value = "0.6000001"），数值形态一并兼容。
        XCTAssertEqual(
            SystemBrightnessMath.brightness(fromNotificationValue: "0.6000001") ?? -1,
            0.6000001, accuracy: 1e-9)
        XCTAssertEqual(
            SystemBrightnessMath.brightness(fromNotificationValue: NSNumber(value: 0.25)) ?? -1,
            0.25, accuracy: 1e-9)
        XCTAssertNil(SystemBrightnessMath.brightness(fromNotificationValue: "not a number"))
        XCTAssertNil(SystemBrightnessMath.brightness(fromNotificationValue: nil))
    }

    // MARK: 后端合流（按 control 分发）

    @MainActor
    func testCompositeListsBuiltinFirstAndRoutesByControlPath() async throws {
        let builtin = BrightnessDisplay(id: 1, name: "Built-in Display", control: .system)
        let external = BrightnessDisplay(id: CGDirectDisplayID(7), name: "Test Panel")
        let system = FakeBackend(
            displays: [builtin], reading: LuminanceReading(value: 30, max: 100))
        let ddc = FakeBackend(
            displays: [external], reading: LuminanceReading(value: 60, max: 100))
        let composite = CompositeBackend(system: system, ddc: ddc)

        let listed = await composite.listDisplays()
        XCTAssertEqual(listed.map(\.id), [1, external.id], "内建屏在前，外接屏随后")

        let builtinReading = try await composite.readLuminance(builtin)
        XCTAssertEqual(builtinReading.value, 30)
        XCTAssertEqual(system.reads.count, 1)
        XCTAssertTrue(ddc.reads.isEmpty, "内建屏的回读不落到 DDC 后端")

        try await composite.writeLuminance(external, value: 12)
        XCTAssertEqual(ddc.writes.first?.value, 12)
        XCTAssertTrue(system.writes.isEmpty, "外接屏的写入不落到系统后端")
    }

    func testCompositeRejectsDisplayOfMissingChannel() async {
        let composite = CompositeBackend(system: nil, ddc: FakeBackend(displays: []))
        do {
            _ = try await composite.readLuminance(
                BrightnessDisplay(id: 1, name: "Built-in Display", control: .system))
            XCTFail("系统通道缺失时回读应当抛错")
        } catch {
            XCTAssertEqual(error as? BrightnessError, .controlPathUnavailable)
        }
    }

    // MARK: 系统亮度变化回灌（内建屏）

    @MainActor
    func testSystemBrightnessChangeUpdatesSlider() async throws {
        let builtin = BrightnessDisplay(id: 1, name: "Built-in Display", control: .system)
        let backend = FakeBackend(displays: [builtin])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(backend.observations, 1, "系统通道的屏建立一次观察")

        backend.emitBrightnessChange(displayID: builtin.id, value: 0.8)
        try await waitFor(
            { model.percent == 80 }, "亮度键改的内建屏亮度应回灌到滑杆")
        XCTAssertEqual(model.percent, 80, accuracy: 0.001)
    }

    @MainActor
    func testSystemBrightnessChangeIgnoredWhileDragging() async throws {
        let builtin = BrightnessDisplay(id: 1, name: "Built-in Display", control: .system)
        let backend = FakeBackend(displays: [builtin])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)

        model.isDragging = true
        backend.emitBrightnessChange(displayID: builtin.id, value: 0.8)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.percent, 42, accuracy: 0.001, "拖动中不回灌，滑杆不脱离手指")
    }

    @MainActor
    func testLocalWriteSuppressesImmediateEcho() async throws {
        let builtin = BrightnessDisplay(id: 1, name: "Built-in Display", control: .system)
        let backend = FakeBackend(displays: [builtin])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)

        controller.requestWrite(model, percent: 10)
        try await waitFor({ !backend.writes.isEmpty }, "本机写入应已投递")
        // 本机写入必然触发系统通知（真机实测），紧接着的回声不该覆盖刚松手的目标值。
        backend.emitBrightnessChange(displayID: builtin.id, value: 0.9)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.percent, 10, accuracy: 0.001, "自写回声被静默窗口挡下")
    }

    @MainActor
    func testSuspendDropsSystemBrightnessObservation() async throws {
        let builtin = BrightnessDisplay(id: 1, name: "Built-in Display", control: .system)
        let backend = FakeBackend(displays: [builtin])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        let model = try XCTUnwrap(controller.rows.first)

        controller.suspend()
        XCTAssertEqual(backend.invalidations, 1, "禁用时撤销观察注册")
        backend.emitBrightnessChange(displayID: builtin.id, value: 0.8)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.percent, 42, accuracy: 0.001, "禁用后系统亮度变化不再回灌")
    }

    @MainActor
    func testDDCDisplayDoesNotEstablishObservation() async throws {
        // 外接屏没有变化回调通道：假后端虽实现了观察，控制器也不该为纯 DDC 列表注册。
        let backend = FakeBackend(displays: [testDisplay])
        let controller = BrightnessController(backend: backend)
        await controller.startIfNeeded()
        try await waitForProbe(controller)
        XCTAssertTrue(controller.rows.count == 1)
        XCTAssertEqual(backend.observations, 0)
    }

    // MARK: 假后端与等待原语（不触碰真实 IOKit / DisplayServices）

    private let testDisplay = BrightnessDisplay(id: CGDirectDisplayID(7), name: "Test Panel")

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

    private final class FakeBackend: DisplayBrightnessBackend, @unchecked Sendable {
        private let lock = NSLock()
        /// 当前在线显示器列表：测试可改写以模拟拔插。
        var displays: [BrightnessDisplay]
        private let readError: BrightnessError?
        private let writeError: BrightnessError?
        private let reading: LuminanceReading
        private var readCalls: [BrightnessDisplay] = []
        private var writeCalls: [(display: BrightnessDisplay, value: Int)] = []
        private var changeHandler: (@Sendable (CGDirectDisplayID, Double) -> Void)?
        private var observationCount = 0
        private var invalidationCount = 0

        init(
            displays: [BrightnessDisplay],
            readError: BrightnessError? = nil,
            writeError: BrightnessError? = nil,
            reading: LuminanceReading = LuminanceReading(value: 42, max: 100)
        ) {
            self.displays = displays
            self.readError = readError
            self.writeError = writeError
            self.reading = reading
        }

        var reads: [BrightnessDisplay] {
            lock.lock(); defer { lock.unlock() }
            return readCalls
        }

        var writes: [(display: BrightnessDisplay, value: Int)] {
            lock.lock(); defer { lock.unlock() }
            return writeCalls
        }

        func listDisplays() -> [BrightnessDisplay] { displays }

        func readLuminance(_ display: BrightnessDisplay) throws -> LuminanceReading {
            lock.lock()
            readCalls.append(display)
            lock.unlock()
            if let readError { throw readError }
            return reading
        }

        func writeLuminance(_ display: BrightnessDisplay, value: Int) throws {
            lock.lock()
            writeCalls.append((display, value))
            lock.unlock()
            if let writeError { throw writeError }
        }

        // MARK: 系统亮度变化观察（假实现：测试经 `emitBrightnessChange` 驱动）

        var observations: Int {
            lock.lock(); defer { lock.unlock() }
            return observationCount
        }

        var invalidations: Int {
            lock.lock(); defer { lock.unlock() }
            return invalidationCount
        }

        func observeBrightnessChanges(
            _ handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
        ) -> BrightnessChangeObservation? {
            lock.lock()
            changeHandler = handler
            observationCount += 1
            lock.unlock()
            return FakeObservation { [weak self] in self?.clearHandler() }
        }

        /// 模拟系统侧改了亮度（亮度键 / 自动调节 / 其它 App）。
        func emitBrightnessChange(displayID: CGDirectDisplayID, value: Double) {
            lock.lock()
            let handler = changeHandler
            lock.unlock()
            handler?(displayID, value)
        }

        private func clearHandler() {
            lock.lock()
            changeHandler = nil
            invalidationCount += 1
            lock.unlock()
        }

        private final class FakeObservation: BrightnessChangeObservation, @unchecked Sendable {
            private let onInvalidate: @Sendable () -> Void

            init(_ onInvalidate: @escaping @Sendable () -> Void) {
                self.onInvalidate = onInvalidate
            }

            func invalidate() { onInvalidate() }
        }
    }

    /// 回灌落在 MainActor 任务里：轮询等待谓词成立（假后端即时完成，1s 超时兜底）。
    @MainActor
    private func waitFor(
        _ condition: () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message, file: file, line: line)
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
        let second = BrightnessDisplay(id: CGDirectDisplayID(8), name: "Second Panel")
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
        let second = BrightnessDisplay(id: CGDirectDisplayID(8), name: "Second Panel")
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

    @MainActor
    func testDiscardForgetsModelButKeepsDiskBinding() {
        // 删实例后内存注册表须忘掉该模型（下次拖出重建），而 discard 本身
        // 只清内存：持久化绑定留给插件入口 placementWasRemoved 清。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleDisplayRemovalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootDirectory: root)
        let id = "removal-\(UUID().uuidString)"

        let m1 = SingleDisplayInstanceRegistry.model(placementID: id, stateStore: store)
        m1.update(SingleDisplayInstanceConfig(displayID: 1))

        SingleDisplayInstanceRegistry.discard(placementID: id)

        let m2 = SingleDisplayInstanceRegistry.model(placementID: id, stateStore: store)
        XCTAssertFalse(m1 === m2, "内存模型已被遗忘并重建")
        XCTAssertEqual(m2.config.displayID, 1, "磁盘绑定仍在，discard 只清内存模型")
    }
}
