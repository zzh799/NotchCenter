import AppKit

// MARK: - 抽屉滑动切页判据

/// "这一下算不算向左/向右滑、滑到哪了、该不该落位"的唯一判据
/// （纯函数 + 值类型累加器，无视图与窗口依赖）。两条输入通路各传自己的横向
/// 平移量进来：触控板轻扫逐事件喂 `DrawerPageScrollTracker`，网格背景拖拽
/// 直接喂 `DragGesture` 的 translation。平移量即带符号的**条带位移**
/// （原点 = 会话起点页）：反手不重起累加、位移连续回退到原点，越过原点
/// （死区外）才换向（`reversedSide`）。
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

    /// 手势中途反手（条带位移越过原点）的换向死区（pt）：|位移| 越过它才把
    /// 条带换绑到另一侧邻居。原点附近 ±几点的手指抖动必须吸收在死区内——
    /// 换绑那一帧另一侧目标页层以 O(deadBand) 宽的边缘一步进入视口，死区越小
    /// 这笔可见边缘越小。
    static let flipDeadBand: CGFloat = 8

    /// 无边界设备（`phase` 恒空）就地提交后的冷却（秒）：它们等不到 `.ended`、
    /// 没有手势边界，冷却是唯一的防连翻手段。有手势边界的通路（触控板）**不
    /// 走冷却**——惯性尾巴由调用方按 `momentumPhase` 过滤、`.began` 重置防串
    /// 手势，提交后再压冷却纯属输入锁定期。
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

    /// 松手瞬间的意图方向 = 条带位移的符号（向左翻 = 负位移 → `.right`，
    /// 向右翻 = 正位移 → `.left`，位移 0 = 无意图）。它是提交门的半边：
    /// 意图方向必须与**会话当前条带方向**一致才落位——反手滑回原点后的
    /// 松手天然不匹配，只弹回、不落位。
    static func side(forOffset offset: CGFloat) -> DrawerPageSide? {
        offset < 0 ? .right : (offset > 0 ? .left : nil)
    }

    /// 条带中途反手的换向判据（触控板累加器与控制器会话换绑共用同一份）：
    /// 当前条带方向 + 带符号条带位移 → 应换到的方向；死区（|offset| ≤
    /// deadBand）内不换。`.right` 条带由负位移揭示，位移越过 `+deadBand`
    /// 说明条带已被拖回原点并继续向另一侧推进 → 换到 `.left`；反之亦然。
    static func reversedSide(
        current: DrawerPageSide,
        offset: CGFloat,
        deadBand: CGFloat = flipDeadBand
    ) -> DrawerPageSide? {
        switch current {
        case .right: return offset > deadBand ? .left : nil
        case .left: return offset < -deadBand ? .right : nil
        }
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

    /// 页带留白 = 抽屉内容边距的两倍（“两倍边框距离”）：目标页与源页面在
    /// 滑动中不得贴死，中间要露出一条背景带才看得出是两页。倍数的唯一出处，
    /// 调用点传当前指标快照的 `contentPadding`。
    static func bandSpacing(contentPadding: CGFloat) -> CGFloat {
        contentPadding * 2
    }

    /// 目标页层相对原点页层的**带符号**间距：目标页在右让出“源页宽 + 留白”，
    /// 在左让出“目标页宽 + 留白”——两层之间恒隔一条 `spacing` 宽的背景带
    /// （相邻缘各按自己的页宽对齐，再各让出一份留白）。
    ///
    /// 会话期一次性算出并冻结：落位动画途中当前页尺寸会换成目标页尺寸，
    /// 位移若再现算，两层会在滑动途中错开一条缝。
    static func gap(
        side: DrawerPageSide,
        gridWidth: CGFloat,
        targetWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        side == .right ? gridWidth + spacing : -(targetWidth + spacing)
    }

    /// 落位终点位移：两层构成刚性页带（目标页层位置 = 位移 + gap，层间距恒等于
    /// 留白），走到 `-gap` 时目标页层正好落在 x=0 完全覆盖可视区（源页连留白
    /// 一起滑出视口）——换页就在这一帧之后发生。
    static func arrivalOffset(gap: CGFloat) -> CGFloat { -gap }

    /// 条带是否已推过目标页覆盖点（沿推的方向）：覆盖点 = `arrivalOffset`，
    /// 右带（gap > 0）位移到达 `-gap`、左带（gap < 0）位移到达 `-gap` 即越点。
    /// 连页判据：越点且更远侧有邻居 → 原地前进换绑（见 `advanceCarry`）；
    /// 无邻居 → 硬停在覆盖点（与首/末页"不得滑过起点"同一语义）。
    static func coverCrossed(offset: CGFloat, gap: CGFloat) -> Bool {
        gap > 0 ? offset <= -gap : offset >= -gap
    }

    /// 覆盖点前进的位移衔接：新带原点 = 旧目标页。像素连续要求新带位移 = 旧
    /// 位移 + 旧 gap——旧目标页层位置（offset + gap）在前进前后必须同帧重合
    /// （与落位交接同一条"像素重合"原理）。推出的越点余量自然带进新带坐标，
    /// 手指不丢行程。
    static func advanceCarry(offset: CGFloat, gap: CGFloat) -> CGFloat { offset + gap }
}

