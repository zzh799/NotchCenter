import AppKit
import NotchCenter

// 应用用户在设置面板选择的语言覆盖（写入 AppleLanguages），
// 必须在任何本地化字符串 / bundle 加载之前执行。
SettingsStore.applyLanguageOverrideAtLaunch()

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()