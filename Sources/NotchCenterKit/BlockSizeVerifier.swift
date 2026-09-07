import CoreGraphics

// MARK: - 最小尺寸遮挡校验（打包期，纯几何）

/// 打包期最小尺寸遮挡校验的单条违规（探针维度）。
public enum BlockSizeViolation: Hashable, Sendable {
    /// 探针 rect 越出内容盒（至少一边超出 `BlockSizeVerifier.tolerance`）：
    /// 内容会伸到邻居块上（宿主卡片不裁切），是块间遮挡的真源。
    case probeOutsideContent(id: String, rect: CGRect, contentSize: CGSize)
    /// 两个探针 rect 相交（交集宽高均超过 `BlockSizeVerifier.tolerance`）：
    /// 组件内部的关键 UI 区互相覆盖。
    case probesOverlap(id: String, otherID: String, intersection: CGRect)
}

/// 打包期"最小尺寸遮挡校验"的纯几何判定（见 Agent Note
/// 2026-09-07-block-min-size-occlusion-verification）。
///
/// 语义：探针是插件声明的"关键 UI 区必须完整可见"矩形（意图契约，非渲染实测）。
/// 校验器拿 `contentSize`（打包校验时为块的 `minSize` 物理像素）当内容盒，逐条检查：
/// 探针越界 → 溢出邻居；探针互叠 → 组件内部遮挡。输入来自
/// `NotchBlock.probes` 回调，与渲染解耦，可在无窗口测试进程里确定性执行。
public enum BlockSizeVerifier {
    /// 判定"越界/相交"的容差（pt）：吸收取整与亚像素噪声；小于此的越出与
    /// 贴边相交不算违规。贴边不算遮挡（两元素各自完整可见）。
    public static let tolerance: CGFloat = 0.5

    /// 对一组探针跑三类几何检查，返回违规列表（保持探针声明顺序，重叠按声明序配对）。
    public static func violations(
        probes: [BlockProbe],
        contentSize: CGSize
    ) -> [BlockSizeViolation] {
        var result: [BlockSizeViolation] = []
        guard !probes.isEmpty, contentSize.width > 0, contentSize.height > 0 else {
            // 无探针无事可查（是否"必须声明"是门禁策略，不是几何判定）；
            // 零尺寸内容盒没有可判定的可见区。
            return result
        }

        let contentOutset = CGRect(origin: .zero, size: contentSize)
            .insetBy(dx: -tolerance, dy: -tolerance)

        for probe in probes {
            guard probe.rect.width > 0, probe.rect.height > 0 else { continue }
            if !contentOutset.contains(probe.rect) {
                result.append(.probeOutsideContent(
                    id: probe.id, rect: probe.rect, contentSize: contentSize))
            }
        }

        for (index, probe) in probes.enumerated() {
            guard probe.rect.width > 0, probe.rect.height > 0 else { continue }
            for other in probes.dropFirst(index + 1) {
                guard other.rect.width > 0, other.rect.height > 0 else { continue }
                let intersection = probe.rect.intersection(other.rect)
                guard !intersection.isNull,
                      intersection.width > tolerance,
                      intersection.height > tolerance else { continue }
                result.append(.probesOverlap(
                    id: probe.id, otherID: other.id, intersection: intersection))
            }
        }
        return result
    }
}
