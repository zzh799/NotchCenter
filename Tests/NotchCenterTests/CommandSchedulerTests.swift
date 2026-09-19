import Foundation
import Testing
import NotchCenterKit
@testable import CommandSchedulerPlugin

// MARK: - 调度纯函数与存储边界回归
//
// 全插件唯一做时间数学的地方（`ScheduleModel.next`）必须能被穷举喂时间，
// 所以这里一律显式构造 `Calendar`（含指定时区），不读 `Calendar.current`。

private func calendar(_ identifier: String) -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: identifier) ?? .gmt
    return value
}

private func moment(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0,
    in calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

private func components(of date: Date, in calendar: Calendar) -> (Int, Int, Int, Int, Int) {
    let value = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return (value.year!, value.month!, value.day!, value.hour!, value.minute!)
}

@Suite("命令调度 · 下次触发时刻")
struct ScheduleModelTests {
    private let shanghai = calendar("Asia/Shanghai")

    @Test("每 N 分钟与整分对齐，不是从创建时刻起算")
    func everyMinutesAlignsToMinuteBoundary() throws {
        let after = moment(2026, 3, 10, 10, 7, in: shanghai)
        let next = try #require(ScheduleModel.next(after: after, rule: .everyMinutes(minutes: 30), calendar: shanghai))
        let parts = components(of: next, in: shanghai)
        #expect(parts.3 == 10 && parts.4 == 30, "10:07 之后的 30 分钟对齐点是 10:30")
    }

    @Test("恰好落在触发点上时取下一次（严格晚于）")
    func nextIsStrictlyAfter() throws {
        let exact = moment(2026, 3, 10, 10, 30, in: shanghai)
        let next = try #require(ScheduleModel.next(after: exact, rule: .everyMinutes(minutes: 30), calendar: shanghai))
        let parts = components(of: next, in: shanghai)
        #expect(parts.3 == 11 && parts.4 == 0)
    }

    @Test("每 N 分钟跨午夜后仍落在对齐点上")
    func everyMinutesCrossesMidnight() throws {
        let after = moment(2026, 3, 10, 23, 50, in: shanghai)
        // 45 分钟档：当日 23:50 之后的下一个对齐点是次日 00:00。
        let next = try #require(ScheduleModel.next(after: after, rule: .everyMinutes(minutes: 45), calendar: shanghai))
        let parts = components(of: next, in: shanghai)
        #expect(parts.2 == 11 && parts.3 == 0 && parts.4 == 0)
    }

    @Test("每小时第 M 分：未过则本小时，已过则下一小时")
    func hourlyRespectsMinuteOfHour() throws {
        let before = moment(2026, 3, 10, 10, 7, in: shanghai)
        let nextBefore = try #require(ScheduleModel.next(after: before, rule: .hourlyAt(minute: 15), calendar: shanghai))
        #expect(components(of: nextBefore, in: shanghai).3 == 10)

        let after = moment(2026, 3, 10, 10, 20, in: shanghai)
        let nextAfter = try #require(ScheduleModel.next(after: after, rule: .hourlyAt(minute: 15), calendar: shanghai))
        #expect(components(of: nextAfter, in: shanghai).3 == 11)
    }

    @Test("每天 HH:MM：当日已过则顺延到次日")
    func dailyRollsToNextDay() throws {
        let morning = moment(2026, 3, 10, 9, 0, in: shanghai)
        let sameDay = try #require(ScheduleModel.next(after: morning, rule: .dailyAt(hour: 9, minute: 30), calendar: shanghai))
        let sameDayParts = components(of: sameDay, in: shanghai)
        #expect(sameDayParts.2 == 10 && sameDayParts.3 == 9)

        let evening = moment(2026, 3, 10, 22, 0, in: shanghai)
        let nextDay = try #require(ScheduleModel.next(after: evening, rule: .dailyAt(hour: 9, minute: 30), calendar: shanghai))
        #expect(components(of: nextDay, in: shanghai).2 == 11)
    }

    @Test("每周指定星期：跳到下一个命中的星期")
    func weeklyPicksMatchingWeekday() throws {
        // 2026-03-10 是周二；规则只要周一（weekday 2）。
        let tuesday = moment(2026, 3, 10, 12, 0, in: shanghai)
        #expect(shanghai.component(.weekday, from: tuesday) == 3)

        let next = try #require(ScheduleModel.next(
            after: tuesday, rule: .weeklyAt(weekdays: [2], hour: 8, minute: 0), calendar: shanghai
        ))
        let parts = components(of: next, in: shanghai)
        #expect(parts.2 == 16 && parts.3 == 8)
        #expect(shanghai.component(.weekday, from: next) == 2)
    }

    @Test("每周多选星期：取最近的一个")
    func weeklyTakesNearestOfSeveral() throws {
        // 2026-03-10 是周二（weekday 3）。集合 [2, 5] = 周一 + 周四，
        // 因此周二之后最近的一次是周四 3/12。
        let tuesday = moment(2026, 3, 10, 12, 0, in: shanghai)
        let next = try #require(ScheduleModel.next(
            after: tuesday, rule: .weeklyAt(weekdays: [2, 5], hour: 8, minute: 0), calendar: shanghai
        ))
        let parts = components(of: next, in: shanghai)
        #expect(parts.2 == 12 && parts.3 == 8)
        #expect(shanghai.component(.weekday, from: next) == 5)
    }

    @Test("每月 31 日在小月直接跳过该月，不顺延到月末")
    func monthlySkipsShortMonths() throws {
        let june = moment(2026, 6, 1, 0, 0, in: shanghai)
        let next = try #require(ScheduleModel.next(
            after: june, rule: .monthlyAt(day: 31, hour: 3, minute: 0), calendar: shanghai
        ))
        let parts = components(of: next, in: shanghai)
        #expect(parts.1 == 7 && parts.2 == 31)
        #expect(ScheduleModel.next(after: june, rule: .monthlyAt(day: 31, hour: 3, minute: 0), calendar: shanghai) != nil)
    }

    @Test("夏令时跳时日：02:30 不存在的那天整天跳过，不顺延")
    func dailySkipsSpringForwardDay() throws {
        // 美国 2026 年春季进入夏令时：3/8 的 02:00→03:00，02:30 不存在。
        let eastern = calendar("America/New_York")
        let after = moment(2026, 3, 7, 3, 0, in: eastern)
        let next = try #require(ScheduleModel.next(
            after: after, rule: .dailyAt(hour: 2, minute: 30), calendar: eastern
        ))
        let parts = components(of: next, in: eastern)
        #expect(parts.2 == 9, "3/8 的 02:30 不存在，应整日跳过到 3/9")
        #expect(parts.3 == 2 && parts.4 == 30)
    }

    @Test("规则夹紧：非法输入被收进合法域而不是让整份任务表罢工")
    func normalizationClampsInvalidValues() {
        #expect(ScheduleRule.everyMinutes(minutes: 0).normalized() == .everyMinutes(minutes: 1))
        #expect(ScheduleRule.everyMinutes(minutes: 99_999).normalized() == .everyMinutes(minutes: 720))
        #expect(ScheduleRule.hourlyAt(minute: 99).normalized() == .hourlyAt(minute: 59))
        #expect(ScheduleRule.dailyAt(hour: -3, minute: 61).normalized() == .dailyAt(hour: 0, minute: 59))
        #expect(ScheduleRule.monthlyAt(day: 40, hour: 3, minute: 0).normalized() == .monthlyAt(day: 31, hour: 3, minute: 0))
        // 空星期集合会让规则永不触发 → 兜底为周一。
        #expect(ScheduleRule.weeklyAt(weekdays: [], hour: 1, minute: 0).normalized() == .weeklyAt(weekdays: [2], hour: 1, minute: 0))
        // 重复与乱序也会被收敛。
        #expect(ScheduleRule.weeklyAt(weekdays: [5, 2, 5], hour: 1, minute: 0).normalized() == .weeklyAt(weekdays: [2, 5], hour: 1, minute: 0))
    }

    @Test("规则 Codable 往返（磁盘形状稳定）")
    func ruleRoundTrips() throws {
        let rules: [ScheduleRule] = [
            .everyMinutes(minutes: 30),
            .hourlyAt(minute: 5),
            .dailyAt(hour: 9, minute: 30),
            .weeklyAt(weekdays: [2, 5], hour: 8, minute: 0),
            .monthlyAt(day: 1, hour: 3, minute: 15),
        ]
        for rule in rules {
            let data = try JSONEncoder().encode(rule)
            #expect(try JSONDecoder().decode(ScheduleRule.self, from: data) == rule)
        }
    }
}

