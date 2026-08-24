import AppKit

// MARK: - 隐藏主菜单（标准编辑快捷键载体）

// NotchCenter 是 accessory 应用：没有可见菜单栏，程序化启动也不会得到带
// Edit 菜单的默认主菜单。⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 属于菜单键等价物，分发
// 路径是 keyWindow.performKeyEquivalent → NSApp.mainMenu → nil-target 动作
// 沿响应链落到 NSTextView 的 copy: 等实现；菜单缺失时按键在进入响应链之前
// 就被丢弃——表现为“笔记编辑器里复制/粘贴等快捷键无效”（普通输入不受影响）。
//
// 这里显式安装一份含应用菜单 + Edit 菜单的主菜单：accessory 应用不显示
// 它，但键等价物匹配照常生效；条目一律 nil target + 标准选择器，让启用
// 校验与动作解析都走系统默认的响应链逻辑（抽屉编辑器、设置窗口、插件
// 管理窗口的文本输入全部受益）。不要移除这份菜单来“修”快捷键问题。
@MainActor
enum EditMenuInstaller {
    /// 在启动时安装主菜单；重复调用无害（整份替换）。
    static func install() {
        NSApp.mainMenu = makeMainMenu()
    }

    /// 构造隐藏主菜单。纯构造、不触碰 NSApp 全局状态，便于单测断言接线。
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // 应用菜单：保留 Quit / Hide 的键等价物（⌘Q / ⌘H），避免替换默认
        // 主菜单后这两个系统级快捷键失效。
        let appMenu = NSMenu()
        appMenu.addItem(
            localizedItem(key: "menu.app.hide",
                          action: #selector(NSApplication.hide(_:)),
                          key: "h", modifiers: [.command])
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            localizedItem(key: "menu.app.quit",
                          action: #selector(NSApplication.terminate(_:)),
                          key: "q", modifiers: [.command])
        )
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        // 编辑菜单：nil-target 标准编辑动作，沿响应链解析到 NSTextView。
        let edit = NSMenu(title: "Edit")
        edit.addItem(
            // undo:/redo: 是响应链动作选择器（NSTextView 转发给自己的
            // undoManager），Swift 未在 UndoManager 上暴露带 sender 的重载，
            // 只能按名字构造。
            localizedItem(key: "menu.edit.undo",
                          action: Selector(("undo:")),
                          key: "z", modifiers: [.command])
        )
        edit.addItem(
            localizedItem(key: "menu.edit.redo",
                          action: Selector(("redo:")),
                          key: "z", modifiers: [.command, .shift])
        )
        edit.addItem(.separator())
        edit.addItem(
            localizedItem(key: "menu.edit.cut",
                          action: #selector(NSText.cut(_:)),
                          key: "x", modifiers: [.command])
        )
        edit.addItem(
            localizedItem(key: "menu.edit.copy",
                          action: #selector(NSText.copy(_:)),
                          key: "c", modifiers: [.command])
        )
        edit.addItem(
            localizedItem(key: "menu.edit.paste",
                          action: #selector(NSText.paste(_:)),
                          key: "v", modifiers: [.command])
        )
        edit.addItem(.separator())
        edit.addItem(
            localizedItem(key: "menu.edit.selectAll",
                          action: #selector(NSText.selectAll(_:)),
                          key: "a", modifiers: [.command])
        )
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = edit
        main.addItem(editMenuItem)

        return main
    }

    /// 标题走宿主本地化表；target 保持 nil，由响应链在运行时解析。
    private static func localizedItem(
        key: String,
        action: Selector,
        key keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: L(key), action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
