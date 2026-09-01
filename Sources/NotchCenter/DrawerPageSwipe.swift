import AppKit

// MARK: - 抽屉滑动切页判据

/// "这一下算不算向左/向右滑、滑到哪了、该不该落位"的唯一判据
/// （纯函数 + 值类型累加器，无视图与窗口依赖）。两条输入通路各传自己的横向
/// 平移量进来：触控板轻扫逐事件喂 `DrawerPageScrollTracker`，网格背景拖拽
/// 直接喂 `DragGesture` 的 translation。
///
/// 判据必须只有一份：门槛与横纵压比一旦在视图里各写一遍，手感会在两通路之间
/// 漂移，且无法在单测里重放。
enum DrawerPageSwipe {
    /// 触控板横向**累加**到该点数才认定方向：40pt ≈ 最窄格宽的 1/4，远高于手指
    /// 贴玻璃的抖动，又远低于一次有意轻扫（几百点）。
    static let scrollThreshold: CGFloat = 40

    /// 拖拽认定方向所需的最小平移量，同时是背景手势的 `minimumDistance`。
    /// 必须大于 `BlockTapClassifier.movementTolerance`(10pt)，否则块上一次
    /// 杂散的按压位移会被读成滑动。
    static let dragMinDistance: CGFloat = 14

    /// 横向必须压过纵向的倍数（对**累加后**的总量判定：逐事件比值在触控板上就是
    /// 噪声，斜着划也会被误判成纯横向）。
    static let dominanceRatio: CGFloat = 1.5

    /// 一次切页后的冷却（秒）：与调用方的 `momentumPhase` 过滤配合，挡住一次长扫连翻数页。
    static let cooldown: TimeInterval = 0.35

    static let commitRatio: CGFloat = 0.28

    /// 落位门槛的绝对距离项，与 `commitRatio`（按页宽）取较小者：窄页面按比例
    /// 更容易达到门槛，宽页面（1300pt+）按比例要拖三四百点、手指划不到，
    /// 于是退化成 90pt。
    static let commitDistance: CGFloat = 90

    /// 松手瞬间的速度门槛（pt/s）：位移没到落位门槛但速度够猛也算落位
    /// （“较强速度的滑动能触发滑到目的页，而不只看滑动距离”）。刻意慢推
    /// （< 800pt/s）不触发；速度必须与位移**同向**——往回甩的加速度不算。
    static let commitVelocity: CGFloat = 800

    /// 越界橡皮筋阻尼：拖过整页宽度后每移动 1pt 只推进 0.35pt。
    static let rubberBand: CGFloat = 0.35

    /// 速度估计的采样窗口（秒）：只取手势最近这一小段做差商，整段的平均
    /// 速度会把“先慢后猛的一甩”稀释掉。
    static let velocityWindow: TimeInterval = 0.12

    /// 落位门槛距离（比例与绝对距离取较严者）。
    static func commitThreshold(limit: CGFloat) -> CGFloat {
        min(limit * commitRatio, commitDistance)
    }

    /// 横向平移量 → 目标页面侧；未达门槛或横向没压过纵向时为 nil。
    ///
    /// 方向约定是"内容跟手"：手指向左移（`width < 0`）揭示**右侧**的页面。真机若
    /// 发现触控板方向相反，只需在调用处翻 `scrollingDeltaX` 的符号，判据本身不动。
    static func side(for translation: CGSize, threshold: CGFloat) -> DrawerPageSide? {
        guard abs(translation.width) >= threshold else { return nil }
        guard abs(translation.width) >= abs(translation.height) * dominanceRatio else { return nil }
        return translation.width < 0 ? .right : .left
    }

    /// 横向平移量 → 面板实际位移（同号）：`limit` 内 1:1，越界按 `rubberBand` 阻尼。
    static func offset(translation: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let magnitude = abs(translation)
        let clamped = magnitude <= limit
            ? magnitude
            : limit + (magnitude - limit) * rubberBand
        return translation < 0 ? -clamped : clamped
    }

