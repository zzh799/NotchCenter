import XCTest
@testable import PomodoroPlugin

/// 番茄钟设置净化回归：越界值拉回合法档位、最小/最大间隔保持 min ≤ max、
/// 未知音效名回退默认值（静音哨兵合法）。
final class PomodoroConfigLogicTests: XCTestCase {
    func testSanitizeClampsOutOfRangeValues() {
        var config = PomodoroConfig()
        config.focusMinutes = 500
        config.restMinutes = 0
        config.reminderMinMinutes = 0
        config.reminderMaxMinutes = 999
        config.microBreakSeconds = 1

        let sanitized = PomodoroConfigLogic.sanitized(config)
        XCTAssertEqual(sanitized.focusMinutes, PomodoroConfigLogic.focusRange.upperBound)
        XCTAssertEqual(sanitized.restMinutes, PomodoroConfigLogic.restRange.lowerBound)
        XCTAssertEqual(sanitized.reminderMinMinutes, PomodoroConfigLogic.reminderMinRange.lowerBound)
        XCTAssertEqual(sanitized.reminderMaxMinutes, PomodoroConfigLogic.reminderMaxRange.upperBound)
        XCTAssertEqual(sanitized.microBreakSeconds, PomodoroConfigLogic.microBreakRange.lowerBound)
    }

    func testReminderMaxIsAtLeastMin() {
        var config = PomodoroConfig()
        config.reminderMinMinutes = 30
        config.reminderMaxMinutes = 5

        let sanitized = PomodoroConfigLogic.sanitized(config)
        XCTAssertEqual(sanitized.reminderMaxMinutes, 30)
    }

    func testValidValuesPassThroughUnchanged() {
        let config = PomodoroConfig()
        XCTAssertEqual(PomodoroConfigLogic.sanitized(config), config)
    }

    func testUnknownSoundNamesFallBackToDefaults() {
        var config = PomodoroConfig()
        config.startSound = "NonexistentSound"
        config.microBreakSound = "AlsoMissing"
        config.endSound = PomodoroSoundCatalog.noneID

        let sanitized = PomodoroConfigLogic.sanitized(config)
        XCTAssertEqual(sanitized.startSound, PomodoroConfig().startSound)
        XCTAssertEqual(sanitized.microBreakSound, PomodoroConfig().microBreakSound)
        // 静音哨兵是合法值，保持不变。
        XCTAssertEqual(sanitized.endSound, PomodoroSoundCatalog.noneID)
    }
}
