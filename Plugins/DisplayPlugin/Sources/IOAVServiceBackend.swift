import CoreGraphics
import Darwin
import Foundation
import IOKit

// MARK: - Apple Silicon DDC 后端（IOAVService 路线）
//
// 行为忠实移植自 m1ddc（MIT License, Copyright (c) 2021 waydabber，
// https://github.com/waydabber/m1ddc —— sources/ioregistry.m / sources/i2c.m）：
// - 显示器 → AV 服务定位：CoreDisplay 信息字典取 IODisplayLocation → 注册表
//   adapter → IORegistry 单趟迭代，先命中注册表 ID 对齐的 IOMobileFramebuffer，
//   其后首个 DCPAVServiceProxy 即该屏的 AV 服务入口；Location 非 External 的
//   （内建屏代理）跳过。
// - MCDP29xx 转换芯片（代理父节点 EPICProviderClass == AppleDCPMCDP29XX）的
//   DDC 通道走 0xB7 芯片地址，其余 0x37。
// - 每次传输前 usleep 10ms；读回复对 MCDP29xx 用 50ms（10ms 会拿到空回复）。
// 与 m1ddc 的差异：写入成功不再重复写第二次（m1ddc 的重试循环在成功时也会
// 跑满 DDC_ITERATIONS 次），失败重试一次后放弃。
//
// IOAVServiceCreate / IOAVServiceCreateWithService / IOAVServiceReadI2C /
// IOAVServiceWriteI2C 与 CoreDisplay_DisplayCreateInfoDictionary 均为未公开
// 符号，经 dlopen/dlsym 运行时解析（与 MediaControlsPlugin 的 MediaRemoteSession
// 同一封装形态；插件内的私有 API 接触面共两处，另一处是内建屏的
// SystemBrightnessBackend）；x86_64 切片没有这些符号，`isAvailable()` 天然为
// false，由 `DDCBackendFactory.make()` 回退 IOI2CBackend。
// 注意：`CoreDisplay_DisplayCreateInfoDictionary` 的宿主框架随系统版本漂移
// （macOS 14 及更早 CoreDisplay → macOS 15 起 DisplayServices 承接），
// 真机（macOS 15.6, Apple Silicon）已验证枚举 + 读 + 回写同值全链路可用。

final class IOAVServiceBackend: DisplayBrightnessBackend, @unchecked Sendable {
    private static let ddcWait: UInt32 = 10_000 // µs，m1ddc DDC_WAIT
    private static let mcdpReadWait: UInt32 = 50_000 // µs，m1ddc DDC_MCDP_READ_WAIT
    private static let chipAddressDefault: UInt32 = 0x37
    private static let chipAddressMCDP29XX: UInt32 = 0xB7
    private static let i2cSubAddress: UInt32 = 0x51

    // MARK: 私有符号（进程级缓存，只解析一次）

    private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias IOAVServiceCreateWithServiceFn = @convention(c) (
        CFAllocator?, io_service_t
    ) -> Unmanaged<AnyObject>?
    private typealias IOAVServiceReadI2CFn = @convention(c) (
        AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
    ) -> IOReturn
    private typealias IOAVServiceWriteI2CFn = @convention(c) (
        AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32
    ) -> IOReturn
    private typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private struct Symbols {
        let create: IOAVServiceCreateFn
        let createWithService: IOAVServiceCreateWithServiceFn
        let read: IOAVServiceReadI2CFn
        let write: IOAVServiceWriteI2CFn
        let displayInfo: CoreDisplayInfoFn
    }

    nonisolated(unsafe) private static var cachedSymbols: Symbols?

    private static func symbols() -> Symbols? {
        if let cachedSymbols { return cachedSymbols }
        guard
            let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let create = dlsym(iokit, "IOAVServiceCreate"),
            let createWithService = dlsym(iokit, "IOAVServiceCreateWithService"),
            let read = dlsym(iokit, "IOAVServiceReadI2C"),
            let write = dlsym(iokit, "IOAVServiceWriteI2C"),
            let displayInfo = loadDisplayInfoSymbol()
        else { return nil }
        let resolved = Symbols(
            create: unsafeBitCast(create, to: IOAVServiceCreateFn.self),
            createWithService: unsafeBitCast(createWithService, to: IOAVServiceCreateWithServiceFn.self),
            read: unsafeBitCast(read, to: IOAVServiceReadI2CFn.self),
            write: unsafeBitCast(write, to: IOAVServiceWriteI2CFn.self),
            displayInfo: unsafeBitCast(displayInfo, to: CoreDisplayInfoFn.self)
        )
        cachedSymbols = resolved
        return resolved
    }