    static func shouldCommit(offset: CGFloat, limit: CGFloat) -> Bool {
        abs(offset) >= commitThreshold(limit: limit)
    }

    /// 松手定夺：位移门槛之外，另两条速度通路共用同一判据——
    /// - `velocity`：触控板通路的采样即时速度（`velocityEstimate` 估计）；
    /// - `predictedOffset`：拖拽通路的预测终点位移（`DragGesture.predictedEndTranslation`
    ///   折算了松手瞬间的速度）。
    /// 两条都要求与当前位移同向，且只作“加码”：没到位移门槛时它们能抬一手，
    /// 慢推或往回甩则保持原判。
    static func shouldCommit(
        offset: CGFloat,
        limit: CGFloat,
        velocity: CGFloat? = nil,
        predictedOffset: CGFloat? = nil
    ) -> Bool {
        let threshold = commitThreshold(limit: limit)
        if abs(offset) >= threshold { return true }
        if let velocity, velocity * offset > 0, abs(velocity) >= commitVelocity {
            return true
        }
        if let predictedOffset, predictedOffset * offset > 0, abs(predictedOffset) >= threshold {
            return true
        }
        return false
    }

    /// 滑动进度 p ∈ [0,1]：位移对“落位全程”（|gap|）的比例。
    /// 面板尺寸插值与胶囊高亮层都从这一份进度派生——跟手期它随手指线性
    /// 推进，落位/回弹期它随同一条 spring 收敛，往回滑 p 减小、一切同步回退。
    static func progress(offset: CGFloat, gap: CGFloat) -> CGFloat {
        let travel = abs(gap)
        guard travel > 0 else { return 0 }
        return min(max(abs(offset) / travel, 0), 1)
    }

    /// 面板尺寸在会话起止两端间的线性插值（进度与位移一致）。
    static func interpolatedSize(from start: CGSize, to target: CGSize, progress p: CGFloat) -> CGSize {
        CGSize(
            width: start.width + (target.width - start.width) * p,
            height: start.height + (target.height - start.height) * p
        )
    }

    /// 由一段 (时间, 累计横向位移) 样本估计即时速度（pt/s）：取最近
    /// `velocityWindow` 秒内的首尾样本做差商；样本不足两个时速度视为 0。
    /// 惯性尾巴由调用方按 `momentumPhase` 过滤、不进样本。
    static func velocityEstimate(
        from samples: [(time: TimeInterval, x: CGFloat)],
        at now: TimeInterval
    ) -> CGFloat {
        let recent = samples.filter { now - $0.time <= velocityWindow }
        guard recent.count >= 2 else { return 0 }
        let dt = recent.last!.time - recent.first!.time
        guard dt > 0.001 else { return 0 }
        return (recent.last!.x - recent.first!.x) / dt
    }

    /// 预览层相对网格层的**带符号**相邻间距：目标页在右贴当前页右缘，在左贴
    /// 当前页左缘（各按自己的页宽相邻）。
    ///
    /// 会话期一次性算出并冻结：落位动画途中当前页尺寸会换成目标页尺寸，
    /// 位移若再现算，两层会在滑动途中错开一条缝。
    static func gap(side: DrawerPageSide, gridWidth: CGFloat, targetWidth: CGFloat) -> CGFloat {
        side == .right ? gridWidth : -targetWidth
    }

    /// 落位终点位移：两层刚性相邻（预览层位置 = 位移 + gap），走到 `-gap` 时
    /// 预览层正好落在 x=0 完全覆盖可视区——换页就在这一帧之后发生。
    static func arrivalOffset(gap: CGFloat) -> CGFloat { -gap }
}

/// 触控板轻扫的一帧输出：滑动方向、实时位移，以及本帧是否就该落位。
struct DrawerScrollFrame {
    let side: DrawerPageSide
    let offset: CGFloat
    /// 无手势边界的输入设备（`phase` 恒空，等不到 `.ended`）：越线即提交。
    let commits: Bool
}

