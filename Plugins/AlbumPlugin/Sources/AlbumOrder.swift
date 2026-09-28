import Foundation

// MARK: - 轮播次序（纯逻辑，可注入随机源）

/// 轮播"下一张是哪一张"的全部逻辑。抽成纯函数是为了能钉住两条容易出错的语义：
/// 顺序播放的环绕、以及随机播放在两轮交界处不连播同一张。
enum AlbumOrder {
    /// 顺序播放的下一张（末尾回到开头）。
    static func nextSequential(after index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index + 1) % count
    }

    /// 顺序播放的上一张（开头回到末尾）。
    static func previousSequential(before index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index - 1 + count) % count
    }

    /// 洗出一整轮的次序。`previous` 是上一轮最后显示的那一张：新一轮的第一项要
    /// 避开它，否则两轮交界处会连播同一张，观感上像卡住了（只有一张时不适用）。
    static func shuffledQueue<Generator: RandomNumberGenerator>(
        count: Int,
        previous: Int?,
        using generator: inout Generator
    ) -> [Int] {
        guard count > 0 else { return [] }
        var order = Array(0..<count).shuffled(using: &generator)
        if count > 1, let previous, order[0] == previous {
            order.swapAt(0, 1)
        }
        return order
    }
}

/// 随机播放的游标：持有一轮的洗牌队列，走完再洗下一轮。
struct AlbumShuffleCursor {
    private var queue: [Int] = []
    private var position = 0

    /// 当前轮是否已排好（供测试与调试观察）。
    var pendingCount: Int { max(queue.count - position, 0) }

    mutating func reset<Generator: RandomNumberGenerator>(
        count: Int,
        previous: Int?,
        using generator: inout Generator
    ) {
        queue = AlbumOrder.shuffledQueue(count: count, previous: previous, using: &generator)
        position = 0
    }

    /// 下一张。图片张数变了（换来源 / 目录里增删了文件）就整轮重洗。
    mutating func next<Generator: RandomNumberGenerator>(
        count: Int,
        current: Int?,
        using generator: inout Generator
    ) -> Int {
        if queue.count != count || position >= queue.count {
            reset(count: count, previous: current, using: &generator)
        }
        guard position < queue.count else { return current ?? 0 }
        let value = queue[position]
        position += 1
        return value
    }
}
