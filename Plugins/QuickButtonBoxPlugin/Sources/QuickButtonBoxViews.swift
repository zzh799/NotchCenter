import NotchCenterKit
import SwiftUI

// MARK: - 盒块视图（纯图标宫格 + 悬停显名）

/// 「快捷按钮盒」抽屉块视图：按放置实例的动作集渲染纯图标宫格。按钮悬停
/// 时经系统 tooltip 显示动作全名（.help），开关类动作带点亮态；需要确认的
/// 重动作点击先弹 confirmationDialog。动作来源插件被禁用后该格置灰保留
/// （容器只存动作 ID，禁用的动作宿主注册表查不到即 nil）。
struct QuickButtonBoxView: View {
    let context: BlockContext
    @ObservedObject private var model: BoxInstanceModel

    init(context: BlockContext) {
        self.context = context
        _model = ObservedObject(
            wrappedValue: BoxInstanceRegistry.shared.model(
                placementID: context.placementID,
                stateStore: context.stateStore
            )
        )
    }

    var body: some View {
        BlockCard(hoverEffect: true) { _ in
            Group {
                if model.actionIDs.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
            Text(L("block.empty"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(L("block.empty.hint"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 每个动作 ID 解析为宿主注册表里的活体动作（nil = 来源插件已禁用/未知）。
    private var resolvedActions: [QuickAction?] {
        model.actionIDs.map { context.hostController.quickAction(id: $0) }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: QuickButtonBoxLayout.iconSize,
                                         maximum: QuickButtonBoxLayout.iconSize + 8),
                                spacing: QuickButtonBoxLayout.iconSpacing)],
            spacing: QuickButtonBoxLayout.iconSpacing
        ) {
            ForEach(Array(resolvedActions.enumerated()), id: \.offset) { _, action in
                if let action {
                    BoxActionButtonCell(action: action)
                } else {
                    BoxActionMissingCell()
                }
            }
        }
    }
}

/// 正常动作按钮：图标 + 悬停显名（.help）；开关类高亮点亮态；重动作确认后执行。
private struct BoxActionButtonCell: View {
    @ObservedObject var action: QuickAction

    @State private var isConfirming = false
    @State private var isHovering = false

    var body: some View {
        let isActive = action.isActive
        Button {
            if action.requiresConfirmation {
                isConfirming = true
            } else {
                action.execute()
            }
        } label: {
            // 与快速区/目录共用统一外观基元：同一动作在任何位置长相一致。
            QuickActionTile(
                systemImage: action.systemImage,
                isActive: action.kind == .toggle && action.isActive,
                symbolSize: 17,
                sideLength: QuickButtonBoxLayout.iconSize,
                cornerRadius: 9
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled(true)
        .help(action.displayName)
        .accessibilityLabel(action.displayName)
        .accessibilityValue(action.kind == .toggle
            ? (action.isActive ? L("a11y.on") : L("a11y.off"))
            : "")
        .onHover { isHovering = $0 }
        .confirmationDialog(
            Text(action.displayName),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L("confirm.run"), role: .destructive) {
                action.execute()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("confirm.message"))
        }
    }
}

/// 失效动作占位格：来源插件被禁用/动作已不存在——置灰保留，提示可移除。
private struct BoxActionMissingCell: View {
    var body: some View {
        Image(systemName: "questionmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.22))
            .frame(width: QuickButtonBoxLayout.iconSize, height: QuickButtonBoxLayout.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.015))
            )
            .help(L("action.unavailable"))
            .accessibilityLabel(L("action.unavailable"))
    }
}

// MARK: - 盒管理面板（编辑模式齿轮 → instanceSettingsView）

/// 移除 / 排序 / 失效项清理。列表行即当前动作集（与块视图同一模型）。
struct QuickButtonBoxManageView: View {
    let context: BlockContext
    @ObservedObject private var model: BoxInstanceModel

    init(context: BlockContext) {
        self.context = context
        _model = ObservedObject(
            wrappedValue: BoxInstanceRegistry.shared.model(
                placementID: context.placementID,
                stateStore: context.stateStore
            )
        )
    }

    /// 管理面板无网格 frame 时按默认尺寸（extraLarge）估算容量。
    private var capacity: Int {
        if let columns = context.layoutInfo.widthColumns,
           let rows = context.layoutInfo.heightRows {
            return QuickButtonBoxLayout.capacity(
                for: GridSpan(columns: max(columns, 1), rows: max(rows, 1))
            )
        }
        return QuickButtonBoxLayout.capacity(forSize: context.layoutInfo.size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("panel.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(LF("panel.capacity", model.actionIDs.count, capacity))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }

            if model.actionIDs.isEmpty {
                Text(L("block.empty.hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 6)
            } else {
                rows
            }
        }
        .frame(width: 232)
        .padding(2)
    }

    private var rows: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(model.actionIDs.enumerated()), id: \.offset) { index, actionID in
                    row(at: index, actionID: actionID)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func row(at index: Int, actionID: String) -> some View {
        let action = context.hostController.quickAction(id: actionID)
        let symbol: String
        if let action, !action.systemImage.isEmpty {
            symbol = action.systemImage
        } else if action == nil {
            symbol = "questionmark"
        } else {
            symbol = "bolt.fill"
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(action == nil ? 0.25 : 0.8))
                .frame(width: 16)
            Text(action?.displayName ?? L("action.unavailable"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(action == nil ? 0.3 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 0)

            rowButton("chevron.up", disabled: index == 0) {
                model.move(from: index, by: -1)
            }
            rowButton("chevron.down", disabled: index == model.actionIDs.count - 1) {
                model.move(from: index, by: 1)
            }
            rowButton("xmark", tint: .red.opacity(0.8)) {
                model.remove(actionID: actionID)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func rowButton(
        _ systemImage: String,
        tint: Color = .white,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint.opacity(disabled ? 0.2 : 0.6))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