@Suite("命令调度 · 执行环境")
struct ExecutionEnvironmentTests {
    @Test("注入目录在继承 PATH 之后追加且不重复")
    func mergedPathAppendsWithoutDuplicates() throws {
        let merged = ExecutionEnvironment.mergedPath(inherited: "/usr/bin:/bin:/opt/homebrew/bin")
        let parts = merged.split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(parts.first == "/usr/bin", "继承的 PATH 必须排在前面")
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.contains(FileManager.default.homeDirectoryForCurrentUser.path + "/.cargo/bin"))
    }

    @Test("继承 PATH 为空时仍有可用目录（不让 zsh 找不到任何东西）")
    func mergedPathFallsBack() {
        let parts = ExecutionEnvironment.mergedPath(inherited: nil).split(separator: ":").map(String.init)
        #expect(parts.contains("/usr/bin"))
        #expect(parts.contains("/bin"))
    }

    @Test("任务工作目录：显式优先、空串回落 $HOME、波浪号展开")
    func workingDirectoryResolution() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var task = ScheduledTask.make(name: "t", command: "true")
        task.workingDirectory = nil
        #expect(ExecutionEnvironment.workingDirectory(for: task) == home)

        task.workingDirectory = "   "
        #expect(ExecutionEnvironment.workingDirectory(for: task) == home)

        task.workingDirectory = "~/Projects"
        #expect(ExecutionEnvironment.workingDirectory(for: task) == home + "/Projects")
    }

    @Test("任务级环境变量叠加在注入环境之上")
    func taskEnvironmentOverrides() {
        var task = ScheduledTask.make(name: "t", command: "true")
        task.environment = ["MY_FLAG": "1"]
        let environment = ExecutionEnvironment.make(task: task)
        #expect(environment["MY_FLAG"] == "1")
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}

