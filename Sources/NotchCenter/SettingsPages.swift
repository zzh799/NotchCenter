import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 设置页面（通用 / 组件 / 布局）

// MARK: 通用

struct GeneralSettingsPage: View {
    let controller: NotchPanelController
    @ObservedObject var settingsStore: SettingsStore

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: L("settings.section.interaction")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("settings.triggerMode"))
                            .font(NotchTokens.Text.system(12))
                            .foregroundStyle(.white.opacity(0.72))
                        Picker("", selection: $settingsStore.triggerMode) {
                            ForEach(SettingsStore.TriggerMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }

                SettingsSection(title: L("settings.section.general")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: launchAtLoginBinding) {
                            Text(L("settings.launchAtLogin"))
                                .font(NotchTokens.Text.system(12))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        if let hint = launchAtLoginHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsSection(title: L("settings.language")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $settingsStore.languageOverride) {
                            Text(L("language.system")).tag(SettingsStore.LanguageOverride.system)
                            Text("简体中文").tag(SettingsStore.LanguageOverride.simplifiedChinese)
                            Text("English").tag(SettingsStore.LanguageOverride.english)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        if settingsStore.languageOverride != .system {
                            Text(L("language.restartHint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 开机自启（SMAppService）

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginError = nil
                } catch {
                    // 注册失败后回读真实状态，避免开关与系统不一致。
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }

    /// 开发态裸二进制无法注册登录项；或注册出错时给出提示。
    private var launchAtLoginHint: String? {
        if let launchAtLoginError {
            return LF("settings.launchAtLogin.error", launchAtLoginError)
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            return L("settings.launchAtLogin.devHint")
        }
        return nil
    }
}

// MARK: 组件（按插件分组 + 二级侧边导航 + 拖拽到抽屉/快速区）

/// 目录条目：块身份 + 预览视图 + 拖拽载荷。
///
/// `quickActionID` 非 nil 表示该块卡与插件注册的某动作**合一**（动作的
/// `sourceBlockID` 指向本块）：这张卡拖到快速区/抽屉摆块、拖到快捷按钮盒则
/// 装填该动作（块+动作双身份，见 `BlockDragCoordinator.Payload`）。
struct ComponentCatalogItem: Identifiable {
    let pluginID: String
    let blockID: String
    let displayName: String
    let symbolName: String?
    let isCompact: Bool
    /// 默认跨度（抽屉块）；紧凑块为 1×1。
    let span: GridSpan
    let preview: AnyView
    /// 与该块点击同义、可被快捷按钮盒收纳的动作 ID；nil = 纯块卡。
    let quickActionID: String?

    var id: String { pluginID + "." + blockID }

    /// 跟手浮窗的 1:1 像素尺寸：抽屉块按默认跨度的格网尺寸，
    /// 紧凑块按刘海两侧的槽位尺寸。
    var previewSize: CGSize {
        isCompact
            ? CGSize(
                width: NotchGeometry.compactSlotSize.width,
                height: NotchGeometry.compactSlotSize.height
            )
            : CGSize(
                width: NotchGridMetrics.contentWidth(columns: span.columns),
                height: NotchGridMetrics.contentHeight(rows: span.rows)
            )
    }

    var payload: BlockDragCoordinator.Payload {
        BlockDragCoordinator.Payload(
            pluginID: pluginID,
            blockID: blockID,
            kind: isCompact ? .compact : .drawer,
            displayName: displayName,
            symbolName: symbolName,
            span: span,
            preview: BlockDragCoordinator.DragPreviewContent(
                view: preview,
                size: previewSize
            ),
            actionID: quickActionID
        )
    }
}

struct ComponentCatalogGroup: Identifiable {
    let pluginID: String
    let displayName: String
    let compactItems: [ComponentCatalogItem]
    let drawerItems: [ComponentCatalogItem]

    var id: String { pluginID }
    var count: Int { compactItems.count + drawerItems.count }
}

/// 预览视图构建：与抽屉同一渲染管线（`makeView(BlockContext)`），
/// placementID 用固定合成值——同类型预览共享一份放置实例作用域，
/// 与 Size Lab 的对照渲染一致（不因反复打开设置面板而堆积实例）。
@MainActor
enum ComponentCatalogBuilder {
    static func build(
        pluginManager: PluginManager,
        hostController: any HostController
    ) -> [ComponentCatalogGroup] {
        pluginManager.entries
            .filter { $0.isEnabled && $0.instance != nil }
            .compactMap { entry -> ComponentCatalogGroup? in
                guard let store = entry.stateStore else { return nil }
                var compactItems: [ComponentCatalogItem] = []
                var drawerItems: [ComponentCatalogItem] = []

                for block in entry.blocks {
                    let span = preferredSpan(for: block)
                    let placementID = previewPlacementID(pluginID: entry.id, blockID: block.id)
                    let frame = CGRect(
                        x: 0,
                        y: 0,
                        width: NotchGridMetrics.contentWidth(columns: span.columns),
                        height: NotchGridMetrics.contentHeight(rows: span.rows)
                    )
                    let context = BlockContext(
                        pluginID: entry.id,
                        blockID: block.id,
                        placementID: placementID,
                        stateStore: store,
                        hostController: hostController,
                        layoutInfo: BlockLayoutInfo(
                            region: block.kind == .compact ? .compact : .drawer,
                            placementID: placementID,
                            frame: frame,
                            size: block.kind == .compact ? nil : span,
                            originColumn: 0,
                            originRow: 0,
                            widthColumns: span.columns,
                            heightRows: span.rows,
                            isEditing: false,
                            compactSlotIndex: nil
                        )
                    )
                    // 块+动作合一：动作的 sourceBlockID 指向本块时，块卡携带该
                    // 动作身份（拖到盒上装填动作），避免同入口在目录出现两份。
                    let actions = entry.instance?.quickActions ?? []
                    let item = ComponentCatalogItem(
                        pluginID: entry.id,
                        blockID: block.id,
                        displayName: block.displayName,
                        symbolName: block.symbolName,
                        isCompact: block.kind == .compact,
                        span: span,
                        preview: block.makeView(context),
                        quickActionID: ComponentCatalogMerger.actionID(
                            for: block.id,
                            in: actions
                        )
                    )
                    if block.kind == .compact {
                        compactItems.append(item)
                    } else {
                        drawerItems.append(item)
                    }
                }

                guard !compactItems.isEmpty || !drawerItems.isEmpty else { return nil }
                return ComponentCatalogGroup(
                    pluginID: entry.id,
                    displayName: entry.metadata.displayName,
                    compactItems: compactItems,
                    drawerItems: drawerItems
                )
            }
    }

    /// 预览用跨度：抽屉块取推荐尺寸（优先显示档；物理像素按**当前格子**换算成
    /// 格跨）；紧凑块（无尺寸声明）回退 1×1。
    private static func preferredSpan(for block: NotchBlock) -> GridSpan {
        if block.kind == .compact {
            return GridSpan.globalMinimum
        }
        return block.sizeBox(
            cellWidth: NotchGridMetrics.cellWidth,
            cellHeight: NotchGridMetrics.cellHeight
        )?.recommended ?? GridSpan.globalMinimum
    }

    /// 合成放置实例 ID：必须是合法 StateStore 键（仅字母数字与 . _ -）。
    private static func previewPlacementID(pluginID: String, blockID: String) -> String {
        "settings-preview." + sanitized(pluginID) + "." + sanitized(blockID)
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .map(String.init)
            .joined()
    }
}

/// 块卡与动作的合一规则（文档 §4.11）：动作 `sourceBlockID` 指向本插件的某块
/// 时，该动作并入块卡（块卡双身份）；未被任何块吸收的动作作为**独立「盒用
/// 动作」卡**展示。纯逻辑、可单测。`QuickAction` 是 @MainActor，本类型同隔离。
@MainActor
enum ComponentCatalogMerger {
    /// 某块是否命中一条 `sourceBlockID` 指向它的动作：是则返回该动作 ID。
    /// 同块多条指向时取第一条（插件应保证语义唯一）。
    static func actionID(for blockID: String, in actions: [QuickAction]) -> String? {
        actions.first { $0.sourceBlockID == blockID }?.id
    }

    /// 未被本插件块吸收的独立动作（`sourceBlockID == nil`，或指向了不存在的
    /// 块——防御插件改名后遗留）：它们以独立卡展示，供拖入快捷按钮盒。
    static func standaloneActions(
        _ actions: [QuickAction],
        blockIDs: some Sequence<String>
    ) -> [QuickAction] {
        let knownBlocks = Set(blockIDs)
        return actions.filter { action in
            guard let source = action.sourceBlockID else { return true }
            return !knownBlocks.contains(source)
        }
    }
}

/// 独立「盒用动作」目录分组（文档 §4.11）：按来源插件归组，只含**未被块卡
/// 吸收**的动作（已合一进块卡的动作不再单列，见 `ComponentCatalogMerger`）。
struct QuickActionCatalogGroup: Identifiable {
    let pluginID: String
    let displayName: String
    let actions: [QuickAction]

    var id: String { pluginID }
}

/// 独立动作目录构建：读已启用插件的 `quickActions`（动作实例缓存于插件上，
/// 身份稳定），过滤掉与块合一的部分，其余按插件归组，供渲染进该插件的组件
/// 分区。动作不随布局变，只在插件启用/禁用时增删——`ComponentsSettingsPage`
/// 的 pluginSignature 已覆盖。
@MainActor
enum QuickActionCatalogBuilder {
    static func build(pluginManager: PluginManager) -> [QuickActionCatalogGroup] {
        pluginManager.entries
            .filter { $0.isEnabled && $0.instance != nil }
            .compactMap { entry -> QuickActionCatalogGroup? in
                let actions = entry.instance?.quickActions ?? []
                let standalone = ComponentCatalogMerger.standaloneActions(
                    actions,
                    blockIDs: entry.blocks.map(\.id)
                )
                guard !standalone.isEmpty else { return nil }
                return QuickActionCatalogGroup(
                    pluginID: entry.id,
                    displayName: entry.metadata.displayName,
                    actions: standalone
                )
            }
    }
}

struct ComponentsSettingsPage: View {
    let controller: NotchPanelController
    @ObservedObject private var pluginManager: PluginManager

    @State private var groups: [ComponentCatalogGroup] = []
    @State private var quickActionGroups: [QuickActionCatalogGroup] = []
    @State private var signature = ""

    init(controller: NotchPanelController) {
        self.controller = controller
        self.pluginManager = controller.pluginManager
    }

    var body: some View {
        HStack(spacing: 0) {
            pluginSidebar
                .frame(width: 168)

            Divider().overlay(.white.opacity(0.06))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    hint
                    ForEach(groups) { group in
                        groupSection(group)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: CatalogSectionFrameKey.self,
                                        value: [group.id: geo.frame(in: .named(Self.catalogSpace)).minY]
                                    )
                                }
                            )
                    }
                    if groups.isEmpty {
                        Text(L("settings.components.empty"))
                            .font(NotchTokens.Text.system(12))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 40)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: Self.catalogSpace)
            .scrollPosition(id: $scrollPositionID)
            .onPreferenceChange(CatalogSectionFrameKey.self) { frames in
                // 反向同步：分区实时上报视口内 minY，据此推导顶缘所在分组。
                // 不读 scrollPosition 绑定——macOS 下用户滚动不会回填它。
                guard !frames.isEmpty else {
                    topVisibleGroupID = nil
                    return
                }
                let reached = frames.filter { $0.value <= Self.sectionAnchorY }
                let topID = reached.max(by: { $0.value < $1.value })?.key
                    ?? frames.min(by: { $0.value < $1.value })?.key
                if topID != topVisibleGroupID {
                    topVisibleGroupID = topID
                }
                guard let topID,
                      topID != selectedPluginID,
                      Date.now >= reverseSyncHoldUntil
                else { return }
                selectedPluginID = topID
            }
        }
        .onAppear(perform: rebuildIfNeeded)
        .onChange(of: pluginSignature) { _, newValue in
            guard newValue != signature else { return }
            rebuildIfNeeded()
        }
    }

    // MARK: 二级侧边导航（插件列表）

    @State private var selectedPluginID: String?
    /// 跳转写入位：侧边栏点击写入以滚动目录。macOS 下用户滚动不回填该绑定，
    /// 读取侧由 CatalogSectionFrameKey 偏好追踪承担。
    @State private var scrollPositionID: String?
    /// 目录顶缘当前所在分组，用于反向同步与重复点击回滚。
    @State private var topVisibleGroupID: String?
    /// 程序化跳转的回写抑制截止时刻，挡住动画途经的中间分区。
    @State private var reverseSyncHoldUntil = Date.distantPast

    private static let catalogSpace = "componentsCatalogSpace"
    /// 分区归属线：分组顶缘越过视口顶部该深度即视为「顶缘分区」。
    private static let sectionAnchorY: CGFloat = 24

    /// 侧边栏行点击：选中该插件分组，并把目录滚到对应分区顶。
    /// 重复点击已选中行时，绑定值可能因用户滚动与实际位置脱节（同值
    /// 赋值不触发滚动），先写入当前顶缘分组再二次写入强制触发。
    private func selectPlugin(_ group: ComponentCatalogGroup) {
        selectedPluginID = group.id
        reverseSyncHoldUntil = .now.addingTimeInterval(0.3)
        if scrollPositionID == group.id, let current = topVisibleGroupID, current != group.id {
            scrollPositionID = current
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollPositionID = group.id
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPositionID = group.id
            }
        }
    }

    private var pluginSidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L("settings.components.groups"))
                .font(NotchTokens.Text.system(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(groups) { group in
                        pluginRow(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(Color.white.opacity(0.015))
    }

    private func pluginRow(_ group: ComponentCatalogGroup) -> some View {
        let isSelected = selectedPluginID == group.id
        return Button {
            selectPlugin(group)
        } label: {
            HStack(spacing: 6) {
                Text(group.displayName)
                    .font(NotchTokens.Text.system(11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.count)")
                    .font(NotchTokens.Text.system(10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .font(NotchTokens.Text.system(11, weight: .semibold))
            Text(L("settings.components.hint"))
                .font(NotchTokens.Text.system(11.5))
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    private func groupSection(_ group: ComponentCatalogGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.displayName)
                .font(NotchTokens.Text.system(13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            // 快捷按钮与抽屉组件合并到同一网格混排（紧凑块在前），
            // 类型区分靠卡片名称行的「快捷按钮 / N×N」标注。
            let items = group.compactItems + group.drawerItems
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156, maximum: 200), spacing: 12)],
                spacing: 12
            ) {
                ForEach(items) { item in
                    ComponentCard(item: item) {
                        controller.addBlock(pluginID: item.pluginID, blockID: item.blockID)
                    }
                }
            }

            // 快捷按钮（可进快速区 / 可收纳进按钮盒的统一动作卡）：与块卡同一
            // 分区、卡片下方一段。图标行卡与块预览卡样式天然可辨，不再重复
            // 分区标题。单击 = 加入快速区末尾；按住拖到快速区精确定位、拖到
            // 「快捷按钮盒」上装填。
            if let standalone = standaloneActions(for: group.pluginID), !standalone.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 12)],
                    spacing: 10
                ) {
                    ForEach(standalone) { action in
                        QuickActionCard(
                            action: action,
                            pluginID: group.pluginID,
                            sourceName: L("settings.components.quickActions.cardHint"),
                            onAdd: {
                                controller.addQuickAction(
                                    pluginID: group.pluginID,
                                    actionID: action.id
                                )
                            }
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// 该插件分区内需要单列的「盒用动作」（未被块卡吸收的独立动作）。
    private func standaloneActions(for pluginID: String) -> [QuickAction]? {
        quickActionGroups.first { $0.pluginID == pluginID }?.actions
    }

    // MARK: 构建

    private var pluginSignature: String {
        pluginManager.entries
            .map { "\($0.id):\($0.isEnabled ? 1 : 0):\($0.instance != nil ? 1 : 0)" }
            .joined(separator: ",")
    }

    private func rebuildIfNeeded() {
        signature = pluginSignature
        groups = ComponentCatalogBuilder.build(
            pluginManager: pluginManager,
            hostController: controller
        )
        quickActionGroups = QuickActionCatalogBuilder.build(pluginManager: pluginManager)
        guard !groups.contains(where: { $0.id == selectedPluginID }) else { return }
        if selectedPluginID == nil {
            // 首次构建：默认高亮第一组，不动滚动位置，保住顶部提示条可见。
            selectedPluginID = groups.first?.id
        } else {
            // 原选中分组消失（插件被关闭/卸载）：回退第一组并同步定位。
            selectedPluginID = groups.first?.id
            guard let fallback = selectedPluginID else { return }
            reverseSyncHoldUntil = .now.addingTimeInterval(0.25)
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPositionID = fallback
            }
        }
    }
}

/// 组件目录各分区在视口坐标系内的 minY 上报，反向同步的数据源。
private struct CatalogSectionFrameKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// 组件卡片：极简展示——真实块预览 + 名称 + 尺寸，无边框与底色。
/// 单击添加；按住拖动（位移 > 4px）到抽屉/快速区。
private struct ComponentCard: View {
    let item: ComponentCatalogItem
    let onAdd: () -> Void

    @State private var isHovering = false
    @ObservedObject private var dragCoordinator = BlockDragCoordinator.shared

    private let previewHeight: CGFloat = 96
    private let previewWidth: CGFloat = 148

    var body: some View {
        // 名称/尺寸与预览居中对齐：预览在卡片内水平居中，文字随之居中。
        VStack(alignment: .center, spacing: 8) {
            preview
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity, alignment: .center)
                .brightness(isHovering ? 0.08 : 0)

            VStack(alignment: .center, spacing: 2) {
                Text(item.displayName)
                    .font(NotchTokens.Text.system(11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.86))
                    .lineLimit(1)
                Text(item.isCompact ? L("settings.components.compact") : spanText)
                    .font(NotchTokens.Text.system(9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 单击添加（短按不会满足长按序列，两者互不干扰）。
        .onTapGesture(perform: onAdd)
        // 按住拖动起手：位移超过 4px 即进入拖拽会话（幂等），
        // 会话跟踪与提交由 BlockDragCoordinator 的事件监听器兜底。
        // 不用"长按序列"起手：长按要求按住静止 0.3s，按下即拖（自然习惯）
        // 会被判定长按失败而整条手势不启动；位移阈值起手没有这个死区，
        // highPriorityGesture 同时压过 ScrollView 对鼠标拖动的竞争。
        // 位移 < 4px 的短按不触发本手势，仍走 onTapGesture 的"单击添加"，
        // 两者天然互斥。
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    BlockDragCoordinator.shared.beginIfNeeded(item.payload)
                }
                .onEnded { _ in
                    BlockDragCoordinator.shared.commit()
                }
        )
        // 合一块卡角标：这张卡与某快捷动作同义，除快速区/抽屉外还可拖入
        // 「快捷按钮盒」收纳（原件保留，盒与原件共享同一份状态）。
        .overlay(alignment: .topTrailing) {
            if item.quickActionID != nil {
                Image(systemName: "square.grid.3x3")
                    .font(NotchTokens.Text.system(9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(5)
                    .background(
                        Circle()
                            .fill(NotchTokens.Surface.window.opacity(0.92))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    )
                    .padding(6)
                    .help(L("settings.components.quickActions.boxable"))
            }
        }
        .opacity(dragCoordinator.payload == item.payload ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// 预览：按默认跨度渲染真实块视图，等比缩放进卡片预览区。
    private var preview: some View {
        let size = CGSize(
            width: item.isCompact ? NotchGeometry.compactSlotSize.width
                : NotchGridMetrics.contentWidth(columns: item.span.columns),
            height: item.isCompact ? NotchGeometry.compactSlotSize.height
                : NotchGridMetrics.contentHeight(rows: item.span.rows)
        )
        let scale = min(
            1,
            min(previewWidth / max(size.width, 1), previewHeight / max(size.height, 1))
        )
        return item.preview
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .allowsHitTesting(false)
    }

    private var spanText: String {
        "\(item.span.columns)×\(item.span.rows)"
    }
}

/// 快捷按钮卡片（统一样式）：动作图标 + 名称 + 去向提示。单击 = 加入快速区
/// 末尾；按住拖到快速区精确定位、或拖到抽屉里的「快捷按钮盒」装填。复用
/// `BlockDragCoordinator` 会话：载荷带 `pluginID` + `actionID`，落点判定按
/// 「快速区插入 / 容器盒装填」分流。
private struct QuickActionCard: View {
    let action: QuickAction
    let pluginID: String
    let sourceName: String
    let onAdd: () -> Void

    @State private var isHovering = false
    @ObservedObject private var dragCoordinator = BlockDragCoordinator.shared

    var body: some View {
        HStack(spacing: 8) {
            QuickActionTile(
                systemImage: action.systemImage,
                isActive: action.kind == .toggle && action.isActive,
                symbolSize: 12,
                sideLength: 26,
                cornerRadius: 7
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(action.displayName)
                    .font(NotchTokens.Text.system(11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.85))
                    .lineLimit(1)
                Text(sourceName)
                    .font(NotchTokens.Text.system(9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(NotchTokens.Text.system(10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.5 : 0.3))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.14 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 单击快捷添加（短按不会满足拖拽序列，两者互不干扰）。
        .onTapGesture(perform: onAdd)
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    BlockDragCoordinator.shared.beginIfNeeded(payload)
                }
                .onEnded { _ in
                    BlockDragCoordinator.shared.commit()
                }
        )
        .opacity(dragCoordinator.payload == payload ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var payload: BlockDragCoordinator.Payload {
        BlockDragCoordinator.Payload(
            pluginID: pluginID,
            quickActionID: action.id,
            displayName: action.displayName,
            symbolName: action.systemImage.isEmpty ? "bolt.fill" : action.systemImage
        )
    }
}

// MARK: 布局

struct LayoutSettingsPage: View {
    let controller: NotchPanelController
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject private var layoutEngine: LayoutEngine
    @ObservedObject private var metrics = GridMetricsStore.shared

    init(controller: NotchPanelController, settingsStore: SettingsStore) {
        self.controller = controller
        self.settingsStore = settingsStore
        self.layoutEngine = controller.layoutEngine
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                cellSection
                spacingSection
                columnsSection
                minimumSection
                previewSection
                restoreSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 分节内容

    private var cellSection: some View {
        SettingsSection(title: L("settings.layout.cell")) {
            MetricsSlider(title: L("settings.layout.cellWidth"), metric: .cellWidth)
            MetricsSlider(title: L("settings.layout.cellHeight"), metric: .cellHeight)
        }
    }

    private var spacingSection: some View {
        SettingsSection(title: L("settings.layout.spacingSection")) {
            MetricsSlider(title: L("settings.layout.spacing"), metric: .spacing)
            MetricsSlider(title: L("settings.layout.padding"), metric: .contentPadding)
        }
    }

    private var columnsSection: some View {
        SettingsSection(title: L("settings.layout.columnsSection")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(L("settings.columns"))
                        .font(NotchTokens.Text.system(12))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 76, alignment: .leading)
                    ColumnRangeSlider(
                        minValue: min(layoutEngine.userMinColumns, layoutEngine.userMaxColumns),
                        maxValue: layoutEngine.userMaxColumns,
                        onMinChange: { newValue in
                            layoutEngine.setUserMinColumns(newValue)
                            controller.refreshAfterLayoutChange(animated: true)
                        },
                        onMaxChange: { newValue in
                            layoutEngine.setUserMaxColumns(newValue)
                            controller.refreshAfterLayoutChange(animated: true)
                        }
                    )
                }
                Text(LF("settings.layout.effectiveColumns", layoutEngine.effectiveMaxColumns()))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if layoutEngine.userMaxColumns < LayoutModel.minColumnsRange.lowerBound {
                    Text(L("settings.layout.minColumnsUnavailable"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var minimumSection: some View {
        SettingsSection(title: L("settings.layout.minSection")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(L("settings.layout.minRows"))
                        .font(NotchTokens.Text.system(12))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer(minLength: 0)
                    Picker("", selection: minRowsBinding) {
                        ForEach(Array(LayoutModel.minRowsRange), id: \.self) { rows in
                            Text(LF("settings.layout.minRow.count", rows)).tag(rows)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                Text(L("settings.layout.minHint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewSection: some View {
        SettingsSection(title: L("settings.layout.previewSection")) {
            GridMetricsPreview()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var restoreSection: some View {
        HStack(spacing: 10) {
            Button(L("settings.layout.restoreDefault")) {
                metrics.resetToDefaults()
            }
            .disabled(metrics.isDefault)
            Text(metrics.isDefault ? L("settings.layout.isDefault") : "")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var minRowsBinding: Binding<Int> {
        Binding(
            get: { layoutEngine.userMinRows },
            set: { newValue in
                layoutEngine.setUserMinRows(newValue)
                controller.refreshAfterLayoutChange(animated: true)
            }
        )
    }
}

/// 单条指标调节：滑杆 + 数字输入框（同一钳制区间，改动即时生效）。
private struct MetricsSlider: View {
    let title: String
    let metric: GridMetricsStore.Metric
    @ObservedObject private var store = GridMetricsStore.shared

    var body: some View {
        let range = GridMetricsStore.range(for: metric)
        HStack(spacing: 12) {
            Text(title)
                .font(NotchTokens.Text.system(12))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 76, alignment: .leading)
            sliderControl(range)
            numberField
        }
    }

    /// 连续滑杆 + setter 内四舍五入。不用 `Slider(step: 1)`：macOS 桥接会按
    /// 区间格数生成 tick marks（cellWidth 区间 191 格），四条滑杆的首帧挂载
    /// 合计 ~120ms，正是设置面板「组件页 → 布局页」卡顿的主因；连续滑杆 +
    /// 取整（1pt 量化远小于可视像素）手感无差别、首帧挂载接近零成本。
    private func sliderControl(_ range: ClosedRange<CGFloat>) -> some View {
        Slider(
            value: Binding(
                get: { Double(store.value(for: metric)) },
                set: {
                    let clamped = min(max($0, Double(range.lowerBound)), Double(range.upperBound))
                    store.set(metric, to: CGFloat(clamped.rounded()))
                }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound)
        )
    }

    private var numberField: some View {
        TextField(
            "",
            value: store.binding(for: metric),
            format: .number.precision(.fractionLength(0))
        )
        .multilineTextAlignment(.trailing)
        .frame(width: 48)
        .textFieldStyle(.roundedBorder)
        .font(NotchTokens.Text.system(11).monospacedDigit())
    }
}

/// 指标示意：按当前单元大小 / 间隔画两行三列的格网缩略，调参时直观对照。
private struct GridMetricsPreview: View {
    @ObservedObject private var store = GridMetricsStore.shared

    private let columns = 3
    private let rows = 2
    private let canvasWidth: CGFloat = 300

    var body: some View {
        let scale = min(
            1,
            canvasWidth / max(NotchGridMetrics.contentWidth(columns: columns), 1)
        )
        return ZStack(alignment: .topLeading) {
            ForEach(0..<(columns * rows), id: \.self) { index in
                let column = index % columns
                let row = index / columns
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
                    .frame(
                        width: store.cellWidth,
                        height: store.cellHeight
                    )
                    .offset(
                        x: CGFloat(column) * (store.cellWidth + store.spacing),
                        y: CGFloat(row) * (store.cellHeight + store.spacing)
                    )
            }
        }
        .frame(
            width: NotchGridMetrics.contentWidth(columns: columns) * scale,
            height: NotchGridMetrics.contentHeight(rows: rows) * scale
        )
        .scaleEffect(scale, anchor: .topLeading)
        .overlay(alignment: .bottomLeading) {
            Text(
                LF(
                    "settings.layout.previewCaption",
                    Int(store.cellWidth),
                    Int(store.cellHeight),
                    Int(store.spacing)
                )
            )
            .font(NotchTokens.Text.system(10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.4))
            .offset(y: 16)
        }
        .padding(.bottom, 18)
    }
}

// MARK: - 通用分区容器

/// 设置分区：标题 + 内容（统一间距，替代 Form 的系统样式）。
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(NotchTokens.Text.system(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 调试

/// 调试页：调整设置面板窗口尺寸（即时生效、跨启动持久化）。滑杆 + 数字
/// 输入框交互与布局页 MetricsSlider 同款——连续滑杆 + setter 内取整的
/// 性能结论也一并沿用（`Slider(step:)` 的 tick marks 挂载成本）。
struct DebugSettingsPage: View {
    let controller: NotchPanelController
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(title: L("settings.debug.windowSize")) {
                    VStack(alignment: .leading, spacing: 10) {
                        sizeSlider(
                            title: L("settings.debug.width"),
                            range: SettingsWindowMetrics.widthRange,
                            value: $settingsStore.settingsWindowWidth
                        )
                        sizeSlider(
                            title: L("settings.debug.height"),
                            range: SettingsWindowMetrics.heightRange,
                            value: $settingsStore.settingsWindowHeight
                        )
                        Text(L("settings.debug.hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                #if DEBUG
                sizeLabSection
                #endif
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 块尺寸对照实验室入口（仅 DEBUG 构建）：同一组件在全部跨度档下的
    /// 批量并排对比，手动打开不再随 run 直开。
    #if DEBUG
    private var sizeLabSection: some View {
        SettingsSection(title: L("settings.debug.sizeLab")) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    controller.showSizeLab()
                } label: {
                    Text(L("settings.debug.sizeLab.open"))
                        .font(NotchTokens.Text.system(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                Text(L("settings.debug.sizeLab.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif

    private func sizeSlider(
        title: String,
        range: ClosedRange<CGFloat>,
        value: Binding<CGFloat>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(NotchTokens.Text.system(12))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 76, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: {
                        value.wrappedValue = CGFloat($0.rounded())
                        controller.applySettingsWindowSize()
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            // 显式 Binding<Double>：`TextField(_:value:format:)` 有多个
            // 重载，不标注会被推到 Optional 变体（setter 收到 Double?）。
            TextField(
                "",
                value: Binding<Double>(
                    get: { Double(value.wrappedValue) },
                    set: { newValue in
                        // 输入框放行任意输入，钳制统一在
                        // applySettingsWindowSize 内做（含写回 store）。
                        value.wrappedValue = CGFloat(newValue)
                    }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            .textFieldStyle(.roundedBorder)
            .font(NotchTokens.Text.system(11).monospacedDigit())
            .onSubmit { controller.applySettingsWindowSize() }
        }
    }
}
