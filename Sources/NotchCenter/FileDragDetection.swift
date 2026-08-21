import AppKit
import Foundation

/// 核心侧的文件拖入检测（文档 §6 中拖入展开抽屉的交互）。
@MainActor
enum FileDragDetector {
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }
}