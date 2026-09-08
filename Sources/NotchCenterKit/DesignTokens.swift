import AppKit
import SwiftUI

// MARK: - 设计 Token（DESIGN.md 的代码化唯一事实源）
//
// `docs/DESIGN.md` 的 §2 配色 / §3 圆角 / §4 排版 / §5 间距 / §7 动效在此
// 落成命名常量：宿主与插件的 UI 一律引用 `NotchTokens`，不再散落内联
// 字面量。spec 值与 token 一一对应（DESIGN.md §14 对应表），文档改动
// 必须同步本文件，反之亦然。
//
// 约定：
// - 全部为纯值类型常量（`static let`），无运行期状态，Swift 6 严格并发
//   下无需隔离。
// - spec 没有的取值不要"顺手"加进来：确需新 token 先改 DESIGN.md 再改这里。
// - spec 角色之外的字体/尺寸走 `Text.system(...)` 工厂（唯一的 `.system`
//   收敛点），便于扫描脚本识别与后续全局调整。

public enum NotchTokens {

    // MARK: 前景白色 alpha 层级（DESIGN.md §2.2）

    /// 白色 alpha 前景阶梯：正文 > 次要 > 悬停 > 静音 > 禁用 > 占位。
    /// 悬停/按下等交互态由组件（如 `BlockCard`）内部按态切换时引用。
    public enum Foreground {
        /// 正文/主文本（`bodyText`）。
        public static let body: Color = .white.opacity(0.92)
        /// 选中/激活态文本（chip 选中、KeepAwake 激活）。
        public static let selected: Color = .white.opacity(0.94)
        /// 次要文本/图标悬停态。
        public static let hover: Color = .white.opacity(0.88)
        /// 次要文本/图标常态。
        public static let secondary: Color = .white.opacity(0.76)
        /// 静音文本（`mutedText`、状态行、暂存文件名）。
        public static let muted: Color = .white.opacity(0.58)
        /// 禁用文本（`disabledText`）。
        public static let disabled: Color = .white.opacity(0.38)
        /// 占位文本（"Start typing…"）。
        public static let placeholder: Color = .white.opacity(0.24)
        /// 标题标记 `#`（`headingMarker`）。
        public static let headingMarker: Color = .white.opacity(0.44)
        /// 不可用内容（源文件丢失的 chip 文本等）。
        public static let unavailable: Color = .white.opacity(0.34)
    }

    // MARK: 表面（DESIGN.md §2.1）

