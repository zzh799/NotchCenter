import NotchCenterKit
import SwiftUI

// MARK: - 页面设置浮窗（分页胶囊齿轮角标触发）
//
// 经 `SettingPopover` 展示（标题行与窗口管线由它提供）：名称即时生效 +
// 图标宫格点选，无保存按钮——每次变更直接回调宿主写盘。宫格候选是精选的
// SF Symbols 清单（DESIGN.md §10：一律 SF Symbols），首格"无"清除自定义
// 图标（主页回落房子、其余页退化为纯文本）。

/// 页面设置浮窗内容。浮窗每次触发都重新构造，初值经 init 注入 `@State`，
/// 之后完全由本地状态驱动（选中高亮不需要反向观察 uiState）。
struct DrawerPageSettingsPopover: View {
    /// 图标宫格候选（macOS 14 可用的 SF Symbol 名）。
    private static let iconChoices: [String] = [
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "tag.fill", "gift.fill", "bell.fill", "pin.fill",
        "folder.fill", "doc.fill", "briefcase.fill", "tray.fill", "shippingbox.fill", "cart.fill", "creditcard.fill", "book.fill",
        "music.note", "photo.fill", "camera.fill", "paintpalette.fill", "gamecontroller.fill", "pencil", "list.bullet", "square.grid.2x2.fill",
        "calendar", "clock.fill", "timer", "globe", "cloud.fill", "bolt.fill", "moon.fill", "sun.max.fill",
        "person.fill", "person.2.fill", "message.fill", "envelope.fill", "phone.fill", "lock.fill", "key.fill", "shield.fill",
        "gearshape.fill", "hammer.fill", "wrench.and.screwdriver.fill", "terminal.fill", "chart.bar.fill", "chart.pie.fill", "laptopcomputer", "power",
    ]

    private let onTitleChange: (String) -> Void
    private let onIconChange: (String) -> Void
    @State private var draftTitle: String
    @State private var selectedIcon: String

    /// - Parameters:
    ///   - title: 当前自定义标题（空 = 回落序号）。
    ///   - icon: 当前**已解析**的图标（nil = 无图标，纯文本）。
    ///   - fallbackIcon: 清除图标后的回落图标（主页 `house.fill`，其余页 nil）。
    ///     选中高亮按"有效图标"对齐：主页清空后房子格保持选中，与胶囊一致。
    init(
        title: String,
        icon: String?,
        fallbackIcon: String?,
        onTitleChange: @escaping (String) -> Void,
        onIconChange: @escaping (String) -> Void
    ) {
        self.onTitleChange = onTitleChange
        self.onIconChange = onIconChange
        _draftTitle = State(initialValue: title)
        _selectedIcon = State(initialValue: icon ?? fallbackIcon ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("panel.page.settings.name"))
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(NotchTokens.Text.system(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                    // 改变即设置：每次键入直接写盘（清空 = 回落序号），无保存按钮。
                    .onChange(of: draftTitle) { _, newValue in
                        onTitleChange(newValue)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("panel.page.settings.icon"))
                    .font(NotchTokens.Text.system(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    clearCell
                    ForEach(Self.iconChoices, id: \.self) { symbol in
                        iconCell(symbol)
                    }
                }
            }
        }
    }

    // MARK: 宫格单元

    /// "无"格：清除自定义图标（空串语义，见 `setDrawerPageIcon`）。
    private var clearCell: some View {
        iconCellBody(symbol: "circle.slash", isSelected: selectedIcon.isEmpty) {
            onIconChange("")
            selectedIcon = ""
        }
        .help(L("panel.page.settings.icon.none"))
    }

    private func iconCell(_ symbol: String) -> some View {
        iconCellBody(symbol: symbol, isSelected: selectedIcon == symbol) {
            onIconChange(symbol)
            selectedIcon = symbol
        }
        .help(symbol)
    }

    private func iconCellBody(
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotchTokens.Text.system(13))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.62))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(isSelected ? 0.14 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(.white.opacity(isSelected ? 0.20 : 0), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .hoverBrighten()
    }
}
