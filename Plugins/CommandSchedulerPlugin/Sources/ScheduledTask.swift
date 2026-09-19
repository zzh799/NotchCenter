import Foundation

// MARK: - 任务定义

/// 一条用户定义的定时任务。
///
/// 持久化为插件级 `StateStore` 的单键 JSON（决策：任务表是插件级共享数据，
/// 不按 placement 复制——`docs/agents/插件开发约定.md`「共享数据仍放插件级
/// store」）。因此同一块摆几处都读同一份任务表，不存在"两份调度在跑"。
struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    /// 交给 `/bin/zsh -c` 的整行命令（决策 3：非登录 shell + 显式注入 PATH）。
    var command: String
    /// 工作目录；nil = `$HOME`。保存时**不校验存在性**——定时任务跑在未来，
    /// 那时外挂卷可能才挂载好，现在拦下来是错的。
    var workingDirectory: String?
    /// 任务级环境变量覆盖（叠加在注入的 PATH 之上）。
    var environment: [String: String]
    var rule: ScheduleRule
    /// 守卫超时（秒）；nil = 用全局默认，0 = 关闭超时。
    var timeoutSeconds: Int?
    var isEnabled: Bool
    var createdAt: Date

    /// 新建任务的初值。
    static func make(
        name: String,
        command: String,
        rule: ScheduleRule = .dailyAt(hour: 9, minute: 0)
    ) -> ScheduledTask {
        ScheduledTask(
            id: UUID().uuidString,
            name: name,
            command: command,
            workingDirectory: nil,
            environment: [:],
            rule: rule,
            timeoutSeconds: nil,
            isEnabled: true,
            createdAt: Date()
        )
    }

    // 逐字段 decodeIfPresent + 默认值（与 `PomodoroHistory` / `LayoutModel` 同款
    // 约定）：合成的 `init(from:)` 不会在键缺失时回落到属性默认值，而任务表
    // 将来加字段时旧文件必须还能读——一次写对，省掉一次迁移。
    private enum CodingKeys: String, CodingKey {
        case id, name, command, workingDirectory, environment, rule
        case timeoutSeconds, isEnabled, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        rule = try container.decodeIfPresent(ScheduleRule.self, forKey: .rule) ?? .dailyAt(hour: 9, minute: 0)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    init(
        id: String,
        name: String,
        command: String,
        workingDirectory: String?,
        environment: [String: String],
        rule: ScheduleRule,
        timeoutSeconds: Int?,
        isEnabled: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.rule = rule
        self.timeoutSeconds = timeoutSeconds
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

// MARK: - 命令快照

/// 一次执行时**当时的**命令配置副本。
///
/// 任务定义会改；不存快照的话三个月后翻历史根本不知道当时跑的是什么。
/// 快照里存规则本身（而不是本地化后的摘要文案）——文案随语言变，历史不该变。
struct CommandSnapshot: Codable, Equatable, Sendable {
    var name: String
    var command: String
    var workingDirectory: String?
    var environment: [String: String]
    var rule: ScheduleRule

    init(task: ScheduledTask) {
        name = task.name
        command = task.command
        workingDirectory = task.workingDirectory
        environment = task.environment
        rule = task.rule
    }

    private enum CodingKeys: String, CodingKey {
        case name, command, workingDirectory, environment, rule
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        rule = try container.decodeIfPresent(ScheduleRule.self, forKey: .rule) ?? .dailyAt(hour: 9, minute: 0)
    }
}

// MARK: - 一次执行

/// 一次执行的记录（元数据）。完整输出另存 `runs/<runID>.log` 一文件
/// （决策：索引与输出分离——单键 JSON 每次追加要读全量再写全量，
/// 500 条 × 10KB 就是每次跑完命令重写 5MB）。
struct TaskRun: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        /// 正在跑。
        case running
        /// 退出码 0。
        case succeeded
        /// 退出码非 0。
        case failed
        /// 守卫超时被杀（先 SIGTERM 进程组，宽限后 SIGKILL）。
        case timedOut
        /// 宿主退出 / 插件被禁用时被杀。**不是**失败——被你自己关掉不是失败。
        case aborted
        /// 宿主启动时发现的遗留 `running`（宿主崩溃过）。否则历史里会堆着
        /// 永远"运行中"的僵尸记录。
        case interrupted

        /// 是否已经结束（非 `running`）。
        var isFinished: Bool { self != .running }

        /// 是否应当计为"出问题了"（任务行上点红点、摘要亮警示色）。
        var isTrouble: Bool {
            switch self {
            case .failed, .timedOut: return true
            case .running, .succeeded, .aborted, .interrupted: return false
            }
        }
    }

    /// 触发来源。
    enum Trigger: String, Codable, Sendable {
        case scheduled
        case manual
    }

    let id: String
    let taskID: String
    let trigger: Trigger
    let startedAt: Date
    var endedAt: Date?
    var status: Status
    var exitCode: Int32?
    /// 落盘输出的字节数（截断后）。
    var outputBytes: Int
    /// 是否发生过截断（超出头部 + 尾部窗口）。
    var truncated: Bool
    var snapshot: CommandSnapshot

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// 输出文件名（相对 `runs/` 目录）。
    var outputFileName: String { id + ".log" }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, trigger, startedAt, endedAt, status, exitCode
        case outputBytes, truncated, snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .scheduled
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .interrupted
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        outputBytes = try container.decodeIfPresent(Int.self, forKey: .outputBytes) ?? 0
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        snapshot = try container.decodeIfPresent(CommandSnapshot.self, forKey: .snapshot)
            ?? CommandSnapshot(task: ScheduledTask.make(name: "", command: ""))
    }

    init(
        id: String,
        taskID: String,
        trigger: Trigger,
        startedAt: Date,
        endedAt: Date? = nil,
        status: Status,
        exitCode: Int32? = nil,
        outputBytes: Int = 0,
        truncated: Bool = false,
        snapshot: CommandSnapshot
    ) {
        self.id = id
        self.taskID = taskID
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.exitCode = exitCode
        self.outputBytes = outputBytes
        self.truncated = truncated
        self.snapshot = snapshot
    }
}

