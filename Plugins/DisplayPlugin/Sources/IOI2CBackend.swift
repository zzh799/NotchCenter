import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

// MARK: - Intel DDC 后端（IOI2C / IOFramebuffer 路线）
//
// 依据 Apple 公开 IOKit API（IOGraphicsLib / IOI2CInterface 头文档）与 VESA
// DDC/CI 标准帧实现，行为对齐 MonitorControl（MIT）在 Intel Mac 上的同路线：
// - IOFramebuffer 按 DisplayVendorID / DisplayProductID / DisplaySerialNumber
//   与 CGDisplay 元数据对齐定位（glfw 同款方法；serial 常为 0，同型号双屏
//   靠顺序对齐是该方法的已知边界）。
// - Get 请求回复用 kIOI2CDDCciReplyTransactionType；总线不支持时按注册表
//   IOI2CTransactionTypes 位域探测，回退 kIOI2CSimpleTransactionType。
// - AMD 帧缓冲需要更长的 minReplyDelay（30ms）才有回复。
// - 回读按 VESA DDC/CI 通信错误恢复节奏重试（40ms 间隔，至多 10 次）；
//   纯写请求后 usleep 20ms 再放行下一笔。
//
// 思路参考 ddcctl（GPLv3，仅作行为参照，未复制其代码；帧格式为 VESA 标准、
// 与 MIT 许可的 m1ddc 一致）。Intel 真机验证条件暂缺（开发机为 Apple
// Silicon），帧编解码与映射逻辑由 DisplayPluginTests 覆盖。

final class IOI2CBackend: DisplayDDCBackend, @unchecked Sendable {
    private static let errorRecoveryWait: UInt32 = 40_000 // µs，VESA 错误恢复间隔
    private static let writeSettleWait: UInt32 = 20_000 // µs，纯写请求后的间隔

