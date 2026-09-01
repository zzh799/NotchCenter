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
                            .font(.system(size: 12))
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
                                .font(.system(size: 12))
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
struct ComponentCatalogItem: Identifiable {
    let pluginID: String
    let blockID: String
    let displayName: String
    let symbolName: String?
    let isCompact: Bool
    /// 默认跨度（抽屉块）；紧凑块为 1×1。
    let span: GridSpan
    let preview: AnyView

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
            )
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
                            originColumn: 0,
                            originRow: 0,
                            widthColumns: span.columns,
                            heightRows: span.rows,
                            isEditing: false,
                            compactSlotIndex: nil
                        )
                    )
                    let item = ComponentCatalogItem(
                        pluginID: entry.id,
                        blockID: block.id,
                        displayName: block.displayName,
                        symbolName: block.symbolName,
                        isCompact: block.kind == .compact,
                        span: span,
                        preview: block.makeView(context)
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

    /// 预览用跨度：默认尺寸档优先，否则取支持跨度里最小的一档。
    private static func preferredSpan(for block: NotchBlock) -> GridSpan {
        if let size = block.defaultSize {
            return GridSpan(columns: size.gridSpan.columns, rows: size.gridSpan.rows)
        }
        guard let smallest = block.supportedSpans.sorted(by: { lhs, rhs in
            (lhs.columns * lhs.rows, lhs.columns) < (rhs.columns * rhs.rows, rhs.columns)
        }).first else {
            return GridSpan(columns: 1, rows: 1)
        }
        return smallest
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

struct ComponentsSettingsPage: View {
    let controller: NotchPanelController
    @ObservedObject private var pluginManager: PluginManager

    @State private var groups: [ComponentCatalogGroup] = []
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        hint
                        ForEach(groups) { group in
                            groupSection(group)
                                .id(group.id)
                        }
                        if groups.isEmpty {
                            Text(L("settings.components.empty"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.top, 40)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedPluginID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
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

    private var pluginSidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L("settings.components.groups"))
                .font(.system(size: 10, weight: .semibold))
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
            selectedPluginID = group.id
        } label: {
            HStack(spacing: 6) {
                Text(group.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
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
                .font(.system(size: 11, weight: .semibold))
            Text(L("settings.components.hint"))
                .font(.system(size: 11.5))
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
                .font(.system(size: 13, weight: .semibold))
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
        }
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
        if let selectedPluginID, !groups.contains(where: { $0.id == selectedPluginID }) {
            self.selectedPluginID = nil
        }
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.86))
                    .lineLimit(1)
                Text(item.isCompact ? L("settings.components.compact") : spanText)
                    .font(.system(size: 9.5, weight: .medium))
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
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 76, alignment: .leading)
                    ColumnRangeSlider(
                        minValue: min(layoutEngine.userMinColumns, layoutEngine.userMaxColumns),
                        maxValue: layoutEngine.userMaxColumns,
                        onMinChange: { newValue in
                            layoutEngine.setUserMinColumns(newValue)
                            controller.refreshAfterLayoutChange()
                        },
                        onMaxChange: { newValue in
                            layoutEngine.setUserMaxColumns(newValue)
                            controller.refreshAfterLayoutChange()
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
                        .font(.system(size: 12))
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
                controller.refreshAfterLayoutChange()
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
                .font(.system(size: 12))
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
        .font(.system(size: 11).monospacedDigit())
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
            .font(.system(size: 10).monospacedDigit())
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
