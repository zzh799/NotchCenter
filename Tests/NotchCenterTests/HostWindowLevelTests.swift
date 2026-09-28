import AppKit
import NotchCenterKit
import XCTest

private let repoRoot: URL = {
    // 测试源码位于 <root>/Tests/NotchCenterTests/，上溯两级即包根。
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // 文件名
    url.deleteLastPathComponent() // NotchCenterTests
    url.deleteLastPathComponent() // Tests
    return url
}()

/// 层级阶梯的递增不变量与「系统窗口抬层级」的推导。
///
/// 这组值是宿主界面、插件、系统辅助窗口三方共用的排序契约。它一旦被破坏，症状是
/// 「某个窗口被自己的界面压住」——只在特定的重叠位置才复现，肉眼极难归因，所以用
/// 断言钉死，而不是靠注释。
final class HostWindowLevelTests: XCTestCase {
    /// 阶梯自上而下必须严格递增。
    func testLadderStrictlyIncreases() {
        let ladder: [(name: String, level: NSWindow.Level)] = [
            ("drawer", HostWindowLevel.drawer),
            ("popover", HostWindowLevel.popover),
            ("drawerAuxiliary", HostWindowLevel.drawerAuxiliary),
            ("utility", HostWindowLevel.utility),
            ("utilityAuxiliary", HostWindowLevel.utilityAuxiliary),
            ("dragPreview", HostWindowLevel.dragPreview),
            ("effectOverlay", HostWindowLevel.effectOverlay),
        ]
        for (lower, upper) in zip(ladder, ladder.dropFirst()) {
            XCTAssertLessThan(
                lower.level.rawValue,
                upper.level.rawValue,
                "\(lower.name)(\(lower.level.rawValue)) 必须低于 \(upper.name)(\(upper.level.rawValue))"
            )
        }
    }

    /// 系统辅助窗口必须严格高于锚点域内的每一档宿主界面。
    func testAuxiliaryLevelsClearTheirAnchorDomain() {
        XCTAssertGreaterThan(
            HostWindowLevel.auxiliary(above: .drawer).rawValue,
            HostWindowLevel.drawer.rawValue)
        XCTAssertGreaterThan(
            HostWindowLevel.auxiliary(above: .drawer).rawValue,
            HostWindowLevel.popover.rawValue)
        XCTAssertGreaterThan(
            HostWindowLevel.auxiliary(above: .utility).rawValue,
            HostWindowLevel.utility.rawValue)
    }

    /// 抽屉域的辅助档必须仍低于 `utility`（`popUpMenuWindow`）：系统弹出菜单在该层，
    /// 不能为了压住自己的浮窗就把系统菜单也盖掉。
    func testDrawerAuxiliaryStaysBelowSystemMenus() {
        XCTAssertLessThan(
            HostWindowLevel.drawerAuxiliary.rawValue, HostWindowLevel.utility.rawValue)
    }

    /// 设置域辅助档与拖拽预览的先后是刻意定的：拖拽预览只在拖动块的过程中存在，
    /// 而拖拽期间不可能去设置窗点安装/停用，两者不会同时在场，辅助档无须压过它。
    /// 写死这条以免后来者"顺手"把两档调换成同一个数。
    func testUtilityAuxiliaryStaysBelowDragPreview() {
        XCTAssertLessThan(
            HostWindowLevel.utilityAuxiliary.rawValue, HostWindowLevel.dragPreview.rawValue)
    }

    // MARK: 层级字面量收口

    /// 层级只允许在阶梯里定义一次：源码树（宿主 + 插件）中不得再出现
    /// `CGWindowLevelForKey`，也不得把 `.statusBar` 这类档位名直接赋给窗口。
    ///
    /// 历史教训：同一组 `.statusBar + n` 与 `popUpMenuWindow` 表达式曾散落八处，
    /// 谁都不负责它们的相对次序——相册插件的文件面板就是这么被自己的抽屉压住的。
    func testWindowLevelLiteralsStayInTheLadder() throws {
        let ladder = "Sources/NotchCenterKit/HostWindowLevel.swift"
        var offenders: [String] = []

        for file in try swiftSources(under: ["Sources", "Plugins"]) {
            let relative = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            guard relative != ladder else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains("CGWindowLevelForKey") {
                    offenders.append("\(relative):\(index + 1) 用了 CGWindowLevelForKey，请从 HostWindowLevel 取档")
                }
                if code.contains(".level = .statusBar") || code.contains(".level = .floating") {
                    offenders.append("\(relative):\(index + 1) 直接赋了裸档位名，请从 HostWindowLevel 取档")
                }
            }
        }

        XCTAssertEqual(offenders, [], "层级字面量只允许出现在 \(ladder)")
    }

    /// 收集 `Sources/` 与 `Plugins/` 下的全部 Swift 源码（跳过 Vendor / Experiments）。
    private func swiftSources(under directories: [String]) throws -> [URL] {
        var files: [URL] = []
        for directory in directories {
            let root = repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }
}
