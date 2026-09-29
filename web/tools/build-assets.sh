#!/usr/bin/env bash
# 从仓库内已有的源资产派生主页用的压缩资源。产物直接提交进仓库（静态站点无法在 CI
# 里稳定重造图片：runner 不保证有 ffmpeg/cwebp），本脚本存在的意义是让派生过程可复现。
#
# 用法：bash web/tools/build-assets.sh
#
# 需要 macOS 自带 sips 与 Homebrew 的 ffmpeg / cwebp。改源资产（docs/assets、
# Resources/AppIcon.png）后重跑一次并提交 web/assets 的变化。
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$WEB_DIR/.." && pwd)"
ASSETS_DIR="$WEB_DIR/assets"
MAIN_VIEW_SRC="$REPO_ROOT/docs/assets/MainView.png"
DEMO_SOURCES=("$REPO_ROOT/docs/assets/Common.gif:demo-common" "$REPO_ROOT/docs/assets/Setting.gif:demo-settings")
APP_ICON_SRC="$REPO_ROOT/Resources/AppIcon.png"
# 背景色取自 DESIGN.md §2.1 的抽屉主背景（近黑，带一点点蓝）。
BACKGROUND="0x050506"

for tool in sips ffmpeg cwebp; do
  command -v "$tool" >/dev/null || { echo "缺少 $tool，先安装它（brew install $tool）"; exit 1; }
done

mkdir -p "$ASSETS_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1) 主界面截图：裁掉四周的蓝色桌面壁纸 -> webp。原图 1428px 宽，足够 2x 展示，不缩放。
#
# 裁剪偏移是实测出来的：docs/assets/MainView.png 的黑色区域精确落在 x 45..1378 / y 1..1198
# （四周是录屏带进来的蓝色壁纸），而抽屉底部两角有约 47px 的圆角，左下/右下角在 y≈1175 之外
# 就露出壁纸。所以取 x 52..1371 / y 4..1171，四条边都落在纯黑里。
# 换掉这张截图后必须重新测量这些常量——assert_dark_edges 会在失配时直接报错，
# 而不是把蓝边悄悄带进主页。
CROP_X=52
CROP_Y=4
CROP_W=1320
CROP_H=1168

[ -f "$MAIN_VIEW_SRC" ] || { echo "缺少 $MAIN_VIEW_SRC"; exit 1; }
ffmpeg -y -loglevel error -i "$MAIN_VIEW_SRC" -vf "crop=$CROP_W:$CROP_H:$CROP_X:$CROP_Y" "$TMP_DIR/main-view.png"

# 断言裁剪结果的四条边都是暗色：任一浅色像素即说明裁剪偏移与截图不再匹配。
assert_dark_edges() {
  local png="$1" w="$2" h="$3" strip ymax
  for strip in "$w:1:0:0" "$w:1:0:$((h - 1))" "1:$h:0:0" "1:$h:$((w - 1)):0"; do
    ymax="$(ffmpeg -v error -i "$png" -vf "crop=$strip,format=gray" -f rawvideo - \
      | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$' | sort -n | tail -1)"
    if [[ -z "$ymax" ]] || (( ymax >= 30 )); then
      echo "裁剪边存在浅色像素（边条 $strip，最大亮度 ${ymax:-未知}）：截图四周的蓝色壁纸未被裁净。"
      echo "请重新测量 docs/assets/MainView.png 的黑色区域边界并更新 build-assets.sh 里的 CROP_* 常量。"
      exit 1
    fi
  done
}
assert_dark_edges "$TMP_DIR/main-view.png" "$CROP_W" "$CROP_H"

cwebp -quiet -q 82 -m 6 -metadata none "$TMP_DIR/main-view.png" -o "$ASSETS_DIR/main-view.webp"

