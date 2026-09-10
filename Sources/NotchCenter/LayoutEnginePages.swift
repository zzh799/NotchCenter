import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 整页块（独占一个抽屉页）

/// 添加整页块的结果。分开 `.noPageCapacity` 与 `.unavailable`，是因为前者
/// 需要向用户解释"抽屉页已满"（可行动），后者只是块声明有问题（内部错误）。
enum ExclusivePageAddOutcome: Equatable {
    case placed(placementID: String, page: Int)
    /// 页数已达上限且没有空页——调用方提示用户，宿主不自动清理任何页。
    case noPageCapacity
    /// 块查不到、不是整页块，或声明非法。
    case unavailable
}

extension LayoutEngine {
    /// 某页的整页块（无则 nil）。
    func pageBlock(onPage page: Int) -> PlacedBlock? {
        drawerBlocks(onPage: page).first { isExclusivePageBlock($0) }
    }

    /// 某页是否已被整页块独占（该页不允许再落任何其它块）。
    func isExclusivePage(_ page: Int) -> Bool {
        pageBlock(onPage: page) != nil
    }

    /// 放置实例是否整页块。
    ///
    /// 插件声明是**唯一真源**（能解析就用它）；解析不到时回落到持久化标记
    /// `PlacedBlock.isPage`——插件被停用 / 卸载后独占守卫与宿主占位视图
    /// 都还要靠它工作（见 Agent Note 2026-09-10-plugin-page-blocks）。
    func isExclusivePageBlock(_ block: PlacedBlock) -> Bool {
        if let definition = blockResolver(block.pluginID, block.blockID) {
            return definition.kind.isExclusivePage
        }
        return block.isPage
    }

    /// 整页块的提交跨度：列夹进 `[minimumColumnCount(), effectiveMaxColumns()]`，
    /// 行至少 1。
    ///
    /// 列下限这一步是"整页正好铺满内容区"的由来——面板宽度由 `occupiedColumns`
    /// 从块跨度反推、再被用户的最小列数抬起来；把下限提前并入块跨度，两者就不会
    /// 各算一套。它同时解释了既有的"插件声明窄页也会被撑到 N 列起"。
    func normalizedExclusivePageSpan(columns: Int, rows: Int) -> GridSpan {
        GridSpan(
            columns: min(max(columns, minimumColumnCount()), effectiveMaxColumns()),
            rows: max(rows, 1)
        )
    }

    // MARK: 添加（Q2 规则：空页就地占用，否则新开一页）

    /// 添加整页块。
    ///
    /// `preferredPage` 传用户当前所在页：该页为空（无任何块）就直接占用它，
    /// 否则新开一页（右外侧）——既不破坏已有内容，也不留下空页垃圾。
    /// 页数已达 `LayoutModel.maxDrawerPageCount` 且无空页时返回 `.noPageCapacity`，
    /// **不自动清理任何页**（由调用方提示用户）。
    @discardableResult
    func addPageBlock(
        pluginID: String,
        blockID: String,
        preferredPage: Int,
        cellWidth: CGFloat = NotchGridMetrics.cellWidth,
        cellHeight: CGFloat = NotchGridMetrics.cellHeight
    ) -> ExclusivePageAddOutcome {
        guard let block = blockResolver(pluginID, blockID),
              block.kind.isExclusivePage,
              block.validationError == nil else {
            return .unavailable
        }

        let targetPage: Int
        if model.drawerPages.contains(preferredPage),
           drawerBlocks(onPage: preferredPage).isEmpty {
            targetPage = preferredPage
        } else if canAddDrawerPage() {
            targetPage = addDrawerPage(.right)
        } else {
            return .noPageCapacity
        }

        let recommended = block.sizeBox(cellWidth: cellWidth, cellHeight: cellHeight)?.recommended
            ?? GridSpan.globalMinimum
        let span = normalizedExclusivePageSpan(columns: recommended.columns, rows: recommended.rows)
        let placed = PlacedBlock(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString,
            page: targetPage,
            originColumn: 0,
            originRow: 0,
            widthColumns: span.columns,
            heightRows: span.rows,
            isPage: true
        )
        model.drawerBlocks.append(placed)
        // 该书签页还没有自定义标题 / 图标时用块名与图标补一次默认值，之后
        // 用户仍可在分页胶囊的页面设置里改（不清空已有自定义值）。
        seedPageIdentity(page: targetPage, title: block.displayName, symbol: block.symbolName)
        saveToDisk()
        return .placed(placementID: placed.placementID, page: targetPage)
    }

