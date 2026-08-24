# NotchCenter

NotchCenter 是一款原生 macOS 刘海交互**插件宿主**应用。将鼠标移到或点击屏幕顶部中央的刘海区域展开抽屉，抽屉网格与紧凑刘海区展示各插件提供的“块”。

核心只负责刘海区域交互、窗口管理、插件加载与生命周期、布局引擎与状态存储；笔记、文件暂存、防休眠等功能以官方插件形式提供，第三方插件可动态安装（`.bundle`）。架构基线见 [`docs/NotchCenter 架构设计文档.md`](docs/NotchCenter%20架构设计文档.md)。

## 下载与安装

- [下载最新版](https://github.com/oil-oil/NotchCenter/releases/latest/download/NotchCenter.zip)
- [打开产品官网](https://oil-oil.github.io/NotchCenter/)

下载包同时支持 Apple Silicon 和 Intel，要求 macOS 14 或更高版本。

1. 解压 `NotchCenter.zip`，将 `NotchCenter.app` 移入“应用程序”。
2. 首次启动时右键点击应用，选择“打开”。
3. 如果 macOS 仍然拦截，请前往“系统设置 → 隐私与安全性”，点击“仍要打开”。

当前公开构建使用临时签名，尚未经过 Apple 公证，因此首次启动会出现安全提示。正式免提示分发需要 Developer ID Application 证书和 Apple 公证。

## 使用

启动后，将鼠标移到或点击屏幕顶部中央展开抽屉。已启用插件的块显示在刘海下方的 3 个紧凑槽位与抽屉网格中；点击状态栏图标可进入“插件管理…”启用/禁用插件、安装第三方 `.bundle`，或通过“编辑布局”拖拽重排、缩放与添加块。

官方插件：

- **Notes**：多标签 Markdown 笔记（TextKit 2 编辑器，支持内嵌图片）。
- **Scratchpad**：文件暂存区，只保留文件引用，不会移动或删除原文件。
- **Keep Awake**：一键防止 Mac 休眠（需要管理员权限）。

笔记和暂存记录保存在本机，不会因覆盖安装应用而删除。

## 本地运行

```bash
./Scripts/prepare-dev-plugins.sh   # 组装官方插件 bundle 到 dev PlugIns 目录
swift run NotchCenter
```

## 构建发布包

```bash
./Scripts/package-app.sh
open dist.noindex/NotchCenter.app
```

脚本会生成 Apple Silicon + Intel 通用应用（含 `Contents/PlugIns/` 官方插件与 `Contents/Frameworks/` 共享框架）、ZIP 附件和 SHA-256 校验文件。正式签名和公证时可设置：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="notary-profile" \
./Scripts/package-app.sh
```

## 自动发布

- 每次推送 `main`，GitHub Actions 会先运行测试，再构建通用应用，并自动覆盖 `latest` Release。
- 官网下载按钮固定指向 `releases/latest`，因此不需要手动修改下载地址。
- 推送 `v*` 版本标签时，仍会生成对应的版本快照 Release。
- 官网由 GitHub Pages 读取 `main` 分支的 `docs` 目录，页面修改推送后会自动部署。

如果测试或构建失败，Release 不会被覆盖，用户仍会下载上一份验证通过的版本。

## 技术栈

- Swift + AppKit：浮层窗口（`NSPanel`）、窗口层级、屏幕定位和顶部触发行为。
- SwiftUI：紧凑区、抽屉网格、编辑模式与插件管理界面。
- 插件系统：动态 `.bundle` + `NSPrincipalClass`，共享 `NotchCenterKit` 动态库，插件状态经 `StateStore` 键值持久化。
- MarkdownEngine：Notes 插件的 Markdown 编辑和内嵌图片。