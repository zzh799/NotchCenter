import Foundation
import IOKit
import IOKit.hid

/// 从 MacBook 姿态传感器读取**上盖铰链角度**。
///
/// 传感器是 `AppleSPUHIDDevice`,vendor `0x05AC`,product `0x8104`,HID usage page
/// `0x20`、usage `0x8A`。两份 report 携带同一个角度,都走 `kIOHIDReportTypeFeature`:
///
/// - report 7:5 字节 `[0x07, b0, b1, b2, b3]`,小端**百分之一度**;
/// - report 1:3 字节 `[0x01, lo, hi]`,小端**整度**,0...360。
///
/// 并非所有机型都声明 report 7,故以 report 1 兜底。读数约每 100 ms 刷新一次,
/// **不需要任何系统权限**(与屏幕录制、辅助功能都无关)。
///
/// 线程约定:本类型不持有跨线程状态,`angle()`/`isAvailable` 可在任意线程调用;
/// 但 `IOHIDDeviceGetReport` 是同步阻塞调用,不要放在主线程的高频路径上——使用方
/// 应把它放在自己的轮询节拍里(参考 `LidAngleMonitor`)。
public final class LidAngleSensor: @unchecked Sendable {

    /// 传感器应答用的是哪份 report,在打开设备时定一次。
    public enum Resolution: Sendable, Equatable {
        /// report 7,0.01° 步进。
        case hundredthsOfADegree
        /// report 1,1° 步进。
        case wholeDegrees

        public var reportID: Int {
            switch self {
            case .hundredthsOfADegree: return 7
            case .wholeDegrees: return 1
            }
        }

        /// 供 UI/日志展示的分辨率名。
        public var describedName: String {
            switch self {
            case .hundredthsOfADegree: return "report 7 (0.01°)"
            case .wholeDegrees: return "report 1 (1°)"
            }
        }

        /// 该档位的量化步长(度)。
        public var step: Double {
            switch self {
            case .hundredthsOfADegree: return 0.01
            case .wholeDegrees: return 1
            }
        }
    }

    /// 上一次 `angle()` 调用看到了什么。读取失败时 `angle()` 返回 nil,原因留在这里。
    public struct ReadTrace: Sendable {
        /// `IOHIDDeviceGetReport` 的返回值。
        public var status: IOReturn = kIOReturnSuccess
        /// 设备实际写回的字节数。
        public var length: Int = 0
        /// 设备实际写回的字节。
        public var bytes: [UInt8] = []
        /// 解出的值越界(不在 0...360)时记在这里。
        public var rejectedDegrees: Double?
    }

    /// 上次读取的诊断信息(只读快照)。
    public private(set) var lastRead = ReadTrace()
    /// 打开设备时确定的档位;设备不可用时为 nil。
    public private(set) var resolution: Resolution?

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 32)

    /// 设备已打开且档位已确定。
    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return device != nil && resolution != nil
    }

    public init() {
        open()
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// 当前盖角(度),读取失败返回 nil。
    ///
    /// 0 表示完全合上;MacBook 打开到约 130 度。注意 `0` 是**合法读数**,
    /// 因此不能用 `angle() ?? 0` 之类的写法把失败与"合上"混为一谈——判定合盖
    /// 请用 `LidAngleMonitor` 的状态,或显式区分 nil。
    public func angle() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let resolution else { return nil }
        guard let bytes = read(reportID: resolution.reportID) else { return nil }

        let degrees: Double
        switch resolution {
        case .hundredthsOfADegree:
            guard bytes.count >= 5 else { return nil }
            let raw = UInt32(bytes[1])
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3]) << 16
                | UInt32(bytes[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard bytes.count >= 3 else { return nil }
            degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }

        // 传感器在设备刚打开、以及系统睡眠唤醒的瞬间会给垃圾值,越界即丢弃。
        guard degrees >= 0, degrees <= 360 else {
            lastRead.rejectedDegrees = degrees
            return nil
        }
        return degrees
    }

    // MARK: - 设备

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }
        self.manager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            device = candidate
            if let bytes = read(reportID: 7), bytes.count >= 5 {
                resolution = .hundredthsOfADegree
                return
            }
            if let bytes = read(reportID: 1), bytes.count >= 3 {
                resolution = .wholeDegrees
                return
            }
        }
        device = nil
    }

    /// 调用方必须已持有 `lock`。
    private func read(reportID: Int) -> [UInt8]? {
        lastRead = ReadTrace()
        guard let device else {
            lastRead.status = kIOReturnNoDevice
            return nil
        }
        var length = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, &length)
        }
        lastRead.status = result
        lastRead.length = Int(length)
        guard result == kIOReturnSuccess, length > 0 else { return nil }
        let bytes = Array(buffer[0..<Int(length)])
        lastRead.bytes = bytes
        return bytes
    }
}
