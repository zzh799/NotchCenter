import Foundation

// MARK: - 系统监控纯逻辑层（差分 / 阈值 / 单位换档 / 滑窗）
//
// 本文件只放值类型与纯函数，不触碰 SwiftUI / AppKit / 系统调用：
// 采集（MetricsCollector）负责产生 `SystemRawSample`，store（SystemMonitorStore）
// 负责节奏与生命周期，展示层消费 `MetricSample` 序列。全部逻辑可离线注入测试。

// MARK: - 指标种类

/// 四项系统指标；All-in-one 块的开关与目录图标共用。
enum MetricKind: String, Codable, Sendable, CaseIterable {
    case cpu
    case memory
    case disk
    case network

    /// 目录条目 / 卡片头部图标（SF Symbol）。
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        }
    }

    var displayNameKey: String {
        switch self {
        case .cpu: return "block.cpu.name"
        case .memory: return "block.memory.name"
        case .disk: return "block.disk.name"
        case .network: return "block.network.name"
        }
    }
}

// MARK: - 原始采样（累计值快照）

/// 网络单接口的累计字节数。
struct NetCumulative: Sendable, Equatable {
    var down: UInt64 = 0
    var up: UInt64 = 0
}

/// 一次采集的原始快照：CPU/磁盘/网络是**累计计数**，吞吐由主线程消化时
/// 与上一份快照差分得到；内存是绝对值。值类型 + Sendable，供后台采集
/// 直接跨并发域传递。
struct SystemRawSample: Sendable, Equatable {
    var timestamp = Date()
    /// CPU 累计 tick：busy = user + system + nice，total = busy + idle。
    var cpuBusyTicks: UInt64 = 0
    var cpuTotalTicks: UInt64 = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    /// 内核内存压力等级：1 normal / 2 warning / 4 critical / 0 未知。
    var memoryPressureLevel: Int = 0
    /// 全盘累计读写字节（IOBlockStorageDriver 聚合）。
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    /// 磁盘统计源不可用（理论上仅 IOKit 迭代失败）时为 false，UI 显示占位。
    var diskAvailable = false
    /// 每接口累计收发字节（AF_LINK 计数），聚合口径由实例配置决定。
    var netInterfaces: [String: NetCumulative] = [:]
}

// MARK: - 消化后的展示样本

/// 内核内存压力三态（与 `kern.memorystatus_vm_pressure_level` 1/2/4 对应）。
enum MemoryPressure: String, Codable, Sendable {
    case normal
    case warning
    case critical

    init(level: Int) {
        switch level {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }
}

/// 网络单接口的瞬时速率（字节/秒）。
struct NetRate: Sendable, Equatable {
    var down: Double
    var up: Double
}

/// 一次采样消化后的全部指标瞬时值；store 的历史序列即本类型数组。
struct MetricSample: Sendable, Equatable {
    var timestamp: Date
    /// 0…1。
    var cpuUsage = 0.0
    /// 0…1（已用 / 物理 总量，活动监视器口径）。
    var memoryUsage = 0.0
    var memoryPressure = MemoryPressure.normal
    var diskReadRate = 0.0
    var diskWriteRate = 0.0
    var diskAvailable = false
    /// 每接口瞬时速率；聚合口径（排除表）属于展示层配置，不在此烘焙。
    var netInterfaceRates: [String: NetRate] = [:]
}

// MARK: - 负载等级与阈值

/// 三档负载等级（对应视觉 绿(白)/黄/红）。
enum LoadLevel: Comparable, Sendable {
    case normal
    case elevated
    case high
}

/// 单指标的黄/红阈值（CPU 为 0…1 占比，磁盘/网络为字节/秒）。
struct MetricThresholds: Equatable, Sendable {
    var yellow: Double
    var red: Double
}

enum SystemMetricsLogic {
    /// 内置默认阈值（常量集中一处；实例设置可覆盖）。
    static func defaultThresholds(for kind: MetricKind) -> MetricThresholds {
        switch kind {
        case .cpu: return MetricThresholds(yellow: 0.70, red: 0.90)
        case .memory: return MetricThresholds(yellow: 0.70, red: 0.90) // 内存不走阈值，仅占位
        case .disk: return MetricThresholds(yellow: 80_000_000, red: 400_000_000)
        case .network: return MetricThresholds(yellow: 1_000_000, red: 10_000_000)
        }
    }

    /// 默认排除的网络接口名前缀（loopback 与虚拟口）；实例配置可整体替换。
    static let defaultNetExclusions: [String] = [
        "lo", "utun", "awdl", "llw", "bridge", "anpi", "ap", "gif", "stf", "xsc", "demux", "vmnet",
    ]

    // MARK: 差分

    /// 由上一份原始快照差分出瞬时样本。`previous == nil`（首采）或时间倒退
    /// 时速率全 0、绝对值照常；计数器回绕/设备重挂（delta 为负）按 0 处理。
    static func differential(from previous: SystemRawSample?, to current: SystemRawSample) -> MetricSample {
        var sample = MetricSample(timestamp: current.timestamp)
        sample.memoryPressure = MemoryPressure(level: current.memoryPressureLevel)
        sample.diskAvailable = current.diskAvailable
        if current.memoryTotalBytes > 0 {
            sample.memoryUsage = min(Double(current.memoryUsedBytes) / Double(current.memoryTotalBytes), 1)
        }
        guard let previous else { return sample }
        let dt = current.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return sample }

