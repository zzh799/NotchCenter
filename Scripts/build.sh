#!/usr/bin/env bash
# NotchCenter 统一构建脚本。插件唯一登记处是各插件的 Plugins/<Name>/Plugin.plist，
# 本脚本与 Package.swift 都从 Plugins/ 目录自动发现插件，新增插件不需要改任何列表或 case 分支。
#
# 用法:
#   build.sh dev [debug|release]   全量构建，把插件 dylib 组装成 .bundle 放到
#                                  .build/<config>/PlugIns/（swift run 直接发现加载）
#   build.sh package               发布打包：通用架构 .app + 内置插件 bundle + 共享框架
#                                  + zip + sha256（可选公证），产物在 dist.noindex/
#   build.sh clean                 删除 .build 与 dist.noindex（均为纯可再生制品）
#
# 环境变量（仅 package）：APP_VERSION、BUILD_NUMBER、SIGN_IDENTITY、NOTARY_PROFILE。
#
# 发布产物结构（文档 §2.2 / §2.3）：
#   NotchCenter.app/
#     Contents/MacOS/NotchCenter
#     Contents/Frameworks/libNotchCenterKit.dylib
#     Contents/Frameworks/libLaunchdControlKit.dylib
#     Contents/PlugIns/<Name>.bundle/{Contents/Info.plist, Contents/MacOS/<Name>}
#     Contents/Resources/AppIcon.icns
#
# 依赖的 install_name 均为 @rpath 形式（SwiftPM 动态库产物），
# 宿主与插件已内置对应 rpath，无需 install_name_tool 修复。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS_SRC_DIR="$ROOT_DIR/Plugins"

# 插件 API 版本全局默认值；个别插件可在其 Plugin.plist 的 APIVersionRange 覆盖。
API_RANGE="1.0..<2.0"
API_RANGE_XML="${API_RANGE//</&lt;}"   # XML 转义（解析后仍是 1.0..<2.0）

die() { echo "错误：$*" >&2; exit 1; }