    private let queue = DispatchQueue(label: "notchcenter.display-plugin.ioi2c", qos: .utility)
    /// displayID → IOFramebuffer（持有枚举引用）。
    private var framebuffers: [CGDirectDisplayID: io_service_t] = [:]
    /// 回读事务类型：优先 DDCciReply；总线不支持时回退 Simple。
    private var replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)

    /// IOI2C 一族是公开 API，始终可构造；实际能力由枚举结果体现。
    static func isAvailable() -> Bool { true }

    deinit {
        for (_, framebuffer) in framebuffers {
            IOObjectRelease(framebuffer)
        }
    }

    // MARK: 枚举

    func listDisplays() async -> [ExternalDisplay] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if framebuffers.isEmpty { probeReplyTransactionType() }
                continuation.resume(returning: enumerate())
            }
        }
    }

    private func enumerate() -> [ExternalDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

        var remaining = DisplayListFilter.externalCandidates(
            ids.prefix(Int(count)).map { id in
                (id: id,
                 isBuiltin: CGDisplayIsBuiltin(id) != 0,
                 isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                 isMain: id == CGMainDisplayID())
            }
        )

        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator
            ) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [ExternalDisplay] = []
        var freshFramebuffers: [CGDirectDisplayID: io_service_t] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            guard let (id, productName) = Self.matchFramebuffer(service, candidates: remaining) else {
                IOObjectRelease(service)
                continue
            }
            // 接手本次迭代引用（不再释放），替换枚举时统一释放旧条目。
            freshFramebuffers[id] = service
            remaining.removeAll { $0 == id }
            let name = productName ?? LF("display.fallback.name", result.count + 1)
            result.append(ExternalDisplay(id: id, name: name))
        }
        for (id, old) in framebuffers where freshFramebuffers[id] == nil {
            IOObjectRelease(old)
        }
        framebuffers = freshFramebuffers
        return result
    }

    /// IOFramebuffer ↔ CGDisplay 元数据对齐（vendor / model / serial）。
    private static func matchFramebuffer(
        _ service: io_service_t, candidates: [CGDirectDisplayID]
    ) -> (id: CGDirectDisplayID, productName: String?)? {
        var busCount: IOItemCount = 0
        guard
            IOFBGetI2CInterfaceCount(service, &busCount) == KERN_SUCCESS, busCount >= 1,
            let info = IODisplayCreateInfoDictionary(
                service, IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any],
            let vendor = (info["DisplayVendorID"] as? NSNumber)?.uint32Value,
            let product = (info["DisplayProductID"] as? NSNumber)?.uint32Value
        else { return nil }
        let serial = (info["DisplaySerialNumber"] as? NSNumber)?.uint32Value ?? 0
        let productName = (info["DisplayProductName"] as? [String: String])?.values.first
        for id in candidates
        where
            vendor == CGDisplayVendorNumber(id)
            && product == CGDisplayModelNumber(id)
            && serial == CGDisplaySerialNumber(id) {
            return (id, productName)
        }
        return nil
    }

    /// 注册表 IOI2CTransactionTypes 位域探测：优先 DDCciReply，否则 Simple。
    private func probeReplyTransactionType() {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &iterator
            ) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        var fallback: IOOptionBits?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard
                let types = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "IOI2CTransactionTypes" as CFString,
                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                ) as? NSNumber
            else { continue }
            let bitfield = types.uint64Value
            if bitfield & (1 << UInt64(kIOI2CDDCciReplyTransactionType)) != 0 {
                replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                return
            }
            if bitfield & (1 << UInt64(kIOI2CSimpleTransactionType)) != 0 {
                fallback = IOOptionBits(kIOI2CSimpleTransactionType)
            }
        }
        if let fallback { replyTransactionType = fallback }
    }

    // MARK: 亮度读写

    func readLuminance(_ display: ExternalDisplay) async throws -> LuminanceReading {
        try await perform { [self] in
            guard let framebuffer = framebuffers[display.id] else { throw DDCError.displayGone }
            let frame = DDCPacketCodec.i2cBuffer(
                DDCPacketCodec.getMessage(vcp: VCPCode.luminance))
            let replyDelay = Self.minReplyDelay(for: framebuffer)
            var reply = [UInt8](repeating: 0, count: 11)
            var lastResult: IOReturn = kIOReturnError
            // VESA 通信错误恢复：失败后 40ms 重试，至多 10 次。
            for _ in 0..<10 {
                lastResult = send(
                    frame: frame, framebuffer: framebuffer, reply: &reply,
                    replyType: replyTransactionType, replyDelay: replyDelay)
                if lastResult == KERN_SUCCESS,
                   let reading = try? DDCPacketCodec.decodeReply(reply, vcp: VCPCode.luminance) {
                    return reading
                }
                usleep(Self.errorRecoveryWait)
            }
            throw DDCError.transportFailed(code: Int(lastResult))
        }
    }

    func writeLuminance(_ display: ExternalDisplay, value: Int) async throws {
        try await perform { [self] in
            guard let framebuffer = framebuffers[display.id] else { throw DDCError.displayGone }
            let frame = DDCPacketCodec.i2cBuffer(
                DDCPacketCodec.setMessage(vcp: VCPCode.luminance, value: UInt16(clamping: value)))
            var reply = [UInt8]()
            var lastResult: IOReturn = kIOReturnError
            for _ in 0..<2 {
                lastResult = send(
                    frame: frame, framebuffer: framebuffer, reply: &reply,
                    replyType: IOOptionBits(kIOI2CNoTransactionType), replyDelay: 0)
                if lastResult == KERN_SUCCESS { return }
                usleep(Self.writeSettleWait)
            }
            throw DDCError.transportFailed(code: Int(lastResult))
        }
    }

    /// 经帧缓冲的全部 I2C 总线投递一次请求；返回传输是否成功
    /// （成功 = 提交与请求 result 都是 KERN_SUCCESS，回复帧校验由调用方做）。
    private func send(
        frame: [UInt8], framebuffer: io_service_t, reply: inout [UInt8],
        replyType: IOOptionBits, replyDelay: UInt64
    ) -> IOReturn {
        // inout 参数与 withUnsafeMutableBytes 不能重叠访问，副本进出。
        var replyBuffer = reply
        defer { reply = replyBuffer }
        let replyByteCount = UInt32(replyBuffer.count)
        var request = IOI2CRequest()
        request.commFlags = 0
        request.minReplyDelay = replyDelay
        request.sendAddress = 0x6E
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.replyAddress = 0x6F
        request.replySubAddress = 0x51
        request.replyTransactionType = replyType

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else {
            return kIOReturnError
        }
        var lastResult: IOReturn = kIOReturnError
        frame.withUnsafeBytes { sendBuffer in
            replyBuffer.withUnsafeMutableBytes { replyBufferPointer in
                request.sendBuffer = vm_address_t(UInt(bitPattern: sendBuffer.baseAddress))
                request.sendBytes = UInt32(frame.count)
                request.replyBuffer = replyBufferPointer.baseAddress.map {
                    vm_address_t(UInt(bitPattern: $0))
                } ?? 0
                request.replyBytes = replyByteCount
                for bus in 0..<busCount {
                    var interface: io_service_t = 0
                    guard
                        IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS
                    else { continue }
                    defer { IOObjectRelease(interface) }
                    var connect = IOI2CConnectRef(bitPattern: 0)
                    guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS else {
                        continue
                    }
                    defer { IOI2CInterfaceClose(connect, 0) }
                    var requestCopy = request
                    let sendResult = IOI2CSendRequest(connect, 0, &requestCopy)
                    if sendResult == KERN_SUCCESS, requestCopy.result == KERN_SUCCESS {
                        lastResult = KERN_SUCCESS
                        break
                    }
                    lastResult = sendResult != KERN_SUCCESS
                        ? sendResult : requestCopy.result
                }
                if replyType == IOOptionBits(kIOI2CNoTransactionType) {
                    usleep(Self.writeSettleWait)
                }
            }
        }
        return lastResult
    }

    /// AMD 帧缓冲需要更长的回复延迟（对照 MonitorControl/ddcctl 的经验值）。
    private static func minReplyDelay(for framebuffer: io_service_t) -> UInt64 {
        guard
            let path = IORegistryEntryCopyPath(framebuffer, kIOServicePlane)?
                .takeRetainedValue() as? String
        else { return 1 }
        if path.range(of: "/AMD", options: .caseInsensitive) != nil { return 30_000_000 } // ns
        return 1
    }

    /// 把同步阻塞体丢进串行队列（队列即该后端的锁，等价 ddcctl 的 per-fb 信号量）。
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
