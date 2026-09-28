import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 设置面板拖拽落点（文档 §6.4：从设置面板拖组件到抽屉 / 快速区）

extension NotchPanelController {
    /// 屏幕坐标 → 落点。未展开、落在面板之外或种类不匹配时返回 nil
    /// （拖拽浮窗显示无效样式）。
    ///
    /// 判定顺序：先查是否命中**可收纳容器**（实现了 `NotchCenterQuickActionSink`
    /// 的抽屉容器块，即快捷按钮盒）——命中时只有带动作身份的载荷能落（装填
    /// 动作），纯块卡拖到盒上无效（红叉），避免"拖到盒上却被宽松塞进快速区"。
    /// 未命中容器再按块身份走常规区域判定：先快速区（岛顶紧凑带），再抽屉网格
    /// ——抽屉展开时两者在屏幕上上下相邻、互不重叠（紧凑带位于可见面板顶部）。
    /// 纯动作卡（无块身份）未命中容器即无效，任何区域都不接收。
    ///
    /// 区域判定见 `DrawerDropPolicy`，网格换算见 `DrawerScreenMapper`。
    func dropZone(
        at point: NSPoint,
        for payload: BlockDragCoordinator.Payload
    ) -> BlockDragCoordinator.DropZone? {
        guard isExpanded, let pair = activePair else { return nil }
        let mapper = drawerScreenMapper(for: pair)
        let policy = DrawerDropPolicy(mapper: mapper, compactHeight: pair.layout.compactHeight)

        // 1) 命中可收纳容器（盒）整格：虚线占位框恰好框住容器块。有动作身份
        //    才放行（装填动作）；纯块卡拖到盒上无效（红叉，不宽松塞进快速区）。
        if let box = quickActionBoxDropZone(at: point, mapper: mapper) {
            return payload.actionID != nil ? box : nil
        }
        // 2) 纯动作卡（统一快捷按钮、无块身份）未命中容器：只能进快速区——
        //    作为标准快捷按钮槽位插入；抽屉空白格/顶栏/面板外一律无效。
        guard !payload.blockID.isEmpty else {
            if case .compact = policy.region(of: point) {
                return .compact(index: compactScreenInsertionIndex(atX: point.x, pair: pair))
            }
            return nil
        }

        // 3) 块身份：常规区域判定。
        switch policy.region(of: point) {
        case .outside, .topBar:
            return nil
        case .compact:
            // 只有紧凑块能进快速区。
            guard payload.isCompact else { return nil }
            return .compact(index: compactScreenInsertionIndex(atX: point.x, pair: pair))
        case .grid:
            // 快捷按钮（紧凑块）拖到抽屉空白区域：宽松处理为追加到快速区末尾
            // （紧凑块无法放进抽屉网格，但“往面板上放”的意图应当被接住）。
            if payload.isCompact {
                return .compact(index: layoutEngine.compactSlots.count)
            }
            guard let cell = mapper.cell(atScreen: point, span: payload.span) else { return nil }
            return .drawer(
                column: cell.column,
                row: cell.row,
                columns: cell.columnSpan,
                rows: cell.rowSpan
            )
        }
    }

    /// 光标所在处是否是一个「可收纳快捷动作的抽屉容器块」：是则把它整格
    /// 作为落点（虚线占位框恰好框住该块）。判定只认插件实例实现了
    /// `NotchCenterQuickActionSink`（宿主零块 ID 硬编码）。未命中容器返回 nil。
    private func quickActionBoxDropZone(
        at point: NSPoint,
        mapper: DrawerScreenMapper
    ) -> BlockDragCoordinator.DropZone? {
        guard let element = uiState.drawerElements.first(where: { element in
            mapper.screenRect(for: GridCell(element.placement)).contains(point)
        }) else { return nil }
        guard let entry = pluginManager.entry(for: element.placement.pluginID),
              entry.isEnabled,
              entry.instance is any NotchCenterQuickActionSink else { return nil }
        let p = element.placement
        return .drawer(
            column: p.originColumn,
            row: p.originRow,
            columns: p.widthColumns,
            rows: p.heightRows
        )
    }

    /// 落点是否命中「可收纳快捷动作的抽屉容器块」整格（.drawer 格坐标精确
    /// 匹配当前页元素，且该放置实例所属插件实现 `NotchCenterQuickActionSink`）。
    /// 提交分派用（`commit()`：只有容器落点 + 动作身份才走动作装填，
    /// 快速区/空白格一律走块逻辑）。
    func zoneIsQuickActionContainer(_ zone: BlockDragCoordinator.DropZone) -> Bool {
        sinkContainer(at: zone) != nil
    }

