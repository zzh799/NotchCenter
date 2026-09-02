#!/usr/bin/env bash
# doc-driven-dev: verify-terminology.sh
# 术语纪律校验:解析 docs/TERMINOLOGY.md frontmatter 中约束行格式的
#   - banned: "..."(每词一行,双引号包裹),扫描目标 md 中是否出现 banned 词
# (排除 docs/TERMINOLOGY.md 自身、docs/templates/、归档目录与代码围栏内容),命中即报 文件:行号。
# docs/TERMINOLOGY.md 不存在 → 跳过(exit 0)。
# 用法: scripts/verify-terminology.sh [--include-archived]
# 退出码: 0 通过 | 1 命中禁用词
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

TM="docs/TERMINOLOGY.md"
[[ -f "$TM" ]] || { echo "verify-terminology: skip (无 $TM)"; exit 0; }

INCLUDE_ARCHIVED=0
[[ "${1:-}" == "--include-archived" ]] && INCLUDE_ARCHIVED=1

# ---- 从 frontmatter 提取 banned 词(第一对 --- 之间)----
declare -a TERMS=()
AWK_FM='
/^---[[:space:]]*$/ { n++; next }
n == 1 && match($0, /banned: "[^"]+"/) {
  s = substr($0, RSTART + 9, RLENGTH - 10); gsub(/"/, "", s); print s
}
'
while IFS= read -r t; do
  [[ -n "$t" ]] && TERMS+=("$t")
done < <(awk "$AWK_FM" "$TM")
if (( ${#TERMS[@]} == 0 )); then
  echo "verify-terminology: OK (frontmatter 无 banned 词)"
  exit 0
fi

declare -a EXCLUDES=("docs/agent-notes/archive/" ".doc-driven-dev/" "docs/templates/")
if [[ -f doc-budgets.manifest.json ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "null" ]] && continue
    p="${p%%/\*\*}"
    [[ -z "$p" ]] && continue
    EXCLUDES+=("${p%/}/")
  done < <(jq -r '.exclude_paths[]? // empty' doc-budgets.manifest.json 2>/dev/null)
fi

excluded() {
  local f="$1" ex
  for ex in "${EXCLUDES[@]}"; do
    [[ "$INCLUDE_ARCHIVED" -eq 1 && "$ex" == "docs/agent-notes/archive/" ]] && continue
    [[ "$f" == "$ex"* ]] && return 0
  done
  [[ "$f" == "docs/TERMINOLOGY.md" ]] && return 0
  return 1
}

declare -a FILES=()
if command -v rg >/dev/null 2>&1; then
  RAW="$(rg --files -g '*.md' 2>/dev/null || true)"
else
  RAW="$(find . -type f -name '*.md' -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null)"
fi
while IFS= read -r f; do
  rel="${f#./}"; excluded "$rel" || FILES+=("$rel")
done <<< "$RAW"

# awk:跳过代码围栏内容,在非围栏行内做字面查找;多文件时用 FNR 保证行号正确。
# 词经 ENVIRON 传入,规避引号/转义问题。
export TM_TERM
HITS="$(for term in "${TERMS[@]}"; do
  TM_TERM="$term" awk '
    function hit() { return index($0, ENVIRON["TM_TERM"]) > 0 }
    BEGIN { fence = 0 }
    /^```/ { fence = (fence == 0) ? 1 : 0; next }
    fence == 1 { next }
    hit() { print FILENAME ":" FNR ": banned word \"" ENVIRON["TM_TERM"] "\"" }
  ' "${FILES[@]}"
done)"

FAIL=0
if [[ -n "$HITS" ]]; then
  printf '%s\n' "$HITS"
  FAIL=1
fi

[[ "$FAIL" -eq 0 ]] && echo "verify-terminology: OK (${#TERMS[@]} terms, ${#FILES[@]} files)"
exit "$FAIL"
