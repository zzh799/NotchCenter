#!/usr/bin/env bash
# doc-driven-dev: verify-md-links.sh
# 校验 md 内部链接目标存在。忽略 http(s)://、mailto:、tel:、纯锚点与其他协议。
# 默认跳过 docs/agent-notes/archive/ 与 .doc-driven-dev/;--include-archived 纳入归档。
# 用法: scripts/verify-md-links.sh [--include-archived]
# 退出码: 0 通过 | 1 断链 | 2 环境错误
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

INCLUDE_ARCHIVED=0
[[ "${1:-}" == "--include-archived" ]] && INCLUDE_ARCHIVED=1

# ---- 排除规则(内置 + manifest exclude_paths)----
declare -a EXCLUDES=("docs/agent-notes/archive/" ".doc-driven-dev/")
if [[ -f doc-budgets.manifest.json ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == "null" ]] && continue
    p="${p%%/\*\*}"           # 剥离尾部 /**(glob),保留目录前缀语义
    [[ -z "$p" ]] && continue
    EXCLUDES+=("${p%/}/")
  done < <(jq -r '.exclude_paths[]? // empty' doc-budgets.manifest.json 2>/dev/null)
fi

excluded() { # $1=rel path; 命中排除返回 0
  local f="$1" ex
  for ex in "${EXCLUDES[@]}"; do
    [[ "$INCLUDE_ARCHIVED" -eq 1 && "$ex" == "docs/agent-notes/archive/" ]] && continue
    [[ "$f" == "$ex"* ]] && return 0
  done
  return 1
}

# ---- 收集 md 文件(rg 优先,自动尊重 .rgignore/.ignore;否则 find)----
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
  ln=0
  while IFS= read -r line; do
    ln=$((ln + 1))
    LINKS="$(printf '%s\n' "$line" | grep -oE '\]\([^)]*\)' || true)"
    [[ -z "$LINKS" ]] && continue
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      t="${m#](}"; t="${t%)}"
      [[ -z "$t" ]] && continue
      case "$t" in
        http://*|https://*|mailto:*|tel:*|\#*) continue ;;
      esac
      [[ "$t" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]] && continue   # 其余协议不查
      target="${t%%#*}"
      [[ -z "$target" ]] && continue                         # 纯锚点
      dir="${f%/*}"; [[ "$dir" == "$f" ]] && dir="."
      if [[ ! -e "$dir/$target" && ! -e "$target" ]]; then
        echo "BROKEN LINK: $f:$ln -> $t"
        FAIL=1
      fi
    done <<< "$LINKS"
  done < "$f"
done

[[ "$FAIL" -eq 0 ]] && echo "verify-md-links: OK ($((${#FILES[@]})) files)"
exit "$FAIL"