        let dTotal = current.cpuTotalTicks > previous.cpuTotalTicks
            ? Double(current.cpuTotalTicks - previous.cpuTotalTicks) : 0
        if dTotal > 0 {
            let dBusy = current.cpuBusyTicks >= previous.cpuBusyTicks
                ? Double(current.cpuBusyTicks - previous.cpuBusyTicks) : 0
            sample.cpuUsage = min(max(dBusy / dTotal, 0), 1)
        }
        if current.diskAvailable {
            sample.diskReadRate = byteRate(current.diskReadBytes, previous.diskReadBytes, dt)
            sample.diskWriteRate = byteRate(current.diskWriteBytes, previous.diskWriteBytes, dt)
        }
        for (name, currentCounters) in current.netInterfaces {
            guard let previousCounters = previous.netInterfaces[name] else { continue }
            sample.netInterfaceRates[name] = NetRate(
                down: byteRate(currentCounters.down, previousCounters.down, dt),
                up: byteRate(currentCounters.up, previousCounters.up, dt)
            )
        }
        return sample
    }

    /// 字节计数差分速率；now ≤ before（计数器重置）时为 0。
    static func byteRate(_ now: UInt64, _ before: UInt64, _ dt: TimeInterval) -> Double {
        guard now > before else { return 0 }
        return Double(now - before) / dt
    }

    // MARK: 网络聚合

    /// 按排除前缀聚合出上下行总速率；命中任一前缀的接口不计入。
    static func aggregateNet(
        _ rates: [String: NetRate],
        exclusions: [String]
    ) -> NetRate {
        var total = NetRate(down: 0, up: 0)
        for (name, rate) in rates {
            let excluded = exclusions.contains { name.hasPrefix($0) }
            guard !excluded else { continue }
            total.down += rate.down
            total.up += rate.up
        }
        return total
    }

    // MARK: 等级映射

    /// 阈值二段映射：< yellow → normal，< red → elevated，否则 high。
    static func level(_ value: Double, thresholds: MetricThresholds) -> LoadLevel {
        if value >= thresholds.red { return .high }
        if value >= thresholds.yellow { return .elevated }
        return .normal
    }

    /// 内存不走数值阈值：直接映射内核压力等级（绿/黄/红）。
    static func level(of pressure: MemoryPressure) -> LoadLevel {
        switch pressure {
        case .normal: return .normal
        case .warning: return .elevated
        case .critical: return .high
        }
    }

    // MARK: 滑窗与归一化

    /// 取历史序列里 `now - window` 之后的切片（历史按时间升序）。
    static func windowSeries(
        _ history: [MetricSample],
        windowSeconds: TimeInterval,
        now: Date,
        field: (MetricSample) -> Double
    ) -> [Double] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        return history.filter { $0.timestamp >= cutoff }.map(field)
    }

    /// 序列归一化到 0…1：`fixedRange`（CPU/内存占比）直接钳制；
    /// 吞吐类按窗口内峰值缩放（峰值下限 1 字节/秒，避免除零与全 0 抖动）。
    static func normalized(_ values: [Double], fixedRange: Bool) -> [Double] {
        if fixedRange {
            return values.map { min(max($0, 0), 1) }
        }
        let peak = values.max() ?? 0
        guard peak > 0 else { return values.map { _ in 0 } }
        return values.map { min(max($0 / peak, 0), 1) }
    }

    // MARK: 数值展示

    /// 0…1 → 整数百分比字符串。
    static func percentString(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 吞吐档位（1000 进位）：自动档按量级选单位；KB 不带小数、
    /// MB < 10 保留 1 位、GB 保留 1 位。
    static func rateString(_ bytesPerSecond: Double, unit: RateUnitPreference) -> String {
        let clamped = max(bytesPerSecond, 0)
        let factor: Double
        let suffix: String
        switch unit {
        case .auto:
            if clamped < 1_000_000 {
                (factor, suffix) = (1_000, "KB/s")
            } else if clamped < 1_000_000_000 {
                (factor, suffix) = (1_000_000, "MB/s")
            } else {
                (factor, suffix) = (1_000_000_000, "GB/s")
            }
        case .kb: (factor, suffix) = (1_000, "KB/s")
        case .mb: (factor, suffix) = (1_000_000, "MB/s")
        case .gb: (factor, suffix) = (1_000_000_000, "GB/s")
        }
        let scaled = clamped / factor
        let decimals: Int
        switch suffix {
        case "KB/s": decimals = 0
        case "MB/s": decimals = scaled < 10 ? 1 : 0
        default: decimals = 1
        }
        return String(format: "%.\(decimals)f %@", scaled, suffix)
    }
}

/// 吞吐数值的单位偏好（磁盘/网络实例设置）。
enum RateUnitPreference: String, Codable, Sendable, CaseIterable {
    case auto
    case kb
    case mb
    case gb

    var localizationKey: String {
        switch self {
        case .auto: return "settings.unit.auto"
        case .kb: return "settings.unit.kb"
        case .mb: return "settings.unit.mb"
        case .gb: return "settings.unit.gb"
        }
    }
}

// MARK: - 历史序列

/// 指标历史：定长裁剪的时间升序样本序列（store 持有，展示层只读）。
enum MetricHistory {
    /// 追加并裁剪到容量上限（超出时丢弃最旧的）。
    static func appending(
        _ sample: MetricSample,
        to history: [MetricSample],
        capacity: Int
    ) -> [MetricSample] {
        var next = history
        next.append(sample)
        if next.count > capacity {
            next.removeFirst(next.count - capacity)
        }
        return next
    }
}