/// 触控板横向轻扫累加器：一次轻扫由一串小增量事件组成，必须累加后再判方向，
/// 并把累加量换算成实时位移（目标页跟手滑入）。一次手势只许翻一页——方向一旦
/// 锁定就不再改；有手势边界时提交交给 `finish`，惯性尾巴由调用方按
/// `momentumPhase` 过滤、压根不进这里。时钟由调用方注入（`NSEvent.timestamp`）
/// 以便单测逐事件重放。
struct DrawerPageScrollTracker {
    private(set) var accumulatedX: CGFloat = 0
    private(set) var accumulatedY: CGFloat = 0
    /// 本次手势已锁定的滑动方向（未达门槛为 nil）。
    private(set) var lockedSide: DrawerPageSide?

    /// 手势样本（时间, 累计横向位移）：`finish` 时估计即时速度用
    /// （位移判据之外的速度判据）。`.began` 与反向重起时清零。
    private var samples: [(time: TimeInterval, x: CGFloat)] = []

    private var lastCommitTime: TimeInterval?

    /// 喂入一个滚动事件的增量，返回本帧的方向与位移（方向未定/冷却中为 nil）。
    mutating func feed(
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        phase: NSEvent.Phase,
        at now: TimeInterval,
        limit: CGFloat,
        cooldown: TimeInterval = DrawerPageSwipe.cooldown
    ) -> DrawerScrollFrame? {
        if phase.contains(.began) {
            reset()
        }
        guard !isCoolingDown(at: now, cooldown: cooldown) else { return nil }

        // 方向反转：从反向的第一个事件起重新累加并解锁（往回划要能立刻反悔）。
        if accumulatedX * deltaX < 0 {
            reset()
        }
        accumulatedX += deltaX
        accumulatedY += deltaY
        recordSample(at: now)

        if lockedSide == nil {
            lockedSide = DrawerPageSwipe.side(
                for: CGSize(width: accumulatedX, height: accumulatedY),
                threshold: DrawerPageSwipe.scrollThreshold
            )
        }
        guard let lockedSide else { return nil }

        let offset = DrawerPageSwipe.offset(translation: accumulatedX, limit: limit)
        // 等不到 `.ended` 的设备只能就地提交；否则位移继续跟手，提交交给 finish。
        let commits = phase.isEmpty && DrawerPageSwipe.shouldCommit(offset: offset, limit: limit)
        if commits {
            lastCommitTime = now
            reset()
        }
        return DrawerScrollFrame(side: lockedSide, offset: offset, commits: commits)
    }

    /// 手势结束（`.ended` / `.cancelled`）：位移够阈值、或松手速度够猛则返回
    /// 落位方向，否则 nil（调用方负责弹回）。两种情况都会清理本手势。
    mutating func finish(
        at now: TimeInterval,
        limit: CGFloat,
        cooldown: TimeInterval = DrawerPageSwipe.cooldown
    ) -> DrawerPageSide? {
        let offset = DrawerPageSwipe.offset(translation: accumulatedX, limit: limit)
        let side = lockedSide
        let velocity = DrawerPageSwipe.velocityEstimate(from: samples, at: now)
        reset()
        guard let side else { return nil }
        guard DrawerPageSwipe.shouldCommit(offset: offset, limit: limit, velocity: velocity) else {
            return nil
        }
        lastCommitTime = now
        return side
    }

    /// 丢弃已累加的增量与方向（落点不该切页时调用），不动冷却。
    mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        lockedSide = nil
        samples.removeAll()
    }

    /// 记录本帧样本：只保留最近一段（以时间为准），防长手势内存无谓增长。
    private mutating func recordSample(at now: TimeInterval) {
        samples.append((time: now, x: accumulatedX))
        while samples.count > 16 || (samples.count > 2 && now - samples.first!.time > DrawerPageSwipe.velocityWindow * 4) {
            samples.removeFirst()
        }
    }

    /// 冷却：一次切页后 `cooldown` 内不再认新手势。`phase` 恒空的设备没有手势
    /// 边界可依据，冷却是它们唯一的防连翻手段（触控板还有 `.began` 重置）。
    private func isCoolingDown(at now: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard let lastCommitTime else { return false }
        return now - lastCommitTime < cooldown
    }
}
