#!/usr/bin/env bash
# NotchCenter 发布打包：通用架构 .app + 内置插件 bundle + 共享框架 + zip + sha256。
# 产物结构（文档 §2.2 / §2.3）：
#   NotchCenter.app/
#     Contents/MacOS/NotchCenter
#     Contents/Frameworks/libNotchCenterKit.dylib
#     Contents/PlugIns/<Name>.bundle/{Contents/Info.plist, Contents/MacOS/<Name>}
#     Contents/Resources/AppIcon.icns
#
# 依赖的 install_name 均为 @rpath 形式（SwiftPM 动态库产物），
# 宿主与插件已内置对应 rpath，无需 install_name_tool 修复。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NotchCenter"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release-universal}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist.noindex}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.png"
SOURCE_PLIST="$ROOT_DIR/Resources/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
API_RANGE="1.0..<2.0"
API_RANGE_XML="${API_RANGE//</&lt;}"   # XML 转义（解析后仍是 1.0..<2.0）

cd "$ROOT_DIR"

swift build \
  -c release \
  --arch arm64 \
  --arch x86_64 \
  --scratch-path "$BUILD_DIR"

PRODUCTS_DIR="$BUILD_DIR/apple/Products/Release"
BINARY_PATH="$PRODUCTS_DIR/$APP_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "找不到构建产物：$BINARY_PATH" >&2
  exit 1
fi

ARCHS="$(lipo -archs "$BINARY_PATH")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "构建产物不是通用架构：$ARCHS" >&2
  exit 1
fi

rm -rf "$APP_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR" "$PLUGINS_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
cp "$SOURCE_PLIST" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

# 共享框架（宿主与插件通过 @rpath 解析）。
KIT_DYLIB="$PRODUCTS_DIR/libNotchCenterKit.dylib"
if [[ -f "$KIT_DYLIB" ]]; then
  cp "$KIT_DYLIB" "$FRAMEWORKS_DIR/libNotchCenterKit.dylib"
else
  echo "找不到框架产物：$KIT_DYLIB" >&2
  exit 1
fi

# LaunchdControlKit（DshPlugin 依赖的独立基础库动态库）。
LAUNCHD_DYLIB="$PRODUCTS_DIR/libLaunchdControlKit.dylib"
if [[ -f "$LAUNCHD_DYLIB" ]]; then
  cp "$LAUNCHD_DYLIB" "$FRAMEWORKS_DIR/libLaunchdControlKit.dylib"
else
  echo "找不到框架产物：$LAUNCHD_DYLIB" >&2
  exit 1
fi

# 内置官方插件 bundle。
for product in NotesPlugin ScratchpadPlugin CaffeinatePlugin DshPlugin; do
  DYLIB="$PRODUCTS_DIR/lib$product.dylib"
  if [[ ! -f "$DYLIB" ]]; then
    echo "找不到插件产物：$DYLIB" >&2
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

done

if [[ -f "$SOURCE_ICON" ]]; then
  TMP_ICON_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_ICON_DIR"' EXIT
  ICONSET_DIR="$TMP_ICON_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$TMP_ICON_DIR"
  trap - EXIT
fi

xattr -cr "$APP_DIR"

sign_nested() {
  codesign --force --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/libNotchCenterKit.dylib"
  for bundle in "$PLUGINS_DIR"/*.bundle; do
    codesign --force --sign "$SIGN_IDENTITY" "$bundle"
  done
}

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  sign_nested
  codesign --force --sign - "$APP_DIR"
else
  sign_nested "$SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

create_archive() {
  rm -f "$ZIP_PATH"
  ditto --norsrc -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
}

create_archive

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "公证需要 Developer ID 签名，请设置 SIGN_IDENTITY。" >&2
    exit 1
  fi

  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  spctl --assess --type execute --verbose=2 "$APP_DIR"
  create_archive
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256"
)

echo "Built $APP_DIR"
echo "Architectures: $ARCHS"
echo "Archive: $ZIP_PATH"
echo "Checksum: $CHECKSUM_PATH"