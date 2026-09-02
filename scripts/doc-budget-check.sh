#!/usr/bin/env bash
# doc-driven-dev: doc-budget-check.sh
# 字数预算校验:读取 doc-budgets.manifest.json(支持 inherits 链:子包覆盖根),
# 对 budgets 中每个文件做 wc -m <= max;并校验 manifest 自身字符数 <= self_budget_chars。
# 缺文件只告警不失败;归档默认不参与(budgets 按显式路径,不匹配归档目录时自然豁免)。
# 用法: scripts/doc-budget-check.sh
# 退出码: 0 通过 | 1 超限 | 2 环境错误(缺 manifest / 缺 jq / inherits 链损坏)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

MAN="doc-budgets.manifest.json"
[[ -f "$MAN" ]] || { echo "doc-budget-check: 缺少 $MAN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "doc-budget-check: 需要 jq"; exit 2; }

# ---- 收集 inherits 链(根 → 当前),jq add 时后者覆盖前者 ----
declare -a MANS=()
collect_chain() {
  local m="$1" d="${2:-0}"
  (( d > 5 )) && { echo "doc-budget-check: inherits 链过深或成环"; return 1; }
  local parent base
  parent="$(jq -r '.inherits // empty' "$m" 2>/dev/null || true)"
  if [[ -n "$parent" && "$parent" != "null" ]]; then
    base="$(dirname "$m")"
    [[ -f "$base/$parent" ]] || { echo "doc-budget-check: inherits 父不存在 $base/$parent"; return 1; }
    collect_chain "$base/$parent" $((d + 1)) || return 1
  fi
  MANS+=("$m")
}
collect_chain "$MAN" || exit 2

MERGED="$(jq -s '[.[].budgets // {}] | add' "${MANS[@]}")"
FAIL=0

# 每个 manifest 的自身字数预算
for m in "${MANS[@]}"; do
  limit="$(jq -r '.self_budget_chars // 4096' "$m")"
  size="$(wc -m < "$m" | tr -d ' ')"
  if (( size > limit )); then
    echo "SELF-OVER-BUDGET: $m ($size chars > $limit)"
    FAIL=1
  fi
done

# budgets 逐文件校验(从最末 manifest 的键集合出发,值取 merged)
keys="$(printf '%s' "$MERGED" | jq -r 'keys[]')"
[[ -z "$keys" ]] && keys="$(printf '%s' "$MERGED" | jq -r 'keys[]' 2>/dev/null)"
if [[ -n "$keys" ]]; then
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if [[ ! -f "$k" ]]; then
      echo "WARN: budget 目标缺失(将跳过): $k"
      continue
    fi
    max="$(printf '%s' "$MERGED" | jq -r --arg k "$k" '.[$k].max // empty')"
    [[ -z "$max" || "$max" == "null" ]] && continue
    size="$(wc -m < "$k" | tr -d ' ')"
    if (( size > max )); then
      echo "OVER-BUDGET: $k ($size chars > max $max)"
      FAIL=1
    fi
  done <<< "$keys"
fi

[[ "$FAIL" -eq 0 ]] && echo "doc-budget-check: OK (${#MANS[@]} manifest(s) in chain)"
exit "$FAIL"
