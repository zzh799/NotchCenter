import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

// MARK: - 内建屏亮度后端（DisplayServices 系统通道）
//
// 内建屏没有 DDC 通道（DDC 是显示器侧的外部 I2C 总线），背光由系统接管：
// 系统亮度键、控制中心滑杆与「自动调节亮度」改的都是 DisplayServices 里的
// 用户亮度。本后端读写同一份值，于是插件滑杆与亮度键操作的是同一个数。
//
// 符号（GetBrightness / SetBrightness / CanChangeBrightness /
// RegisterForBrightnessChangeNotifications 与对应 Unregister）均为未公开符号，
// 经 dlopen/dlsym 运行时解析：解析不到就不产出内建屏行，外接屏 DDC 路线
// 不受影响，绝不崩溃。真机（macOS 15.7.5 / arm64）实测：读写 0...1 浮点、
// set→get 往返无量化误差、注册后每次亮度变化回调携带新值。
//
// 与 IOAVServiceBackend 的差异：这条通道是进程内同步调用（无 I2C 传输），
// 微秒级返回，故不另起队列也不套超时；要防的只有注册回调——它是 C 函数
// 指针、不能捕获上下文，故经 SystemBrightnessRelay 转发（见下）。

/// 系统亮度数值换算（纯逻辑，回归 DisplayPluginTests）。
enum SystemBrightnessMath {
    /// 内建屏亮度的满量程（0...1 浮点对外统一表达为 0...100 整数，
    /// 与 DDC 的百分比语义对齐，区间 / 映射 / 存储全部复用）。
    static let fullScale = 100

    /// 浮点亮度 0...1 → 0...100 整数（越界钳制、四舍五入）。
    static func raw(fromBrightness brightness: Double) -> Int {
        let clamped = Swift.min(Swift.max(brightness, 0), 1)
        return Int((clamped * Double(fullScale)).rounded())
    }

    /// 0...100 整数 → 浮点亮度 0...1（越界钳制）。
    static func brightness(fromRaw raw: Int) -> Double {
        let clamped = Swift.min(Swift.max(raw, 0), fullScale)
        return Double(clamped) / Double(fullScale)
    }

    /// 变化通知 userInfo 里的新亮度。实测是字符串（`value = "0.6000001"`），
    /// 数值形态一并兼容；两者都不是即返回 nil（不认的通知直接忽略）。
    static func brightness(fromNotificationValue value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// DisplayServices 通知里承载新亮度的键。
private let systemBrightnessValueKey = "value"

final class SystemBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    // MARK: 私有符号（进程级缓存，只解析一次）

    private typealias GetBrightnessFn = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Int32
    fileprivate typealias RegisterFn = @convention(c) (
        CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback?
    ) -> Int32
    fileprivate typealias UnregisterFn = @convention(c) (
        CGDirectDisplayID, CGDirectDisplayID
    ) -> Int32

    private struct Symbols {
        let get: GetBrightnessFn
        let set: SetBrightnessFn
        let canChange: CanChangeBrightnessFn
        let register: RegisterFn
        let unregister: UnregisterFn

        /// DisplayServices 返回值约定：0 为成功。
        static let success: Int32 = 0
    }

    nonisolated(unsafe) private static var cachedSymbols: Symbols?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private static func symbols() -> Symbols? {
        if let cachedSymbols { return cachedSymbols }
        guard
            let framework = dlopen(frameworkPath, RTLD_LAZY),
            let get = dlsym(framework, "DisplayServicesGetBrightness"),
            let set = dlsym(framework, "DisplayServicesSetBrightness"),
            let canChange = dlsym(framework, "DisplayServicesCanChangeBrightness"),
            let register = dlsym(framework, "DisplayServicesRegisterForBrightnessChangeNotifications"),
            let unregister = dlsym(
                framework, "DisplayServicesUnregisterForBrightnessChangeNotifications")
        else { return nil }
        let resolved = Symbols(
            get: unsafeBitCast(get, to: GetBrightnessFn.self),
            set: unsafeBitCast(set, to: SetBrightnessFn.self),
            canChange: unsafeBitCast(canChange, to: CanChangeBrightnessFn.self),
            register: unsafeBitCast(register, to: RegisterFn.self),
            unregister: unsafeBitCast(unregister, to: UnregisterFn.self)
        )
        cachedSymbols = resolved
        return resolved
    }

    /// 符号是否可解析（老系统 / 未来移除即不启用内建屏，不崩溃）。
    static func makeIfAvailable() -> SystemBrightnessBackend? {
        guard let symbols = symbols() else { return nil }
        return SystemBrightnessBackend(symbols: symbols)
    }

    private let symbols: Symbols

    private init(symbols: Symbols) {
        self.symbols = symbols
    }

    // MARK: 枚举

    func listDisplays() async -> [BrightnessDisplay] {
        currentDisplayIDs
            .map { BrightnessDisplay(id: $0, name: L("display.builtin.name"), control: .system) }
    }

    /// 当前可观察 / 可调的内建屏（判据：在线内建 + 系统认可可改；笔记本只有
    /// 一块内建屏，合盖或 Mac mini 类无内建屏的机器为空）。
    private var currentDisplayIDs: [CGDirectDisplayID] {
        DisplayListFilter.builtinCandidates(DisplayDescriptor.online())
            .filter { symbols.canChange($0) != 0 }
    }

    // MARK: 亮度读写

    func readLuminance(_ display: BrightnessDisplay) async throws -> LuminanceReading {
        guard display.control == .system else { throw BrightnessError.controlPathUnavailable }
        var value: Float = 0
        guard symbols.get(display.id, &value) == Symbols.success else {
            throw BrightnessError.unsupported
        }
        return LuminanceReading(
            value: SystemBrightnessMath.raw(fromBrightness: Double(value)),
            max: SystemBrightnessMath.fullScale)
    }

    func writeLuminance(_ display: BrightnessDisplay, value: Int) async throws {
        guard display.control == .system else { throw BrightnessError.controlPathUnavailable }
        let brightness = Float(SystemBrightnessMath.brightness(fromRaw: value))
        guard symbols.set(display.id, brightness) == Symbols.success else {
            throw BrightnessError.unsupported
        }
    }

    // MARK: 亮度变化观察

    /// 注册内建屏的亮度变化通知。同一时刻至多一个注册（只有一块内建屏），
    /// 调用方（控制器）负责撤销后重建。
    func observeBrightnessChanges(
        _ handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) -> BrightnessChangeObservation? {
        guard let display = currentDisplayIDs.first else { return nil }
        return SystemBrightnessObservation(
            displayID: display, register: symbols.register, unregister: symbols.unregister,
            handler: handler)
    }
}

// MARK: - 观察注册与中继

/// 一次系统亮度变化注册（`invalidate` 撤销，幂等）。
final class SystemBrightnessObservation: BrightnessChangeObservation, @unchecked Sendable {
    private let lock = NSLock()
    private let displayID: CGDirectDisplayID
    private let unregister: SystemBrightnessBackend.UnregisterFn
    private var active = true

