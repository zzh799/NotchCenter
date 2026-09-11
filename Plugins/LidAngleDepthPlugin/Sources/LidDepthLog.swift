import Foundation
import os

/// 插件日志。子系统沿用宿主 bundle id,便于 `log show` 一条命令捞出宿主与插件。
///
/// 用 notice 级而非 info:info 级只留在内存里,`log show` 读的是落盘存储。
enum LidDepthLog {
    static let geometry = Logger(subsystem: "com.notchcenter.app", category: "lidangle.geometry")
    static let lid = Logger(subsystem: "com.notchcenter.app", category: "lidangle.lid")
}