@Suite("命令调度 · 退出状态解码")
struct ProcessStatusTests {
    @Test("正常退出码按 Darwin 位布局解码")
    func decodesExitCodes() {
        // WIFEXITED：低 7 位为 0，退出码在高 8 位。
        #expect(ProcessRunner.exitCode(fromWaitStatus: 0 << 8) == 0)
        #expect(ProcessRunner.exitCode(fromWaitStatus: 1 << 8) == 1)
        #expect(ProcessRunner.exitCode(fromWaitStatus: 127 << 8) == 127)
    }

    @Test("信号终止按 128 + 信号号表达（与 shell 惯例一致）")
    func decodesSignals() {
        #expect(ProcessRunner.exitCode(fromWaitStatus: 9) == 137)
        #expect(ProcessRunner.exitCode(fromWaitStatus: 15) == 143)
    }

    @Test("outcome 到记录状态的映射：被中止不是失败")
    func outcomeMapsToStatus() {
        #expect(RunOutcome.exited(code: 0).status == .succeeded)
        #expect(RunOutcome.exited(code: 1).status == .failed)
        #expect(RunOutcome.timedOut.status == .timedOut)
        #expect(RunOutcome.aborted.status == .aborted)
        #expect(RunOutcome.aborted.status.isTrouble == false)
        #expect(RunOutcome.timedOut.status.isTrouble == true)
    }
}

@Suite("命令调度 · 文案与 ANSI")
struct SchedulerTextTests {
    @Test("ANSI 转义序列在渲染前剥离，普通文本原样保留")
    func stripsANSISequences() {
        #expect(ANSIText.stripped("\u{1B}[0;32mok\u{1B}[0m") == "ok")
        #expect(ANSIText.stripped("plain") == "plain")
        #expect(ANSIText.stripped("a\u{1B}[Kb") == "ab")
        #expect(ANSIText.stripped("bell\u{07}") == "bell\u{07}")
    }

