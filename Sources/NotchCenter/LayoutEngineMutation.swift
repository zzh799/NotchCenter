import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 布局修改（公开操作 API）

extension LayoutEngine {
    func setUserMaxColumns(_ columns: Int) {
        let clamped = LayoutModel.clamped(columns, to: LayoutModel.maxColumnsRange)
        guard model.maxColumns != clamped else { return }
        model.maxColumns = clamped
        // 容量缩小后先修越界块再落盘：越界状态（右侧块被面板裁掉）不进 layout.json。
        repairBlocksBeyondCapacity()
        saveToDisk()
    }

    /// 越界重排实例入口（仅 `setUserMaxColumns` 挂钩；`updateScreenConstraint`
    /// 有意不挂——换屏导致的容量变化是临时状态，修复会把布局永久改写，移回
    /// 宽屏不可恢复）。按页分组修复，无越界时零 model 改写。
    func repairBlocksBeyondCapacity() {
        let result = Self.perPage(model.drawerBlocks) {
            Self.repairCapacityOverflow($0, capacity: effectiveMaxColumns())
        }
        guard result.changed else { return }
        model.drawerBlocks = result.blocks
    }

    func setUserMinRows(_ rows: Int) {
        let clamped = LayoutModel.clamped(rows, to: LayoutModel.minRowsRange)
        guard model.minRows != clamped else { return }
        model.minRows = clamped
        saveToDisk()
    }

    /// 最大列数小于可选项下界时忽略写入（不回改存量值，见 `LayoutModel.minColumnsRange`）。
    func setUserMinColumns(_ columns: Int) {
        guard model.maxColumns >= LayoutModel.minColumnsRange.lowerBound else { return }
        let clamped = min(
            LayoutModel.clamped(columns, to: LayoutModel.minColumnsRange),
            model.maxColumns
        )
        guard model.minColumns != clamped else { return }
        model.minColumns = clamped
        saveToDisk()
    }

    /// 屏幕宽度约束（文档 §7.2）：实际列数 = min(用户配置, 屏幕能容纳的列数)。
    func updateScreenConstraint(width: CGFloat) {
        availableScreenWidth = width
    }

    /// 屏幕宽度能容纳的最大列数（容量分量，不受用户最大列数配置约束）。
    /// 抽屉窗口的固定满宽按它取（见 `NotchPanelController.drawerFrame`）
    /// ——列数配置变化只 spring 可见面板，窗口 frame 不动。
    func screenColumnCapacity() -> Int {
        max(
            1,
            Int(
                (availableScreenWidth - NotchGridMetrics.contentPadding * 2
                    + NotchGridMetrics.spacing)
                / (NotchGridMetrics.cellWidth + NotchGridMetrics.spacing)
            )
        )
    }

    func effectiveMaxColumns() -> Int {
        min(model.maxColumns, screenColumnCapacity())
    }

    /// 行/列下限（配置项「最小行数 / 最小列数」）的**唯一计算出口**从这里取：
    /// 各面板与网格尺寸站点用它替代原先硬编码的 `1`。只夹尺寸，不改块原点——
    /// 压实、推挤、落点夹紧与校验都看不到这个下限。
    func minimumRowCount() -> Int {
        model.minRows
    }

    /// 列下限还要夹一次**有效容量**：容量小于配置值时面板恒为满宽，但不会宽出
    /// 按 effectiveMaxColumns 定宽的 `drawerFrame`（否则被裁切并丢失命中测试）。
    func minimumColumnCount() -> Int {
        min(model.minColumns, effectiveMaxColumns())
    }

    /// 同步启用插件列表（文档 §5.4：enabledPluginIDs 存于 layout.json）。
    func syncEnabledPluginIDs(_ ids: Set<String>) {
        let sorted = ids.sorted()
        guard Set(model.enabledPluginIDs) != ids else { return }
        model.enabledPluginIDs = sorted
        saveToDisk()
    }

    /// 首启默认启用内置插件（文档未强制，但官方插件应在首次启动时可用）。
    func seedEnabledBuiltIns(_ ids: Set<String>) {
        guard !didLoadFromDisk else { return }
        model.enabledPluginIDs = Array(ids).sorted()
        saveToDisk()
    }