    /// 反查落点所在的容器放置实例（当前页、.drawer 格坐标精确匹配）；
    /// 该格无元素或非可收纳容器时返回 nil。
    private func sinkContainer(
        at zone: BlockDragCoordinator.DropZone
    ) -> (placement: PlacedBlock, span: GridSpan, sink: any NotchCenterQuickActionSink)? {
        guard case let .drawer(column, row, columns, rows) = zone else { return nil }
        guard let element = uiState.drawerElements.first(where: { element in
            let p = element.placement
            return p.originColumn == column && p.originRow == row
                && p.widthColumns == columns && p.heightRows == rows
        }) else { return nil }
        guard let entry = pluginManager.entry(for: element.placement.pluginID),
              entry.isEnabled,
              let sink = entry.instance as? any NotchCenterQuickActionSink else { return nil }
        let p = element.placement
        let span = GridSpan(columns: max(p.widthColumns, 1), rows: max(p.heightRows, 1))
        return (p, span, sink)
    }

    /// 快速区落点：屏幕坐标先转成紧凑带内容坐标（各屏的槽位布局一致），
    /// 再取**屏幕插入位置**（0...count）。
    private func compactScreenInsertionIndex(atX x: CGFloat, pair: ScreenPanelPair) -> Int {
        compactStrip(for: pair).screenInsertionIndex(atContentX: compactContentX(x, pair: pair))
    }

    // MARK: 快捷按钮重排（编辑模式）

    /// 编辑模式下拖动快捷按钮换位：`from` 为被拖图标的数组下标，`to` 为
    /// **屏幕插入位置**（与拖拽落点同一语义）。重排按屏幕顺序运算，
    /// 其余图标在屏幕上保持相对顺序。
    func moveCompactBlock(from: Int, toScreenPosition to: Int) {
        layoutEngine.moveCompactSlot(from: from, toScreenPosition: to)
        // 图标数不变：无需同步条带几何，按新顺序（带让位动画）重建内容。
        rebuildContent(animated: true)
    }

    /// 编辑模式拖动中的让位预览：被拖图标的数组下标 + 屏幕插入位置 +
    /// 光标横坐标（紧凑带内容坐标）。三者任一为 nil 表示清空。
    ///
    /// 视图据此把每个图标画在**预览后的槽位**上，于是拖动过程中其余图标
    /// 会平滑让位；只有落点/被拖项变化时才写状态，避免每帧重启动画。
    func updateCompactReorderPreview(
        draggingSlot: Int?,
        screenPosition: Int?,
        pointerX: CGFloat?
    ) {
        guard let draggingSlot, let screenPosition else {
            if uiState.dropPreview != nil {
                withAnimation(NotchTokens.Motion.expand) {
                    uiState.dropPreview = nil
                }
            }
            return
        }
        let preview = PanelUIState.DropPreview(
            zone: .compact(index: screenPosition),
            isCompact: true,
            title: "",
            compactPointerX: pointerX,
            draggingSlotIndex: draggingSlot
        )
        // 光标横坐标每次都在变，只按“目标”比较，否则动画会被每帧重启。
        if let current = uiState.dropPreview, current.matchesTarget(of: preview) {
            uiState.dropPreview = preview
            return
        }
        withAnimation(NotchTokens.Motion.expand) {
            uiState.dropPreview = preview
        }
    }

    // MARK: 落点预览

    /// 把当前落点写进 `uiState`（抽屉网格的虚线占位 / 快速区的插入指示）。
    /// 传 nil 清空（拖拽取消或提交后）。`pointer` 为光标屏幕坐标，用于让
    /// 插入指示线跟随光标。
    func updateDropPreview(
        payload: BlockDragCoordinator.Payload?,
        zone: BlockDragCoordinator.DropZone?,
        pointer: NSPoint? = nil
    ) {
        guard let payload, let zone else {
            if uiState.dropPreview != nil {
                uiState.dropPreview = nil
            }
            applyDropPreviewWindowSize(nil)
            return
        }
        var pointerX: CGFloat?
        if case .compact = zone, let pointer, let pair = activePair {
            pointerX = compactContentX(pointer.x, pair: pair)
        }
        uiState.dropPreview = PanelUIState.DropPreview(
            zone: zone,
            isCompact: payload.isCompact,
            title: payload.displayName,
            compactPointerX: pointerX
        )
        // 落点在新行/新列时同步撑开面板：否则占位框被 ScrollView 裁掉。
        applyDropPreviewWindowSize(zone)
    }