// MARK: - 错过留痕（决策 4：聚合，不塞流水）

/// 「本该跑却没跑」的滚动记录：任务忙导致本次跳过、宿主未运行/机器睡眠导致
/// 时刻流失。
///
/// **不往执行流水里写条目**：流水是给你看"命令干了什么"的，把"没干什么"塞进去
/// 等于用一个会自我稀释的列表承载两类信息（每 1 分钟调度 + 机器常睡 =
/// 历史被无输出的空条目灌满，真正重要的失败被淹掉）。这里只留时间戳 + 原因，
/// 由任务卡滚成一行「近 24h 跳过 N 次 · 错过 M 次」，点开看最近若干次。
struct SkipLog: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// 上一次还在跑，本次到点被跳过（与「不补跑」同源：排队等它结束
        /// 再补一次，本质就是补跑）。
        case running
        /// 宿主没运行或机器在睡，时刻流失。唤醒不补跑，但留痕。
        case offline
    }

    struct Entry: Codable, Equatable, Sendable {
        let at: Date
        let reason: Reason
    }

    /// 明细条数硬上限。聚合视图只需要"最近若干次"，超出的从旧端丢弃。
    static let maxEntries = 200

    var entries: [Entry] = []

    private enum CodingKeys: String, CodingKey { case entries }

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    mutating func record(_ reason: Reason, at date: Date) {
        entries.append(Entry(at: date, reason: reason))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// 近 `hours` 小时内的计数（跳过 / 错过分开）。
    func counts(withinHours hours: Int, now: Date, calendar: Calendar = .current) -> (skipped: Int, missed: Int) {
        guard let since = calendar.date(byAdding: .hour, value: -hours, to: now) else { return (0, 0) }
        var skipped = 0
        var missed = 0
        for entry in entries where entry.at >= since {
            switch entry.reason {
            case .running: skipped += 1
            case .offline: missed += 1
            }
        }
        return (skipped, missed)
    }

    /// 最近若干次明细（倒序），供聚合行点开查看。
    func recent(limit: Int) -> [Entry] {
        Array(entries.suffix(limit).reversed())
    }
}

// MARK: - 输出读取结果

/// 一次执行的输出（读取时按需解码）。
struct RunOutput: Equatable, Sendable {
    let text: String
    /// 输出是否被截断（文件里带省略标记）。
    let truncated: Bool
    /// 文件不存在（已被保留策略清掉）时为 true。
    let missing: Bool

    static let empty = RunOutput(text: "", truncated: false, missing: false)
}
