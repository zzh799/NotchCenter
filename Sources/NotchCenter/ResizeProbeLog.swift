#if DEBUG
import CoreGraphics
import Foundation
import NotchCenterKit

// MARK: - 缩放管线诊断（仅 DEBUG 构建）

/// 真实管线的日志开关：`NOTCHCENTER_RESIZE_LOG=1` 时把每个缩放事件
/// （translation → continuous → preview）打到控制台，供拖拽时观察。
enum ResizeProbeLog {
    static let isEnabled = ProcessInfo.processInfo.environment["NOTCHCENTER_RESIZE_LOG"] == "1"

    static func resizeEvent(
        translation: CGSize,
        continuousColumns: CGFloat,
        continuousRows: CGFloat,
        preview: GridSpan
    ) {
        guard isEnabled else { return }
        NSLog(
            "resize t=(%+.1f, %+.1f) continuous=(%.2f, %.2f) preview=%dx%d",
            translation.width,
            translation.height,
            continuousColumns,
            continuousRows,
            preview.columns,
            preview.rows
        )
    }
}
#endif