    /// 抽屉内重排的落点预览：**只写虚线占位框，不写面板尺寸与左列**——
    /// 窗口尺寸与 `drawerGridLeftColumn`（含左扩）由 `applyDrawerDrag`
    /// 预览阶段内的 `applyPreviewWindowSize` 按同一份压实 origins 同帧
    /// 写入（推挤、增宽与全体块横移共用同一 spring）。本方法只负责占位框本身。
    ///
    /// `origin` / `span` 任一为 nil 表示清空（拖动结束或取消）；
    /// nil 分支保留 `applyDropPreviewWindowSize(nil)` 作松手复位兜底
    /// （提交后 `rebuildContent` 会再写正确值）。
    /// `origin` 取压实预览（`previewCommittedArrangement`）后**被拖块**的
    /// 最终原点，保证占位框与松手后的真实落点一致（所见即所得）。
    func updateDrawerReorderPreview(
        _ origin: LayoutEngine.GridOrigin?,
        span: GridSpan?
    ) {
        guard let origin, let span else {
            if uiState.dropPreview != nil {
                withAnimation(DrawerAnimation.spring) {
                    uiState.dropPreview = nil
                }
            }
            applyDropPreviewWindowSize(nil)
            return
        }
        let zone = BlockDragCoordinator.DropZone.drawer(
            column: origin.column,
            row: origin.row,
            columns: span.columns,
            rows: span.rows
        )
        let preview = PanelUIState.DropPreview(
            zone: zone,
            isCompact: false,
            title: "",
            isDrawerReorder: true
        )
        // 只按「目标」比较：否则每帧都会重启 spring（面板尺寸抖动）。
        if let current = uiState.dropPreview, current.matchesTarget(of: preview) {
            return
        }
        uiState.dropPreview = preview
    }

    /// 抽屉内重排的拖动目标 → 合法落点：列夹紧到引擎的合法区间
    /// （`dropTargetColumnBounds`，下界可为负——左扩内建），拖到左边界外
    /// 时格网实时向左扩展（`drawerGridLeftColumn` 由 `applyPreviewWindowSize`
    /// 同帧写入，全体块横移 + 面板重居中，代价已确认接受）。行只向下增长
    /// （网格不支持负行）。
    ///
    /// 预览与提交（`applyDrawerDrag` 的两个阶段）必须共用它，
    /// 否则占位框预示的落点会和真正落到的位置不一致。
    func clampedDropTarget(
        placementID: String,
        column: Int,
        row: Int
    ) -> (column: Int, row: Int) {
        let bounds = layoutEngine.dropTargetColumnBounds(placementID: placementID)
        return (
            min(max(column, bounds.lower), bounds.upper),
            max(row, 0)
        )
    }

    /// 「组件」页卡片上的 + 按钮：不拖拽时的快捷添加路径——紧凑块追加到
    /// 快速区末尾，抽屉网格块按插件声明的落点偏好放置（`NotchBlock.placement`：
    /// 默认自动寻空位，`.newPageWhenOccupied` 在当前页被占用时另开一页）。
    func addBlock(pluginID: String, blockID: String) {
        guard let block = pluginManager.block(pluginID: pluginID, blockID: blockID) else { return }
        switch block.kind {
        case .compact:
            _ = layoutEngine.addCompactBlock(pluginID: pluginID, blockID: blockID)
            refreshCompactGeometry()
        case .drawer:
            addDrawerBlock(pluginID: pluginID, blockID: blockID)
        }
        refreshAfterEdit()
    }

    /// 抽屉块落位：按 `placement` 分派；落到别的页时切过去。
    /// 页数已达上限且当前页非空时**直接失败并提示**，不自动清理任何页。
    private func addDrawerBlock(pluginID: String, blockID: String) {
        switch layoutEngine.addDrawerBlock(
            pluginID: pluginID,
            blockID: blockID,
            page: uiState.drawerActivePage
        ) {
        case let .placed(_, page):
            uiState.drawerActivePage = page
        case .noPageCapacity:
            warnDrawerPagesFull()
        case .unavailable:
            break
        }
    }

