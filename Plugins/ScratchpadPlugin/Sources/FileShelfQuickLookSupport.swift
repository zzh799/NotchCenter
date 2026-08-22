import AppKit
// QLThumbnailRepresentation is not annotated Sendable; @preconcurrency downgrades
// its false-positive diagnostics so the async overload can hand the thumbnail
// straight back to us without a TIFF encode/decode round-trip.
@preconcurrency import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

@MainActor
final class FileShelfPreviewController: NSObject, ObservableObject,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private var onVisibilityChanged: ((Bool) -> Void)?

    func toggle(
        urls: [URL],
        preferredURL: URL?,
        onVisibilityChanged: @escaping (Bool) -> Void
    ) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, panel.dataSource === self {
            close()
            return
        }

        self.urls = urls
        self.onVisibilityChanged = onVisibilityChanged
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let preferredURL, let index = urls.firstIndex(of: preferredURL) {
            panel.currentPreviewItemIndex = index
        } else {
            panel.currentPreviewItemIndex = 0
        }
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged(true)
    }

    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.dataSource === self else {
            onVisibilityChanged?(false)
            return
        }
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        onVisibilityChanged?(false)
    }
}

// 注意：本类型刻意不做 @MainActor 隔离。改用 QLThumbnailGenerator 的 async
// 重载后不再有 completion 闭包，也就不存在“后台队列执行 MainActor 隔离闭包”
// 的 Swift 6 运行时 trap 问题。SE-0414 region isolation 允许非 Sendable 的
// NSImage 直接返回给 MainActor 调用方（request 与 representation 未逃逸），
// 省去 TIFF 编解码往返；主线程依赖（backing scale）仍由调用方传入。
enum FileShelfThumbnailLoader {
    static func thumbnail(for url: URL, backingScale: CGFloat) async -> sending NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 72),
            scale: backingScale,
            representationTypes: .thumbnail
        )

        // SE-0414 region isolation：非 Sendable 的 NSImage 可直接跨越隔离域返回。
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else {
            return nil
        }
        return representation.nsImage
    }
}