    @Test("时长分档：秒 / 分秒 / 时分（不测文案——单测进程拿不到插件 bundle 的 strings）")
    func bucketsDuration() {
        #expect(RunText.durationBucket(nil) == .none)
        #expect(RunText.durationBucket(-1) == .none)
        #expect(RunText.durationBucket(45) == .seconds(45))
        // 59.6 秒先四舍五入成 60 再分档，于是正确切到分档而不是显示 "60s"。
        #expect(RunText.durationBucket(59.6) == .minutes(minutes: 1, seconds: 0))
        #expect(RunText.durationBucket(60) == .minutes(minutes: 1, seconds: 0))
        #expect(RunText.durationBucket(125) == .minutes(minutes: 2, seconds: 5))
        #expect(RunText.durationBucket(3600) == .hours(hours: 1, minutes: 0))
        #expect(RunText.durationBucket(3 * 3600 + 20 * 60 + 59) == .hours(hours: 3, minutes: 20))
    }

    @Test("环境变量文本互转：忽略空行与注释，允许值里带等号")
    func environmentTextRoundTrip() {
        let decoded = TaskFormView.decodeEnvironment("""
        # comment

        FOO=bar
        URL=https://example.com?a=1
        """)
        #expect(decoded == ["FOO": "bar", "URL": "https://example.com?a=1"])
        let encoded = TaskFormView.encodeEnvironment(["B": "2", "A": "1"])
        #expect(encoded == "A=1\nB=2", "编码必须排序，否则每次保存都会抖动 diff")
    }
}

@Suite("命令调度 · 错过留痕")
struct SkipLogTests {
    @Test("近 24 小时的跳过与错过分开计数，窗口外的不算")
    func countsWithinWindow() {
        let now = Date()
        var log = SkipLog()
        log.record(.running, at: now.addingTimeInterval(-60))
        log.record(.running, at: now.addingTimeInterval(-3600))
        log.record(.offline, at: now.addingTimeInterval(-7200))
        log.record(.offline, at: now.addingTimeInterval(-25 * 3600))
        let counts = log.counts(withinHours: 24, now: now)
        #expect(counts.skipped == 2)
        #expect(counts.missed == 1)
    }

    @Test("明细条数有硬上限，超出从旧端丢弃")
    func trimsOldEntries() {
        var log = SkipLog()
        let now = Date()
        for index in 0..<(SkipLog.maxEntries + 50) {
            log.record(.running, at: now.addingTimeInterval(TimeInterval(-index)))
        }
        #expect(log.entries.count == SkipLog.maxEntries)
    }
}

@Suite("命令调度 · 执行器（真跑进程）", .serialized)
struct ProcessRunnerTests {
    private func makeSink() throws -> (RunOutputSink, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandSchedulerExec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("out.log")
        return (try #require(RunOutputSink(url: url)), directory)
    }

    private func makeTask(_ command: String) -> ScheduledTask {
        ScheduledTask.make(name: "t", command: command)
    }

    @Test("退出码被如实带回，stdout 与 stderr 合并落盘")
    func capturesExitCodeAndOutput() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = ProcessRunner.run(
            task: makeTask("echo hello-from-task; echo oops 1>&2; exit 3"),
            sink: sink,
            cancellation: ProcessCancellation()
        )
        let written = sink.finish()
        #expect(outcome == .exited(code: 3))
        #expect(outcome.status == .failed)
        let text = String(decoding: try Data(contentsOf: sink.url), as: UTF8.self)
        #expect(text.contains("hello-from-task"))
        #expect(text.contains("oops"), "stderr 必须与 stdout 合并（任务作者看的是同一条日志）")
        #expect(written.bytes > 0)
    }

