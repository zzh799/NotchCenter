#!/usr/bin/env bash
# NotchCenter 统一构建脚本（Tuist + xcodebuild 后端）。插件唯一登记处是各插件的
# Plugins/<Name>/Plugin.plist，本脚本与 Project.swift 都从 Plugins/ 目录自动发现插件，
# 新增插件不需要改任何列表或 case 分支。
#
# >>> usage
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
#   build.sh doctor                构建增量门禁自检：验证「清单文件或文件路径集合变化必须
#                                  触发工程重生成」「仅改源码内容必须不重生成」等语义边界，
#                                  并打印当前各阶段门禁状态（只读，不改工作区源码）
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
# <<< usage
#
# ---- 增量门禁（三段独立，任一段失效只影响自己）--------------------------------
#   1) 工程重生成：只在「清单文件内容」或「进入工程的文件路径集合」变化时才 tuist generate
#      （见 manifests_fingerprint）。Tuist 每次生成都会重写 Derived/Sources 的派生源，逼
#      xcodebuild 判全部 target 签名失效（实测紧跟 generate 后构建 15 次 CodeSign，不跟则
#      0 次），所以这一步绝不能每次构建都跑。改源码内容不需要重生成，改文件路径集合必须。
#   2) 构建输入指纹：dev/run 级别的整体跳过，见 build_inputs_hash。
#   3) 插件组装：逐插件比对 bundle_fingerprint，只重建/重签变化的 bundle。
#
# ---- 参考：发布产物结构（文档 §2.2 / §2.3）------------------------------------
#   NotchCenter.app/
#     Contents/MacOS/NotchCenter
#     Contents/Frameworks/libNotchCenterKit.dylib（Xcode 按依赖自动嵌入）
#     Contents/Frameworks/libLaunchdControlKit.dylib（本脚本补齐：宿主不直接链接）
#     Contents/Frameworks/libLidAngleKit.dylib（同上；盖角传感器复用库）
#     Contents/PlugIns/<Name>.bundle/{Contents/Info.plist, Contents/MacOS/<Name>}
#     Contents/PlugIns/<Name>.bundle/Contents/Resources/Bridge/（白名单插件才有：
#       MediaRemote helper framework + mediaremote-adapter.pl，由 /usr/bin/perl 加载）
#     Contents/Resources/{en,zh-Hans}.lproj（Xcode 本地化变体组自动嵌入）
#
# 依赖的 install_name 均为 @rpath 形式（DYLIB_INSTALL_NAME_BASE=@rpath，见 Project.swift），
# 宿主与插件已内置对应 rpath，无需 install_name_tool 修复。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 脚本自身绝对路径：usage() 与门禁指纹都要读本文件，而多个子命令会先 cd 到 ROOT_DIR，
# 直接用相对调用路径（如 ./scripts/build.sh）会失效。
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PLUGINS_SRC_DIR="$ROOT_DIR/Plugins"

# 本机架构：dev/run/test 只编它，见 run_xcodebuild。
NATIVE_ARCH="$(uname -m)"

# Plugins/ 下的可复用动态库目录（不是插件，不参与发现与打包）。
# 与 Project.swift 的 sharedLibraryDirNames 必须保持一致。
SHARED_LIBRARY_DIR_NAMES="LidAngleKit"

# 需要随包附带 MediaRemote 桥的插件 ID 白名单（按 PluginID 匹配）。
#
# 为什么需要桥：宿主进程读不到私有框架 MediaRemote——macOS 15.4 起系统只放行 bundle id
# 以 com.apple.* 开头的进程，本仓无沙盒 / ad-hoc 签名的进程实测查询恒返回空。可用的
# 绕行方式是让 /usr/bin/perl（bundle id 恰好是 com.apple.perl）加载一个 helper 动态库
# 代跑查询，再把 JSON 打到 stdout 给宿主读。
#
# 桥的源码 vendored 在 Vendor/mediaremote-adapter（BSD-3，见该目录 LICENSE 与
# Plugins/MediaControlsPlugin/NOTICE）；编译产物不参与任何 target 的链接，只随 bundle
# 分发，因此与 Project.swift 的 target 白名单无关——这里是一份独立的插件 ID 白名单。
BRIDGE_PLUGIN_IDS="com.notchcenter.media-controls"
BRIDGE_SRC_DIR="$ROOT_DIR/Vendor/mediaremote-adapter"
BRIDGE_BUILD_DIR="$ROOT_DIR/.build/bridge"
BRIDGE_FRAMEWORK_NAME="MediaRemoteAdapter"
# 桥的目标架构（空格分隔；留空 = 本机架构）。发布打包要通用二进制，dev/test 不必。
BRIDGE_ARCHS=""
# 桥版本号：上游 CMake 的 0.1.0 + 本仓固定的上游 commit 短哈希（出问题时能直接溯源）。
BRIDGE_VERSION="0.1.0"
if [[ -f "$BRIDGE_SRC_DIR/UPSTREAM_COMMIT" ]]; then
  BRIDGE_VERSION="0.1.0+$(cut -c1-7 < "$BRIDGE_SRC_DIR/UPSTREAM_COMMIT")"