/// 触控板轻扫的一帧输出：滑动方向、实时位移，以及本帧是否就该落位。
struct DrawerScrollFrame {
    let side: DrawerPageSide
    let offset: CGFloat
    /// 无手势边界的输入设备（`phase` 恒空，等不到 `.ended`）：越线即提交。
    let commits: Bool
}

/// 触控板横向轻扫累加器：一次轻扫由一串小增量事件组成，必须累加后再判方向，
/// 并把累加量换算成实时位移（目标页跟手滑入）。一次手势只许翻一页——方向
/// 在条带位移越过原点（死区外）时可改向（反手立刻反悔），死区内恒定；
/// 有手势边界时提交交给 `finish`，惯性尾巴由调用方按 `momentumPhase` 过滤、
/// 压根不进这里。时钟由调用方注入（`NSEvent.timestamp`）以便单测逐事件重放。
struct DrawerPageScrollTracker {
    private(set) var accumulatedX: CGFloat = 0
    private(set) var accumulatedY: CGFloat = 0
    /// 本次手势已锁定的滑动方向（未达门槛为 nil；条带位移越过原点死区后更新）。
    private(set) var lockedSide: DrawerPageSide?
    /// 输入重锚（屏幕累计量）：覆盖点前进（连页）后钉在当前累计量上，位移、
    /// 反手换向与提交判据都改对**锚之后的增量**计算——已消费的整页行程不再
    /// 参与新带判据。新手势（`.began`）与 `reset` 归零。
    private(set) var anchor: CGFloat = 0

    /// 手势样本（时间, 累计横向位移）：`finish` 时估计即时速度用
    /// （位移判据之外的速度判据）。`.began` 时清零。
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

        // 累加量就是带符号的**条带位移**，手势期间连续推进、反手不清零：
        // 回退阶段抽屉随累加量平滑收回到原点，越过原点（死区外）才换向。
        accumulatedX += deltaX
        accumulatedY += deltaY
        recordSample(at: now)
        let travel = accumulatedX - anchor

        if let lockedSide {
            // 手势进行中反手：越过原点死区立即换向（立刻反悔），原点附近
            // 抖动（|位移| ≤ deadBand）保持原方向。
            if let flipped = DrawerPageSwipe.reversedSide(
                current: lockedSide,
                offset: travel,
                deadBand: DrawerPageSwipe.flipDeadBand
            ) {
                self.lockedSide = flipped
            }
        } else {
            lockedSide = DrawerPageSwipe.side(
                for: CGSize(width: travel, height: accumulatedY),
                threshold: DrawerPageSwipe.scrollThreshold
            )
        }
        guard let lockedSide else { return nil }

        let offset = DrawerPageSwipe.offset(translation: travel, limit: limit)
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
        let offset = DrawerPageSwipe.offset(translation: accumulatedX - anchor, limit: limit)
        let side = lockedSide
        let velocity = DrawerPageSwipe.velocityEstimate(from: samples, at: now)
        reset()
        guard let side else { return nil }
        // 冷却只由无边界设备的就地提交置位（见下）：有手势边界的轻扫以
        // `.began` 重置防串手势，惯性尾巴由调用方按 `momentumPhase` 过滤，
        // 提交后再压 0.35s 冷却纯属输入锁定期（连页手感的天敌）。
        guard DrawerPageSwipe.shouldCommit(offset: offset, limit: limit, velocity: velocity) else {
            return nil
        }
        return side
    }

    /// 覆盖点前进（连页）后调用：把输入锚钉在当前累计量上——之后的位移、
    /// 反手换向与提交判据都只看锚之后的增量（已消费的整页行程不重复计数）。
    /// 速度样本窗口同步丢弃：跨带样本混着两段行程的差商，估出的速度没有
    /// 物理意义（真机：锚前猛扫的残速会把锚后的轻推判成第二次提交）。
    mutating func reanchor() {
        anchor = accumulatedX
        samples.removeAll()
    }

    /// 本次手势的**锚后净增量**（屏幕位）：松手意图的方向判据来源——带位移
    /// 在接管（grab）/前进后会偏离手势自身方向（回拉的带仍深在目标侧），
    /// 只有锚后增量忠实反映"这一把手指往哪边推"。
    var netTravel: CGFloat { accumulatedX - anchor }

    /// 丢弃已累加的增量与方向（落点不该切页时调用），不动冷却。
    mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        lockedSide = nil
        anchor = 0
        samples.removeAll()
    }

    /// 记录本帧样本：只保留最近一段（以时间为准），防长手势内存无谓增长。
    private mutating func recordSample(at now: TimeInterval) {
        samples.append((time: now, x: accumulatedX))
        while samples.count > 16 || (samples.count > 2 && now - samples.first!.time > DrawerPageSwipe.velocityWindow * 4) {
            samples.removeFirst()
        }
    }

    /// 冷却：无边界设备就地提交后 `cooldown` 内不再认新手势（它们唯一的
    /// 防连翻手段）。有手势边界的提交不置位冷却（见 `finish` 注释）。
    /// 控制器的接管门也读它：无边界输入只在冷却外才允许接管在飞会话。
    func isCoolingDown(at now: TimeInterval, cooldown: TimeInterval = DrawerPageSwipe.cooldown) -> Bool {
        guard let lastCommitTime else { return false }
        return now - lastCommitTime < cooldown
    }
}
