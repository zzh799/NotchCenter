import NotchCenterKit
import SwiftUI

// MARK: - 设置面板插件说明文档（轻量 Markdown 渲染）
//
// 宿主不链接 vendored 的 swift-markdown-engine（仅 NotesPlugin 使用），这里用
// 行级块解析 + AttributedString 原生内联解析，覆盖插件 README 的常用子集：
// 标题（#..######）、无序列表（- / * / +）、代码围栏（```）、段落内的
// **粗体** / `行内代码` / [链接](url)。其余语法按普通段落原样展示。

/// README 块级解析（纯函数，ReadmeMarkdownTests 覆盖）。
enum ReadmeMarkdown {
    enum Block: Equatable {
        /// `#` 标题；level 为井号数（1...6），text 为去掉井号后的内容。
        case heading(level: Int, text: String)
        /// 无序列表项（- / * / +），text 为去掉列表标记后的内容。
        case bullet(text: String)
        /// ``` 代码围栏之间的原始行（不做任何内联解析）。
        case code(lines: [String])
        case paragraph(text: String)
    }

    /// 行级解析：代码围栏优先（内部行原样保留）；空行只作段落分隔不产生块；
    /// 其余逐行成块（README 多为单行语义，中文硬换行也不被合并破坏）。
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var inFence = false
        var codeLines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines: codeLines))
                    codeLines = []
                    inFence = false
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                inFence = true
                continue
            }
            if trimmed.isEmpty { continue }

            if let level = headingLevel(trimmed) {
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            blocks.append(.paragraph(text: trimmed))
        }

        // 未闭合的围栏兜底：剩余行仍以代码块呈现。
        if inFence, !codeLines.isEmpty {
            blocks.append(.code(lines: codeLines))
        }
        return blocks
    }

    /// `#{1,6}` 后跟空白才算标题；返回井号数。
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        return rest.first?.isWhitespace == true ? hashes.count : nil
    }
}

/// 渲染解析后的块序列。配色沿用宿主深色表单的白色层级（DESIGN.md §2.2）。
struct ReadmeMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(ReadmeMarkdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReadmeMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(NotchTokens.Text.system(level <= 1 ? 15 : level == 2 ? 13 : 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.top, level <= 2 ? 4 : 2)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(.white.opacity(0.45))
                inlineText(text)
                    .font(NotchTokens.Text.system(11))
                    .foregroundStyle(.white.opacity(0.66))
            }
        case let .code(lines):
            Text(lines.joined(separator: "\n"))
                .font(NotchTokens.Text.system(10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
        case let .paragraph(text):
            inlineText(text)
                .font(NotchTokens.Text.system(11))
                .foregroundStyle(.white.opacity(0.66))
        }
    }

    /// 行内样式（粗体/行内代码/链接）交给 AttributedString 原生解析；
    /// 解析失败回退纯文本。颜色/字号由调用方统一施加。
    private func inlineText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