fi

# 插件 API 版本全局默认值；个别插件可在其 Plugin.plist 的 APIVersionRange 覆盖。
API_RANGE="1.0..<2.0"
API_RANGE_XML="${API_RANGE//</&lt;}"   # XML 转义（解析后仍是 1.0..<2.0）

die() { echo "错误：$*" >&2; exit 1; }

usage() {
  # 标记区间而非硬编码行号：后者在改头部注释时会静默截断帮助文本。
  sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$SCRIPT_PATH" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

# 增量门禁状态目录。全部落在 .build 内，clean 时随 .build 一并清除（首次构建走全量路径）。
DEV_STATE_DIR="$ROOT_DIR/.build/dev-state"

# ---- Tuist 定位 --------------------------------------------------------------
# 优先用 PATH 上的 tuist（mise shim / brew），否则借 mise 临时执行。
if command -v tuist >/dev/null 2>&1; then
  tuist_cmd() { tuist "$@"; }
elif command -v mise >/dev/null 2>&1; then
  tuist_cmd() { mise x -- tuist "$@"; }
else
  tuist_cmd() { die "未找到 tuist：请在项目内执行 mise use tuist@<版本> 或 brew install tuist"; }
fi

# ---- 工程重生成门禁 ----------------------------------------------------------
# tuist generate 是构建链里最贵的一步（约 3 s），而且它每次都会重写 Derived/Sources 下的
# 派生源（TuistBundle+NotchCenter / TuistStrings+NotchCenter 等）。派生源一变，xcodebuild
# 就判相关 target 的产物失效：实测紧跟 generate 之后构建是 6 s / 15 次 CodeSign，不跑
# generate 直接构建是 2 s / 0 次 CodeSign。所以生成必须按需触发，不能每次构建都跑。
#
# 触发条件只取「决定 target 集合」的输入：Project.swift（含 sharedLibraryDirNames）、
# mise.toml（Tuist 版本）、本脚本（与 Project.swift 共同维护复用库白名单，两处必须一致）、
# 以及 Plugins/ 一级子目录名集合（插件发现结果）。
#
# 刻意不纳入各插件 Plugin.plist 的内容：它只影响本脚本组装出的 Info.plist，不改变 target
# 结构，纳入会让「改个版本号」也白白触发 3 s 重生成。Plugin.plist 变化由插件组装指纹
# （bundle_fingerprint）负责，那才是它该触发的地方。
MANIFEST_STATE_FILE="$DEV_STATE_DIR/manifests.sha"

# 决定 target 集合的清单文件内容。用数组而非硬编码路径，doctor 子命令可替换成临时样本自检。
MANIFEST_INPUT_FILES=("$ROOT_DIR/Project.swift" "$ROOT_DIR/mise.toml" "$SCRIPT_PATH")

# 会进入工程文件清单的路径根。同样可在 doctor 里被替换。
#
# 为什么需要这一层：Tuist 把 `sources: ["Plugins/X/Sources/**/*.swift"]` 这类 glob 在清单
# 求值阶段展开成 pbxproj 里的显式文件列表。因此**新增、删除、改名任何源文件都必须重新生成**：
# 少了这一步，pbxproj 会指向不存在的文件，构建直接报
# `error: Build input file cannot be found: .../Sources/Foo.swift`（实测踩过）。
#
# 所以这里哈希的是「文件路径集合」而不是文件内容：改内容不重生成（xcodebuild 自己按内容
# 增量），改路径集合才重生成。两者分工明确，这也是本门禁能省下 3 s 的前提。
MANIFEST_PATH_ROOTS=(
  "$ROOT_DIR/Sources"
  "$ROOT_DIR/Plugins"
  "$ROOT_DIR/Tests"
  "$ROOT_DIR/Resources"
)

manifests_fingerprint() {
  local file
  {
    printf 'manifests\n'
    for file in "${MANIFEST_INPUT_FILES[@]}"; do
      shasum -a 256 "$file"
    done
    printf 'paths\n'
    find "${MANIFEST_PATH_ROOTS[@]}" \
      \( -name '.DS_Store' -o -name '.build' -o -name '.swiftpm' \) -prune -o \
      -type f -print 2>/dev/null | LC_ALL=C sort
  } | shasum -a 256 | awk '{print $1}'
}

# 返回 0 = 需要重新生成；1 = 可安全跳过。
# 保守失败：stamp 缺失、指纹不匹配、工程目录缺失，任一成立都返回 0（宁可多花 3 s，
# 不可让构建对着陈旧工程跑）。
needs_generate() {
  local fingerprint
  fingerprint="$(manifests_fingerprint)"
  [[ -f "$MANIFEST_STATE_FILE" ]] || return 0
  [[ "$(cat "$MANIFEST_STATE_FILE")" == "$fingerprint" ]] || return 0
  [[ -d "$ROOT_DIR/NotchCenter.xcworkspace" ]] || return 0
  [[ -d "$ROOT_DIR/NotchCenter.xcodeproj" ]] || return 0
  return 1
}

# tuist generate：产出 NotchCenter.xcworkspace / NotchCenter.xcodeproj（均已被 gitignore）。
# 脚本场景必须 --no-open，否则每次构建都会拉起 Xcode。
run_generate() { # $1=1 强制重新生成（供 --full 使用）；其余值按门禁判断
  if (( ! ${1:-0} )) && ! needs_generate; then
    echo "工程结构与上次一致，跳过 tuist generate"
    return 0
  fi
  # 清单在求值阶段扫描 Plugins/ 目录动态生成 target，但 Tuist 的清单缓存键只由
  # Project.swift 的内容哈希决定（实测 4.207.0：清缓存前后 manifestHash 同值），
  # 目录扫描结果不在键内，因此新增/删除插件目录必须清 manifests 类目才会重扫。
  # 旧实现靠 `touch Project.swift`，只改 mtime 不改内容哈希，对缓存完全无效。
  tuist_cmd clean manifests
  tuist_cmd generate --no-open
  # 生成成功后才落 stamp：失败时 set -e 已在此前中止，不会留下假的「门禁已通过」状态。
  mkdir -p "$DEV_STATE_DIR"
  manifests_fingerprint > "$MANIFEST_STATE_FILE"
}

# xcodebuild 封装：产物落在 <derivedDataPath>/Build/Products/<config>/。
# build 用 generic 目的地；test 必须用具体 platform 目的地。
#
# 只编本机架构：generic 目的地 + 未设 ONLY_ACTIVE_ARCH 时，`-showBuildSettings` 会报
# ARCHS = arm64 x86_64 / ONLY_ACTIVE_ARCH = NO（实测产物就是 fat 二进制），编译量直接翻倍。
# 开发与测试都在本机跑，通用架构没有意义。发布态的通用架构由 cmd_package 显式指定，
# 不经过这里。
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
    ARCHS="$NATIVE_ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    "$@" \
    "$action"
}

