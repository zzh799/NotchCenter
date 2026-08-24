import AppKit
import Testing
@testable import NotchCenter

// MARK: - 隐藏主菜单回归测试
//
// NotchCenter 是 accessory 应用，⌘C / ⌘V 等标准编辑快捷键完全依赖隐藏主
// 菜单里的 nil-target 条目沿响应链分发（见 EditMenuInstaller 顶部说明）。
// 这里锁住菜单接线：条目、选择器、键等价物、nil target 缺一不可——任何
// 一项漂移都会让“笔记编辑器复制快捷键无效”复发。

@MainActor
struct EditMenuInstallerTests {
    @Test func mainMenuCarriesAppAndEditSubmenus() throws {
        let main = EditMenuInstaller.makeMainMenu()

        // 应用菜单：Quit / Hide 键等价物不因替换默认主菜单而丢失。
        let appSubmenu = try #require(main.items.first?.submenu)
        #expect(hasItem(appSubmenu, action: "terminate:"))
        #expect(hasItem(appSubmenu, action: "hide:"))

        // 编辑菜单：六个标准编辑动作全部在位。
        let editSubmenu = try #require(main.items.last?.submenu)
        let actions = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]
        for action in actions {
            #expect(hasItem(editSubmenu, action: action), "Edit 菜单缺少 \(action)")
        }
    }

    private func hasItem(_ menu: NSMenu, action: String) -> Bool {
        menu.items.contains { $0.action == Selector(action) }
    }

    @Test func editItemsUseStandardKeyEquivalentsAndNilTargets() throws {
        let editSubmenu = try #require(EditMenuInstaller.makeMainMenu().items.last?.submenu)

        let expected: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [
            "undo:": ("z", [.command]),
            "redo:": ("z", [.command, .shift]),
            "cut:": ("x", [.command]),
            "copy:": ("c", [.command]),
            "paste:": ("v", [.command]),
            "selectAll:": ("a", [.command])
        ]

        for (action, wiring) in expected {
            let item = try #require(
                editSubmenu.items.first { $0.action == Selector(action) },
                "Edit 菜单缺少 \(action)"
            )
            // target 必须为 nil：动作沿响应链解析到当前 NSTextView；
            // 固定 target 会把快捷键绑死到某个具体视图实例。
            #expect(item.target == nil, "\(action) 不应固定 target")
            #expect(item.keyEquivalent == wiring.key, "\(action) 的键等价物错误")
            #expect(item.keyEquivalentModifierMask == wiring.modifiers, "\(action) 的修饰键错误")
            // 标题走本地化表；缺键时 L() 回退键名本身，据此发现漏翻。
            #expect(!item.title.isEmpty && item.title != "menu.edit.\(actionName(action))",
                    "\(action) 标题疑似未走本地化表：\(item.title)")
        }
    }

    private func actionName(_ action: String) -> String {
        String(action.dropLast(1))
    }
}