    /// 抽屉页已满（上限 9）且当前页非空时的提示。
    ///
    /// 这条路径由**设置窗口**的组件目录触发，而设置窗口打开期间抽屉常驻
    /// （`DrawerStayConditions.isSettingsPresented`），因此模态提示不会遇到
    /// 「抽屉先收起、弹窗悬空」的问题，沿用 `NSAlert` 即可（与删页确认不同）。
    /// 但必须经 `HostAlert` 抬到设置域之上：`NSAlert` 自己会退回
    /// `NSModalPanelWindowLevel`（8），不抬就被设置窗（101）压住。
    private func warnDrawerPagesFull() {
        let alert = NSAlert()
        alert.messageText = L("panel.page.add.fullTitle")
        alert.informativeText = LF(
            "panel.page.add.fullBody",
            LayoutModel.maxDrawerPageCount
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("common.ok"))
        HostAlert.runModal(alert)
    }

    /// 「组件」页快捷按钮卡的快捷添加路径：追加一个快捷动作槽位到快速区
    /// 末尾（与旧「紧凑块单击追加」同一心智；拖拽仍是装盒/精确定位的手段）。
    func addQuickAction(pluginID: String, actionID: String) {
        guard pluginManager.entry(for: pluginID)?.isEnabled == true else { return }
        _ = layoutEngine.addQuickActionSlot(pluginID: pluginID, actionID: actionID)
        refreshCompactGeometry()
        refreshAfterEdit()
    }

    // MARK: 落位

