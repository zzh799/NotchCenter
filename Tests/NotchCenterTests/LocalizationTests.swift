import Foundation
import Testing
@testable import NotchCenter

// MARK: - 多语言方案回归测试（en / zh-Hans）
//
// 不依赖 AppKit 运行环境，直接校验两层约定：
// 1. 源码树里每个模块的 en 与 zh-Hans Localizable.strings 键集合一致（防止漏翻）；
// 2. 各插件 Plugin.plist 带 zh-Hans 元数据译文（build.sh 生成 InfoPlist.strings 的输入）；
// 3. 语言覆盖启动逻辑按预期写 / 清 AppleLanguages。

private let repoRoot: URL = {
    // 测试源码位于 <root>/Tests/NotchCenterTests/，上溯两级即包根。
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // Tests
    url.deleteLastPathComponent() // 包根
    url.deleteLastPathComponent()
    return url
}()

/// 解析 openstep 风格 .strings 文件为字典；解析失败直接让测试失败。
private func parseStringsFile(_ url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    var format: PropertyListSerialization.PropertyListFormat = .openStep
    guard let plist = try PropertyListSerialization.propertyList(
        from: data, options: [], format: &format
    ) as? [String: String] else {
        Issue.record("无法把 \(url.path) 解析为 [String: String]")
        return [:]
    }
    return plist
}

struct LocalizationTests {
    /// 参与本地化键位奇偶校验的模块：宿主 + 全部官方插件目录名。
    static let modules = [
        "Sources/NotchCenter",
        "Plugins/NotesPlugin",
        "Plugins/ScratchpadPlugin",
        "Plugins/CaffeinatePlugin",
        "Plugins/DshPlugin",
        "Plugins/CalibrePlugin",
        "Plugins/PomodoroPlugin",
        "Plugins/DisplayPlugin",
        "Plugins/ClipboardHistoryPlugin",
        "Plugins/CameraPlugin",
        "Plugins/CalendarPlugin",
        "Plugins/ClockPlugin",
        "Plugins/LidAngleDepthPlugin",
        "Plugins/CommandSchedulerPlugin",
        "Plugins/SystemMonitorPlugin",
        "Plugins/RemindersPlugin",
        "Plugins/MediaControlsPlugin"
    ]

    @Test(arguments: LocalizationTests.modules)
    func enAndZhHansTablesHaveIdenticalKeys(modulePath: String) throws {
        let base = repoRoot.appendingPathComponent(modulePath).appendingPathComponent("Resources")
        let en = try parseStringsFile(base.appendingPathComponent("en.lproj/Localizable.strings"))
        let zh = try parseStringsFile(base.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))

        let missingInZh = Set(en.keys).subtracting(zh.keys).sorted()
        let missingInEn = Set(zh.keys).subtracting(en.keys).sorted()
        #expect(missingInZh.isEmpty, "\(modulePath) zh-Hans 缺少键：\(missingInZh)")
        #expect(missingInEn.isEmpty, "\(modulePath) en 缺少键：\(missingInEn)")

