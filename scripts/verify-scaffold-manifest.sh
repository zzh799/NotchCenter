#!/usr/bin/env bash
# doc-driven-dev: verify-scaffold-manifest.sh
# 落地记录一致性校验(建议 17):读取 .doc-driven-dev/manifest.json,
# 校验 artifacts 中每个 path 存在且非空;marker:true 的文本文件必须包含标记
# "managed:doc-driven-dev"。manifest 缺失视为"未做治理落地",跳过(exit 0)。
# 用法: scripts/verify-scaffold-manifest.sh
# 退出码: 0 一致(或未落地) | 1 存在缺失/不一致 | 2 环境错误(缺 jq)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

MF=".doc-driven-dev/manifest.json"
[[ -f "$MF" ]] || { echo "verify-scaffold-manifest: skip (无 $MF,未做治理落地)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "verify-scaffold-manifest: 需要 jq"; exit 2; }

MARKER="managed:doc-driven-dev"
FAIL=0
COUNT=0
# worktree 的 .git 是指向主仓库公共目录的指针文件：manifest 里的 .git/* 落地物
# （如 hooks/pre-commit）须按 git-common-dir 解析，字面相对路径只在主仓库成立。
COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
[[ -n "$COMMON_GIT_DIR" ]] && COMMON_GIT_DIR="$(cd "$COMMON_GIT_DIR" && pwd)"
resolve_path() {
  local p="$1"
  case "$p" in
    .git/*)
      if [[ -n "$COMMON_GIT_DIR" ]]; then
        echo "$COMMON_GIT_DIR/${p#.git/}"
      else
        echo "$p"
      fi
      ;;
    *) echo "$p" ;;
  esac
}
while IFS=$'\t' read -r path marker; do
  [[ -z "$path" ]] && continue
  COUNT=$((COUNT + 1))
  target="$(resolve_path "$path")"
  if [[ ! -e "$target" ]]; then
    echo "MISSING ARTIFACT: $path (manifest 记录存在,磁盘缺失)"
    FAIL=1
    continue
  fi
  if [[ -f "$target" && ! -s "$target" ]]; then
    echo "EMPTY ARTIFACT: $path"
    FAIL=1
    continue
  fi
  if [[ "$marker" == "true" ]] && ! grep -qF "$MARKER" "$target" 2>/dev/null; then
    echo "MISSING MARKER: $path (应含 '$MARKER')"
    FAIL=1
  fi
done < <(jq -r '.artifacts[]? | [(.path // ""), ((.marker // false) | tostring)] | @tsv' "$MF" 2>/dev/null)

[[ "$FAIL" -eq 0 ]] && echo "verify-scaffold-manifest: OK ($COUNT artifact(s))"
exit "$FAIL"
