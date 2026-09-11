#!/usr/bin/env bash
# NotchCenter 统一构建脚本（Tuist + xcodebuild 后端）。插件唯一登记处是各插件的
# Plugins/<Name>/Plugin.plist，本脚本与 Project.swift 都从 Plugins/ 目录自动发现插件，
# 新增插件不需要改任何列表或 case 分支。
#
# 用法:
#   build.sh dev [debug|release]   tuist generate + xcodebuild 构建，把插件 dylib 组装成
#                                  .bundle 放进产物 .app 的 Contents/PlugIns/（开发态 .app 与
#                                  打包态布局一致，宿主直接发现加载）；默认增量——构建输入
#                                  内容未变化时跳过构建直接复用上次产物，--full/-f 强制全量
#   build.sh run [debug|release]   等价于 dev 后立即启动 NotchCenter.app 内部二进制（同样
#                                  支持 --full/-f 强制全量构建）；Size Lab 不再随 run
#                                  打开，入口在 设置 → 调试 页（自动化诊断可用
#                                  NOTCHCENTER_SIZE_LAB=1 显式直开）
#   build.sh test [<filter>]       tuist generate + xcodebuild test 跑全量测试；
#                                  <filter> 定向复验（套件名或 套件/用例，映射 -only-testing）
#   build.sh verify-sizes          官方插件「最小尺寸遮挡校验」定向门禁（几何判定 +
#                                  插件探针声明，等价 test 里对应套件的子集，快速反馈用）
#   build.sh package [-i|--install] [-g|--github] [--no-dmg] [--skip-size-check]
#                                  发布打包：通用架构 .app + 内置插件 bundle + 共享框架
#                                  + zip + dmg + 各自 sha256（可选公证），产物在 dist.noindex/；
#                                  dmg 与 zip 同时产出（拖拽到 /Applications 安装），可用
#                                  --no-dmg 仅出 zip；-i/--install 把 .app 复制到 /Applications
#                                  覆盖安装；-g/--github 把 zip 与 dmg 一并发布到 GitHub
#                                  Release（latest 标签，覆盖式更新，需已安装并登录 gh CLI）。
#                                  打包前默认先跑官方插件最小尺寸遮挡校验门禁
#                                  （BlockMinSizeVerificationTests），--skip-size-check 跳过
#   build.sh clean                 删除 .build 与 dist.noindex（均为纯可再生制品）
#
# 环境变量（仅 package）：APP_VERSION、BUILD_NUMBER、SIGN_IDENTITY、NOTARY_PROFILE。
#
# 发布产物结构（文档 §2.2 / §2.3）：
#   NotchCenter.app/
#     Contents/MacOS/NotchCenter
#     Contents/Frameworks/libNotchCenterKit.dylib（Xcode 按依赖自动嵌入）
#     Contents/Frameworks/libLaunchdControlKit.dylib（本脚本补齐：宿主不直接链接）
#     Contents/PlugIns/<Name>.bundle/{Contents/Info.plist, Contents/MacOS/<Name>}
#     Contents/Resources/{en,zh-Hans}.lproj（Xcode 本地化变体组自动嵌入）
#
# 依赖的 install_name 均为 @rpath 形式（DYLIB_INSTALL_NAME_BASE=@rpath，见 Project.swift），
# 宿主与插件已内置对应 rpath，无需 install_name_tool 修复。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGINS_SRC_DIR="$ROOT_DIR/Plugins"

# 插件 API 版本全局默认值；个别插件可在其 Plugin.plist 的 APIVersionRange 覆盖。
API_RANGE="1.0..<2.0"
API_RANGE_XML="${API_RANGE//</&lt;}"   # XML 转义（解析后仍是 1.0..<2.0）

die() { echo "错误：$*" >&2; exit 1; }