        // 值不能为空：空翻译会以空串上屏而不是回退英文。
        for (key, value) in en { #expect(!value.isEmpty, "\(modulePath) en 键 \(key) 值为空") }
        for (key, value) in zh { #expect(!value.isEmpty, "\(modulePath) zh-Hans 键 \(key) 值为空") }
    }

    @Test(arguments: [
        "NotesPlugin", "ScratchpadPlugin", "CaffeinatePlugin", "DshPlugin", "CalibrePlugin",
        "PomodoroPlugin", "DisplayPlugin",
        "ClipboardHistoryPlugin", "CameraPlugin",
        "CommandSchedulerPlugin", "SystemMonitorPlugin", "CalendarPlugin", "ClockPlugin",
        "MediaControlsPlugin",
    ])
    func pluginPlistCarriesChineseMetadataLocales(plugin: String) throws {
        let url = repoRoot
            .appendingPathComponent("Plugins/\(plugin)/Plugin.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: Any])

        let display = try #require(dict["DisplayNameLocales"] as? [String: String])
        let description = try #require(dict["DescriptionLocales"] as? [String: String])
        #expect(display["zh-Hans"]?.isEmpty == false, "\(plugin) 缺少 DisplayNameLocales.zh-Hans")
        #expect(description["zh-Hans"]?.isEmpty == false, "\(plugin) 缺少 DescriptionLocales.zh-Hans")
    }

    /// 插件元数据里的 `&` / `<` / `>` 必须被 XML 转义后再拼进 bundle 的 Info.plist。
    ///
    /// `build.sh` 是手写 XML 模板拼 Info.plist，DisplayName/Description 是自由文本。
    /// 未转义的 `&`（如 "Calendar & Tasks"）会让整个 plist 不合法，bundle 直接加载
    /// 失败——而且失败点在产物里，源码与插件单测都看不出来。这里锁住转义函数契约。
    @Test(arguments: [
        ("Calendar & Tasks", "Calendar &amp; Tasks"),
        ("A < B > C", "A &lt; B &gt; C"),
        // `&` 必须最先替换，否则会把后续生成的实体再转义一遍（&amp;lt;）。
        ("&lt;", "&amp;lt;"),
        ("plain text", "plain text"),
    ])
    func pluginMetadataIsXMLSafe(input: String, expected: String) throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        #expect(script.contains("xml_escape"), "build.sh 必须提供 xml_escape")
        // 断言转义顺序：`&` 的处理早于 `<`。
        let ampIndex = try #require(script.range(of: "s=\"${s//&/&amp;}\"")?.lowerBound)
        let ltIndex = try #require(script.range(of: "s=\"${s//</&lt;}\"")?.lowerBound)
        #expect(ampIndex < ltIndex, "`&` 必须先于 `<` 替换，否则会二次转义")
        // 元数据模板必须用转义后的数组，而不是原始值。
        #expect(script.contains("${PLUGIN_DISPLAYS_XML[$i]}"))
        #expect(script.contains("${PLUGIN_DESCRIPTIONS_XML[$i]}"))
        _ = (input, expected)
    }

    /// 每个官方插件的 DisplayName/Description 经过与 build.sh 相同的转义后，
    /// 拼出来的 XML 必须能被 PropertyListSerialization 解析。
    @Test(arguments: LocalizationTests.modules.filter { $0.hasPrefix("Plugins/") })
    func pluginMetadataProducesParseableXML(modulePath: String) throws {
        let plugin = (modulePath as NSString).lastPathComponent
        let url = repoRoot.appendingPathComponent("Plugins/\(plugin)/Plugin.plist")
        let data = try Data(contentsOf: url)
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let display = try #require(dict["DisplayName"] as? String)
        let description = try #require(dict["Description"] as? String)

        // 与 build.sh 的 xml_escape 同序：& → < → >。
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>NotchCenterPluginDisplayName</key><string>\(escape(display))</string>
        <key>NotchCenterPluginDescription</key><string>\(escape(description))</string>
        </dict></plist>
        """
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil
        ) as? [String: String]
        #expect(parsed?["NotchCenterPluginDisplayName"] == display, "\(plugin) 的显示名转义后必须原样还原")
        #expect(parsed?["NotchCenterPluginDescription"] == description)
    }

    @Test func languageOverrideAppliesAtLaunch() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 只看本套件持久域里的值：object(forKey:) 会穿透到全局注册域（系统默认
        // AppleLanguages 恒存在），“移除覆盖”无法用普通读取区分。
        var overriddenValue: [String]? {
            defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
        }

        // 覆盖为中文：AppleLanguages 应写成单语言数组。
        defaults.set("zh-Hans", forKey: "notchCenter.language")
        SettingsStore.applyLanguageOverrideAtLaunch(defaults: defaults)
        #expect(overriddenValue == ["zh-Hans"])

        // 覆盖为英文同理。
        defaults.set("en", forKey: "notchCenter.language")
        SettingsStore.applyLanguageOverrideAtLaunch(defaults: defaults)
        #expect(overriddenValue == ["en"])

        // 跟随系统 / 未设置：必须清掉应用级覆盖，恢复系统偏好顺序。
        defaults.set("system", forKey: "notchCenter.language")
        SettingsStore.applyLanguageOverrideAtLaunch(defaults: defaults)
        #expect(overriddenValue == nil)

        defaults.removeObject(forKey: "notchCenter.language")
        SettingsStore.applyLanguageOverrideAtLaunch(defaults: defaults)
        #expect(overriddenValue == nil)
    }
}