    // MARK: 紧凑槽位（文档 §5.2：数组长度即图标数，宽度随其动态伸缩）

    /// 设置某索引的紧凑块引用。`nil` = 移除该图标（**其余保持屏幕相对顺序**，
    /// 见 `CompactSlotOrder.removing`）；非空 = 替换该索引（索引等于当前长度
    /// 则追加到末尾）；越界忽略。
    func setCompactSlot(_ index: Int, to ref: CompactSlotReference?) {
        guard let ref else {
            guard let remaining = CompactSlotOrder.removing(model.compactSlots, at: index) else {
                return
            }
            model.compactSlots = remaining
            saveToDisk()
            return
        }
        if model.compactSlots.indices.contains(index) {
            model.compactSlots[index] = ref
        } else if index == model.compactSlots.count {
            model.compactSlots.append(ref)
        }
        saveToDisk()
    }

    /// 在**屏幕位置** `position`（0 = 最左，count = 末尾）插入紧凑块
    /// （设置面板拖拽落点）：越界钳制。
    ///
    /// 用屏幕位置而不是数组下标：数组下标按奇偶左右分列，直接按下标插入会让
    /// 后续下标整体后移、屏幕上其余图标集体换位（见 `CompactSlotOrder`）。
    @discardableResult
    func insertCompactBlock(
        pluginID: String,
        blockID: String,
        atScreenPosition position: Int
    ) -> Bool {
        guard let block = blockResolver(pluginID, blockID), block.kind == .compact else {
            return false
        }
        let clamped = min(max(position, 0), model.compactSlots.count)
        model.compactSlots = CompactSlotOrder.inserting(
            CompactSlotReference(
                pluginID: pluginID,
                blockID: blockID,
                placementID: UUID().uuidString
            ),
            into: model.compactSlots,
            atScreenPosition: clamped
        )
        saveToDisk()
        return true
    }

    /// 拖动重排快捷按钮（方案 A）：把数组下标 `from` 的图标移到**屏幕位置**
    /// `to`（0...count）。屏幕上只有被拖的那一个移动，其余保持相对顺序。
    /// 越界钳制；落点即原位（含右侧相邻）时不改动、不落盘。
    @discardableResult
    func moveCompactSlot(from: Int, toScreenPosition to: Int) -> Bool {
        guard let reordered = CompactSlotOrder.reordered(
            model.compactSlots,
            from: from,
            to: min(max(to, 0), model.compactSlots.count)
        ) else { return false }
        model.compactSlots = reordered
        saveToDisk()
        return true
    }

    func swapCompactSlots(_ first: Int, _ second: Int) {
        guard model.compactSlots.indices.contains(first),
              model.compactSlots.indices.contains(second) else { return }
        model.compactSlots.swapAt(first, second)
        saveToDisk()
    }

    /// 添加紧凑块到末尾（紧凑带长度随之增长，带宽动态伸缩）。
    @discardableResult
    func addCompactBlock(pluginID: String, blockID: String) -> Bool {
        guard let block = blockResolver(pluginID, blockID), block.kind == .compact else {
            return false
        }
        model.compactSlots.append(CompactSlotReference(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString
        ))
        saveToDisk()
        return true
    }

    // MARK: 抽屉页面

    /// 是否还能新增页面（封顶见 `LayoutModel.maxDrawerPageCount`）。
    func canAddDrawerPage() -> Bool {
        model.drawerPages.count < LayoutModel.maxDrawerPageCount
    }

    /// 在显示序列的左/右外侧新增一个空页面并返回其索引（调用方负责切换激活页）。
    ///
    /// 新索引按既有**权值**外侧生成（min−1 / max+1）而不是 `first`/`last`：
    /// 数组顺序是显示次序不是升序，乱序下会撞出重复索引、把块挂到错的页上。
    @discardableResult
    func addDrawerPage(_ side: DrawerPageSide) -> Int {
        let pages = model.drawerPages
        let newPage: Int
        var updated = pages
        switch side {
        case .left:
            newPage = (pages.min() ?? 1) - 1
            updated.insert(newPage, at: 0)
        case .right:
            newPage = (pages.max() ?? -1) + 1
            updated.append(newPage)
        }
        model.drawerPages = LayoutModel.normalizedPages(updated)
        saveToDisk()
        return newPage
    }