    /// 深色面板表面。spec 明确记载的取值（抽屉/编辑器/工具栏）之外，
    /// 近白半透明填充（卡片常态 0.025 / 悬停 0.04 / 强调 0.055）与
    /// `BlockCard` 壳共用同一套层级。
    public enum Surface {
        /// 抽屉主背景。
        public static let drawer: Color = Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98)
        /// 笔记编辑器面板背景。
        public static let editorPanel: Color = Color(red: 0.06, green: 0.06, blue: 0.07)
        /// Markdown 快捷工具栏背景。
        public static let editorToolbar: Color = Color(red: 0.055, green: 0.055, blue: 0.065)
        /// 卡片/条目常态填充（BlockCard 常态、剪贴行常态）。
        public static let fill: Color = .white.opacity(0.025)
        /// 卡片/条目悬停填充。
        public static let fillHover: Color = .white.opacity(0.04)
        /// 卡片/条目强调（拖入高亮、框选、行复制成功）填充。
        public static let fillHighlighted: Color = .white.opacity(0.055)
        /// 进度条/量表轨道底色（块内数据可视化的通用底）。
        public static let track: Color = .white.opacity(0.08)
    }

    // MARK: 描边与发丝线（DESIGN.md §2.3）

    public enum Hairline {
        /// 抽屉外描边（lineWidth 1）。
        public static let drawerEdge: Color = .white.opacity(0.09)
        /// 分隔线（height 1）。
        public static let divider: Color = .white.opacity(0.045)
        /// chip 选中描边。
        public static let chipSelected: Color = .white.opacity(0.20)
        /// 框选矩形描边。
        public static let marquee: Color = .white.opacity(0.34)
        /// 图片缩略图描边（lineWidth 0.5）。
        public static let thumbnail: Color = .white.opacity(0.12)
    }

    // MARK: 语义色（DESIGN.md §2.4）

    /// 少量系统语义色。UI 主题仍坚持"白色层级"，语义色只用于链接/
    /// 查找/不可用等少数状态；用量等数据可视化配色归插件本地管理。
    /// （macOS 的 systemBlue/systemYellow 是 NSColor 名称，经 `Color(_:)` 桥接。）
    public enum Semantic {
        /// 链接。
        public static let link: Color = Color(NSColor.systemBlue)
        /// 未完成/待确认链接。
        public static let linkPending: Color = Color(NSColor.systemBlue).opacity(0.75)
        /// 查找高亮（当前命中为不透明 systemYellow）。
        public static let findHighlight: Color = Color(NSColor.systemYellow).opacity(0.55)
        /// 不可用角标（文件丢失等）。
        public static let unavailable: Color = Color.orange.opacity(0.72)
        /// 强调绿（复制成功、内存 normal 等"健康"语义；spec 2026-09 新增）。
        public static let accentGreen: Color = Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    // MARK: 圆角（DESIGN.md §3，一律 `style: .continuous`）

    public enum Radius {
        /// 圆角按钮。
        public static let button: CGFloat = 7
        /// 块卡片壳 / 文件暂存区容器（对齐 `BlockCardMetrics.cornerRadius`）。
        public static let card: CGFloat = 10
        /// 文件 chip / 摘要 chip。
        public static let chip: CGFloat = 8
        /// 图片缩略图。
        public static let thumbnail: CGFloat = 4
        /// 抽屉遮罩圆角插值起点（紧凑态）。
        public static let panelCompact: CGFloat = 12
        /// 抽屉遮罩圆角插值终点（展开态）。
        public static let panelExpanded: CGFloat = 18
    }

    // MARK: 排版（DESIGN.md §4）

    /// 排版阶梯：spec 角色用命名预设；角色之外（如数据可视化数字、
    /// 空态大图标）一律走 `system(...)` 工厂——它是 `.system(size:)`
    /// 的唯一收敛点，扫描脚本据此识别裸字体。
    public enum Text {
        /// 正文（编辑器、占位文本）。
        public static let body: Font = .system(size: 15)
        /// 工具栏图标/命令（设置、保持唤醒）。
        public static let toolbar: Font = .system(size: 13, weight: .semibold)
        /// 工具栏次级命令/标签（Markdown 命令、标签页）。
        public static let toolbarSmall: Font = .system(size: 11, weight: .semibold)
        /// 行内代码（bold monospaced 反引号）。
        public static let code: Font = .system(size: 13, weight: .bold, design: .monospaced)
        /// chip/标签/状态行（9 medium，配合 `truncationMode(.middle)`）。
        public static let caption: Font = .system(size: 9, weight: .medium)
        /// 拖入提示（"Release to add"）。
        public static let dropHint: Font = .system(size: 10, weight: .semibold)

        /// 参数化字体工厂：spec 角色之外的 `.system(size:weight:design:)`
        /// 唯一入口（数据可视化数值、空态图标等），保证字体调用可扫描、
        /// 可集中调整。
        public static func system(
            _ size: CGFloat,
            weight: Font.Weight = .regular,
            design: Font.Design = .default
        ) -> Font {
            .system(size: size, weight: weight, design: design)
        }
    }

    // MARK: 间距（DESIGN.md §5）

    public enum Space {
        /// 抽屉内容左右内边距。
        public static let contentHorizontal: CGFloat = 18
        /// 抽屉内容底部内边距。
        public static let contentBottom: CGFloat = 12
        /// 抽屉区块纵向间距（编辑器↔暂存区、暂存区相关）。
        public static let blockGap: CGFloat = 8
        /// 块内容标准内边距（插件块普遍 10pt，2026-09 从代码惯例提炼入 spec）。
        public static let cardPadding: CGFloat = 10
        /// 文件暂存区高度。
        public static let shelfHeight: CGFloat = 72
        /// 暂存区 chip 列表内边距（水平/垂直同值）。
        public static let shelfInset: CGFloat = 6
        /// 标签页行高。
        public static let tabRowHeight: CGFloat = 24
        /// 标签页行距。
        public static let tabRowSpacing: CGFloat = 4
        /// 编辑器快捷工具栏高。
        public static let editorToolbarHeight: CGFloat = 38
        /// 文件 chip 尺寸。
        public static let chipSize = CGSize(width: 60, height: 54)
        /// 图片缩略图尺寸。
        public static let thumbnailSize = CGSize(width: 38, height: 30)
    }

    // MARK: 动效（DESIGN.md §7）

    /// spring 表达"物理弹入"，短 easeOut 表达"悬停/状态反馈"。
    /// 非标的 spring 参数（如 Scratchpad 曾有 0.32/0.82）一律收敛到
    /// 就近的 spec 曲线，禁止自造参数。
    public enum Motion {
        /// 抽屉展开。
        public static let expand = Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// 抽屉收起。
        public static let collapse = Animation.easeOut(duration: 0.16)
        /// 服务/状态翻转等短反馈（与收起同曲线，角色不同单列命名）。
        public static let stateChange = Animation.easeOut(duration: 0.16)
        /// 暂存区出现/拖入高亮。
        public static let shelfAppear = Animation.spring(response: 0.30, dampingFraction: 0.84)
        /// 移除暂存项。
        public static let removal = Animation.spring(response: 0.28, dampingFraction: 0.84)
        /// 标签页切换。
        public static let tabSwitch = Animation.spring(response: 0.26, dampingFraction: 0.82)
        /// 悬停/选中/按压等微反馈（spec 带 0.10–0.13s，取 0.12）。
        public static let hover = Animation.easeOut(duration: 0.12)
        /// 鼠标离开停留区后延时收起。
        public static let collapseDelay: TimeInterval = 0.22
        /// 展开后异步激活编辑器的延时。
        public static let editorActivationDelay: TimeInterval = 0.30
    }
}