usage() {
  sed -n '6,41p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- Tuist 定位 --------------------------------------------------------------
# 优先用 PATH 上的 tuist（mise shim / brew），否则借 mise 临时执行。
if command -v tuist >/dev/null 2>&1; then
  tuist_cmd() { tuist "$@"; }
elif command -v mise >/dev/null 2>&1; then
  tuist_cmd() { mise x -- tuist "$@"; }
else
  tuist_cmd() { die "未找到 tuist：请在项目内执行 mise use tuist@<版本> 或 brew install tuist"; }
fi

# tuist generate：产出 NotchCenter.xcworkspace / NotchCenter.xcodeproj（均已被 gitignore）。
# 脚本场景必须 --no-open，否则每次构建都会拉起 Xcode。
run_generate() {
  # Tuist 按内容哈希缓存清单求值结果，新建插件目录不会触发重扫；
  # touch Project.swift 强制每次重算，保证新插件立刻被发现（清单求值开销在亚秒级）。
  touch "$ROOT_DIR/Project.swift"
  tuist_cmd generate --no-open
}

# xcodebuild 封装：产物落在 <derivedDataPath>/Build/Products/<config>/。
# build 用 generic 目的地；test 必须用具体 platform 目的地。
run_xcodebuild() { # $1=Debug|Release $2=derivedDataPath $3=build|test，其余原样透传
  local config="$1" derived="$2" action="$3" destination
  shift 3
  case "$action" in
    build) destination='generic/platform=macOS' ;;
    test)  destination='platform=macOS' ;;
  esac
  xcodebuild \
    -workspace "$ROOT_DIR/NotchCenter.xcworkspace" \
    -scheme NotchCenter \
    -configuration "$config" \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    "$@" \
    "$action"
}

# ---- 增量构建状态 --------------------------------------------------------------
# dev/run 默认增量：对全部构建输入做内容指纹，与上次成功构建后落盘的记录比对；
# 内容未变化且产物在位时跳过 tuist generate + xcodebuild + 组装，直接复用。--full/-f
# 强制全量构建。状态文件在 .build 内，clean 时随 .build 一并清除。
DEV_STATE_DIR="$ROOT_DIR/.build/dev-state"

# 构建输入内容指纹：清单、源码、插件、资源、vendored 依赖全部逐文件 hash 后汇总。
# Tests/ 不纳入：dev 产物不含测试 target，避免只改测试也触发宿主重构建。
# 输出仅受文件路径集合与内容影响（排序后 hash），同一份代码必然得到同一指纹。
build_inputs_hash() {
  local inputs=(
    "$ROOT_DIR/Project.swift"
    "$ROOT_DIR/mise.toml"
    "$ROOT_DIR/Sources"
    "$ROOT_DIR/Plugins"
    "$ROOT_DIR/Resources"
    "$ROOT_DIR/Vendor"
  )
  find "${inputs[@]}" -type f -print0 2>/dev/null \
    | sort -z \
    | xargs -0 shasum -a 256 2>/dev/null \
    | shasum -a 256 \
    | awk '{print $1}'
}

# ---- 插件自动发现 ------------------------------------------------------------
# 发现结果存入并行数组：名字即文件夹名，也即 target 名与 Info.plist 的 CFBundleExecutable。
PLUGIN_NAMES=()
PLUGIN_IDS=()
PLUGIN_VERSIONS=()
PLUGIN_DISPLAYS=()
PLUGIN_DESCRIPTIONS=()
# DisplayName / Description 的 XML 转义版本：这两个字段是自由文本，可能含
# `&`、`<`、`>`（如 "Calendar & Tasks"）。不转义就会生成不合法的 Info.plist，
# bundle 直接加载失败（`&` 在 XML 里是实体起始符）。
PLUGIN_DISPLAYS_XML=()
PLUGIN_DESCRIPTIONS_XML=()
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

