#!/usr/bin/env bash
# doc-driven-dev: verify-comment-duplication.sh(重复注释门禁,决策 D10)
# 同一归一化 // 注释文本出现在 >= MIN_FILES 个 Swift 文件 → 违规("同一为什么信息全局
# 只写一处",D9)。只扫 Sources/ 与 Plugins/ 下的 *.swift;块注释 /* */ v1 不扫。
# 归一化:取行中第一个 // 之后的内容(行内 // 前的 "://" 先替换为占位,避免把 URL
# 协议当注释起点),去行首空白与 //+ 前缀、尾随空白。排除:^MARK: 行、含
# Copyright/License 的许可证头。
# 阈值常量(误报时调参,v1 无白名单):
#   MIN_CHARS:归一化后最少字符数才计数(按 Unicode 字符,非字节;awk length() 在
#             BSD/macOS 按字节计,故用 bash ${#var} 计字符)
#   MIN_FILES:出现在多少个不同文件算违规
# 用法: scripts/verify-comment-duplication.sh
# 退出码: 0 通过 | 1 违规
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

MIN_CHARS=15
MIN_FILES=3

shopt -s extglob
TMP="$(mktemp "${TMPDIR:-/tmp}/dup-comment.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

while IFS= read -r -d '' f; do
  while IFS= read -r line; do
    # 先把 URL 协议(://)掩掉,再找注释起点:行内第一个 // 之后即注释文本
    masked="${line//:\/\//:U}"
    [[ "$masked" == *"//"* ]] || continue
    t="${masked#*//}"
    # 去注释起点残留的 / 与首尾空白(/// 文档注释归一化后与 // 等价)
    t="${t##+([/[:space:]])}"
    t="${t%%+([[:space:]])}"
    [[ -z "$t" ]] && continue
    case "$t" in
      MARK:*) continue;;
    esac
    [[ "$t" == *Copyright* || "$t" == *License* ]] && continue
    (( ${#t} >= MIN_CHARS )) || continue
    printf '%s\t%s\n' "$f" "$t"
  done < "$f"
done < <(find Sources Plugins -type f -name '*.swift' \
  -not -path '*/.build/*' -not -path '*/.swiftpm/*' -print0 2>/dev/null) | LC_ALL=C sort -u > "$TMP"

# 按归一化文本分组:同文本出现在 >= MIN_FILES 个不同文件 → 违规
# 输出记录:count \t 文本 \t "文件 | 文件 | ..."(单行,便于解析)
OUT="$(awk -F'\t' -v min="$MIN_FILES" '
  { count[$2]++; files[$2] = files[$2] (files[$2] ? " | " : "") $1 }
  END {
    for (k in count)
      if (count[k] >= min) print count[k] "\t" k "\t" files[k]
  }' "$TMP" | LC_ALL=C sort -rn)"

if [[ -n "$OUT" ]]; then
  while IFS=$'\t' read -r n text filelist; do
    echo "DUPLICATE COMMENT ($n files): $text"
    echo "  - ${filelist// | /$'\n  - '}"
    echo
  done <<< "$OUT"
  exit 1
fi
echo "verify-comment-duplication: OK"
exit 0