usage() {
  sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- 插件自动发现 ------------------------------------------------------------
# 发现结果存入并行数组：名字即文件夹名，也即 SPM 产品名与 Info.plist 的 CFBundleExecutable。
PLUGIN_NAMES=()
PLUGIN_IDS=()
PLUGIN_VERSIONS=()
PLUGIN_DISPLAYS=()
PLUGIN_DESCRIPTIONS=()
PLUGIN_PRINCIPALS=()
PLUGIN_API_RANGES_XML=()
# 可选的元数据本地化（多语言方案）：Plugin.plist 里 DisplayNameLocales /
# DescriptionLocales 字典按语言键存放译文，这里只取 zh-Hans（en 用基准字段）。
PLUGIN_DISPLAY_ZH=()
PLUGIN_DESC_ZH=()

# 读取 plist 字符串键；键缺失时输出空串（是否致命由调用方判断）。
# 注意：plutil 失败时会把错误文本写到 stdout，必须整体丢弃，否则错误文本会被当成值捕获。
plist_get() { # $1=key $2=plist
  local out
  if ! out="$(plutil -extract "$1" raw -o - "$2" 2>/dev/null)"; then
    out=""
  fi
  printf '%s' "$out"
}

discover_plugins() {
  # SwiftPM 会缓存清单求值结果，新建插件目录不会触发重新扫描；
  # touch Package.swift 强制每次重算，保证新插件立刻被发现（清单求值开销在亚秒级）。
  touch "$ROOT_DIR/Package.swift"

  local dir name plist value
  for dir in "$PLUGINS_SRC_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    plist="$dir/Plugin.plist"
    # 缺元数据直接报错而非跳过：新建插件忘了写 Plugin.plist 时必须炸出来，不能静默漏打包。
    [[ -f "$plist" ]] || die "插件目录缺少 Plugin.plist：$dir"

    for key in PluginID Version DisplayName Description; do
      value="$(plist_get "$key" "$plist")"
      [[ -n "$value" ]] || die "$plist 缺少必填字段 $key"
    done

    local id version display description principal api_xml
    id="$(plist_get PluginID "$plist")"
    version="$(plist_get Version "$plist")"
    display="$(plist_get DisplayName "$plist")"
    description="$(plist_get Description "$plist")"
    # 类名缺省等于产品名（依赖 @objc(ClassName) 与类名一致的约定）；特殊类名可显式覆盖。
    principal="$(plist_get NSPrincipalClass "$plist")"
    [[ -n "$principal" ]] || principal="$name"
    api_xml="${API_RANGE_XML}"
    value="$(plist_get APIVersionRange "$plist")"
    if [[ -n "$value" ]]; then
      api_xml="${value//</&lt;}"
    fi

    # 插件身份（PluginID）必须全局唯一，重复会让宿主把两个插件当成同一个。
    for existing in "${PLUGIN_IDS[@]:-}"; do
      [[ "$existing" != "$id" ]] || die "PluginID 重复：$id（$name 与已发现插件冲突）"
    done

    PLUGIN_NAMES+=("$name")
    PLUGIN_IDS+=("$id")
    PLUGIN_VERSIONS+=("$version")
    PLUGIN_DISPLAYS+=("$display")
    PLUGIN_DESCRIPTIONS+=("$description")
    PLUGIN_PRINCIPALS+=("$principal")
    PLUGIN_API_RANGES_XML+=("$api_xml")
    PLUGIN_DISPLAY_ZH+=("$(plist_get "DisplayNameLocales.zh-Hans" "$plist")")
    PLUGIN_DESC_ZH+=("$(plist_get "DescriptionLocales.zh-Hans" "$plist")")
  done
  (( ${#PLUGIN_NAMES[@]} > 0 )) || die "$PLUGINS_SRC_DIR 下没有发现任何插件目录"
}

# 组装单个插件 bundle 并生成 Info.plist（模板结构见架构文档 §3.2）。
# $4 = SPM 产物目录（含 <Name>_<Name>.bundle 资源包），dev 与 package 的路径不同。
assemble_bundle() { # $1=目标PlugIns目录 $2=索引 $3=dylib路径 $4=SPM产物目录
  local dest_root="$1" i="$2"
  local name="${PLUGIN_NAMES[$i]}" dylib="$3"
  local bundle_dir contents_dir resources_dir

  if [[ ! -f "$dylib" ]]; then
    die "找不到插件产物：lib$name.dylib"
  fi

  bundle_dir="$dest_root/$name.bundle"
  contents_dir="$bundle_dir/Contents"
  resources_dir="$contents_dir/Resources"
  mkdir -p "$contents_dir/MacOS" "$resources_dir"
  cp "$dylib" "$contents_dir/MacOS/$name"

  # 本地化 UI 文案：把 SPM 资源包里的 lproj 平铺复制进 Contents/Resources，
  # 插件代码用 Bundle(for:) 在这个 bundle 里查 Localizable.strings。
  # SPM 资源包命名规则是 <包名>_<target名>.bundle。
  local spm_res_bundle="$4/NotchCenter_${name}.bundle"
  if [[ -d "$spm_res_bundle" ]]; then
    cp -R "$spm_res_bundle/"*.lproj "$resources_dir/" 2>/dev/null || true
  else
    echo "警告：找不到 $name 的本地化资源包 ${spm_res_bundle}，插件 UI 将回退英文。" >&2
  fi

  # 本地化元数据：DisplayNameLocales / DescriptionLocales 生成 InfoPlist.strings。
  local display_zh="${PLUGIN_DISPLAY_ZH[$i]}" desc_zh="${PLUGIN_DESC_ZH[$i]}"
  if [[ -n "$display_zh" || -n "$desc_zh" ]]; then
    mkdir -p "$resources_dir/zh-Hans.lproj"
    cat > "$resources_dir/zh-Hans.lproj/InfoPlist.strings" <<EOF
/* 由 build.sh 从 Plugin.plist 自动生成，不要手工修改。 */
"NotchCenterPluginDisplayName" = "${display_zh//\\/\\\\}";
"NotchCenterPluginDescription" = "${desc_zh//\\/\\\\}";
EOF
  fi

  cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- 开发区域语言：本地化缺失时的回退基准 -->
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleIdentifier</key>
  <string>${PLUGIN_IDS[$i]}.bundle</string>
  <key>CFBundleExecutable</key>
  <string>$name</string>
  <key>CFBundleName</key>
  <string>$name</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${PLUGIN_VERSIONS[$i]}</string>
  <key>NSPrincipalClass</key>
  <string>${PLUGIN_PRINCIPALS[$i]}</string>
  <key>NotchCenterPluginID</key>
  <string>${PLUGIN_IDS[$i]}</string>
  <key>NotchCenterPluginVersion</key>
  <string>${PLUGIN_VERSIONS[$i]}</string>
  <key>NotchCenterPluginAPIVersion</key>
  <string>${PLUGIN_API_RANGES_XML[$i]}</string>
  <key>NotchCenterPluginDisplayName</key>
  <string>${PLUGIN_DISPLAYS[$i]}</string>
  <key>NotchCenterPluginDescription</key>
  <string>${PLUGIN_DESCRIPTIONS[$i]}</string>
</dict>
</plist>
EOF
}

# 在构建产物目录里定位插件 dylib（排除 PlugIns 里已组装的旧 bundle 副本）。
find_plugin_dylib() { # $1=name $2=config
  find "$ROOT_DIR/.build" -path "*/$2/lib$1.dylib" -not -path "*/PlugIns/*" | head -1
}

# ---- 子命令 ------------------------------------------------------------------

cmd_dev() {
  local config="${1:-debug}"
  case "$config" in debug|release) ;; *) usage >&2; die "未知配置：$config（可用 debug|release）";; esac

  cd "$ROOT_DIR"
  discover_plugins

  echo "Building (${config})..."
  # 全量一次构建：增量缓存下通常只重编改动过的插件；失败时 SPM 会指明具体 target。
  swift build -c "$config"

  local bin_dir plugins_out dylib i
  bin_dir="$(swift build -c "$config" --show-bin-path)"
  plugins_out="$bin_dir/PlugIns"
  rm -rf "$plugins_out"
  mkdir -p "$plugins_out"

  for i in "${!PLUGIN_NAMES[@]}"; do
    dylib="$(find_plugin_dylib "${PLUGIN_NAMES[$i]}" "$config")"
    assemble_bundle "$plugins_out" "$i" "$dylib" "$bin_dir"
    echo "Prepared $plugins_out/${PLUGIN_NAMES[$i]}.bundle"
  done
  echo "Dev plugin bundles ready at $plugins_out"
}

cmd_package() {
  cd "$ROOT_DIR"
  discover_plugins

  local app_name="NotchCenter"
  local app_version="${APP_VERSION:-1.0.0}"
  local build_number="${BUILD_NUMBER:-1}"
  local build_dir="${BUILD_DIR:-$ROOT_DIR/.build/release-universal}"
  local dist_dir="${DIST_DIR:-$ROOT_DIR/dist.noindex}"
  local app_dir="$dist_dir/$app_name.app"
  local zip_path="$dist_dir/$app_name.zip"
  local checksum_path="$zip_path.sha256"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local frameworks_dir="$contents_dir/Frameworks"
  local resources_dir="$contents_dir/Resources"
  local plugins_out="$contents_dir/PlugIns"
  local source_icon="$ROOT_DIR/Resources/AppIcon.png"
  local source_plist="$ROOT_DIR/Resources/Info.plist"
  local sign_identity="${SIGN_IDENTITY:--}"
  local notary_profile="${NOTARY_PROFILE:-}"

  # 发布包要求可复现：新增/重命名插件后增量缓存可能使新 product 缺失
  # （本地残留旧产物，上次构建后新增的插件不会自动补上）。强制清理 scratch 目录。
  rm -rf "$build_dir"

  swift build \
    -c release \
    --arch arm64 \
    --arch x86_64 \
    --scratch-path "$build_dir"

  local products_dir="$build_dir/apple/Products/Release"
  local binary_path="$products_dir/$app_name"
  [[ -x "$binary_path" ]] || die "找不到构建产物：$binary_path"

  local archs
  archs="$(lipo -archs "$binary_path")"
  if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
    die "构建产物不是通用架构：$archs"
  fi

  rm -rf "$app_dir"
  rm -f "$zip_path" "$checksum_path"
  mkdir -p "$macos_dir" "$frameworks_dir" "$resources_dir" "$plugins_out"
  cp "$binary_path" "$macos_dir/$app_name"
  cp "$source_plist" "$contents_dir/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$app_version" "$contents_dir/Info.plist"
  plutil -replace CFBundleVersion -string "$build_number" "$contents_dir/Info.plist"

  # 宿主本地化资源：SPM 生成的资源 bundle 复制进 Contents/Resources，
  # Bundle.module 在打包态经 Bundle.main.resourceURL 定位到它。
  host_res_bundle="$products_dir/${app_name}_${app_name}.bundle"
  if [[ -d "$host_res_bundle" ]]; then
    cp -R "$host_res_bundle" "$resources_dir/"
  else
    die "找不到宿主本地化资源：$host_res_bundle"
  fi

  # 共享框架（宿主与插件通过 @rpath 解析），同样要求通用架构。
  copy_universal_dylib() { # $1=产物名
    local dylib="$products_dir/lib$1.dylib"
    [[ -f "$dylib" ]] || die "找不到框架产物：$dylib"
    local framework_archs
    framework_archs="$(lipo -archs "$dylib")"
    if [[ "$framework_archs" != *"arm64"* || "$framework_archs" != *"x86_64"* ]]; then
      die "框架不是通用架构：lib$1 ($framework_archs)"
    fi
    cp "$dylib" "$frameworks_dir/lib$1.dylib"
  }
  copy_universal_dylib "NotchCenterKit"
  copy_universal_dylib "LaunchdControlKit"

  local i dylib plugin_archs
  for i in "${!PLUGIN_NAMES[@]}"; do
    # 通用架构产物在固定位置（apple/Products/Release），不需要像 dev 那样 find。
    dylib="$products_dir/lib${PLUGIN_NAMES[$i]}.dylib"
    if [[ -f "$dylib" ]]; then
      plugin_archs="$(lipo -archs "$dylib")"
    else
      die "找不到插件产物：$dylib"
    fi
    if [[ "$plugin_archs" != *"arm64"* || "$plugin_archs" != *"x86_64"* ]]; then
      die "插件不是通用架构：${PLUGIN_NAMES[$i]} ($plugin_archs)"
    fi
    assemble_bundle "$plugins_out" "$i" "$dylib" "$products_dir"
  done

  if [[ -f "$source_icon" ]]; then
    local tmp_icon_dir iconset_dir
    tmp_icon_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_icon_dir"' EXIT
    iconset_dir="$tmp_icon_dir/AppIcon.iconset"
    mkdir -p "$iconset_dir"

    sips -z 16 16 "$source_icon" --out "$iconset_dir/icon_16x16.png" >/dev/null
    sips -z 32 32 "$source_icon" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$source_icon" --out "$iconset_dir/icon_32x32.png" >/dev/null
    sips -z 64 64 "$source_icon" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$source_icon" --out "$iconset_dir/icon_128x128.png" >/dev/null
    sips -z 256 256 "$source_icon" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$source_icon" --out "$iconset_dir/icon_256x256.png" >/dev/null
    sips -z 512 512 "$source_icon" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$source_icon" --out "$iconset_dir/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$source_icon" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
    rm -rf "$tmp_icon_dir"
    trap - EXIT
  fi

  xattr -cr "$app_dir"

  sign_nested() {
    local framework bundle
    for framework in "$frameworks_dir"/*.dylib; do
      codesign --force --sign "$sign_identity" "$framework"
    done
    for bundle in "$plugins_out"/*.bundle; do
      codesign --force --sign "$sign_identity" "$bundle"
    done
  }

  if [[ "$sign_identity" == "-" ]]; then
    sign_nested
    codesign --force --sign - "$app_dir"
  else
    sign_nested
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$app_dir"
  fi
  codesign --verify --deep --strict --verbose=2 "$app_dir"

  create_archive() {
    rm -f "$zip_path"
    ditto --norsrc -c -k --keepParent "$app_dir" "$zip_path"
  }

  create_archive

  if [[ -n "$notary_profile" ]]; then
    if [[ "$sign_identity" == "-" ]]; then
      die "公证需要 Developer ID 签名，请设置 SIGN_IDENTITY。"
    fi

    xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_dir"
    codesign --verify --deep --strict --verbose=2 "$app_dir"
    spctl --assess --type execute --verbose=2 "$app_dir"
    create_archive
  fi

  (
    cd "$dist_dir"
    shasum -a 256 "$app_name.zip" > "$app_name.zip.sha256"
  )

  echo "Built $app_dir"
  echo "Architectures: $archs"
  echo "Archive: $zip_path"
  echo "Checksum: $checksum_path"
}

cmd_clean() {
  rm -rf "$ROOT_DIR/.build" "$ROOT_DIR/dist.noindex"
  echo "Cleaned .build and dist.noindex"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage >&2; exit 1; }
  shift
  case "$cmd" in
    dev)     cmd_dev "$@" ;;
    package) cmd_package ;;
    clean)   cmd_clean ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "未知子命令：$cmd" ;;
  esac
}

main "$@"
