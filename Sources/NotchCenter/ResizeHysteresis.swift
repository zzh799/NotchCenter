import AppKit

/// 缩放握把的死区量化（迟滞）：把连续跨度值吸附到整数档位，
/// 且只有越过当前档位的半格边界（0.5 ± band）之外才允许换档，
/// 边界两侧各留 band 宽的稳定带。否则鼠标在半格边界附近抖动时，
/// round() 会在相邻档位间来回翻转，预览随之闪烁。
enum ResizeHysteresis {
    /// 死区余量（单位：网格步长）。0.18 格 ≈ 水平 29pt / 垂直 24pt，
    /// 远大于像素级抖动，又不足以下意识拖动跨越。
    static let band: CGFloat = 0.18

    /// 死区量化：`continuous` 越过当前档位的边界 ± band 之外才换档，
    /// 否则保持 `current`；越过较多时一次跨多档直接落到最近整数。
    static func quantized(_ continuous: CGFloat, current: Int, band: CGFloat = ResizeHysteresis.band) -> Int {
        let delta = continuous - CGFloat(current)
        if delta > 0.5 + band {
            return Int((continuous - band).rounded())
        }
        if delta < -0.5 - band {
            return Int((continuous + band).rounded())
        }
        return current
    }
}
