#if DEBUG
import AppKit
import Foundation

// MARK: - 收起动画诊断（layer 树 dump 与逐帧自拍，仅 DEBUG 构建）

/// 合成鼠标事件的坐标系换算基准（原 ResizeProbe 内四处重复的取屏逻辑，
/// 提取为共享辅助，行为不变）：优先取原点在 (0,0) 的主屏 frame，
/// 兜底 NSScreen.main 与 1440×900 默认值。CG 全局坐标以上主屏左上为原点
/// （y 向下），AppKit 全局坐标以其左下为原点（y 向上）。
func debugPrimaryScreenFrame() -> NSRect {
    NSScreen.screens.first { $0.frame.origin == .zero }?.frame
        ?? NSScreen.main?.frame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
}

extension NotchPanelController {
    /// 收起动画期间逐帧 dump 抽屉宿主视图的 layer 树（model 与 presentation
    /// 位置对照）：presentation 是合成器实际显示的位置，能区分“布局跳变”
    /// 与“仍在动画中的层”。
    func dumpDrawerLayerTreeSamples(
        count: Int = 8,
        interval: TimeInterval = 0.033
    ) {
        guard let host = (activePair ?? pairs.first)?.drawerHostingView, let root = host.layer else {
            return
        }
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) { [weak self] in
                guard self != nil else { return }
                NSLog("collapse-probe layers sample %d", i)
                func walk(_ layer: CALayer, depth: Int) {
                    guard depth < 12 else { return }
                    let pres = layer.presentation()
                    func fmt(_ p: CGPoint?) -> String {
                        p.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) } ?? "nil"
                    }
                    NSLog(
                        "collapse-probe L d=%d %@ bounds=%@ pos=%@ presPos=%@ presBounds=%@",
                        depth,
                        String(describing: type(of: layer)),
                        NSStringFromRect(NSRect(origin: .zero, size: layer.bounds.size)),
                        fmt(layer.position),
                        fmt(pres?.position),
                        pres.map { NSStringFromRect(NSRect(origin: .zero, size: $0.bounds.size)) } ?? "nil"
                    )
                    layer.sublayers?.forEach { walk($0, depth: 1 + depth) }                }
                walk(root, depth: 0)
            }
        }
    }

    /// 收起动画逐帧像素采样（NOTCHCENTER_COLLAPSE_PROBE=1，配 AppDelegate
    /// 的 runCollapseProbe 序列）：CGWindowListCreateImage 抓合成器表现层
    /// （含动画中帧；cacheDisplay 只能渲染布局终态，抓不到过渡）。自拍本
    /// 进程窗口不需要屏幕录制权限。
    func captureDrawerWindowSamples(
        count: Int = 12,
        interval: TimeInterval = 0.033,
        prefix: String = "live"
    ) {
        guard let pair = activePair ?? pairs.first else { return }
        let windowID = CGWindowID(pair.drawerPanel.windowNumber)
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                // 窗口收起 orderOut 后采样返回 nil，属预期。
                guard let cgImage = CGWindowListCreateImage(
                    .null,
                    [.optionIncludingWindow],
                    windowID,
                    [.bestResolution]
                ) else {
                    NSLog("collapse-probe live %@%d: window offscreen", prefix, i)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let data = rep.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: URL(fileURLWithPath: "/tmp/nc_\(prefix)\(i).png"))
                NSLog(
                    "collapse-probe live %@%d: %dx%d",
                    prefix,
                    i,
                    cgImage.width,
                    cgImage.height
                )
            }
        }
    }
}
#endif
