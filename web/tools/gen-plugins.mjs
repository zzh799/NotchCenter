#!/usr/bin/env node
// 生成主页的插件清单：Plugins/*/Plugin.plist -> web/data/plugins.gen.js
//
// 为什么要有这个脚本：仓库纪律明确「插件列表任何脚本/清单都不得手工维护」
// （AGENTS.md FAQ）。README 曾因此写错插件数与清单，主页不能再复制一份会漂移
// 的手写数据。这里的输入只有 Plugin.plist 本身，页面上的插件数量取自数组长度，
// 因此主页在结构上不可能与 Plugins/ 脱节。
//
// 为什么用 plutil 而不是自写 plist 解析器：Plugin.plist 是 XML plist，自写解析
// 器要处理实体转义、CDATA、嵌套 dict/array，是纯 bug 面；`plutil -convert json`
// 是 macOS 自带工具，零依赖且语义正确。代价是需要 macOS（发布 workflow 因此跑
// macOS runner，见 .github/workflows/pages.yml）。
//
// 用法：
//   node web/tools/gen-plugins.mjs          写入 web/data/plugins.gen.js
//   node web/tools/gen-plugins.mjs --check  只比对不写入，不一致则退出码 1（CI 防漂移门禁）
//
// 为什么按目录名排序而不是英文名：插件发现顺序（scripts/build.sh、Project.swift）
// 就是 Plugins/* 的目录名字典序，应用内插件管理列表用的也是这个顺序。主页沿用同一
// 顺序，站点与应用看到的次序一致。

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const WEB_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const REPO_ROOT = path.dirname(WEB_DIR);
const PLUGINS_DIR = path.join(REPO_ROOT, "Plugins");
const OUTPUT_PATH = path.join(WEB_DIR, "data", "plugins.gen.js");

const checkOnly = process.argv.includes("--check");

function fail(message) {
  console.error(`gen-plugins: ${message}`);
  process.exit(1);
}

// 单个 plist 转成 JS 对象。plutil 的 JSON 输出对 <true/> 等类型同样成立。
function readPlist(plistPath) {
  let json;
  try {
    json = execFileSync("plutil", ["-convert", "json", "-o", "-", plistPath], {
      encoding: "utf8",
    });
  } catch (error) {
    fail(`无法解析 ${path.relative(REPO_ROOT, plistPath)}：${error.message.trim()}`);
  }
  try {
    return JSON.parse(json);
  } catch (error) {
    fail(`${path.relative(REPO_ROOT, plistPath)} 转 JSON 失败：${error.message}`);
  }
}

function localized(dict, fallback) {
  const value = dict && typeof dict["zh-Hans"] === "string" ? dict["zh-Hans"].trim() : "";
  return value === "" ? fallback : value;
}

// 只扫 Plugin.plist：Plugins/ 下另一个目录 LidAngleKit 是「可复用动态库」而非插件
// （Project.swift / build.sh 用白名单标注），它没有 Plugin.plist，天然被排除。
// 缺元数据的插件由 Project.swift 的 manifest 直接报错拦下，不归本脚本负责，
// 这里也就不需要再维护一份共享库白名单。
function collectPlugins() {
  const plists = readdirSync(PLUGINS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .map((name) => ({ name, plist: path.join(PLUGINS_DIR, name, "Plugin.plist") }))
    .filter(({ plist }) => existsSync(plist));

  if (plists.length === 0) {
    fail(`${path.relative(REPO_ROOT, PLUGINS_DIR)} 下没有发现任何 Plugin.plist`);
  }

  const seenIds = new Map();
  const plugins = plists.map(({ name, plist }) => {
    const dict = readPlist(plist);
    const required = ["PluginID", "DisplayName", "Description"];
    for (const key of required) {
      if (typeof dict[key] !== "string" || dict[key].trim() === "") {
        fail(`${name}/Plugin.plist 缺少必填字段 ${key}`);
      }
    }

    const id = dict.PluginID.trim();
    if (seenIds.has(id)) {
      fail(`PluginID 重复：${id}（${name} 与 ${seenIds.get(id)}）`);
    }
    seenIds.set(id, name);

    const nameEn = dict.DisplayName.trim();
    const descEn = dict.Description.trim();
    const nameZh = localized(dict.DisplayNameLocales, nameEn);
    const descZh = localized(dict.DescriptionLocales, descEn);
    if (nameZh === nameEn || descZh === descEn) {
      console.warn(`gen-plugins: 提示 ${name} 缺少 zh-Hans 元数据，中文页将回退英文`);
    }

    // 字段顺序固定，保证同一份输入产出字节一致的输出（--check 才能可靠比对）。
    return {
      dir: name,
      id,
      name: { en: nameEn, zh: nameZh },
      desc: { en: descEn, zh: descZh },
    };
  });

  return plugins;
}

function render(plugins) {
  const header = [
    "// 本文件由 web/tools/gen-plugins.mjs 生成，请勿手工编辑。",
    "// 数据源：Plugins/*/Plugin.plist（PluginID / DisplayName / Description / *Locales.zh-Hans）。",
    "// 顺序与插件发现顺序一致（Plugins/* 目录名字典序）。改 Plugin.plist 后请重新运行：",
    "//   node web/tools/gen-plugins.mjs",
    `window.NOTCH_PLUGINS = ${JSON.stringify(plugins, null, 2)};`,
    "",
  ];
  return header.join("\n");
}

const plugins = collectPlugins();
const content = render(plugins);

if (checkOnly) {
  const current = existsSync(OUTPUT_PATH) ? readFileSync(OUTPUT_PATH, "utf8") : "";
  if (current !== content) {
    console.error(
      `gen-plugins: ${path.relative(REPO_ROOT, OUTPUT_PATH)} 与 Plugins/*/Plugin.plist 不同步。\n` +
        "请运行 `node web/tools/gen-plugins.mjs` 并提交生成结果。",
    );
    process.exit(1);
  }
  console.log(`gen-plugins: 已同步（${plugins.length} 个插件）`);
} else {
  mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  writeFileSync(OUTPUT_PATH, content);
  console.log(`gen-plugins: 写入 ${path.relative(REPO_ROOT, OUTPUT_PATH)}（${plugins.length} 个插件）`);
}
