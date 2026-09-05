import SwiftUI

// MARK: - 快捷按钮统一外观（文档 §4.11）

/// 快捷按钮在**任何落位**（快速区、快捷按钮盒、设置目录卡片）共享的唯一
/// 外观基元：圆角方块 + SF Symbol。
///
/// - 纯视觉、不处理点击/确认/悬停——由各容器按自身交互约定包装
///   （快速区槽位直接执行、盒格先悬停显名、设置卡拖拽起手）。
/// - 状态只表达三层：`isActive`（开关类点亮）、`dimmed`（来源失效置灰）、
///   其余为静态。统一中性白阶，不用各家插件的自定义色（这就是「统一显示
///   样式」的落点：同一动作在快速区、盒里、目录里长相完全一致）。
public struct QuickActionTile: View {
    let systemImage: String
    let isActive: Bool
    let dimmed: Bool
    let symbolSize: CGFloat
    let sideLength: CGFloat?
    let cornerRadius: CGFloat

    public init(
        systemImage: String,
        isActive: Bool = false,
        dimmed: Bool = false,
        symbolSize: CGFloat = 13,
        sideLength: CGFloat? = nil,
        cornerRadius: CGFloat = 8
    ) {
        self.systemImage = systemImage
        self.isActive = isActive
        self.dimmed = dimmed
        self.symbolSize = symbolSize
        self.sideLength = sideLength
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let fillOpacity: Double = dimmed ? 0.03 : (isActive ? 0.2 : 0.06)
        let symbolOpacity: Double = dimmed ? 0.25 : (isActive ? 0.95 : 0.72)
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(fillOpacity))
            Image(systemName: systemImage.isEmpty ? "bolt.fill" : systemImage)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(.white.opacity(symbolOpacity))
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
    }
}
