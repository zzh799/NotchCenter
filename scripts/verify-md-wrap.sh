#!/usr/bin/env bash
# doc-driven-dev: verify-md-wrap.sh
# 校验"段落硬换行":同一段落内无空行的手动换行即违规,除非行尾为显式换行
# (两空格 / 反斜杠 / <br>),或处于列表、表格、引用、代码围栏中。
# 用法: scripts/verify-md-wrap.sh [--include-archived]
# 退出码: 0 通过 | 1 违规
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

INCLUDE_ARCHIVED=0
[[ "${1:-}" == "--include-archived" ]] && INCLUDE_ARCHIVED=1

declare -a EXCLUDES=("docs/agent-notes/archive/" ".doc-driven-dev/")
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

declare -a FILES=()
if command -v rg >/dev/null 2>&1; then
  RAW="$(rg --files -g '*.md' 2>/dev/null || true)"
else
  RAW="$(find . -type f -name '*.md' -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null)"
fi
while IFS= read -r f; do
  rel="${f#./}"; excluded "$rel" || FILES+=("$rel")
done <<< "$RAW"

AWK_PROG='
function is_block(l){ return l ~ /^[ \t]*(#{1,6}[ \t]|>|[-*+][ \t]|[0-9]+[.)][ \t]|\|)/ }
function is_meta(l){ return l ~ /^---|^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]|^<!--/ }
BEGIN{ fence=0; prev="x"; prevline="" }
/^```/ { if (fence==0) fence=1; else fence=0; prev="x"; prevline=$0; next }
fence==1 { prev="x"; prevline=$0; next }
/^[[:space:]]*$/ { prev="x"; prevline=$0; next }
is_block($0) || is_meta($0) { prev="b"; prevline=$0; next }
{
  if (prev=="p" && $0 !~ /^(  |\\|<\/?br[[:space:]]*>)[[:space:]]*$/ && prevline !~ /( {2}|\\|<\/?br[[:space:]]*>)[[:space:]]*$/) {
    print FILENAME ":" (NR-1) ": 段落软换行(缺空行分隔)"
    bad=1
  }
  prev="p"; prevline=$0
}
END{ if (bad) exit 1 }
'

FAIL=0
for f in "${FILES[@]}"; do
  OUT="$(awk "$AWK_PROG" "$f")" || true
  if [[ -n "$OUT" ]]; then echo "$OUT"; FAIL=1; fi
done

[[ "$FAIL" -eq 0 ]] && echo "verify-md-wrap: OK ($((${#FILES[@]})) files)"
exit "$FAIL"
