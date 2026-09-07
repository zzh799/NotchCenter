import CoreGraphics
import Foundation
import SwiftUI

// MARK: - 可配置网格指标（设置 → 布局）

/// 抽屉网格指标存储：单元宽/高、间距、内容内边距（文档 §5.3 原为固定常量，
/// 现开放给用户调整）。
///
/// 设计为 **非隔离** 的共享单例（`ObservableObject` + `NSLock`），因为
/// `NotchGridMetrics` 的静态访问点被大量 nonisolated / 非 MainActor 的代码
/// （几何计算、测试）同步读取，无法统一改造成 MainActor 隔离。写入只发生在
/// 主线程（设置面板），读取线程安全（锁 + 值类型）。
///
/// 变更后发出 `didChangeNotification`：控制器据此重建内容并重排窗口
/// （抽屉尺寸随指标变化）。
final class GridMetricsStore: ObservableObject, @unchecked Sendable {
    static let shared = GridMetricsStore()

    /// 指标变更后发出（主线程）。object 为 `GridMetricsStore` 本身。
    static let didChangeNotification = Notification.Name("notchCenter.gridMetricsDidChange")

    // MARK: 可调指标

    enum Metric: Hashable {
        case cellWidth
        case cellHeight
        case spacing
        case contentPadding
    }

    /// 各指标的合法区间（步长 1pt；写入前钳制，UI 滑杆共用同一区间）。
    static func range(for metric: Metric) -> ClosedRange<CGFloat> {
        switch metric {
        case .cellWidth: return 75...280
        case .cellHeight: return 60...240
        case .spacing: return 0...32
        case .contentPadding: return 0...40
        }
    }

    @Published private(set) var cellWidth: CGFloat
    @Published private(set) var cellHeight: CGFloat
    @Published private(set) var spacing: CGFloat
    @Published private(set) var contentPadding: CGFloat

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let postsNotification: Bool

    private static let cellWidthKey = "notchCenter.grid.cellWidth"
    private static let cellHeightKey = "notchCenter.grid.cellHeight"
    private static let spacingKey = "notchCenter.grid.spacing"
    private static let contentPaddingKey = "notchCenter.grid.contentPadding"

    /// 线上出厂默认值（与文档 §5.3 一致）。
    static let defaultCellWidth: CGFloat = 150
    static let defaultCellHeight: CGFloat = 120
    static let defaultSpacing: CGFloat = 12
    static let defaultContentPadding: CGFloat = 16

    init(defaults: UserDefaults = .standard, postsNotification: Bool = true) {
        self.defaults = defaults
        self.postsNotification = postsNotification
        // 越界/缺失的持久化值一律回退默认（用户手改 plist 也自愈）。
        cellWidth = Self.load(defaults, key: Self.cellWidthKey, metric: .cellWidth)
        cellHeight = Self.load(defaults, key: Self.cellHeightKey, metric: .cellHeight)
        spacing = Self.load(defaults, key: Self.spacingKey, metric: .spacing)
        contentPadding = Self.load(defaults, key: Self.contentPaddingKey, metric: .contentPadding)
    }

    private static func load(
        _ defaults: UserDefaults,
        key: String,
        metric: Metric
    ) -> CGFloat {
        let persisted = defaults.object(forKey: key) as? CGFloat
            ?? (defaults.object(forKey: key) as? NSNumber).map { CGFloat($0.doubleValue) }
        guard let persisted else { return defaultValue(for: metric) }
        let range = Self.range(for: metric)
        return min(max(persisted, range.lowerBound), range.upperBound)
    }

    static func defaultValue(for metric: Metric) -> CGFloat {
        switch metric {
        case .cellWidth: return defaultCellWidth
        case .cellHeight: return defaultCellHeight
        case .spacing: return defaultSpacing
        case .contentPadding: return defaultContentPadding
        }
    }

    // MARK: 写入

    /// 设置单项指标（主线程）：值被钳制到合法区间；无变化时直接返回
    /// （不落盘、不通知，避免滑杆拖动中的冗余重建）。
    func set(_ metric: Metric, to value: CGFloat) {
        let range = Self.range(for: metric)
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let changed = lock.withLock { () -> Bool in
            switch metric {
            case .cellWidth:
                guard cellWidth != clamped else { return false }
                cellWidth = clamped
            case .cellHeight:
                guard cellHeight != clamped else { return false }
                cellHeight = clamped
            case .spacing:
                guard spacing != clamped else { return false }
                spacing = clamped
            case .contentPadding:
                guard contentPadding != clamped else { return false }
                contentPadding = clamped
            }
            return true
        }
        guard changed else { return }
        persist(metric)
        notify()
    }

    /// 恢复出厂默认（设置 → 布局 → 恢复默认）。
    func resetToDefaults() {
        let changed = lock.withLock { () -> Bool in
            let before = [cellWidth, cellHeight, spacing, contentPadding]
            cellWidth = Self.defaultCellWidth
            cellHeight = Self.defaultCellHeight
            spacing = Self.defaultSpacing
            contentPadding = Self.defaultContentPadding
            return before != [cellWidth, cellHeight, spacing, contentPadding]
        }
        guard changed else { return }
        for metric in [Metric.cellWidth, .cellHeight, .spacing, .contentPadding] {
            defaults.removeObject(forKey: key(for: metric))
        }
        notify()
    }

    /// 当前是否为出厂默认（UI 提示用）。
    var isDefault: Bool {
        cellWidth == Self.defaultCellWidth
            && cellHeight == Self.defaultCellHeight
            && spacing == Self.defaultSpacing
            && contentPadding == Self.defaultContentPadding
    }

    private func key(for metric: Metric) -> String {
        switch metric {
        case .cellWidth: return Self.cellWidthKey
        case .cellHeight: return Self.cellHeightKey
        case .spacing: return Self.spacingKey
        case .contentPadding: return Self.contentPaddingKey
        }
    }

    private func persist(_ metric: Metric) {
        let value: CGFloat
        switch metric {
        case .cellWidth: value = cellWidth
        case .cellHeight: value = cellHeight
        case .spacing: value = spacing
        case .contentPadding: value = contentPadding
        }
        defaults.set(Double(value), forKey: key(for: metric))
    }

    /// 通知观察者：SwiftUI 刷新（`objectWillChange`）与控制器重建都要在主线程。
    private func notify() {
        objectWillChange.send()
        guard postsNotification else { return }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }
}

extension GridMetricsStore {
    /// 供 UI 绑定的读写访问器（Slider / TextField 共用）。
    func binding(for metric: Metric) -> Binding<Double> {
        Binding(
            get: { Double(self.value(for: metric)) },
            set: { self.set(metric, to: CGFloat($0)) }
        )
    }

    func value(for metric: Metric) -> CGFloat {
        switch metric {
        case .cellWidth: return cellWidth
        case .cellHeight: return cellHeight
        case .spacing: return spacing
        case .contentPadding: return contentPadding
        }
    }
}

extension NSLock {
    /// 带返回值的临界区（项目内多处 `@unchecked Sendable` 容器共用）。
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