    /// 拖动排序：把页面 `from` 放到显示序列的第 `targetIndex` 位（胶囊行里的目标
    /// 槽位，夹紧到 0...count−1）。只改次序，块上的 `page` 一律不动。
    @discardableResult
    func moveDrawerPage(from: Int, to targetIndex: Int) -> Bool {
        var pages = model.drawerPages
        guard let source = pages.firstIndex(of: from) else { return false }
        let target = min(max(targetIndex, 0), pages.count - 1)
        guard target != source else { return false }
        pages.remove(at: source)
        pages.insert(from, at: target)
        model.drawerPages = pages
        saveToDisk()
        return true
    }

    func drawerPageTitle(_ page: Int) -> String? {
        model.drawerPageTitles[String(page)]
    }

    /// 设置页面标题；空串（或纯空白）= 清除，回落为序号。
    func setDrawerPageTitle(page: Int, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        model.drawerPageTitles[String(page)] = trimmed.isEmpty ? nil : trimmed
        saveToDisk()
    }

    func drawerPageIcon(_ page: Int) -> String? {
        model.drawerPageIcons[String(page)]
    }

    /// 设置页面图标（SF Symbol 名）；空串（或纯空白）= 清除，主页回落房子、其余页无图标。
    func setDrawerPageIcon(page: Int, icon: String) {
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        model.drawerPageIcons[String(page)] = trimmed.isEmpty ? nil : trimmed
        saveToDisk()
    }

    /// 删除页面，连页内的块一起移除并返回被删块（调用方逐个补
    /// `placementWasRemoved`）；主页不可删。
    ///
    /// 块与页必须在**同一次写盘**里消失：`normalizedPages` 会收编"块引用的散页"，
    /// 先摘页再删块会让刚删的页原样复活。
    @discardableResult
    func removeDrawerPage(page: Int) -> [PlacedBlock]? {
        guard page != LayoutModel.homePage, model.drawerPages.contains(page) else {
            return nil
        }
        let removed = drawerBlocks(onPage: page)
        model.drawerBlocks.removeAll { $0.page == page }
        model.drawerPages.removeAll { $0 == page }
        model.drawerPageTitles[String(page)] = nil
        model.drawerPageIcons[String(page)] = nil
        saveToDisk()
        return removed
    }

    // MARK: 抽屉网格（文档 §5.3）

    /// 自动放置到第一个可用位置；超出最大列数后自动换行。
    /// 落位后压实空行/空列（左扩布局可能存在负列空洞）。
    @discardableResult
    func autoPlaceDrawerBlock(pluginID: String, blockID: String, page: Int = 0) -> PlacedBlock? {
        guard let block = blockResolver(pluginID, blockID), block.kind == .drawer else {
            return nil
        }
        let span = (block.defaultSize ?? .small).gridSpan
        let columns = effectiveMaxColumns()
        let occupied = occupiedRects(page: page, excluding: nil)

        // 在既有行内寻找首个可用位置。
        let maxRow = occupied.map(\.maxRow).max() ?? -1
        for row in 0...max(0, maxRow) {
            for col in 0...max(0, columns - span.columns) {
                let candidate = PlacedBlock(
                    pluginID: pluginID,
                    blockID: blockID,
                    placementID: UUID().uuidString,
                    page: page,
                    originColumn: col,
                    originRow: row,
                    widthColumns: span.columns,
                    heightRows: span.rows
                )
                if !overlaps(candidate, with: occupied) {
                    model.drawerBlocks.append(candidate)
                    compactEmptyRows()
                    compactEmptyColumns()
                    saveToDisk()
                    return candidate
                }
            }
        }

        // 无可用位置：新起一行（文档 §5.3：超出后自动换行；高度随内容增长，超高则滚动）。
        let placed = PlacedBlock(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString,
            page: page,
            originColumn: 0,
            originRow: maxRow + 1,
            widthColumns: span.columns,
            heightRows: span.rows
        )
        model.drawerBlocks.append(placed)
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return placed
    }

