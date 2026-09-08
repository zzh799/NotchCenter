#!/usr/bin/env bash
# doc-driven-dev: verify-note-lifecycle.sh(proposed 滞留硬线,决策 D4)
# 扫描 docs/agent-notes/proposed/*.md,frontmatter date 早于 cutoff(今天 - 7 天)即违规:
# 处置 = git mv 至 implemented/、archive/、rejected/ 之一(长周期规划 7 天内无法实现的,
# 移至 rejected/ 注明待排期,排期后按新日期重新提回 proposed/)。
# 用法: scripts/verify-note-lifecycle.sh
# 退出码: 0 通过 | 1 违规 | 2 环境错误
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

DIR="docs/agent-notes/proposed"
[[ -d "$DIR" ]] || { echo "verify-note-lifecycle: skip (无 $DIR)"; exit 0; }

today="$(date +%F)"
# cutoff = 7 天前的日期;BSD/macOS 用 -j -v,Linux 用 -d
if ! cutoff="$(date -j -v-7d +%F 2>/dev/null)"; then
  cutoff="$(date -d '7 days ago' +%F 2>/dev/null)" || true
fi
[[ -z "$cutoff" ]] && { echo "verify-note-lifecycle: 无法计算 cutoff(不支持 date -j / date -d)"; exit 2; }
now_epoch="$(date +%s)"
epoch_of() { # 日期 → epoch;不支持则输出空
  date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || true
}

FAIL=0
while IFS= read -r f; do
  d="$(sed -n '/^date:[[:space:]]*/{s///;s/[[:space:]]*$//;p;q;}' "$f")"
  if [[ -z "$d" ]]; then
    echo "LIFECYCLE: $f 缺少可解析的 frontmatter date 行(^date: <yyyy-mm-dd>)"
    FAIL=1
    continue
  fi
  # ISO 日期可直接按字符串比较
  if [[ "$d" < "$cutoff" ]]; then
    note_epoch="$(epoch_of "$d")"
    days="?"
    if [[ -n "$note_epoch" ]]; then
      days=$(( (now_epoch - note_epoch) / 86400 ))
    fi
    echo "LIFECYCLE: $f 滞留 proposed/ 已 $days 天(frontmatter date $d,上限 7 天)"
    echo "  处置: git mv $f docs/agent-notes/implemented/$(basename "$f")"
    echo "        (或移入 docs/agent-notes/archive/、rejected/ 之一;长周期规划移 rejected/ 注明待排期)"
    FAIL=1
  fi
done < <(find "$DIR" -type f -name '*.md' | sort)

[[ "$FAIL" -eq 0 ]] && echo "verify-note-lifecycle: OK"
exit "$FAIL"
