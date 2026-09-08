#!/usr/bin/env bash
# doc-driven-dev: run-doc-checks.sh(聚合门禁入口)
# 依次执行全部文档校验并汇总;任一失败 → 整体 exit 1。钩子/CI 只调用本脚本。
# 用法: scripts/run-doc-checks.sh [--include-archived]
# 退出码: 0 全部通过 | 1 存在失败 | 2 运行环境错误
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 2

EXTRA=""
[[ "${1:-}" == "--include-archived" ]] && EXTRA="--include-archived"

CHECKS=(
  "verify-md-links.sh"
  "verify-md-wrap.sh"
  "verify-agent-note-format.sh"
  "verify-note-lifecycle.sh"
  "verify-comment-duplication.sh"
  "doc-budget-check.sh"
  "verify-code-blocks.sh"
  "verify-terminology.sh"
  "verify-scaffold-manifest.sh"
)

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/doc-driven.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0; FAIL=0; SKIP=0
for c in "${CHECKS[@]}"; do
  f="$SCRIPT_DIR/$c"
  if [[ ! -x "$f" ]]; then
    printf 'SKIP %-30s (脚本缺失或不可执行)\n' "$c"; SKIP=$((SKIP + 1)); continue
  fi
  LOG="$TMPDIR/$c.log"
  if "$f" $EXTRA >"$LOG" 2>&1; then
    printf 'PASS %-30s\n' "$c"; PASS=$((PASS + 1))
  else
    rc=$?
    printf 'FAIL %-30s (exit=%s)\n' "$c" "$rc"; FAIL=$((FAIL + 1))
    sed 's/^/     | /' "$LOG" | tail -n 20
  fi
done

echo "--------------------------------------------------"
echo "doc-driven checks: pass=$PASS fail=$FAIL skip=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
