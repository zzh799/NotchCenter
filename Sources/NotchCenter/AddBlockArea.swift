import AppKit
import NotchCenterKit
import SwiftUI

// MARK: - 添加块区域（文档 §5.5）

/// 目录的插件分组：上栏列紧凑块、下栏列抽屉块（均来自已启用插件）。
struct CatalogPluginGroup: Identifiable {
    let pluginID: String
    let displayName: String
    let compactBlocks: [NotchBlock]
    let drawerBlocks: [NotchBlock]

    var id: String { pluginID }
}

/// 编辑模式的横向 AddBlock 区域：插入在紧凑带与网格之间，自身分上下两栏。
/// 上栏：紧凑块目录，点击即追加到紧凑带末尾（带宽随图标数动态伸缩，
/// 不设数量上限，无需置灰）；下栏：抽屉块目录，按插件内联分组（插件名
/// 小标签 → 块条目 → 竖分隔线），单行横向滚动不换行。条目统一为
/// “图标 + 块名”药丸；块未声明 symbolName 时回退纯文本。
struct AddBlockArea: View {
    let plugins: [CatalogPluginGroup]
    let onAddBlock: (String, String) -> Void

    /// 行高（上下两栏一致，条目在行内垂直居中）。
    static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 6
    private static let verticalPadding: CGFloat = 7
    private static let separatorHeight: CGFloat = 1

    /// 区域总高：控制器据此联动抽屉窗口高度，与 body 布局保持同一公式。
    static func height(for plugins: [CatalogPluginGroup]) -> CGFloat {
        let hasCompactRow = plugins.contains { !$0.compactBlocks.isEmpty }
        let hasDrawerRow = plugins.contains { !$0.drawerBlocks.isEmpty }
        let rows = (hasCompactRow ? 1 : 0) + (hasDrawerRow ? 1 : 0)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * rowSpacing
            + verticalPadding * 2
            + separatorHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Self.rowSpacing) {
                if hasCompactRow {
                    compactRow
                        .frame(height: Self.rowHeight)
                }
                if hasDrawerRow {
                    drawerRow
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, Self.verticalPadding)

            // 与网格的分界发丝线（DESIGN.md hairlines）。
            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(height: Self.separatorHeight)
        }
    }

    private var hasCompactRow: Bool {
        plugins.contains { !$0.compactBlocks.isEmpty }
    }

    private var hasDrawerRow: Bool {
        plugins.contains { !$0.drawerBlocks.isEmpty }
    }

    /// 上栏：紧凑块目录（跨插件扁平排列，滚轮 + 按住拖动横向滚动）。
    private var compactRow: some View {
        HorizontalDragScroll {
            HStack(spacing: 8) {
                rowCaption(L("addblock.compact"))
                ForEach(flatCompactEntries) { entry in
                    catalogPill(
                        entry.block,
                        pluginID: entry.pluginID,
                        disabled: false,
                        help: L("addblock.help.compact")
                    )
                }
            }
        }
    }

    /// 下栏：抽屉块目录，按插件内联分组（滚轮 + 按住拖动横向滚动）。
    private var drawerRow: some View {
        let groups = plugins.filter { !$0.drawerBlocks.isEmpty }
        return HorizontalDragScroll {
            HStack(spacing: 8) {
                rowCaption(L("addblock.drawer"))
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, plugin in
                    HStack(spacing: 6) {
                        Text(plugin.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                            .fixedSize()
                        ForEach(plugin.drawerBlocks) { block in
                            catalogPill(
                                block,
                                pluginID: plugin.pluginID,
                                disabled: false,
                                help: L("addblock.help.drawer")
                            )
                        }
                    }
                    if index < groups.count - 1 {
                        groupDivider
                    }
                }
            }
        }
    }

    /// 上栏条目：紧凑块跨插件扁平化。
    private var flatCompactEntries: [CompactCatalogEntry] {
        plugins.flatMap { group in
            group.compactBlocks.map { block in
                CompactCatalogEntry(pluginID: group.pluginID, block: block)
            }
        }
    }

    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.38))
            .fixedSize()
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(width: 1, height: 16)
    }

    /// 目录药丸：图标 + 块名；未声明 symbolName 的块回退纯文本。
    private func catalogPill(
        _ block: NotchBlock,
        pluginID: String,
        disabled: Bool,
        help: String
    ) -> some View {
        Button {
            onAddBlock(pluginID, block.id)
        } label: {
            HStack(spacing: 5) {
                if let symbolName = block.symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(block.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.055))
            )
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(disabled)
        .help(help)
    }
}

/// 上栏的紧凑块条目（跨插件扁平化后的载体）。
private struct CompactCatalogEntry: Identifiable {
    let pluginID: String
    let block: NotchBlock
    let id: String

    @MainActor
    init(pluginID: String, block: NotchBlock) {
        self.pluginID = pluginID
        self.block = block
        self.id = pluginID + "." + block.id
    }
}
