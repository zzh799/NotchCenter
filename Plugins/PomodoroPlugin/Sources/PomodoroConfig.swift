import AppKit
import Foundation

// MARK: - 用户设置（StateStore 持久化）与净化逻辑

/// 番茄钟用户设置。时间为整数档（滑杆步进），音效为 NSSound 名称
/// （"none" 表示静音）。
struct PomodoroConfig: Codable, Equatable {
    /// 专注时间（分钟）。
    var focusMinutes: Int = 25
    /// 休息时间（分钟）。
    var restMinutes: Int = 5
    /// 随机提示音最小间隔（分钟）。
    var reminderMinMinutes: Int = 3
    /// 随机提示音最大间隔（分钟）。
    var reminderMaxMinutes: Int = 5
    /// 微休息时长（秒）。
    var microBreakSeconds: Int = 10
    /// 微休息中的提示音。
    var microBreakSound: String = "Pop"
    /// 开始音效（专注开始，含微休息/休息结束回归）。
    var startSound: String = "Glass"
    /// 结束音效（专注结束，含手动跳过）。
    var endSound: String = "Hero"
}

/// 设置的边界与净化（纯逻辑，单元测试覆盖）：磁盘上或版本升级带入的
/// 越界值一律拉回合法档位；最小/最大间隔保持 min ≤ max。
enum PomodoroConfigLogic {
    static let focusRange = 5...90
    static let restRange = 1...30
    static let reminderMinRange = 1...30
    static let reminderMaxRange = 2...60
    static let microBreakRange = 5...60

    static func sanitized(_ config: PomodoroConfig) -> PomodoroConfig {
        var next = config
        next.focusMinutes = clamp(next.focusMinutes, focusRange)
        next.restMinutes = clamp(next.restMinutes, restRange)
        next.reminderMinMinutes = clamp(next.reminderMinMinutes, reminderMinRange)
        next.reminderMaxMinutes = clamp(next.reminderMaxMinutes, reminderMaxRange)
        next.reminderMaxMinutes = max(next.reminderMaxMinutes, next.reminderMinMinutes)
        next.microBreakSeconds = clamp(next.microBreakSeconds, microBreakRange)
        if !PomodoroSoundCatalog.isAvailable(next.microBreakSound) {
            next.microBreakSound = PomodoroConfig().microBreakSound
        }
        if !PomodoroSoundCatalog.isAvailable(next.startSound) {
            next.startSound = PomodoroConfig().startSound
        }
        if !PomodoroSoundCatalog.isAvailable(next.endSound) {
            next.endSound = PomodoroConfig().endSound
        }
        return next
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - 音效目录（系统内置 NSSound，无自定义资源）

enum PomodoroSoundCatalog {
    /// 静音选项的哨兵值。
    static let noneID = "none"
    /// 系统内置音效子集（按听感轻 → 重排序；NSSound(named:) 即时可播）。
    static let names = [
        "Pop", "Tink", "Ping", "Glass", "Purr", "Hero",
        "Submarine", "Blow", "Bottle", "Funk", "Sosumi", "Basso",
    ]

    /// 值是否合法（用于存储净化；含静音哨兵）。
    static func isAvailable(_ name: String) -> Bool {
        name == noneID || names.contains(name)
    }

    /// 值是否需要实际播放。
    static func isPlayable(_ name: String) -> Bool {
        name != noneID && names.contains(name)
    }
}

// MARK: - 音效播放（可注入替身做测试）

@MainActor
protocol PomodoroSoundPlaying {
    func play(_ name: String)
}

struct NSSoundPlayer: PomodoroSoundPlaying {
    func play(_ name: String) {
        guard PomodoroSoundCatalog.isPlayable(name), let sound = NSSound(named: name) else {
            return
        }
        sound.play()
    }
}