    /// 在指定网格位置放置抽屉块（设置面板拖拽落点，文档 §5.3）：
    /// 落点被占/越界时按行优先扫描最近可用位置（与 `moveDrawerBlock`
    /// 同一语义）；无处可放返回 nil。行仅向下增长（row < 0 一律按 0 计）。
    @discardableResult
    func placeDrawerBlock(
        pluginID: String,
        blockID: String,
        column: Int,
        row: Int,
        page: Int = 0
    ) -> PlacedBlock? {
        guard let block = blockResolver(pluginID, blockID), block.kind == .drawer else {
            return nil
        }
        let span = (block.defaultSize ?? .small).gridSpan
        guard let origin = nearestFreeOrigin(
            for: span,
            preferredColumn: column,
            preferredRow: row,
            page: page,
            excluding: nil
        ) else { return nil }

        let placed = PlacedBlock(
            pluginID: pluginID,
            blockID: blockID,
            placementID: UUID().uuidString,
            page: page,
            originColumn: origin.column,
            originRow: origin.row,
            widthColumns: span.columns,
            heightRows: span.rows
        )
        model.drawerBlocks.append(placed)
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return placed
    }

    /// 为给定跨度寻找落点：优先 `preferred`（clamp 到合法列区间，行非负），
    /// 被占时**由近及远**找最近可用位置，保证“拖到哪都能放下”。
    ///
    /// 不能像 `moveDrawerBlock` 那样从列区间下限开始行优先扫描：下限在左扩
    /// 语义下可为负（capacity 远大于占用列时），被占一格就会被推到最左侧
    /// （如落点 (0,0) 被占 → 落到 (-3,0)），整个布局向左偏移——与用户
    /// “放到旁边”的直觉相反。这里按“落点所在行优先、行内先右后左、
    /// 行按距离递增”的顺序探测：先贴着落点找，再向上下相邻行扩展。
    private func nearestFreeOrigin(
        for span: (columns: Int, rows: Int),
        preferredColumn: Int,
        preferredRow: Int,
        page: Int,
        excluding placementID: String?
    ) -> (column: Int, row: Int)? {
        let others = siblings(onPage: page, excluding: placementID)
        let bounds = validColumnRange(others: others, width: span.columns)
        let occupied = others.map(rectKey)

        let clampedColumn = min(max(preferredColumn, bounds.lower), bounds.upper)
        let clampedRow = max(preferredRow, 0)
        var candidate = PlacedBlock(
            pluginID: "",
            blockID: "",
            placementID: placementID ?? "",
            originColumn: clampedColumn,
            originRow: clampedRow,
            widthColumns: span.columns,
            heightRows: span.rows
        )
        if !overlaps(candidate, with: occupied) {
            return (clampedColumn, clampedRow)
        }

        // 探测下界：既有布局最底行 + 1（新起一行必然无冲突）。
        let maxRow = max(others.map(\.maxRow).max() ?? 0, clampedRow) + 1
        let columnReach = max(bounds.upper - clampedColumn, clampedColumn - bounds.lower)

        // 行顺序：落点行、下一行、上一行、下两行…… （距离递增，越界跳过）。
        var rows: [Int] = []
        for offset in 0...max(maxRow - clampedRow, clampedRow) {
            if clampedRow + offset <= maxRow { rows.append(clampedRow + offset) }
            if offset > 0, clampedRow - offset >= 0 { rows.append(clampedRow - offset) }
        }

        for row in rows {
            // 行内顺序：落点列、右侧一格、左侧一格、右侧两格……（先右后左）。
            for offset in 0...max(columnReach, 0) {
                if clampedColumn + offset <= bounds.upper {
                    candidate.originColumn = clampedColumn + offset
                    candidate.originRow = row
                    if !overlaps(candidate, with: occupied) {
                        return (candidate.originColumn, row)
                    }
                }
                if offset > 0, clampedColumn - offset >= bounds.lower {
                    candidate.originColumn = clampedColumn - offset
                    candidate.originRow = row
                    if !overlaps(candidate, with: occupied) {
                        return (candidate.originColumn, row)
                    }
                }
            }
        }
        return nil
    }

