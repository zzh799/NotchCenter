#!/usr/bin/env bash
# doc-driven-dev: verify-code-blocks.sh
# 校验 md 代码围栏:必须闭合;语言必须标注;若 doc-budgets.manifest.json 的
# code_block_langs 非空,标注语言必须属于白名单。默认排除 docs/templates/(模板含各类示例语言)。
# 用法: scripts/verify-code-blocks.sh [--include-archived]
# 退出码: 0 通过 | 1 违规 | 2 环境错误
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

INCLUDE_ARCHIVED=0
[[ "${1:-}" == "--include-archived" ]] && INCLUDE_ARCHIVED=1

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
  return 1
}

# 白名单(bash 数组 + 精确匹配)
declare -a WHITELIST=()
if [[ -f doc-budgets.manifest.json ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r l; do
    [[ -n "$l" && "$l" != "null" ]] && WHITELIST+=("$l")
  done < <(jq -r '.code_block_langs[]? // empty' doc-budgets.manifest.json 2>/dev/null)
fi

declare -a FILES=()
if command -v rg >/dev/null 2>&1; then
  RAW="$(rg --files -g '*.md' 2>/dev/null || true)"
else
  RAW="$(find . -type f -name '*.md' -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null)"
fi
while IFS= read -r f; do
  rel="${f#./}"; excluded "$rel" || FILES+=("$rel")
done <<< "$RAW"

FAIL=0
for f in "${FILES[@]}"; do
  # awk 输出:每个围栏一行 "<语言>",语言为空输出 "<empty>";结构错误直接打印并标记
  OUT="$(awk '
    /^```/ {
      if (fence == 0) {
        fence = 1; lang = $0; sub(/^```[ \t]*/, "", lang); sub(/[ \t]+$/, "", lang)
        if (lang == "") { print "<empty>" } else { print lang }
        next
      } else { fence = 0; next }
    }
    END { if (fence == 1) { print "__UNCLOSED__" } }
  ' "$f")" || true
  [[ -z "$OUT" ]] && continue
  while IFS= read -r lang; do
    [[ -z "$lang" ]] && continue
    if [[ "$lang" == "__UNCLOSED__" ]]; then
      echo "UNCLOSED FENCE: $f"; FAIL=1; continue
    fi
    if [[ "$lang" == "<empty>" ]]; then
      echo "UNNAMED FENCE: $f (代码围栏必须标注语言)"; FAIL=1; continue
    fi
    if (( ${#WHITELIST[@]} > 0 )); then
      ok=0
      for w in "${WHITELIST[@]}"; do [[ "$lang" == "$w" ]] && ok=1; done
      if [[ "$ok" -eq 0 ]]; then
        echo "DISALLOWED LANG: $f -> \`$lang\` (白名单: ${WHITELIST[*]})"; FAIL=1
      fi
    fi
  done <<< "$OUT"
done

[[ "$FAIL" -eq 0 ]] && echo "verify-code-blocks: OK ($((${#FILES[@]})) files, whitelist=${#WHITELIST[@]})"
exit "$FAIL"