    @Test("工作目录与任务级环境变量对子进程真实生效")
    func appliesWorkingDirectoryAndEnvironment() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = makeTask("pwd; printf 'FLAG=%s\\n' \"$SCHEDULER_TEST_FLAG\"")
        task.workingDirectory = directory.path
        task.environment = ["SCHEDULER_TEST_FLAG": "on"]
        _ = ProcessRunner.run(task: task, sink: sink, cancellation: ProcessCancellation())
        _ = sink.finish()
        let text = String(decoding: try Data(contentsOf: sink.url), as: UTF8.self)
        #expect(text.contains(directory.path))
        #expect(text.contains("FLAG=on"))
    }

    @Test("注入的 PATH 让子进程能找到 homebrew 目录（GUI 启动不再丢 PATH）")
    func injectedPathReachesChild() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = ProcessRunner.run(
            task: makeTask("echo \"$PATH\""),
            sink: sink,
            cancellation: ProcessCancellation()
        )
        _ = sink.finish()
        let text = String(decoding: try Data(contentsOf: sink.url), as: UTF8.self)
        #expect(text.contains("/opt/homebrew/bin"))
        #expect(text.contains("/usr/bin"))
    }

    @Test("守卫超时杀掉整个进程组：后代不能在 shell 死后继续跑")
    func timeoutKillsProcessGroup() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 判据刻意不查 pid 存活：`kill(pid, 0)` 对**僵尸**同样返回 0，而僵尸何时
        // 被回收是时序相关的（父进程先死 → 重parent 给 launchd），拿它断言会假失败。
        // 改成行为判据——后代进程若活下来，会在 2 秒后写出这个文件。
        let marker = directory.appendingPathComponent("survived.txt")
        var task = makeTask("( sleep 2; echo survived > '\(marker.path)' ) & wait")
        task.timeoutSeconds = 1

        let started = Date()
        let outcome = ProcessRunner.run(
            task: task,
            sink: sink,
            cancellation: ProcessCancellation()
        )
        let elapsed = Date().timeIntervalSince(started)
        _ = sink.finish()

        #expect(outcome == .timedOut)
        #expect(outcome.status.isTrouble, "超时必须被计为「出问题了」")
        #expect(elapsed < 8, "必须在守卫超时后很快收敛，实测 \(elapsed) 秒")

        // 留足"如果后代还活着就会写出文件"的时间。
        Thread.sleep(forTimeInterval: 2.5)
        #expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "后代进程活过了进程组 SIGTERM——它仍在继续执行"
        )
    }

    @Test("取消（宿主退出 / 插件禁用）记为中止，不是失败")
    func cancellationReportsAborted() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancellation = ProcessCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            cancellation.cancel(.abort)
        }
        let outcome = ProcessRunner.run(
            task: makeTask("sleep 20"),
            sink: sink,
            cancellation: cancellation
        )
        _ = sink.finish()
        #expect(outcome == .aborted)
        #expect(outcome.status == .aborted)
        #expect(outcome.status.isTrouble == false, "被自己关掉不是失败")
    }

    @Test("工作目录不存在时如实报起不来，不静默成功")
    func reportsSpawnFailureForMissingDirectory() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = makeTask("echo never")
        task.workingDirectory = "/definitely/not/here-\(UUID().uuidString)"
        let outcome = ProcessRunner.run(task: task, sink: sink, cancellation: ProcessCancellation())
        _ = sink.finish()
        guard case .spawnFailed = outcome else {
            Issue.record("期望 spawnFailed，实际 \(outcome)")
            return
        }
        #expect(outcome.status == .failed)
    }

    @Test("输出超过文件硬上限时置截断标记，文件不会无限增长")
    func truncatesHugeOutput() throws {
        let (sink, directory) = try makeSink()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 直连 sink 写超限数据（不经子进程，避免测试产出几百 MB）。
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        for _ in 0..<(RunOutputSink.fileLimit / (64 * 1024) + 4) {
            sink.append(chunk)
        }
        let written = sink.finish()
        #expect(written.truncated)
        #expect(written.bytes <= RunOutputSink.fileLimit)
    }
}

