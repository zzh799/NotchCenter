import Foundation
import Testing
@testable import NotchCenter

// MARK: - 设置面板插件说明文档回归测试
//
// 覆盖两块纯逻辑（不依赖 AppKit 运行环境）：
// 1. ReadmeMarkdown 块级解析：标题 / 无序列表 / 代码围栏 / 段落与空行；
// 2. PluginDocumentationDisclosure.loadReadme 的 bundle 内 README 读取与缺失兜底。

struct ReadmeMarkdownTests {
    @Test func parsesHeadingsBulletsAndParagraphs() {
        let markdown = """
        # 大标题
        ## 二级标题
        普通段落一行。
        - 列表项一
        * 列表项二
        + 列表项三
        不是列表的普通文字。
        """

        let blocks = ReadmeMarkdown.parse(markdown)

        #expect(blocks == [
            .heading(level: 1, text: "大标题"),
            .heading(level: 2, text: "二级标题"),
            .paragraph(text: "普通段落一行。"),
            .bullet(text: "列表项一"),
            .bullet(text: "列表项二"),
            .bullet(text: "列表项三"),
            .paragraph(text: "不是列表的普通文字。")
        ])
    }

    @Test func headingRequiresSpaceAfterHashes() {
        // “#标签” 是正文（话题标签），不是一级标题；###### 之后必须跟空白。
        #expect(ReadmeMarkdown.parse("#标签") == [.paragraph(text: "#标签")])
        #expect(ReadmeMarkdown.parse("####### 七个井号") == [.paragraph(text: "####### 七个井号")])
    }

    @Test func codeFenceCapturesRawLinesUntilClosing() {
        let markdown = """
        前文。

        ```bash
        swift run NotchCenter
        # 注释原样保留 **不解析**
        ```

        后文。
        """

        let blocks = ReadmeMarkdown.parse(markdown)

        #expect(blocks == [
            .paragraph(text: "前文。"),
            .code(lines: ["swift run NotchCenter", "# 注释原样保留 **不解析**"]),
            .paragraph(text: "后文。")
        ])
    }

    @Test func unclosedFenceFlushesRemainderAsCode() {
        let blocks = ReadmeMarkdown.parse("```\n第一行\n第二行")

        #expect(blocks == [.code(lines: ["第一行", "第二行"])])
    }

    @Test func blankLinesProduceNoBlocks() {
        #expect(ReadmeMarkdown.parse("\n\n\n").isEmpty)
        #expect(ReadmeMarkdown.parse("段落 A\n\n\n段落 B") == [
            .paragraph(text: "段落 A"),
            .paragraph(text: "段落 B")
        ])
    }
}

/// loadReadme 读取 bundle 结构内的 Contents/Resources/README.md；
/// 缺文件或 bundle 无效时返回 nil（面板回退占位文案）。
struct PluginReadmeLoaderTests {
    @Test func loadsReadmeFromBundleResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("NotchCenterReadmeTests-\(UUID().uuidString)")
        let bundleURL = root.appendingPathComponent("FakePlugin.bundle")
        try fileManager.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try Data("<plist version=\"1.0\"><dict/></plist>".utf8)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try "# 说明".write(
            to: bundleURL.appendingPathComponent("Contents/Resources/README.md"),
            atomically: true,
            encoding: .utf8
        )

        let text = try #require(PluginDocumentationDisclosure.loadReadme(bundleURL: bundleURL))
        #expect(text.contains("说明"))
    }

    @Test func missingBundleYieldsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).bundle")
        #expect(PluginDocumentationDisclosure.loadReadme(bundleURL: url) == nil)
    }
}