    func removeDrawerBlock(placementID: String) {
        model.drawerBlocks.removeAll { $0.placementID == placementID }
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
    }

    /// 跨页搬移抽屉块（胶囊驻留切页的落位动作）：**保留 placementID**
    /// （插件实例状态键），从原页摘除并压实原页，再按「最近可用位置」
    /// （`nearestFreeOrigin`，与 `placeDrawerBlock` 同语义）落到目标页。
    /// 同页搬移不走这里（返回 nil）——页内移动是 `moveDrawerBlock` 的语义。
    @discardableResult
    func moveDrawerBlockCrossPage(
        placementID: String,
        toPage: Int,
        column: Int,
        row: Int
    ) -> PlacedBlock? {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }),
              model.drawerPages.contains(toPage) else { return nil }
        let block = model.drawerBlocks[index]
        guard block.page != toPage else { return nil }
        model.drawerBlocks.remove(at: index)
        // 原页压实：块搬走留下的整行/整列空洞闭合（与 removeDrawerBlock 同款）。
        compactEmptyRows()
        compactEmptyColumns()
        var placed = block
        placed.page = toPage
        if let origin = nearestFreeOrigin(
            for: (columns: block.widthColumns, rows: block.heightRows),
            preferredColumn: column,
            preferredRow: row,
            page: toPage,
            excluding: placementID
        ) {
            placed.originColumn = origin.column
            placed.originRow = origin.row
        } else {
            // 目标页放不下（极端：跨度超容量）：兜底新起一行，不静默丢弃搬移。
            placed.originColumn = 0
            placed.originRow = (occupiedRects(page: toPage, excluding: nil).map(\.maxRow).max() ?? -1) + 1
        }
        model.drawerBlocks.append(placed)
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return placed
    }

    /// 一键重排（编辑模式）：按“从上到下、从左到右”的阅读顺序紧密排布抽屉块。
    /// 以当前布局的阅读顺序为优先级，逐块放到首个不重叠位置（行优先
    /// 扫描），消除移动/缩放留下的空洞；块身份与跨度保持不变，仅调整原点。
    func reorderDrawerBlocks(page: Int = 0) {
        let pageBlocks = drawerBlocks(onPage: page)
        guard !pageBlocks.isEmpty else { return }
        let columns = effectiveMaxColumns()

        // 阅读顺序即优先级：先看行再看列（元组比较）。
        let ordered = pageBlocks.sorted {
            ($0.originRow, $0.originColumn) < ($1.originRow, $1.originColumn)
        }

        var occupied: [RectKey] = []
        var result: [PlacedBlock] = []
        result.reserveCapacity(ordered.count)

        for block in ordered {
            // 行优先扫描首个可用位置；扫描上界为已占最底行 + 1
            // （新起一行时必然无冲突，无需继续向下找）。
            var candidate = block
            let maxRow = occupied.map(\.maxRow).max() ?? -1
            scan: for row in 0...max(0, maxRow + 1) {
                for col in 0...max(0, columns - block.widthColumns) {
                    candidate.originColumn = col
                    candidate.originRow = row
                    if !overlaps(candidate, with: occupied) {
                        break scan
                    }
                }
            }
            occupied.append(rectKey(candidate))
            result.append(candidate)
        }

        // 仅写回本页块，其他页块留在原数组位置。
        let resultByID = Dictionary(uniqueKeysWithValues: result.map { ($0.placementID, $0) })
        for index in model.drawerBlocks.indices {
            if let replacement = resultByID[model.drawerBlocks[index].placementID] {
                model.drawerBlocks[index] = replacement
            }
        }
        saveToDisk()
    }

    /// 移动抽屉块到目标位置（块只在其所在页内移动）；目标被占用时移动到最近
    /// 可用位置。无处可放或块不存在返回 false。
    @discardableResult
    func moveDrawerBlock(placementID: String, toColumn: Int, toRow: Int) -> Bool {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return false
        }
        let block = model.drawerBlocks[index]
        let others = siblings(of: block)
        let occupied = others.map(rectKey)
        let bounds = validColumnRange(others: others, width: block.widthColumns)
        var bestTarget: PlacedBlock?

        // 优先目标位置（clamp 到合法列区间，左侧可为负——左扩）。
        let clampedColumn = min(max(toColumn, bounds.lower), bounds.upper)
        let clampedRow = max(toRow, 0)
        var candidate = block
        candidate.originColumn = clampedColumn
        candidate.originRow = clampedRow
        if !overlaps(candidate, with: occupied) {
            bestTarget = candidate
        }

        // 否则按行优先扫描最近可用位置。
        if bestTarget == nil {
            let maxRow = max(others.map(\.maxRow).max() ?? 0, clampedRow)
            scan: for row in 0...maxRow + 1 {
                for col in bounds.lower...bounds.upper {
                    var probe = block
                    probe.originColumn = col
                    probe.originRow = row
                    if !overlaps(probe, with: occupied) {
                        bestTarget = probe
                        break scan
                    }
                }
            }
        }

        guard var target = bestTarget else { return false }
        target.originColumn = min(max(target.originColumn, bounds.lower), bounds.upper)
        target.originRow = max(target.originRow, 0)
        model.drawerBlocks[index] = target
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return true
    }

    /// 在支持的尺寸等级间切换块尺寸（编辑模式，文档 §5.5）。
    @discardableResult
    func resizeDrawerBlock(placementID: String, to size: BlockSize) -> Bool {
        resizeDrawerBlock(
            placementID: placementID,
            toColumns: size.gridSpan.columns,
            toRows: size.gridSpan.rows
        )
    }

    /// 缩放块到任意声明的跨度（编辑模式）：跨度必须在块的 supportedSpans 内。
    /// 扩大与下方块重叠时不再回退，而是按阅读顺序推挤下移（与拖拽同一
    /// 逐块安放语义）；缩小留下的空行随后压实。左上角原点保持不变
    /// （仅当合并后跨度过容量时向左收紧，原点可为负——左扩）。
    @discardableResult
    func resizeDrawerBlock(placementID: String, toColumns: Int, toRows: Int) -> Bool {
        guard let index = model.drawerBlocks.firstIndex(where: { $0.placementID == placementID }) else {
            return false
        }
        let block = model.drawerBlocks[index]
        guard let definition = blockResolver(block.pluginID, block.blockID),
              definition.supportedSpans.contains(GridSpan(columns: toColumns, rows: toRows)) else {
            return false
        }

        var resized = block
        resized.widthColumns = toColumns
        resized.heightRows = toRows

        let bounds = validColumnRange(others: siblings(of: block), width: toColumns)
        resized.originColumn = min(max(resized.originColumn, bounds.lower), bounds.upper)
        resized.originRow = max(resized.originRow, 0)

        model.drawerBlocks[index] = resized
        applyOrigins(pushDownOrigins(changed: resized))
        compactEmptyRows()
        compactEmptyColumns()
        saveToDisk()
        return true
    }

    /// 提交拖拽预览结果（与 `previewCommittedArrangement` 同一算法——推挤 +
    /// 离线压实，保证所见即所得），随后压实空行与空列（拖走后遗留的整行/
    /// 整列空洞由下方/右侧块上移/左移闭合）。
    ///
    /// 预览侧已经离线压实过，此处的压实是**幂等兜底**：压实后无空行/空列，
    /// 循环首轮即退出、零位移；对任何传入未压实 origins 的调用方仍正确。
    @discardableResult
    func commitArrangement(_ origins: [String: GridOrigin]) -> Bool {
        guard !origins.isEmpty else { return false }
        let before = model.drawerBlocks.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" }
        applyOrigins(origins)
        compactEmptyRows()
        compactEmptyColumns()
        let after = model.drawerBlocks.map { "\($0.placementID):\($0.originColumn),\($0.originRow)" }
        let changed = before != after
        if changed {
            saveToDisk()
        }
        return changed
    }
}