# ---- 增量构建状态 --------------------------------------------------------------
# dev/run 默认增量：对全部构建输入做内容指纹，与上次成功构建后落盘的记录比对；
# 内容未变化且产物在位时跳过 tuist generate + xcodebuild + 组装，直接复用。--full/-f
# 强制全量构建。状态文件在 .build 内，clean 时随 .build 一并清除（见 DEV_STATE_DIR）。

# 构建输入内容指纹：清单、源码、插件、资源、vendored 依赖、以及本脚本自身，逐文件 hash 后汇总。
# Tests/ 不纳入：dev 产物不含测试 target，避免只改测试也触发宿主机重构建。
# 本脚本自身必须纳入：API_RANGE、复用库目录名等常量直接决定插件 bundle 的组装结果，
# 不纳入的话改了常量会因为「指纹没变」被整体跳过，产物悄悄停留在旧约定上。
#
# 必须排除构建产物与系统垃圾，否则指纹会被与源码无关的操作污染（未排除时 4640 个文件，
# 排除后 363 个）：
#   - Vendor/**/.build：4265 个 SPM 产物，SPM 重解析会改 workspace-state.json；
#   - .DS_Store：12 个，Finder 浏览一次目录就变，会让下一次构建平白全量重来；
#   - .swiftpm：本地 SPM 元数据。
# 指纹计算随之从 1.43 s 降到 0.05 s。
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
  {
    shasum -a 256 "$SCRIPT_PATH"
    find "${inputs[@]}" \
      \( -name '.DS_Store' -o -name '.build' -o -name '.swiftpm' \) -prune -o \
      -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 shasum -a 256 2>/dev/null
  } | shasum -a 256 | awk '{print $1}'
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
    # 复用库白名单（与 Project.swift 的同名白名单保持一致）：这些目录是可复用动态库
    # 而非插件，由插件的 Dependencies 引用、在 Project.swift 里显式登记 target，
    # 不参与插件打包。刻意用白名单而不是「没有 Plugin.plist 就跳过」——后者会让
    # 漏写元数据的插件被静默漏打包。
    case " $SHARED_LIBRARY_DIR_NAMES " in
      *" $name "*) continue ;;
    esac
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

# ---- MediaRemote 桥（Vendor/mediaremote-adapter）--------------------------------
# 用途与「为什么必须绕」见 BRIDGE_PLUGIN_IDS 处的说明。这里只做两件事：把 vendored
# 源码编成 helper framework 落到 .build/bridge，以及回答「某插件要不要带桥」。

