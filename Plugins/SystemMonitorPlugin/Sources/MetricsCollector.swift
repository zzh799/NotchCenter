import Darwin
import Foundation
import IOKit

// MARK: - 系统指标采集（全部公开 API，无私有框架）
//
// CPU / 内存 / 网络走 Mach 与 BSD 接口，磁盘走 IOKit registry（IOBlockStorageDriver
// 的 "Statistics" 字典，累计 Bytes (Read)/(Write)）。采集在后台任务执行
// （store 的 Task.detached 调进来），本文件不持有可变状态、天然 Sendable。

protocol SystemMetricsProviding: Sendable {
    func collect() -> SystemRawSample
}

/// 真实系统数据源。
struct DarwinMetricsProvider: SystemMetricsProviding {
    func collect() -> SystemRawSample {
        var sample = SystemRawSample(timestamp: Date())
        Self.collectCPU(into: &sample)
        Self.collectMemory(into: &sample)
        Self.collectDisk(into: &sample)
        Self.collectNetwork(into: &sample)
        return sample
    }

    // MARK: CPU（HOST_CPU_LOAD_INFO 累计 tick）

    private static func collectCPU(into sample: inout SystemRawSample) {
        var hostPort: mach_port_t = 0
        // mach_host_self 每次调用 +1 引用，用完必须回收，否则每次采样泄漏一个端口权。
        hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutableBytes(of: &info) { buffer -> kern_return_t in
            host_statistics(hostPort, HOST_CPU_LOAD_INFO, buffer.baseAddress?.assumingMemoryBound(to: integer_t.self), &count)
        }
        guard result == KERN_SUCCESS else { return }
        // C 数组以元组导入，元素序 = CPU_STATE：0 user / 1 system / 2 idle / 3 nice。
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let idle = UInt64(ticks.2)
        sample.cpuBusyTicks = busy
        sample.cpuTotalTicks = busy + idle
    }

    // MARK: 内存（HOST_VM_INFO64 + 压力等级 sysctl）

    private static func collectMemory(into sample: inout SystemRawSample) {
        var hostPort: mach_port_t = 0
        hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutableBytes(of: &stats) { buffer -> kern_return_t in
            host_statistics64(hostPort, HOST_VM_INFO64, buffer.baseAddress?.assumingMemoryBound(to: integer_t.self), &count)
        }
        guard result == KERN_SUCCESS else { return }
        // 活动监视器口径：已用 = 应用内存(internal) + 联动内存(wired) + 已压缩(compressor)。
        let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        let used = UInt64(stats.internal_page_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        sample.memoryUsedBytes = used * pageSize
        sample.memoryTotalBytes = totalPhysicalMemory()
        sample.memoryPressureLevel = memoryPressureLevel()
    }

    private static func totalPhysicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return value
    }

    /// 内核内存压力：1 normal / 2 warning / 4 critical；读不到按 normal（0）。
    private static func memoryPressureLevel() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    // MARK: 磁盘（IOKit IOBlockStorageDriver "Statistics"，全盘聚合）

    private static func collectDisk(into sample: inout SystemRawSample) {
        var iterator: io_iterator_t = 0
        // IOServiceMatching 返回 +1 引用的字典，交给内核消费后由 API 语义接管；
        // GetMatchingServices 成功后 iterator 归调用方，统一 release。
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            sample.diskAvailable = false
            return
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            if let statistics = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            entry = IOIteratorNext(iterator)
        }
        sample.diskReadBytes = read
        sample.diskWriteBytes = write
        sample.diskAvailable = true
    }

    // MARK: 网络（getifaddrs AF_LINK 计数，按接口留原始值）

    private static func collectNetwork(into sample: inout SystemRawSample) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // 排除表属于展示层口径；采集层只留原始计数（含 loopback）。
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            sample.netInterfaces[name, default: NetCumulative()] = NetCumulative(
                down: UInt64(counters.ifi_ibytes),
                up: UInt64(counters.ifi_obytes)
            )
        }
    }
}
