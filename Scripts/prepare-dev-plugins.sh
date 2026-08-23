#!/usr/bin/env bash
# 开发期插件 bundle 组装脚本（文档 §2.3 / §3.1 / §3.2）。
#
# SPM 不直接产出 .bundle；本脚本把构建好的插件动态库包装成标准 bundle：
#   <Name>.bundle/Contents/Info.plist + <Name>.bundle/Contents/MacOS/<Name>
# 并放到可执行文件旁的 PlugIns/ 目录（.build/<config>/PlugIns），
# 使 `swift run NotchCenter` 直接发现并加载官方插件。
#
# 用法: ./Scripts/prepare-dev-plugins.sh [debug|release]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BUILD_ROOT="$ROOT_DIR/.build"
API_RANGE="1.0..<2.0"
API_RANGE_XML="${API_RANGE//</&lt;}"   # XML 转义（解析后仍是 1.0..<2.0）

cd "$ROOT_DIR"

# 与可执行文件同目录（swift run 时 Bundle.main 指向该目录）。
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
PLUGINS_DIR="$BIN_DIR/PlugIns"

for product in NotesPlugin ScratchpadPlugin CaffeinatePlugin DshPlugin; do
  echo "Building $product..."
  swift build -c "$CONFIG" --product "$product"
done

rm -rf "$PLUGINS_DIR"
mkdir -p "$PLUGINS_DIR"

for product in NotesPlugin ScratchpadPlugin CaffeinatePlugin DshPlugin; do
  DYLIB="$(find "$BUILD_ROOT" -path "*/$CONFIG/lib$product.dylib" -not -path "*/PlugIns/*" | head -1)"
  if [[ ! -f "$DYLIB" ]]; then
    echo "找不到构建产物: $product.dylib" >&2
    exit 1
  fi

  # 插件元数据（与官方插件 Info.plist 约定一致，见架构文档 §3.2）。
  case "$product" in
    NotesPlugin)
      PLUGIN_ID="com.notchcenter.notes"
      PLUGIN_VERSION="1.0.0"
      DISPLAY_NAME="Notes"
      DESCRIPTION="Markdown notes with TextKit 2 rendering."
      ;;
    ScratchpadPlugin)
      PLUGIN_ID="com.notchcenter.scratchpad"
      PLUGIN_VERSION="1.0.0"
      DISPLAY_NAME="Scratchpad"
      DESCRIPTION="A tray that references files you may want later."
      ;;
    CaffeinatePlugin)
      PLUGIN_ID="com.notchcenter.caffeinate"
      PLUGIN_VERSION="1.0.0"
      DISPLAY_NAME="Keep Awake"
      DESCRIPTION="Keeps your Mac awake on demand."
      ;;
    DshPlugin)
      PLUGIN_ID="com.zhouzihang.notchcenter.dsh"
      PLUGIN_VERSION="1.0.0"
      DISPLAY_NAME="DSH Service"
      DESCRIPTION="Controls the dsh-web launchd service."
      ;;
  esac

  BUNDLE_DIR="$PLUGINS_DIR/$product.bundle"
  CONTENTS_DIR="$BUNDLE_DIR/Contents"
  mkdir -p "$CONTENTS_DIR/MacOS"
  cp "$DYLIB" "$CONTENTS_DIR/MacOS/$product"

  cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$PLUGIN_ID.bundle</string>
  <key>CFBundleExecutable</key>
  <string>$product</string>
  <key>CFBundleName</key>
  <string>$product</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>$PLUGIN_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>$product</string>
  <key>NotchCenterPluginID</key>
  <string>$PLUGIN_ID</string>
  <key>NotchCenterPluginVersion</key>
  <string>$PLUGIN_VERSION</string>
  <key>NotchCenterPluginAPIVersion</key>
  <string>$API_RANGE_XML</string>
  <key>NotchCenterPluginDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>NotchCenterPluginDescription</key>
  <string>$DESCRIPTION</string>
</dict>
</plist>
EOF

  echo "Prepared $PLUGINS_DIR/$product.bundle"
done

echo "Dev plugin bundles ready at $PLUGINS_DIR"