# 转义 XML 文本节点里的保留字符。Info.plist 是手写模板拼出来的，任何来自
# Plugin.plist 的自由文本都必须先过这里（`&` 必须最先替换，否则会把后续
# 生成的 `&lt;` 再转义成 `&amp;lt;`）。
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

discover_plugins() {
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
    PLUGIN_DISPLAYS_XML+=("$(xml_escape "$display")")
    PLUGIN_DESCRIPTIONS_XML+=("$(xml_escape "$description")")
    PLUGIN_PRINCIPALS+=("$principal")
    PLUGIN_API_RANGES_XML+=("$api_xml")
    PLUGIN_DISPLAY_ZH+=("$(plist_get "DisplayNameLocales.zh-Hans" "$plist")")
    PLUGIN_DESC_ZH+=("$(plist_get "DescriptionLocales.zh-Hans" "$plist")")
  done
  (( ${#PLUGIN_NAMES[@]} > 0 )) || die "$PLUGINS_SRC_DIR 下没有发现任何插件目录"
}

# 组装单个插件 bundle 并生成 Info.plist（模板结构见架构文档 §3.2）。
# 本地化资源直接取自插件源目录（Plugins/<Name>/Resources/*.lproj）：
# Tuist 体系下插件 target 不声明资源，文本格式的 .strings Bundle 可直接读取。
assemble_bundle() { # $1=目标PlugIns目录 $2=索引 $3=dylib路径
  local dest_root="$1" i="$2"
  local name="${PLUGIN_NAMES[$i]}" dylib="$3"
  local bundle_dir contents_dir resources_dir

  if [[ ! -f "$dylib" ]]; then
    die "找不到插件产物：$dylib"
  fi

  bundle_dir="$dest_root/$name.bundle"
  contents_dir="$bundle_dir/Contents"
  resources_dir="$contents_dir/Resources"
  mkdir -p "$contents_dir/MacOS" "$resources_dir"
  cp "$dylib" "$contents_dir/MacOS/$name"

  # 本地化 UI 文案：把插件源目录的 lproj 复制进 Contents/Resources，
  # 插件代码用 Bundle(for:) 在这个 bundle 里查 Localizable.strings。
  # 缺失必须硬失败：静默跳过会让插件 UI 整体退化成原始键名，很难被发现。
  local lproj_src="$PLUGINS_SRC_DIR/$name/Resources"
  [[ -d "$lproj_src" ]] || die "插件缺少本地化资源目录：$lproj_src"
  if ! compgen -G "$lproj_src/*.lproj" > /dev/null; then
    die "$lproj_src 内没有 *.lproj 本地化资源"
  fi
  cp -R "$lproj_src/"*.lproj "$resources_dir/"

  # 插件说明文档：源文件夹的 README.md 随包复制进 Contents/Resources，
  # 设置面板的“插件”分区据此渲染各插件的使用说明（可选文件：第三方或
  # 未写文档的插件缺失时面板回退占位文案）。
  local readme_src="$PLUGINS_SRC_DIR/$name/README.md"
  if [[ -f "$readme_src" ]]; then
    cp "$readme_src" "$resources_dir/README.md"
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
  <string>${PLUGIN_DISPLAYS_XML[$i]}</string>
  <key>NotchCenterPluginDescription</key>
  <string>${PLUGIN_DESCRIPTIONS_XML[$i]}</string>
</dict>
</plist>
EOF
}

# 组装产物 .app：把 LaunchdControlKit 补进 Frameworks（宿主不直接链接所以
# Xcode 不会嵌入它），并把各插件 dylib 组装成 bundle 放进 Contents/PlugIns。
# $1=Build/Products 目录（内含 NotchCenter.app 与 lib<Name>.dylib）
assemble_app() { # $1=products_dir
  local products_dir="$1"
  local app_dir="$products_dir/NotchCenter.app"
  local frameworks_dir="$app_dir/Contents/Frameworks"
  local plugins_out="$app_dir/Contents/PlugIns"
  [[ -d "$app_dir" ]] || die "找不到构建产物：$app_dir"

  local launchd_dylib="$products_dir/libLaunchdControlKit.dylib"
  [[ -f "$launchd_dylib" ]] || die "找不到框架产物：$launchd_dylib"
  cp "$launchd_dylib" "$frameworks_dir/libLaunchdControlKit.dylib"

  rm -rf "$plugins_out"
  mkdir -p "$plugins_out"
  local i
  for i in "${!PLUGIN_NAMES[@]}"; do
    assemble_bundle "$plugins_out" "$i" "$products_dir/lib${PLUGIN_NAMES[$i]}.dylib"
    echo "Prepared $plugins_out/${PLUGIN_NAMES[$i]}.bundle"
  done

  # 组装改动过 .app 内容，ad-hoc 重签（幂等）：arm64 对无效签名零容忍，
  # 不重签会导致插件加载失败。
  codesign --force --sign - "$frameworks_dir/libLaunchdControlKit.dylib"
  local bundle
  for bundle in "$plugins_out"/*.bundle; do
    codesign --force --sign - "$bundle"
  done
  codesign --force --sign - "$app_dir"
}

config_to_xcconfig() { # debug|release -> Debug|Release
  case "$1" in debug) echo "Debug" ;; release) echo "Release" ;; esac
}

# ---- 子命令 ------------------------------------------------------------------

# dev/run 公共参数解析：config（debug|release）+ 可选 --full|-f 强制全量构建。
# 结果放入全局 BUILD_CONFIG / FULL_BUILD。
parse_dev_args() {
  BUILD_CONFIG="debug"
  FULL_BUILD=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      debug|release) BUILD_CONFIG="$arg" ;;
      --full|-f)     FULL_BUILD=1 ;;
      *) usage >&2; die "未知参数：$arg（可用 debug|release，以及 --full/-f 强制全量构建）" ;;
    esac
  done
}

# dev/run 公共构建流程：指纹比对增量跳过，或全量构建后落盘指纹。
run_dev_build() {
  local config="$BUILD_CONFIG" full="$FULL_BUILD"
  local xcconfig; xcconfig="$(config_to_xcconfig "$config")"
  local products_dir="$ROOT_DIR/.build/xcode/Build/Products/$xcconfig"
  local input_hash state_file

  cd "$ROOT_DIR"
  discover_plugins

  if (( ! full )); then
    input_hash="$(build_inputs_hash)"
    state_file="$DEV_STATE_DIR/$xcconfig.sha"
    if [[ -f "$state_file" ]] \
       && [[ "$(cat "$state_file")" == "$input_hash" ]] \
       && [[ -d "$products_dir/NotchCenter.app" ]] \
       && [[ -d "$products_dir/NotchCenter.app/Contents/PlugIns" ]]; then
      echo "内容未变化（${config}），跳过构建，直接复用上次产物"
      echo "如需强制重新构建：./scripts/build.sh dev|run --full"
      echo "Dev app ready at $products_dir/NotchCenter.app"
      return 0
    fi
    echo "检测到输入变化，重新构建（${config}）..."
  else
    echo "强制全量构建（${config}）..."
  fi

  run_generate
  echo "Building (${config})..."
  run_xcodebuild "$xcconfig" "$ROOT_DIR/.build/xcode" build
  assemble_app "$products_dir"

  # 构建成功后落盘指纹（供下次增量跳过）；失败时 set -e 已在此前中止，不会落盘。
  if [[ -z "${input_hash:-}" ]]; then
    input_hash="$(build_inputs_hash)"
  fi
  mkdir -p "$DEV_STATE_DIR"
  printf '%s\n' "$input_hash" > "$DEV_STATE_DIR/$xcconfig.sha"

  echo "Dev app ready at $products_dir/NotchCenter.app"
}

cmd_dev() {
  parse_dev_args "$@"
  run_dev_build
}

cmd_run() {
  # 先走 dev 流程（增量跳过或构建 + 组装插件 bundle），再启动宿主；
  # 插件 bundle 必须先就位，否则启动的应用加载不到任何插件。
  parse_dev_args "$@"
  run_dev_build
  local xcconfig; xcconfig="$(config_to_xcconfig "$BUILD_CONFIG")"
  # Size Lab 不随 run 直开（入口在 设置 → 调试 页）；外部显式设
  # NOTCHCENTER_SIZE_LAB=1 时仍尊重环境值（自动化诊断直开链路）。
  exec "$ROOT_DIR/.build/xcode/Build/Products/$xcconfig/NotchCenter.app/Contents/MacOS/NotchCenter"
}

cmd_test() {
  local filter="${1:-}"
  cd "$ROOT_DIR"
  discover_plugins
  run_generate
  if [[ -n "$filter" ]]; then
    # 对齐旧 swift test --filter 的定向复验体验。
    run_xcodebuild "Debug" "$ROOT_DIR/.build/xcode" test -only-testing "NotchCenterTests/$filter"
  else
    run_xcodebuild "Debug" "$ROOT_DIR/.build/xcode" test
  fi
}

# 官方插件「打包期最小尺寸遮挡校验」定向门禁：几何判定器单测 + 官方抽屉块
# 探针声明校验（BlockSizeVerifierTests 管"判定对不对"，BlockMinSizeVerificationTests
# 管"官方插件 minSize 下会不会互遮/溢出"）。package 预检跑后者即可；本命令两者都跑。
cmd_verify_sizes() {
  cd "$ROOT_DIR"
  discover_plugins
  run_generate
  run_xcodebuild "Debug" "$ROOT_DIR/.build/xcode" test \
    -only-testing NotchCenterTests/BlockSizeVerifierTests \
    -only-testing NotchCenterTests/BlockMinSizeVerificationTests
}

cmd_package() {
  local install_to_applications=0 publish_github=0 make_dmg=1 skip_size_check=0
  while (( $# > 0 )); do
    case "$1" in
      -i|--install)       install_to_applications=1 ;;
      -g|--github)        publish_github=1 ;;
      --no-dmg)           make_dmg=0 ;;
      --skip-size-check)  skip_size_check=1 ;;
      *) usage >&2; die "未知参数：$1（package 可用 -i|--install、-g|--github、--no-dmg、--skip-size-check）" ;;
    esac
    shift
  done

  cd "$ROOT_DIR"
  discover_plugins
  run_generate

  # 打包预检：官方插件「最小尺寸遮挡校验」（原始需求：插件打包时校验组件在
  # 最小尺寸下不会互遮/溢出）。失败即中止打包，--skip-size-check 可逃生。
  if (( ! skip_size_check )); then
    echo "Preflight: 官方插件最小尺寸遮挡校验（BlockMinSizeVerificationTests）..."
    run_xcodebuild "Debug" "$ROOT_DIR/.build/xcode" test \
      -only-testing NotchCenterTests/BlockMinSizeVerificationTests
    echo "Preflight 通过。"
  fi

  local app_name="NotchCenter"
  local app_version="${APP_VERSION:-1.0.0}"
  local build_number="${BUILD_NUMBER:-1}"
  local build_dir="${BUILD_DIR:-$ROOT_DIR/.build/release-universal}"
  local dist_dir="${DIST_DIR:-$ROOT_DIR/dist.noindex}"
  local app_dir="$dist_dir/$app_name.app"
  local zip_path="$dist_dir/$app_name.zip"
  local checksum_path="$zip_path.sha256"
  local dmg_path="$dist_dir/$app_name.dmg"
  local dmg_checksum_path="$dmg_path.sha256"
  local sign_identity="${SIGN_IDENTITY:--}"
  local notary_profile="${NOTARY_PROFILE:-}"

  echo "Building universal (release)..."
  # 通用架构：关闭 only-active-arch 并显式指定双架构。
  # 发布要求可复现：clean build 让 xcodebuild 原生清理 scheme 覆盖的全部 target
  # 后再全量构建（避免直接 rm 整个衍生数据目录）。
  xcodebuild \
    -workspace "$ROOT_DIR/NotchCenter.xcworkspace" \
    -scheme NotchCenter \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_dir" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    clean build

  local products_dir="$build_dir/Build/Products/Release"
  local built_app="$products_dir/$app_name.app"
  local binary_path="$built_app/Contents/MacOS/$app_name"
  [[ -f "$binary_path" ]] || die "找不到构建产物：$binary_path"

  local archs
  archs="$(lipo -archs "$binary_path")"
  if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
    die "构建产物不是通用架构：$archs"
  fi

  rm -rf "$app_dir"
  rm -f "$zip_path" "$checksum_path" "$dmg_path" "$dmg_checksum_path"
  mkdir -p "$dist_dir"
  # 以 Xcode 产物为基底（已含 Info.plist、本地化资源、NotchCenterKit 框架），
  # 再补齐 LaunchdControlKit 与插件 bundle。
  ditto "$built_app" "$app_dir"

  local frameworks_dir="$app_dir/Contents/Frameworks"
  local plugins_out="$app_dir/Contents/PlugIns"

  # 共享框架：NotchCenterKit 已由 Xcode 嵌入，这里校验通用架构；
  # LaunchdControlKit 由本脚本补齐，同样要求通用架构。
  check_universal_dylib() { # $1=dylib路径 $2=显示名
    local dylib="$1"
    [[ -f "$dylib" ]] || die "找不到框架产物：$dylib"
    local dylib_archs
    dylib_archs="$(lipo -archs "$dylib")"
    if [[ "$dylib_archs" != *"arm64"* || "$dylib_archs" != *"x86_64"* ]]; then
      die "$2 不是通用架构：$dylib_archs"
    fi
  }
  check_universal_dylib "$frameworks_dir/libNotchCenterKit.dylib" "libNotchCenterKit"
  cp "$products_dir/libLaunchdControlKit.dylib" "$frameworks_dir/libLaunchdControlKit.dylib"
  check_universal_dylib "$frameworks_dir/libLaunchdControlKit.dylib" "libLaunchdControlKit"

  local i dylib
  for i in "${!PLUGIN_NAMES[@]}"; do
    dylib="$products_dir/lib${PLUGIN_NAMES[$i]}.dylib"
    check_universal_dylib "$dylib" "${PLUGIN_NAMES[$i]}"
    assemble_bundle "$plugins_out" "$i" "$dylib"
  done

  # 应用图标：源 PNG 生成 icns（开发态 .app 无图标，仅发布态需要）。
  local source_icon="$ROOT_DIR/Resources/AppIcon.png"
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
    iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
    rm -rf "$tmp_icon_dir"
    trap - EXIT
  fi

  # 版本号注入：Xcode 产物里的 Info.plist 来自 Resources/Info.plist，
  # 发布时按环境变量覆写版本与构建号。
  plutil -replace CFBundleShortVersionString -string "$app_version" "$app_dir/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"

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

  # 生成 .dmg：临时暂存目录放入 .app 与一个指向 /Applications 的软链，
  # 用户挂载后拖拽 app 即可安装；用系统自带 hdiutil，无需任何第三方依赖。
  # 公证场景下 .app 在 staple 后才重做 dmg，保证镜像内已含工签票据。
  create_dmg() {
    if (( ! make_dmg )); then return 0; fi
    (
      local staging
      staging="$(mktemp -d)"
      cp -R "$app_dir" "$staging/$app_name.app"
      ln -s /Applications "$staging/Applications"
      rm -f "$dmg_path"
      hdiutil create \
        -volname "$app_name" \
        -srcfolder "$staging" \
        -ov \
        -format UDZO \
        "$dmg_path"
      rm -rf "$staging"
    )
  }

  create_archive
  create_dmg

  if [[ -n "$notary_profile" ]]; then
    if [[ "$sign_identity" == "-" ]]; then
      die "公证需要 Developer ID 签名，请设置 SIGN_IDENTITY。"
    fi

    xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_dir"
    codesign --verify --deep --strict --verbose=2 "$app_dir"
    spctl --assess --type execute --verbose=2 "$app_dir"
    create_archive
    create_dmg
  fi

  (
    cd "$dist_dir"
    shasum -a 256 "$app_name.zip" > "$app_name.zip.sha256"
    if (( make_dmg )); then
      shasum -a 256 "$app_name.dmg" > "$app_name.dmg.sha256"
    fi
  )

  echo "Built $app_dir"
  echo "Architectures: $archs"
  echo "Archive: $zip_path"
  echo "Checksum: $checksum_path"
  if (( make_dmg )); then
    echo "Disk image: $dmg_path"
    echo "Checksum: $dmg_checksum_path"
  fi

  # 发布到 GitHub Release：与 CI 的 main 分支路径一致——强制移动 latest 标签到当前
  # 提交，存在 latest Release 则覆盖附件，否则创建；最后标记为 latest 版本。
  # 本地发布要求 gh 已登录（gh auth status）；仓库从 git remote 自动推断。
  # zip 与 dmg（及各自校验和）一并上传。
  if (( publish_github )); then
    command -v gh >/dev/null 2>&1 || die "未安装 gh CLI（brew install gh）"
    gh auth status >/dev/null 2>&1 || die "gh 未登录，请先 gh auth login"
    git diff --quiet || die "工作区有未提交改动，请先提交后再发布（Release 标签需要指向有效提交）"

    local release_tag="latest"
    local release_title="NotchCenter 最新版"
    local release_notes="本地构建 v$app_version (build $build_number)，$(date '+%Y-%m-%d %H:%M')。"
    local head_sha
    head_sha="$(git rev-parse HEAD)"

    echo "Publishing artifacts to GitHub Release '$release_tag'..."
    git tag -f "$release_tag" "$head_sha"
    git push --force origin "refs/tags/$release_tag"

    if gh release view "$release_tag" >/dev/null 2>&1; then
      gh release upload "$release_tag" \
        "$zip_path" "$checksum_path" \
        ${make_dmg:+"$dmg_path" "$dmg_checksum_path"} \
        --clobber
    else
      gh release create "$release_tag" \
        "$zip_path" "$checksum_path" \
        ${make_dmg:+"$dmg_path" "$dmg_checksum_path"} \
        --verify-tag \
        --title "$release_title" \
        --notes "$release_notes"
    fi
    gh release edit "$release_tag" \
      --title "$release_title" \
      --notes "$release_notes" \
      --latest
    echo "Published https://github.com/$(git remote get-url origin | sed -E 's#.*(github\.com[:/])##; s#\.git$##')/releases/tag/$release_tag"
  fi

  if (( install_to_applications )); then
    local dest_app="/Applications/$app_name.app"
    # 先杀掉正在运行的实例再覆盖，避免复制时文件被占用 / 替换后旧进程仍驻留。
    if pgrep -x "$app_name" >/dev/null 2>&1; then
      echo "Stopping running $app_name..."
      pkill -x "$app_name" || true
      sleep 1
    fi
    rm -rf "$dest_app"
    ditto "$app_dir" "$dest_app"
    xattr -cr "$dest_app"
    echo "Installed $dest_app"
  fi
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
    run)     cmd_run "$@" ;;
    test)    cmd_test "$@" ;;
    verify-sizes) cmd_verify_sizes ;;
    package) cmd_package "$@" ;;
    clean)   cmd_clean ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "未知子命令：$cmd" ;;
  esac
}

main "$@"