@Suite("命令调度 · 块声明与浮窗尺寸门禁")
@MainActor
struct CommandSchedulerBlockTests {
    /// 本插件的抽屉块声明必须满足两件事：探针几何合法（打包期门禁的判据），
    /// 以及决策 9 的「卡片 ⊆ 块矩形」不变量在最小尺寸下仍然成立。
    ///
    /// 注意：仓库里 `BlockMinSizeVerificationTests` 这个名字被 `build.sh
    /// verify-sizes` 引用，但测试源码中**不存在**该套件——全仓范围的探针门禁
    /// 目前是空转的。这里只锁本插件自己的块，不去替全仓重建门禁。
    private func drawerBlock() throws -> NotchBlock {
        let blocks = CommandSchedulerPlugin.blocks.filter { $0.kind == .drawer }
        #expect(blocks.count == 1, "本插件只提供一个抽屉块")
        return try #require(blocks.first)
    }

    @Test("块声明合法：三档齐全、逐轴 min ≤ rec ≤ max、不低于全局下限")
    func blockDeclarationIsValid() throws {
        let block = try drawerBlock()
        #expect(block.validationError == nil, "\(block.id)：\(block.validationError ?? "")")
        #expect(block.placement == .newPageWhenOccupied, "大组件不该塞进别人页缝里")
        #expect(block.symbolName?.isEmpty == false)
    }

    @Test("探针在 minSize 下不越界、不互叠")
    func probesPassGeometryGate() throws {
        let block = try drawerBlock()
        let minSize = try #require(block.minSize)
        let factory = try #require(block.probes, "官方抽屉块必须声明 probes")
        let probes = factory(BlockLayoutInfo(
            region: .drawer,
            placementID: "gate-test",
            frame: CGRect(origin: .zero, size: minSize.size)
        ))
        #expect(!probes.isEmpty)
        let violations = BlockSizeVerifier.violations(probes: probes, contentSize: minSize.size)
        #expect(violations.isEmpty, "\(block.id) 探针违规：\(violations)")
    }

    @Test("minSize 装得下工具行 + 声明的最少任务行数")
    func minimumSizeFitsDeclaredRows() throws {
        let block = try drawerBlock()
        let minSize = try #require(block.minSize)
        let required = SchedulerMetrics.padding
            + SchedulerMetrics.toolbarHeight
            + SchedulerMetrics.toolbarSpacing
            + SchedulerMetrics.listMinimumHeight
            + SchedulerMetrics.padding
        #expect(
            minSize.height >= required,
            "minSize \(minSize.height) 低于「工具行 + \(SchedulerMetrics.visibleRowsAtMinimum) 行任务」所需 \(required)"
        )
    }

    @Test("浮窗尺寸约束在 minSize 下成立：卡片 = 块 − cardInset 不会触到兜底下限")
    func cardFitsInsideBlockAtMinimumSize() throws {
        let block = try drawerBlock()
        let minSize = try #require(block.minSize)
        // 下限兜底一旦生效，"卡片 ⊆ 块"就破了 → 卡片会伸出块、鼠标移不过去
        // （决策 9 的停留区约束）。所以最小块也必须撑得住下限。
        #expect(
            minSize.width - BlockPopover.cardInset >= 320,
            "minSize 宽度过小：卡片会被兜底下限撑出块矩形"
        )
        #expect(
            minSize.height - BlockPopover.cardInset >= 200,
            "minSize 高度过小：卡片会被兜底下限撑出块矩形"
        )
        // 浮窗窗口 = 卡片 + 留白，应当恰好与块矩形重合。
        #expect(BlockPopover.cardInset == 48)
    }
}

@Suite("命令调度 · 索引与输出存储")
@MainActor
struct RunStoreTests {
    private func makeStore() throws -> (RunStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandSchedulerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stateStore = StateStore(rootDirectory: root)
        return (RunStore(stateStore: stateStore), root)
    }

    private func finishedRun(taskID: String, at date: Date) -> TaskRun {
        let task = ScheduledTask.make(name: "t", command: "true")
        return TaskRun(
            id: UUID().uuidString,
            taskID: taskID,
            trigger: .scheduled,
            startedAt: date,
            endedAt: date.addingTimeInterval(1),
            status: .succeeded,
            exitCode: 0,
            snapshot: CommandSnapshot(task: task)
        )
    }

