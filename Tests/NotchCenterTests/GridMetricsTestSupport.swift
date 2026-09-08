import CoreGraphics
import XCTest
@testable import NotchCenter

// MARK: - 网格指标隔离（像素夹具的前提）

/// `GridMetricsStore.shared` 四项指标的一份快照（还原用）。
///
/// 指标是**进程级单例**，用例之间会残留：改过的用例必须原样还回去，否则后面
/// 的套件读到别人留下的值，失败面随执行顺序漂移（同一份代码在不同的套件
/// 子集下表现不同）。
struct GridMetricsSnapshot {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let spacing: CGFloat
    let contentPadding: CGFloat

    init(_ store: GridMetricsStore = .shared) {
        cellWidth = store.value(for: .cellWidth)
        cellHeight = store.value(for: .cellHeight)
        spacing = store.value(for: .spacing)
        contentPadding = store.value(for: .contentPadding)
    }

    func apply(to store: GridMetricsStore = .shared) {
        store.set(.cellWidth, to: cellWidth)
        store.set(.cellHeight, to: cellHeight)
        store.set(.spacing, to: spacing)
        store.set(.contentPadding, to: contentPadding)
    }
}

extension XCTestCase {
    /// 把网格指标钉到**像素夹具的换算基准**（`fixtureCellWidth/Height`），用例
    /// 结束（含失败路径）自动还原。
    ///
    /// 为什么必须钉：测试以宿主 App 为 `TEST_HOST`（见 Project.swift），进程里的
    /// `UserDefaults.standard` 就是**开发者机器上真实的偏好域**——用户在「设置
    /// → 布局」调过的格子（例如最小档 75×60）会被 `GridMetricsStore.shared` 读
    /// 进来。像素夹具（`fixtureBox`）按出厂格声明物理像素，"small = 1×1" 的前提
    /// 只在格子等于夹具基准时成立：格子换成 75×60，同一张 small 档（150×120
    /// 点）就被换算成 2×2 格，`drawerContentRows` / `occupiedColumns` 之类断言
    /// 实占跨度的几何用例随之翻倍（4≠2 / 2≠1），`resizeDrawerBlock` 也因档位盒
    /// 被换算成"最少 4 行"而拒绝缩放——全部与源码改动无关。
    ///
    /// 指标已在位时 `GridMetricsStore.set` 直接返回（不落盘、不通知），所以
    /// 出厂默认机器上这一钉是零副作用。
    @discardableResult
    func pinGridMetricsToFixtureDefaults() -> GridMetricsSnapshot {
        let snapshot = GridMetricsSnapshot()
        let store = GridMetricsStore.shared
        store.set(.cellWidth, to: fixtureCellWidth)
        store.set(.cellHeight, to: fixtureCellHeight)
        store.set(.spacing, to: GridMetricsStore.defaultSpacing)
        store.set(.contentPadding, to: GridMetricsStore.defaultContentPadding)
        addTeardownBlock { snapshot.apply(to: .shared) }
        return snapshot
    }
}
