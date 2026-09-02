#!/usr/bin/env bash
# doc-driven-dev: verify-agent-note-format.sh
# 校验决策记录:路径必须匹配 docs/agent-notes/(proposed|implemented|rejected|archive)/(<分类>/)?<yyyy-mm-dd>-*.md
# (<分类>/ 可选);非归档 note 必须含 "## Alternatives considered"。
# 默认跳过 archive/;--include-archived 纳入归档(归档豁免必含节,但路径正则仍校验)。
# 用法: scripts/verify-agent-note-format.sh [--include-archived]
# 退出码: 0 通过 | 1 违规
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

INCLUDE_ARCHIVED=0
[[ "${1:-}" == "--include-archived" ]] && INCLUDE_ARCHIVED=1

BASE="docs/agent-notes"
[[ -d "$BASE" ]] || { echo "verify-agent-note-format: skip (无 $BASE)"; exit 0; }

declare -a FILES=()
if command -v rg >/dev/null 2>&1; then
  RAW="$(rg --files -g '*.md' "$BASE" 2>/dev/null || true)"
else
  RAW="$(find "$BASE" -type f -name '*.md' 2>/dev/null)"
fi
while IFS= read -r f; do
  rel="${f#./}"
  [[ "$rel" == docs/agent-notes/archive/* && "$INCLUDE_ARCHIVED" -eq 0 ]] && continue
  FILES+=("$rel")
done <<< "$RAW"

RE='^docs/agent-notes/(proposed|implemented|rejected|archive)/([^/]+/)?[0-9]{4}-[0-9]{2}-[0-9]{2}-[^/]+\.md$'
FAIL=0
for f in "${FILES[@]}"; do
  if [[ ! "$f" =~ $RE ]]; then
    echo "BAD PATH: $f (期望 docs/agent-notes/(proposed|implemented|rejected|archive)/(<分类>/)?<yyyy-mm-dd>-*.md)"
    FAIL=1
    continue
  fi
  if [[ "$f" != docs/agent-notes/archive/* ]] && ! grep -q '^## Alternatives considered' "$f"; then
    echo "MISSING SECTION: $f (非归档 note 必须含 ## Alternatives considered)"
    FAIL=1
  fi
done

[[ "$FAIL" -eq 0 ]] && echo "verify-agent-note-format: OK ($((${#FILES[@]})) notes)"
exit "$FAIL"