    /// 提交拖拽结果：快速区插入（随后同步条带几何与热区窗口），
    /// 或抽屉网格落位（随后按编辑刷新重建内容）。
    ///
    /// `beforeRefresh` 拿到新块的 placementID，**早于** `refreshAfterEdit()`
    /// 调用——调用方借此在内容重建前把该块标记为落位飞行中
    /// （`uiState.landingPlacementID`，渲染为 `opacity(0)`），让跟手浮窗
    /// 独占飞行期间的画面。默认 nil，自动化探针因此完全不受影响。
    func performBlockDrop(
        _ payload: BlockDragCoordinator.Payload,
        to zone: BlockDragCoordinator.DropZone,
        beforeRefresh: ((String) -> Void)? = nil
    ) {
        switch zone {
        case let .compact(index):
            // 纯动作卡（统一快捷按钮、无块身份）→ 快捷动作槽位；块卡照旧走
            // 紧凑块校验插入（第三方插件仍可注册自带视图的紧凑块）。
            if payload.blockID.isEmpty, let actionID = payload.actionID {
                guard layoutEngine.insertQuickActionSlot(
                    pluginID: payload.pluginID,
                    actionID: actionID,
                    atScreenPosition: index
                ) else { return }
                // 快速区不做落位飞行：沿用现有的插入动画。
                refreshCompactGeometry()
                refreshAfterEdit()
                return
            }
            guard layoutEngine.insertCompactBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                atScreenPosition: index
            ) else { return }
            // 快速区不做落位飞行：把大块缩成 28×28 图标飞过去观感很怪，
            // 沿用现有的插入动画。不回调 beforeRefresh 即走该分支。
            refreshCompactGeometry()
            refreshAfterEdit()
        case let .drawer(column, row, _, _):
            guard let placed = layoutEngine.placeDrawerBlock(
                pluginID: payload.pluginID,
                blockID: payload.blockID,
                column: column,
                row: row,
                page: uiState.drawerActivePage
            ) else { return }
            beforeRefresh?(placed.placementID)
            refreshAfterEdit()
        }
    }

    // MARK: 胶囊驻留切页（设置面板拖组件跨页）

    /// 屏幕点命中的分页胶囊（返回页身份）：**仅**供拖拽驻留切页判定。
    ///
    /// 纵向命中带取整条顶栏（紧凑带之下、网格顶缘之上）——顶栏本就不收
    /// 落点（`DrawerDropPolicy.Region.topBar`），驻留目标又是"大致指到
    /// 某颗胶囊"，命中面宜宽。横向按 `DrawerPagePillLayout` 的定宽槽位
    /// 数学就近取槽；胶囊行居中于顶栏中线，编辑模式顶栏左侧多一颗
    /// "一键重排"使行心右移，由 `rowCenterOffset(isEditing:)` 补偿。
    ///
    /// 滑动会话期不命中：会话中条带在两页间位移，胶囊行的页身份与
    /// 屏幕位置都会变，此时驻留切页会把会话踩断。
    func drawerPageCapsuleHitTest(at point: NSPoint) -> Int? {
        guard isExpanded, let pair = activePair, uiState.drawerSwipe == nil else {
            if BlockDragCoordinator.dragProbeLogEnabled {
                print("[drag-probe] capsuleHit early-nil: expanded=\(isExpanded) pair=\(activePair != nil) swipe=\(uiState.drawerSwipe != nil)")
            }
            return nil
        }
        let mapper = drawerScreenMapper(for: pair)
        let bandTop = mapper.visibleFrame.maxY - pair.layout.compactHeight
        guard point.y >= mapper.gridTopEdgeY, point.y <= bandTop else {
            if BlockDragCoordinator.dragProbeLogEnabled {
                print("[drag-probe] capsuleHit band-miss: point=\(point) band=[\(mapper.gridTopEdgeY), \(bandTop)]")
            }
            return nil
        }
        let pages = uiState.drawerPages
        let regionWidth = uiState.drawerCapsuleRegionWidth
        let centerX = mapper.visibleFrame.midX
            + DrawerPagePillLayout.rowCenterOffset(isEditing: uiState.isEditing)
        let rowLeft: CGFloat
        if regionWidth > 0 {
            // 滚动区内才命中：行溢出时行坐标会盖到两侧按钮组上，不挡住就是
            // 把"拖块到齿轮上"也算成驻留某颗胶囊。
            let regionLeft = centerX - regionWidth / 2
            guard point.x >= regionLeft, point.x <= regionLeft + regionWidth else {
                if BlockDragCoordinator.dragProbeLogEnabled {
                    print("[drag-probe] capsuleHit outside-region: point=\(point) region=[\(regionLeft), +\(regionWidth)]")
                }
                return nil
            }
            // 行左缘 = 区内自然位置（放得下居中 / 溢出左对齐）− 滚动偏移：
            // 行被滚走时胶囊的屏幕位置随之平移，命中必须跟同一份偏移。
            rowLeft = regionLeft + DrawerPagePillLayout.rowLeftInRegion(
                regionWidth: regionWidth,
                pageCount: pages.count,
                offset: uiState.drawerCapsuleScrollOffset
            )
        } else {
            // 宽度尚未发布（视图还没量到）：退回居中口径，行为与加滚动前一致。
            rowLeft = centerX - DrawerPagePillLayout.rowWidth(pageCount: pages.count) / 2
        }
        let slot = DrawerPagePillLayout.hoveredSlot(
            x: point.x,
            rowLeft: rowLeft,
            pageCount: pages.count
        )
        let page = slot.flatMap { pages[$0] }
        if BlockDragCoordinator.dragProbeLogEnabled {
            print("[drag-probe] capsuleHit: point=\(point) row=[\(rowLeft), +\(DrawerPagePillLayout.rowWidth(pageCount: pages.count))] center=\(centerX) region=\(regionWidth) offset=\(uiState.drawerCapsuleScrollOffset) pages=\(pages) editing=\(uiState.isEditing) slot=\(slot.map(String.init) ?? "nil") page=\(page.map(String.init) ?? "nil")")
        }
        return page
    }

    /// 提交「快捷动作」拖拽落位：把动作交给目标容器块所属插件实例
    /// （`NotchCenterQuickActionSink.acceptQuickAction`），由它自行校验容量并
    /// 持久化到该放置实例的作用域存储；接受与否不改变布局（虚线框整格套住
    /// 容器块只是目标指示）。被拒（盒已满等）时系统提示音。
    ///
    /// 落点 zone 是 `.drawer(…容器块整格…)`：用当前页渲染元素反查放置实例，
    /// 与 `quickActionBoxDropZone` 同一数据源（`uiState.drawerElements`）。
    func performQuickActionDrop(
        _ payload: BlockDragCoordinator.Payload,
        to zone: BlockDragCoordinator.DropZone
    ) {
        guard let actionID = payload.actionID,
              let container = sinkContainer(at: zone) else { return }
        // 交给容器块所属插件实例自行校验容量并持久化到该放置实例的作用域存储；
        // 接受与否不改变布局（虚线框整格套住容器块只是目标指示）。
        let accepted = container.sink.acceptQuickAction(
            actionID,
            placementID: container.placement.placementID,
            span: container.span
        )
        if accepted {
            // 动作集已变：内容重建（动画）刷新盒视图；布局与窗口尺寸不变。
            refreshAfterEdit()
        } else {
            // 盒已满等拒绝：提示音，不做任何改动。
            NSSound.beep()
        }
    }
}