# 桥编译指纹：源码内容 + 编译器版本。任一变化即重编。
bridge_fingerprint() {
  {
    find "$BRIDGE_SRC_DIR/src" "$BRIDGE_SRC_DIR/include" -type f \
      \( -name '*.m' -o -name '*.h' \) -print0 2>/dev/null \
      | sort -z | xargs -0 shasum -a 256
    shasum -a 256 "$BRIDGE_SRC_DIR/bin/mediaremote-adapter.pl"
    clang --version | head -1
  } 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

# 编译 helper framework（幂等：指纹与架构都没变即复用，编译一次约 2s）。
build_mediaremote_bridge() {
  [[ -d "$BRIDGE_SRC_DIR/src" ]] || die "缺少 MediaRemote 桥源码：$BRIDGE_SRC_DIR"
  local fw="$BRIDGE_BUILD_DIR/$BRIDGE_FRAMEWORK_NAME.framework"
  local binary="$fw/$BRIDGE_FRAMEWORK_NAME"
  local state_file="$BRIDGE_BUILD_DIR/.fingerprint"
  local want have=""
  want="$(bridge_fingerprint)|archs:${BRIDGE_ARCHS:-native}"
  [[ -f "$state_file" ]] && have="$(cat "$state_file")"
  if [[ "$have" == "$want" && -x "$binary" ]]; then
    return 0
  fi

  local sources=("$BRIDGE_SRC_DIR"/src/adapter/*.m "$BRIDGE_SRC_DIR"/src/private/*.m "$BRIDGE_SRC_DIR"/src/utility/*.m)
  local arch_flags="" a
  for a in ${BRIDGE_ARCHS:-}; do
    arch_flags="$arch_flags -arch $a"
  done

  echo "Building MediaRemote bridge (${BRIDGE_ARCHS:-native})..."
  rm -rf "$fw"
  mkdir -p "$fw/Resources"
  # -fvisibility=default 是必须的：Perl 侧靠 dlsym 按名字取 adapter_* 符号，符号被隐藏
  # 就直接「加载成功但找不到函数」。arch_flags 刻意不加引号（空格分隔的参数列表）。
  # shellcheck disable=SC2086
  clang -dynamiclib -fobjc-arc -fvisibility=default $arch_flags \
    -I "$BRIDGE_SRC_DIR/include" -I "$BRIDGE_SRC_DIR/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    "${sources[@]}" -o "$binary" \
    || die "MediaRemote 桥编译失败"
  cat > "$fw/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- 仅作 framework 目录的元数据；宿主不加载它，加载方是 /usr/bin/perl。 -->
  <key>CFBundleExecutable</key>
  <string>$BRIDGE_FRAMEWORK_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.vandenbe.$BRIDGE_FRAMEWORK_NAME</string>
  <key>CFBundleName</key>
  <string>$BRIDGE_FRAMEWORK_NAME</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>$BRIDGE_VERSION</string>
</dict>
</plist>
PLIST
  # arm64 对无效签名零容忍：DynaLoader 加载未签名动态库会直接失败。
  codesign --force --sign - "$fw" >/dev/null 2>&1 || die "MediaRemote 桥签名失败"
  mkdir -p "$BRIDGE_BUILD_DIR"
  printf '%s\n' "$want" > "$state_file"
}

# 该插件是否在白名单里、需要随包附带桥。
plugin_uses_bridge() { # $1=插件索引
  local id="${PLUGIN_IDS[$1]:-}"
  [[ -n "$id" && " $BRIDGE_PLUGIN_IDS " == *" $id "* ]]
}

# 单个插件 bundle 的组装指纹。以下任一项变化都必须重建该 bundle：
#   - dylib 内容（插件代码改了）
#   - Plugin.plist 内容（版本 / DisplayName / Description / NSPrincipalClass /
#     APIVersionRange / 中文元数据，全部直接决定组装出的 Info.plist 与 InfoPlist.strings）
#   - Resources/**（本地化 .strings 改了但代码没动，同样要重建）
#   - README.md（设置面板「插件」分区读它渲染使用说明）
#   - MediaRemote 桥的产物与 Perl 入口（白名单插件才有；桥重编了必须重打 bundle）
#   - API_RANGE 全局默认值（本脚本常量；改动影响未显式声明 APIVersionRange 的插件）
bundle_fingerprint() { # $1=插件索引 $2=dylib路径
  local i="$1" dylib="$2"
  local name="${PLUGIN_NAMES[$i]}" lproj_src="$PLUGINS_SRC_DIR/$name/Resources"
  {
    printf 'api-default:%s\n' "$API_RANGE"
    shasum -a 256 "$dylib" "$PLUGINS_SRC_DIR/$name/Plugin.plist"
    find "$lproj_src" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256
    if [[ -f "$PLUGINS_SRC_DIR/$name/README.md" ]]; then
      shasum -a 256 "$PLUGINS_SRC_DIR/$name/README.md"
    fi
    if plugin_uses_bridge "$i"; then
      shasum -a 256 "$BRIDGE_BUILD_DIR/$BRIDGE_FRAMEWORK_NAME.framework/$BRIDGE_FRAMEWORK_NAME" \
        "$BRIDGE_SRC_DIR/bin/mediaremote-adapter.pl"
    fi
  } 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

# 组装单个插件 bundle 并生成 Info.plist（模板结构见架构文档 §3.2）。
# 本地化资源直接取自插件源目录（Plugins/<Name>/Resources/*.lproj）：
# Tuist 体系下插件 target 不声明资源，文本格式的 .strings Bundle 可直接读取。
# 先整目录重建再铺内容：增量门禁只保证「指纹变了才调到这里」，而源目录里被删掉的
# 资源必须在 bundle 里同步消失，不能留在旧目录上。
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
  rm -rf "$bundle_dir"
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

  # MediaRemote 桥（白名单插件）：helper framework + Perl 入口随包分发到
  # Contents/Resources/Bridge/，插件运行期按这个相对路径去找。缺失硬失败——
  # 桥没带上时插件会永远显示空态，静默降级很难被发现。
  if plugin_uses_bridge "$i"; then
    local bridge_src="$BRIDGE_BUILD_DIR/$BRIDGE_FRAMEWORK_NAME.framework"
    [[ -x "$bridge_src/$BRIDGE_FRAMEWORK_NAME" ]] \
      || die "插件 $name 需要 MediaRemote 桥但桥未构建：$bridge_src"
    mkdir -p "$resources_dir/Bridge"
    cp -R "$bridge_src" "$resources_dir/Bridge/"
    cp "$BRIDGE_SRC_DIR/bin/mediaremote-adapter.pl" "$resources_dir/Bridge/"
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

# 组装产物 .app：把 LaunchdControlKit / LidAngleKit 补进 Frameworks（宿主不直接
# 链接所以 Xcode 不会嵌入它们），并把各插件 dylib 组装成 bundle 放进 Contents/PlugIns。
# $1=Build/Products 目录（内含 NotchCenter.app 与 lib<Name>.dylib）
assemble_app() { # $1=products_dir
  local products_dir="$1"
  local app_dir="$products_dir/NotchCenter.app"
  local frameworks_dir="$app_dir/Contents/Frameworks"
  local plugins_out="$app_dir/Contents/PlugIns"
  [[ -d "$app_dir" ]] || die "找不到构建产物：$app_dir"

  mkdir -p "$plugins_out"
  local shared_lib entry name i dylib bundle_dir stamp fingerprint
  local changed_frameworks=() changed_bundles=() app_dirty=0

  # 宿主不直接链接的共享库：Xcode 只嵌入宿主链接到的，其余在这里补齐。
  # 内容相同就跳过复制与重签——cmp 比 cp + codesign 便宜，且避免无谓刷新签名。
  for shared_lib in LaunchdControlKit LidAngleKit; do
    local src="$products_dir/lib${shared_lib}.dylib"
    local dst="$frameworks_dir/lib${shared_lib}.dylib"
    [[ -f "$src" ]] || die "找不到框架产物：$src"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      continue
    fi
    cp "$src" "$dst"
    changed_frameworks+=("$dst")
  done

  # 插件 bundle：逐插件比对组装指纹，只重建指纹变了的那个。
  local assembled_state_dir="$DEV_STATE_DIR/assembled"
  mkdir -p "$assembled_state_dir"
  local known_bundles=" "
  for i in "${!PLUGIN_NAMES[@]}"; do
    name="${PLUGIN_NAMES[$i]}"
    dylib="$products_dir/lib$name.dylib"
    [[ -f "$dylib" ]] || die "找不到插件产物：$dylib"
    known_bundles+="$name.bundle "
    stamp="$assembled_state_dir/$name.sha"
    bundle_dir="$plugins_out/$name.bundle"
    fingerprint="$(bundle_fingerprint "$i" "$dylib")"
    if [[ -f "$stamp" ]] \
       && [[ "$(cat "$stamp")" == "$fingerprint" ]] \
       && [[ -f "$bundle_dir/Contents/MacOS/$name" ]]; then
      continue
    fi
    assemble_bundle "$plugins_out" "$i" "$dylib"
    printf '%s\n' "$fingerprint" > "$stamp"
    echo "Prepared $bundle_dir"
    changed_bundles+=("$bundle_dir")
    app_dirty=1
  done

  # 孤儿清理：插件目录被删除或改名后残留的 bundle 必须移除，否则宿主仍会加载旧插件。
  for entry in "$plugins_out"/*.bundle; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    case "$known_bundles" in
      *" $name "*) ;;
      *) rm -rf "$entry"; echo "Removed stale $entry"; app_dirty=1 ;;
    esac
  done
  # 同步清理已消失插件的组装指纹，避免目录名被复用后误判成「已组装」。
  for entry in "$assembled_state_dir"/*.sha; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry" .sha)"
    case "$known_bundles" in
      *" $name.bundle "*) ;;
      *) rm -f "$entry" ;;
    esac
  done

  # 组装改动过 .app 内容，ad-hoc 重签（幂等）：arm64 对无效签名零容忍，
  # 不重签会导致插件加载失败。只重签本次真正改动过的嵌套项，最后按需重签宿主 .app
  # ——全量重签会把签名每次刷新一遍，是无谓开销。
  if (( app_dirty )); then
    if (( ${#changed_frameworks[@]} > 0 )); then
      for entry in "${changed_frameworks[@]}"; do
        codesign --force --sign - "$entry"
      done
    fi
    if (( ${#changed_bundles[@]} > 0 )); then
      for entry in "${changed_bundles[@]}"; do
        codesign --force --sign - "$entry"
      done
    fi
    codesign --force --sign - "$app_dir"
  fi
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

# 跳过构建的前置检查：产物 .app、PlugIns 目录、每个已发现插件的 bundle 都必须在位，
# 且 PlugIns 下不能有不在发现结果里的残留 bundle。缺任一项就走构建路径——组装门禁会
# 补齐缺失的、清掉多余的，不会因为「指纹没变」交出残缺或带脏产物的 .app。
dev_products_complete() { # $1=products_dir
  local products_dir="$1"
  local plugins_out="$products_dir/NotchCenter.app/Contents/PlugIns"
  [[ -d "$products_dir/NotchCenter.app" ]] || return 1
  [[ -d "$plugins_out" ]] || return 1
  local known=" " i name entry
  for i in "${!PLUGIN_NAMES[@]}"; do
    name="${PLUGIN_NAMES[$i]}"
    known+="$name.bundle "
    [[ -f "$plugins_out/$name.bundle/Contents/MacOS/$name" ]] || return 1
  done
  for entry in "$plugins_out"/*.bundle; do
    [[ -e "$entry" ]] || continue
    [[ "$known" == *" $(basename "$entry") "* ]] || return 1
  done
  return 0
}

# 能否整体跳过 dev/run 构建。三个条件必须全部满足：
#   1) 构建输入内容指纹与上次成功构建落盘的记录一致；
#   2) 工程结构与当前文件路径集合一致（needs_generate 为假）；
#   3) 产物完整（.app、全部插件 bundle 在位，且没有不在发现结果里的残留 bundle）。
#
# 条件 2 不能省。少了它就会出现「产物完整、输入指纹也匹配，但工程还停在另一套 target
# 集合上」的窗口——实测踩过：插件目录被删过一次又恢复后，输入指纹回到了旧值、工程却还
# 是删除后的 pbxproj，于是整体跳过，交付一个与源真相不符的产物。
dev_can_skip() { # $1=products_dir $2=输入指纹 $3=状态文件
  local products_dir="$1" input_hash="$2" state_file="$3"
  [[ -f "$state_file" ]] || return 1
  [[ "$(cat "$state_file")" == "$input_hash" ]] || return 1
  needs_generate && return 1
  dev_products_complete "$products_dir" || return 1
  return 0
}

# dev/run 公共构建流程：指纹比对增量跳过，或全量构建后落盘指纹。
run_dev_build() {
  local config="$BUILD_CONFIG" full="$FULL_BUILD"
  local xcconfig; xcconfig="$(config_to_xcconfig "$config")"
  local products_dir="$ROOT_DIR/.build/xcode/Build/Products/$xcconfig"
  local input_hash state_file

  cd "$ROOT_DIR"
  discover_plugins
  build_mediaremote_bridge

  if (( ! full )); then
    input_hash="$(build_inputs_hash)"
    state_file="$DEV_STATE_DIR/$xcconfig.sha"
    if dev_can_skip "$products_dir" "$input_hash" "$state_file"; then
      echo "内容未变化（${config}），跳过构建，直接复用上次产物"
      echo "如需强制重新构建：./scripts/build.sh dev|run --full"
      echo "Dev app ready at $products_dir/NotchCenter.app"
      return 0
    fi
    echo "检测到输入变化，重新构建（${config}）..."
  else
    echo "强制全量构建（${config}）..."
    # --full 语义是「不信任何脚本层门禁」：连带清掉插件组装指纹，让 11 个 bundle 全量重建。
    rm -rf "$DEV_STATE_DIR/assembled"
  fi

  # 传 1/0 而不是空串判断：full 恒为非空字符串（0 也是非空），用 ${var:+force} 会永远为真。
  run_generate "$full"
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

# ---- doctor：增量门禁自检 ------------------------------------------------------
# 门禁写错的代价是「静默不重新生成」——构建照跑，产物却是陈旧的，极难发现。所以
# 语义边界必须有可复跑的回归入口。
# 全程只读真实工作区：把门禁的输入路径临时指向 mktemp 样本目录，绝不碰 Sources/ 与
# Plugins/ 的实际文件，也不触发任何构建。
DOCTOR_TMP=""
DOCTOR_FAILURES=0

doctor_assert_same() { # $1=描述 $2=期望指纹 $3=实际指纹
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s（期望不变，实际变了）\n' "$1"
    DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  fi
}

doctor_assert_changed() { # $1=描述 $2=旧指纹 $3=新指纹
  if [[ "$2" != "$3" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s（期望变化，实际没变）\n' "$1"
    DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  fi
}

doctor_assert_skip() { # $1=描述 $2=期望(0 允许跳过 / 1 否决) $3=products_dir $4=状态文件
  local actual
  if dev_can_skip "$3" "matching-input-hash" "$4"; then actual=0; else actual=1; fi
  if [[ "$2" == "$actual" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s（期望 %s，实际 %s）\n' "$1" "$2" "$actual"
    DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
  fi
}

cmd_doctor() {
  cd "$ROOT_DIR"
  DOCTOR_TMP="$(mktemp -d)"
  trap '[[ -n "${DOCTOR_TMP:-}" ]] && rm -rf "$DOCTOR_TMP"' EXIT

  echo "== 当前工作区门禁状态（只读）=="
  discover_plugins
  local live_manifest live_input
  live_manifest="$(manifests_fingerprint)"
  live_input="$(build_inputs_hash)"
  echo "  已发现插件：${#PLUGIN_NAMES[@]} 个"
  if [[ -f "$MANIFEST_STATE_FILE" && "$(cat "$MANIFEST_STATE_FILE")" == "$live_manifest" ]]; then
    echo "  工程重生成：stamp 匹配 → 下次构建跳过 tuist generate"
  else
    echo "  工程重生成：stamp 缺失或不匹配 → 下次构建会跑 tuist generate"
  fi
  if [[ -f "$DEV_STATE_DIR/Debug.sha" && "$(cat "$DEV_STATE_DIR/Debug.sha")" == "$live_input" ]]; then
    echo "  构建输入：Debug stamp 匹配 → 无改动时 dev 整体跳过"
  else
    echo "  构建输入：Debug stamp 缺失或不匹配 → 下次 dev 会构建"
  fi

  echo
  echo "== 门禁语义边界（在临时样本目录上验证）=="
  mkdir -p "$DOCTOR_TMP/Plugins/AlphaPlugin/Sources" "$DOCTOR_TMP/Plugins/BetaPlugin/Sources"
  printf 'struct Alpha {}\n' > "$DOCTOR_TMP/Plugins/AlphaPlugin/Sources/Alpha.swift"
  printf 'struct Beta {}\n' > "$DOCTOR_TMP/Plugins/BetaPlugin/Sources/Beta.swift"
  printf 'let manifestVersion = 1\n' > "$DOCTOR_TMP/Project.swift"
  printf '[tools]\ntuist = "1"\n' > "$DOCTOR_TMP/mise.toml"

  PLUGINS_SRC_DIR="$DOCTOR_TMP/Plugins"
  MANIFEST_STATE_FILE="$DOCTOR_TMP/manifests.sha"
  MANIFEST_INPUT_FILES=("$DOCTOR_TMP/Project.swift" "$DOCTOR_TMP/mise.toml")
  MANIFEST_PATH_ROOTS=("$DOCTOR_TMP/Plugins")

  local base after

  base="$(manifests_fingerprint)"

  # 边界 1：只改插件源码内容。指纹只取路径集合，因此绝不能变——
  # 变了就意味着「改一行插件代码也要重跑 3 s 的 tuist generate」。
  printf 'struct Alpha { var value = 1 }\n' > "$DOCTOR_TMP/Plugins/AlphaPlugin/Sources/Alpha.swift"
  doctor_assert_same "仅改插件源码内容 → 不触发工程重生成" "$base" "$(manifests_fingerprint)"

  # 边界 2：新增源文件。Tuist 把来源 glob 展开成 pbxproj 显式文件列表，新增文件不重新
  # 生成就会漏编；这里正是曾经踩过的坑（漏了这条，删除文件后构建报 Build input file
  # cannot be found）。
  printf 'struct Extra {}\n' > "$DOCTOR_TMP/Plugins/AlphaPlugin/Sources/Extra.swift"
  after="$(manifests_fingerprint)"
  doctor_assert_changed "新增源文件 → 触发工程重生成" "$base" "$after"
  base="$after"
  rm -f "$DOCTOR_TMP/Plugins/AlphaPlugin/Sources/Extra.swift"

  # 边界 3：删除源文件。不重新生成会让 pbxproj 指向已不存在的文件，构建直接失败。
  after="$(manifests_fingerprint)"
  doctor_assert_changed "删除源文件 → 触发工程重生成" "$base" "$after"
  base="$after"

  # 边界 4：新增插件目录。target 集合变了，必须重新生成。
  mkdir -p "$DOCTOR_TMP/Plugins/GammaPlugin/Sources"
  printf 'struct Gamma {}\n' > "$DOCTOR_TMP/Plugins/GammaPlugin/Sources/Gamma.swift"
  after="$(manifests_fingerprint)"
  doctor_assert_changed "新增插件目录 → 触发工程重生成" "$base" "$after"
  base="$after"
  rm -rf "$DOCTOR_TMP/Plugins/GammaPlugin"

  # 边界 5：删除插件目录。必须重新生成，否则被删插件的 target 会残留在工程里。
  rm -rf "$DOCTOR_TMP/Plugins/BetaPlugin"
  after="$(manifests_fingerprint)"
  doctor_assert_changed "删除插件目录 → 触发工程重生成" "$base" "$after"
  base="$after"

  # 边界 6：清单文件内容变化。必须重新生成。
  printf 'let manifestVersion = 2\n' > "$DOCTOR_TMP/Project.swift"
  doctor_assert_changed "清单文件内容变化 → 触发工程重生成" "$base" "$(manifests_fingerprint)"

  # 边界 7/8：整体跳过必须同时满足「输入指纹匹配」与「工程结构不过期」。
  # 构造产物完整（每个已发现插件都有 bundle）+ 输入指纹匹配的局面，只切换清单 stamp：
  # 清单 stamp 缺失时不得跳过（否则会拿陈旧 target 集合的产物交付），在位时才允许跳过。
  local fake_products="$DOCTOR_TMP/products"
  mkdir -p "$fake_products/NotchCenter.app/Contents/PlugIns"
  local i
  for i in "${!PLUGIN_NAMES[@]}"; do
    local name="${PLUGIN_NAMES[$i]}"
    mkdir -p "$fake_products/NotchCenter.app/Contents/PlugIns/$name.bundle/Contents/MacOS"
    : > "$fake_products/NotchCenter.app/Contents/PlugIns/$name.bundle/Contents/MacOS/$name"
  done
  printf 'matching-input-hash\n' > "$DOCTOR_TMP/Debug.sha"

  rm -f "$MANIFEST_STATE_FILE"
  doctor_assert_skip "工程结构过期（清单 stamp 缺失）→ 否决整体跳过" 1 \
    "$fake_products" "$DOCTOR_TMP/Debug.sha"

  manifests_fingerprint > "$MANIFEST_STATE_FILE"
  doctor_assert_skip "输入与工程结构均一致且产物完整 → 允许整体跳过" 0 \
    "$fake_products" "$DOCTOR_TMP/Debug.sha"

  mkdir -p "$fake_products/NotchCenter.app/Contents/PlugIns/GhostPlugin.bundle/Contents/MacOS"
  doctor_assert_skip "产物残留多余 bundle → 否决整体跳过" 1 \
    "$fake_products" "$DOCTOR_TMP/Debug.sha"
  rm -rf "$fake_products/NotchCenter.app/Contents/PlugIns/GhostPlugin.bundle"

  rm -rf "$fake_products/NotchCenter.app/Contents/PlugIns/${PLUGIN_NAMES[0]}.bundle"
  doctor_assert_skip "产物缺一个插件 bundle → 否决整体跳过" 1 \
    "$fake_products" "$DOCTOR_TMP/Debug.sha"

  echo
  if (( DOCTOR_FAILURES > 0 )); then
    echo "doctor：$DOCTOR_FAILURES 项失败"
    exit 1
  fi
  echo "doctor：全部通过"
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

  # 桥随包分发，必须与宿主同架构：只出 arm64 的话 Intel 机器上插件会永远空转。
  BRIDGE_ARCHS="arm64 x86_64"
  build_mediaremote_bridge

  echo "Building universal (release)..."
  # 这里刻意不复用 run_xcodebuild：发布要 clean build（两段动作形式，run_xcodebuild 只接
  # 单个 action），并要显式覆写 ARCHS / ONLY_ACTIVE_ARCH 关掉「只编当前架构」。
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
  # 再补齐 LaunchdControlKit / LidAngleKit 与插件 bundle。
  ditto "$built_app" "$app_dir"

  local frameworks_dir="$app_dir/Contents/Frameworks"
  local plugins_out="$app_dir/Contents/PlugIns"

  # 共享框架：NotchCenterKit 已由 Xcode 嵌入，这里校验通用架构；
  # LaunchdControlKit / LidAngleKit 由本脚本补齐，同样要求通用架构。
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
  local shared_lib
  for shared_lib in LaunchdControlKit LidAngleKit; do
    cp "$products_dir/lib${shared_lib}.dylib" "$frameworks_dir/lib${shared_lib}.dylib"
    check_universal_dylib "$frameworks_dir/lib${shared_lib}.dylib" "lib${shared_lib}"
  done

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
    doctor)  cmd_doctor ;;
    package) cmd_package "$@" ;;
    clean)   cmd_clean ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "未知子命令：$cmd" ;;
  esac
}

main "$@"