    /// 整页块落位时为所在页补一次默认标题 / 图标；已有非空值不动。
    private func seedPageIdentity(page: Int, title: String, symbol: String?) {
        let key = String(page)
        if model.drawerPageTitles[key]?.isEmpty != false {
            model.drawerPageTitles[key] = title
        }
        if model.drawerPageIcons[key]?.isEmpty != false, let symbol {
            model.drawerPageIcons[key] = symbol
        }
    }

    // MARK: 加载 / 配置变化时的归一（防漂移 + 自愈）

    /// 整页状态的统一归一，加载路径与启用集变化共用：
    /// 1. 回写 `PlacedBlock.isPage`（插件可解析时以声明为真源）；
    /// 2. 整页块几何归一（原点恒 (0,0)、列跨度夹进 `[最小列数, 有效容量]`）；
    /// 3. 拆解非法共存（整页块自己搬到新页）。
    /// 有改动即落盘。
    func normalizeExclusivePageState() {
        var changed = false
        for index in model.drawerBlocks.indices {
            let block = model.drawerBlocks[index]
            guard let definition = blockResolver(block.pluginID, block.blockID) else { continue }
            let shouldBePage = definition.kind.isExclusivePage
            if block.isPage != shouldBePage {
                model.drawerBlocks[index].isPage = shouldBePage
                changed = true
            }
        }
        changed = normalizeExclusivePageGeometry() || changed
        changed = separateExclusivePageConflicts() || changed
        if changed {
            saveToDisk()
        }
    }

    /// 整页块的几何归一：整页块恒落 (0,0)，列跨度夹进 `[最小列数, 有效容量]`。
    /// 手改过的 `layout.json`、以及用户调过「最小 / 最大列数」之后都在这里收敛。
    @discardableResult
    func normalizeExclusivePageGeometry() -> Bool {
        var changed = false
        for index in model.drawerBlocks.indices {
            let block = model.drawerBlocks[index]
            guard isExclusivePageBlock(block) else { continue }
            let span = normalizedExclusivePageSpan(columns: block.widthColumns, rows: block.heightRows)
            guard block.originColumn != 0 || block.originRow != 0
                || block.widthColumns != span.columns || block.heightRows != span.rows else { continue }
            model.drawerBlocks[index].originColumn = 0
            model.drawerBlocks[index].originRow = 0
            model.drawerBlocks[index].widthColumns = span.columns
            model.drawerBlocks[index].heightRows = span.rows
            changed = true
        }
        return changed
    }

    /// 拆解"整页块 + 同页其它块"的非法共存：普通块原地不动，**整页块自己搬到
    /// 新页**（优先复用空页，其次新开一页；两者都没有则退化为丢掉整页块）。
    /// 与添加规则同构——"页面想要独占一页，那就给它一页"。
    @discardableResult
    func separateExclusivePageConflicts() -> Bool {
        var changed = false
        while true {
            let conflicts = Self.exclusivePageConflictPages(
                model.drawerBlocks,
                isPageBlock: isExclusivePageBlock
            )
            guard let page = conflicts.first,
                  let index = model.drawerBlocks.firstIndex(where: {
                      $0.page == page && isExclusivePageBlock($0)
                  }) else {
                break
            }
            var moved = model.drawerBlocks[index]
            if let target = vacantOrNewPage() {
                moved.page = target
                model.drawerBlocks[index] = moved
            } else {
                model.drawerBlocks.remove(at: index)
            }
            changed = true
        }
        return changed
    }

    /// 冲突页集合（纯函数，单测覆盖）：一页里同时存在整页块与别的块。
    static func exclusivePageConflictPages(
        _ blocks: [PlacedBlock],
        isPageBlock: (PlacedBlock) -> Bool
    ) -> [Int] {
        Dictionary(grouping: blocks, by: \.page)
            .filter { $0.value.count > 1 && $0.value.contains(where: isPageBlock) }
            .keys
            .sorted()
    }

    /// 让被挤出的整页块可居留的页：优先复用空页，其次新开一页（≤ 页数上限）；
    /// 都没有则 nil。
    private func vacantOrNewPage() -> Int? {
        if let vacant = model.drawerPages.first(where: { drawerBlocks(onPage: $0).isEmpty }) {
            return vacant
        }
        guard canAddDrawerPage() else { return nil }
        return addDrawerPage(.right)
    }
}