# 2) 演示动画：GIF -> H.264 mp4 + webp 首帧封面。
#    源 GIF 分别是 862KB / 2.5MB，直接放落地页首屏不可接受，必须转码。
#    yuv420p + 偶数尺寸是 H.264 的硬要求；faststart 让 moov 前置以便边下边播。
#
#    两段 GIF 都是屏幕录制，桌面壁纸是一整块饱和蓝，与主页的近黑底色冲突。这里用
#    chromakey 把壁纸抠掉、垫上页面同款近黑，观感相当于「深色桌面上的浮层」，抽屉
#    开合动画露出的区域也自然融为一体（硬裁剪做不到：抽屉展开过程中边缘会露壁纸）。
#    键色 0x2D82E4 是实测的壁纸色；similarity 0.06 是逐档对比（0.04/0.06/0.08）后
#    能保住文件架里蓝色文件夹图标的最大档。换源素材时如果壁纸颜色变了，这里会悄悄
#    失效，跑完请看一眼输出。
for source in "${DEMO_SOURCES[@]}"; do
  input="${source%%:*}"
  name="${source##*:}"
  [ -f "$input" ] || { echo "缺少 $input"; exit 1; }
  dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$input")"
  fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$input")"
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input")"
  # color 源是无限流，必须显式给定帧率与时长，并让 overlay 以它为底、以抠像结果为
  # 上层；否则 overlay 会跟着无限流一直编码下去（实测曾写出 125MB 还在涨）。
  ffmpeg -y -loglevel error -i "$input" \
    -f lavfi -i "color=c=${BACKGROUND}:s=${dims}:r=${fps}:d=${duration}" \
    -filter_complex "[0:v]chromakey=0x2D82E4:0.06:0.04[ck];[1:v][ck]overlay,scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -pix_fmt yuv420p -c:v libx264 -crf 20 -preset slow -movflags +faststart \
    "$ASSETS_DIR/$name.mp4"
  # 封面取第 1 秒的一帧（GIF 首帧往往还是空态，1 秒后内容已成型）。
  ffmpeg -y -loglevel error -ss 1 -i "$ASSETS_DIR/$name.mp4" -frames:v 1 "$TMP_DIR/$name-poster.png"
  cwebp -quiet -q 82 -m 6 -metadata none "$TMP_DIR/$name-poster.png" -o "$ASSETS_DIR/$name-poster.webp"
done

# 3) 应用图标派生：站点图标与 apple-touch-icon。sips 按「高 宽」顺序取参。
#    AppIcon.png 自带一圈白底画布（实测内容边界 x 33..1224 / y 27..1252），这里不做
#    抠底：favicon 在浅色与深色工具栏里都要可见，apple-touch-icon 则必须是整幅不透明
#    方图（iOS 会把透明合成成黑角），白底恰好是两者都安全的选择。
[ -f "$APP_ICON_SRC" ] || { echo "缺少 $APP_ICON_SRC"; exit 1; }
sips -s format png -z 32 32 "$APP_ICON_SRC" --out "$ASSETS_DIR/favicon-32.png" >/dev/null
sips -s format png -z 180 180 "$APP_ICON_SRC" --out "$ASSETS_DIR/apple-touch-icon-180.png" >/dev/null

# 4) 社交卡片 1200x630：近黑底 + 居中图标。
#    卡片背景是近黑，图标的白底画布必须抠掉，否则分享出去是一块白色补丁。用
#    colorkey（RGB 距离）而不是 chromakey（YUV 色度距离）：白色与图标的深灰主体都是
#    无色差（chroma 相同），chromakey 会把图标主体一起抠掉，实测如此。
#    刻意不渲染文字：ffmpeg 的 drawtext 要显式指定字体文件路径，跨机器不可靠。
ffmpeg -y -loglevel error -i "$APP_ICON_SRC" -f lavfi -i "color=c=${BACKGROUND}:s=1200x630" \
  -filter_complex "[0:v]colorkey=0xFEFDFE:0.12:0.04,crop=1192:1226:33:27,scale=320:328[icon];[1:v][icon]overlay=(W-w)/2:(H-h)/2" \
  -frames:v 1 "$ASSETS_DIR/og-image.png"

echo "web/assets 已更新："
ls -lh "$ASSETS_DIR" | tail -n +2 | awk '{print "  " $9 "  " $5}'