    /// `CoreDisplay_DisplayCreateInfoDictionary` 的宿主框架随系统版本漂移：
    /// macOS 14 及更早在 CoreDisplay；macOS 15 起该框架移除，符号由
    /// DisplayServices 承接（SkyLight 亦再导出）。逐个探测。
    private static func loadDisplayInfoSymbol() -> UnsafeMutableRawPointer? {
        let frameworkPaths = [
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        ]
        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            if let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") {
                return symbol
            }
        }
        return nil
    }

    /// IOAVService 符号是否可解析（即是否在 Apple Silicon 上运行）。
    static func isAvailable() -> Bool {
        symbols() != nil
    }

    static func makeIfAvailable() -> IOAVServiceBackend? {
        guard let symbols = symbols() else { return nil }
        return IOAVServiceBackend(symbols: symbols)
    }

    // MARK: 状态（仅在 queue 上访问）

    private let queue = DispatchQueue(label: "notchcenter.display-plugin.ioavservice", qos: .utility)
    private let symbols: Symbols
    /// displayID → (IOAVService, 芯片地址)；service 为 +1 持有，替换枚举时 release。
    private var transports: [CGDirectDisplayID: (service: Unmanaged<AnyObject>, chipAddress: UInt32)] = [:]

    private init(symbols: Symbols) {
        self.symbols = symbols
    }

    deinit {
        for (_, transport) in transports {
            transport.service.release()
        }
    }

    // MARK: 枚举

    func listDisplays() async -> [BrightnessDisplay] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: enumerate())
            }
        }
    }

    private func enumerate() -> [BrightnessDisplay] {
        let candidates = DisplayListFilter.externalCandidates(DisplayDescriptor.online())

        var result: [BrightnessDisplay] = []
        var freshTransports: [CGDirectDisplayID: (service: Unmanaged<AnyObject>, chipAddress: UInt32)] = [:]
        for (index, id) in candidates.enumerated() {
            guard let transport = findTransport(displayID: id) else { continue }
            freshTransports[id] = (transport.service, transport.chipAddress)
            let name = transport.productName ?? LF("display.fallback.name", index + 1)
            result.append(BrightnessDisplay(id: id, name: name))
        }
        // 本轮消失的显示器：释放其 AV 服务引用。
        for (id, transport) in transports where freshTransports[id] == nil {
            transport.service.release()
        }
        transports = freshTransports
        return result
    }

    /// m1ddc getOnlineDisplayInfos + getDisplayDDCTransport 的组合移植：
    /// CoreDisplay 信息字典 → IODisplayLocation → 注册表 adapter →
    /// IOMobileFramebuffer 对齐 → DCPAVServiceProxy → IOAVServiceCreateWithService。
    /// 虚拟屏（Sidecar/AirPlay，无信息字典）与无 AV 通道的屏返回 nil。
    private func findTransport(
        displayID: CGDirectDisplayID
    ) -> (service: Unmanaged<AnyObject>, chipAddress: UInt32, productName: String?)? {
        guard
            let info = symbols.displayInfo(displayID)?.takeRetainedValue() as NSDictionary?,
            let location = info["IODisplayLocation"] as? String, !location.isEmpty,
            info["kCGDisplayUUID"] != nil
        else { return nil }
        let adapter = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard adapter != 0 else { return nil }
        defer { IOObjectRelease(adapter) }

        let productName = Self.productName(of: adapter)
        guard let (service, chipAddress) = Self.avService(for: adapter, symbols: symbols) else {
            return nil
        }
        return (service, chipAddress, productName)
    }

    /// EDID 产品名（m1ddc 同款：adapter 下递归取 DisplayAttributes →
    /// ProductAttributes → ProductName）。
    private static func productName(of adapter: io_registry_entry_t) -> String? {
        guard
            let attributes = IORegistryEntrySearchCFProperty(
                adapter, kIOServicePlane, "DisplayAttributes" as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
            ) as? [String: Any],
            let productAttributes = attributes["ProductAttributes"] as? [String: Any],
            let name = productAttributes["ProductName"] as? String,
            !name.isEmpty
        else { return nil }
        return name
    }

    /// 单趟注册表迭代定位该显示器的外接 AV 服务（忠实移植 getDisplayDDCTransport）。
    private static func avService(
        for adapter: io_registry_entry_t, symbols: Symbols
    ) -> (service: Unmanaged<AnyObject>, chipAddress: UInt32)? {
        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else {
            return nil
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryCreateIterator(
                root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
            ) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var framebufferMatchesDisplay = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if IOObjectConformsTo(service, "IOMobileFramebuffer") != 0 {
                var framebufferID: UInt64 = 0
                framebufferMatchesDisplay =
                    IORegistryEntryGetRegistryEntryID(service, &framebufferID) == KERN_SUCCESS
                    && framebufferID == adapterID
                IOObjectRelease(service)
                continue
            }
            var name = [CChar](repeating: 0, count: 128)
            let isProxyService =
                IORegistryEntryGetName(service, &name) == KERN_SUCCESS
                && String(cString: name) == "DCPAVServiceProxy"
            guard framebufferMatchesDisplay, isProxyService else {
                IOObjectRelease(service)
                continue
            }

            // IOAVServiceCreateWithService 为 +1 返回，Unmanaged 自持。
            guard let avService = symbols.createWithService(kCFAllocatorDefault, service) else {
                IOObjectRelease(service)
                continue
            }
            guard Self.isExternalProxy(service) else {
                avService.release()
                IOObjectRelease(service)
                continue
            }
            let chipAddress = Self.isMCDP29XXProxy(service)
                ? chipAddressMCDP29XX : chipAddressDefault
            IOObjectRelease(service)
            return (avService, chipAddress)
        }
        return nil
    }

    /// 代理的 Location 属性是否为 External（内建屏代理是 Internal）。
    private static func isExternalProxy(_ service: io_registry_entry_t) -> Bool {
        guard
            let location = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "Location" as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
            ) as? String
        else { return false }
        return location == "External"
    }

    /// MCDP29xx 转换芯片判定（m1ddc isMCDP29XXProxy）：父节点 EPICProviderClass。
    private static func isMCDP29XXProxy(_ proxy: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(parent) }
        guard
            let providerClass = IORegistryEntryCreateCFProperty(
                parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
        else { return false }
        return providerClass == "AppleDCPMCDP29XX"
    }

    // MARK: 亮度读写

    func readLuminance(_ display: BrightnessDisplay) async throws -> LuminanceReading {
        try await perform { [self] in
            guard let transport = transports[display.id] else { throw BrightnessError.displayGone }
            let avService = transport.service.takeUnretainedValue()
            // Get 请求（I2C 写）→ 稍候 → 读 11 字节回复（m1ddc readingOperation）。
            usleep(Self.ddcWait)
            let request = DDCPacketCodec.avServiceBuffer(
                DDCPacketCodec.getMessage(vcp: VCPCode.luminance))
            let writeResult = request.withUnsafeBytes { buffer in
                symbols.write(
                    avService, transport.chipAddress, Self.i2cSubAddress,
                    buffer.baseAddress!, UInt32(request.count))
            }
            guard writeResult == kIOReturnSuccess else {
                throw BrightnessError.transportFailed(code: Int(writeResult))
            }
            usleep(
                transport.chipAddress == Self.chipAddressMCDP29XX
                    ? Self.mcdpReadWait : Self.ddcWait)
            var reply = [UInt8](repeating: 0, count: 12)
            let replyByteCount = UInt32(reply.count)
            let readResult = reply.withUnsafeMutableBytes { buffer in
                symbols.read(
                    avService, transport.chipAddress, Self.i2cSubAddress,
                    buffer.baseAddress!, replyByteCount)
            }
            guard readResult == kIOReturnSuccess else {
                throw BrightnessError.transportFailed(code: Int(readResult))
            }
            return try DDCPacketCodec.decodeReply(Array(reply.prefix(11)), vcp: VCPCode.luminance)
        }
    }

    func writeLuminance(_ display: BrightnessDisplay, value: Int) async throws {
        try await perform { [self] in
            guard let transport = transports[display.id] else { throw BrightnessError.displayGone }
            let avService = transport.service.takeUnretainedValue()
            let frame = DDCPacketCodec.avServiceBuffer(
                DDCPacketCodec.setMessage(vcp: VCPCode.luminance, value: UInt16(clamping: value)))
            // 每次尝试前 10ms；失败重试一次（成功不重复写，见文件头与 m1ddc 的差异）。
            var lastResult: IOReturn = kIOReturnError
            for _ in 0..<2 {
                usleep(Self.ddcWait)
                lastResult = frame.withUnsafeBytes { buffer in
                    symbols.write(
                        avService, transport.chipAddress, Self.i2cSubAddress,
                        buffer.baseAddress!, UInt32(frame.count))
                }
                if lastResult == kIOReturnSuccess { return }
            }
            throw BrightnessError.transportFailed(code: Int(lastResult))
        }
    }

    /// 把同步阻塞体丢进串行队列（队列即该后端的锁）。
    private func perform<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