    @Test("任务表 Codable 往返")
    func taskRoundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var task = ScheduledTask.make(name: "备份", command: "rsync -a ~/a ~/b")
        task.environment = ["K": "V"]
        task.timeoutSeconds = 120
        store.saveTasks([task])
        #expect(store.loadTasks() == [task])
    }

    @Test("每任务 run 条数裁剪到上限，且运行中的记录不被裁掉")
    func trimsRunsPerTask() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID().uuidString
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(RunStore.runsPerTaskLimit + 5) {
            store.upsert(finishedRun(taskID: taskID, at: base.addingTimeInterval(TimeInterval(index))))
        }
        // 再插一条运行中的（最新）：它必须活下来。
        let running = TaskRun(
            id: UUID().uuidString,
            taskID: taskID,
            trigger: .manual,
            startedAt: base.addingTimeInterval(10_000),
            status: .running,
            snapshot: CommandSnapshot(task: ScheduledTask.make(name: "t", command: "sleep 1"))
        )
        store.upsert(running)
        let runs = store.loadRuns(taskID: taskID)
        #expect(runs.filter { $0.status == .running }.count == 1)
        #expect(runs.filter { $0.status.isFinished }.count == RunStore.runsPerTaskLimit)
    }

    @Test("读取投影：超过头尾窗口时给头部 + 省略标记 + 尾部")
    func projectsLongOutput() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID().uuidString
        var run = finishedRun(taskID: taskID, at: Date())
        let sink = try #require(store.makeSink(forRunID: run.id))

        let head = String(repeating: "H", count: RunStore.readWindow)
        let middle = String(repeating: "M", count: 4096)
        let tail = String(repeating: "T", count: RunStore.readWindow)
        sink.append(Data((head + middle + tail).utf8))
        let written = sink.finish()
        run.truncated = written.truncated

        let output = store.runOutput(for: run)
        #expect(output.text.hasPrefix(String(repeating: "H", count: 64)))
        #expect(output.text.contains("omitted"))
        #expect(output.text.hasSuffix(String(repeating: "T", count: 64)))
        #expect(output.truncated)
        #expect(output.missing == false)
    }

    @Test("运行中读取文件尾（watch 语义），不看头部")
    func liveReadsTail() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID().uuidString
        let run = finishedRun(taskID: taskID, at: Date())
        let sink = try #require(store.makeSink(forRunID: run.id))
        let payload = String(repeating: "A", count: 128 * 1024) + "LAST-LINE"
        sink.append(Data(payload.utf8))
        _ = sink.finish()

        var live = run
        live.status = .running
        let output = store.runOutput(for: live, live: true)
        #expect(output.text.hasSuffix("LAST-LINE"))
    }

    @Test("宿主启动时把遗留的 running 收敛为 interrupted")
    func reconcilesInterruptedRuns() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = ScheduledTask.make(name: "t", command: "sleep 999")
        store.saveTasks([task])
        let zombie = TaskRun(
            id: UUID().uuidString,
            taskID: task.id,
            trigger: .scheduled,
            startedAt: Date(),
            status: .running,
            snapshot: CommandSnapshot(task: task)
        )
        store.upsert(zombie)
        #expect(store.reconcileInterruptedRuns(tasks: [task]) == 1)
        #expect(store.loadRuns(taskID: task.id).first?.status == .interrupted)
        // 再跑一次不该重复计数（幂等）。
        #expect(store.reconcileInterruptedRuns(tasks: [task]) == 0)
    }

    @Test("删除任务会连它的 run 索引与错过留痕一起清掉")
    func removesEverythingForTask() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID().uuidString
        store.upsert(finishedRun(taskID: taskID, at: Date()))
        store.recordSkip(taskID: taskID, reason: .running)
        store.removeAll(taskID: taskID)
        #expect(store.loadRuns(taskID: taskID).isEmpty)
        #expect(store.skipLog(taskID: taskID).entries.isEmpty)
    }
}
