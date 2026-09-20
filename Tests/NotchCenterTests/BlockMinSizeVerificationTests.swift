import CoreGraphics
import NotchCenterKit
import XCTest
@testable import CalibrePlugin
@testable import CalendarPlugin
@testable import CameraPlugin
@testable import ClipboardHistoryPlugin
@testable import CommandSchedulerPlugin
@testable import DisplayPlugin
@testable import DshPlugin
@testable import LidAngleDepthPlugin
@testable import NotesPlugin
@testable import PomodoroPlugin
@testable import QuickButtonBoxPlugin
@testable import ScratchpadPlugin
@testable import SystemMonitorPlugin

/// 官方插件「打包期最小尺寸遮挡校验」门禁（原始需求第 5 句；设计见 Agent Note
/// 2026-09-07-block-min-size-occlusion-verification，判定器单测见
/// `BlockSizeVerifierTests`——本套件管插件声明，那个管几何判定本身）。
///
/// 对每个官方 drawer 块：
/// 1. **必须声明探针**（缺失即失败：无声明则打包期无从校验最小尺寸遮挡）；
/// 2. 声明合法性（`validationError`，双保险）；
/// 3. 以 `minSize`（物理像素，frame = 内容盒、无网格跨度上下文）取探针 →
///    `BlockSizeVerifier` 纯几何校验，断言零违规。
///
/// 失败信息带 插件名 / 块 id / 探针 id / 违规类别与像素数据，直接可修。
/// 第三方插件不在本仓、无探针声明即跳过（不在此门禁范围）。
///
/// 清单与 `Plugins/` 现有插件一一对应：新增官方插件后必须在此登记，否则新块的
/// 探针声明无人校验（`./scripts/build.sh verify-sizes` 只按套件名过滤，漏登记
/// 不会报错，只会静默少跑）。CaffeinatePlugin 只有紧凑块，无需探针故不列入。
@MainActor
final class BlockMinSizeVerificationTests: XCTestCase {
    /// 全部官方块（插件模块已逐一 @testable import）。
    private static let officialBlocks: [(plugin: String, block: NotchBlock)] = {
        [
            ("CalibrePlugin", CalibrePlugin.blocks),
            ("CalendarPlugin", CalendarPlugin.blocks),
            ("CameraPlugin", CameraPlugin.blocks),
            ("ClipboardHistoryPlugin", ClipboardHistoryPlugin.blocks),
            ("CommandSchedulerPlugin", CommandSchedulerPlugin.blocks),
            ("DisplayPlugin", DisplayPlugin.blocks),
            ("DshPlugin", DshPlugin.blocks),
            ("LidAngleDepthPlugin", LidAngleDepthPlugin.blocks),
            ("NotesPlugin", NotesPlugin.blocks),
            ("PomodoroPlugin", PomodoroPlugin.blocks),
            ("QuickButtonBoxPlugin", QuickButtonBoxPlugin.blocks),
            ("ScratchpadPlugin", ScratchpadPlugin.blocks),
            ("SystemMonitorPlugin", SystemMonitorPlugin.blocks),
        ]
        .flatMap { plugin, blocks in blocks.map { (plugin, $0) } }
    }()

    /// 受"必须声明探针"约束的官方块：抽屉网格块（全部抽屉块，无豁免）。
    private static let officialDrawerBlocks = officialBlocks.filter { $0.block.kind == .drawer }

    func testAllOfficialDrawerBlocksPassMinSizeVerification() {
        var failures: [String] = []
        for (plugin, block) in Self.officialDrawerBlocks {
            failures.append(contentsOf: verify(plugin: plugin, block: block))
        }
        XCTAssertTrue(
            failures.isEmpty,
            "打包期最小尺寸遮挡校验失败（共 \(failures.count) 处）：\n" + failures.joined(separator: "\n")
        )
    }

    /// 校验单个块，返回违规描述列表（空 = 通过）。
    private func verify(plugin: String, block: NotchBlock) -> [String] {
        let tag = "\(plugin)/\(block.id)"

        // 声明合法性（双保险，正常在运行期已被宿主拦截）。
        if let declarationError = block.validationError {
            return ["\(tag): 声明非法 —— \(declarationError)"]
        }

        // 1. 抽屉块必须声明探针（无豁免：任何抽屉块都可能与邻居同页）。
        guard let probesClosure = block.probes else {
            return ["\(tag): 未声明打包期遮挡校验探针（probes）。"
                + "官方抽屉块必须在 minSize 下可校验——请参照其他官方插件为关键 UI 区声明 BlockProbe。"]
        }

        // 2. min 布局：frame = minSize 物理像素内容盒；无网格跨度上下文
        //    （探针只准依赖 frame，打包期没有格子换算）。
        guard let minPixel = block.minSize else {
            return ["\(tag): 缺少 minSize（声明不完整）"]
        }
        let minLayout = BlockLayoutInfo(
            region: .drawer,
            placementID: "__pack_verify__",
            frame: CGRect(origin: .zero, size: minPixel.size)
        )
        let probes = probesClosure(minLayout)

        // 3. 探针不得为空：声明了回调但什么都不报 = 没有可校验的内容。
        if probes.isEmpty {
            return ["\(tag): probes 回调在 minSize(\(Int(minPixel.width))×\(Int(minPixel.height)))"
                + " 下返回空——请至少声明一个关键 UI 区探针。"]
        }

        // 4. 纯几何校验：越界（溢出邻居）/ 自叠（块内互遮）。
        let violations = BlockSizeVerifier.violations(
            probes: probes,
            contentSize: minPixel.size
        )
        if violations.isEmpty { return [] }

        let detail = probes.map {
            "      probe[\($0.id)] rect=(\(Int($0.rect.minX)),\(Int($0.rect.minY))"
                + " \(Int($0.rect.width))×\(Int($0.rect.height)))"
        }.joined(separator: "\n")
        return ["\(tag): minSize \(Int(minPixel.width))×\(Int(minPixel.height)) 下遮挡校验失败（\(violations.count) 处）：\n"
            + violations.map(describe).joined(separator: "\n")
            + "\n    探针清单：\n" + detail]
    }

    private func describe(_ violation: BlockSizeViolation) -> String {
        switch violation {
        case .probeOutsideContent(let id, let rect, let contentSize):
            return "      越界溢出：probe[\(id)] rect=(\(fmt(rect.minX)),\(fmt(rect.minY)) "
                + "\(fmt(rect.width))×\(fmt(rect.height))) 超出内容盒 "
                + "\(fmt(contentSize.width))×\(fmt(contentSize.height))——最小尺寸下内容会伸到邻居块"
        case .probesOverlap(let id, let otherID, let intersection):
            return "      块内自叠：probe[\(id)] 与 probe[\(otherID)] 相交 "
                + "(\(fmt(intersection.width))×\(fmt(intersection.height)))——最小尺寸下两关键 UI 区互相覆盖"
        }
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