    fileprivate init(
        displayID: CGDirectDisplayID,
        register: SystemBrightnessBackend.RegisterFn,
        unregister: @escaping SystemBrightnessBackend.UnregisterFn,
        handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) {
        self.displayID = displayID
        self.unregister = unregister
        SystemBrightnessRelay.shared.install(displayID: displayID, handler: handler)
        // 真机实测签名是 (display, observer, C 回调) —— 第三个参数是 C 函数指针
        // 而非 block，按 block 传会直接段错误；observer 传显示器自身，回调侧
        // 不读它（显示身份由中继按注册表补齐）。
        _ = register(displayID, displayID, systemBrightnessChangedCallback)
    }

    func invalidate() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        lock.unlock()
        SystemBrightnessRelay.shared.remove(displayID: displayID)
        _ = unregister(displayID, displayID)
    }
}

/// 变化通知没有上下文参数（CFNotificationCallback 不能捕获），注册表是唯一落点：
/// 回调按发送线程投递，故用锁保护；显示身份来自注册时的 id，不从通知里取。
private final class SystemBrightnessRelay: @unchecked Sendable {
    static let shared = SystemBrightnessRelay()

    private let lock = NSLock()
    private var handlers: [CGDirectDisplayID: @Sendable (CGDirectDisplayID, Double) -> Void] = [:]

    func install(
        displayID: CGDirectDisplayID,
        handler: @escaping @Sendable (CGDirectDisplayID, Double) -> Void
    ) {
        lock.lock()
        handlers[displayID] = handler
        lock.unlock()
    }

    func remove(displayID: CGDirectDisplayID) {
        lock.lock()
        handlers[displayID] = nil
        lock.unlock()
    }

    func deliver(value: Double) {
        lock.lock()
        let snapshot = handlers
        lock.unlock()
        for (displayID, handler) in snapshot {
            handler(displayID, value)
        }
    }
}

/// DisplayServices 亮度变化回调（C 函数指针，不能捕获上下文）。
private func systemBrightnessChangedCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard
        let dictionary = userInfo as NSDictionary?,
        let value = SystemBrightnessMath.brightness(
            fromNotificationValue: dictionary.object(forKey: systemBrightnessValueKey))
    else { return }
    SystemBrightnessRelay.shared.deliver(value: value)
}
