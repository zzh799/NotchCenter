#!/usr/bin/env bash
# doc-driven-dev: verify-scaffold-manifest.sh
# 落地记录一致性校验(建议 17):读取 .doc-driven-dev/manifest.json,
# 校验 artifacts 中每个 path 存在且非空;marker:true 的文本文件必须包含标记
# "managed:doc-driven-dev"。manifest 缺失视为"未做治理落地",跳过(exit 0)。
# 标了 local_only:true 的条目是**本机落地状态**(如 .git/hooks/*),只在本地校验,
# CI 中记 SKIP——检出里不存在它们,要求存在即结构性自锁,见下方 IS_CI 注释。
# 用法: scripts/verify-scaffold-manifest.sh
# 退出码: 0 一致(或未落地) | 1 存在缺失/不一致 | 2 环境错误(缺 jq)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

MF=".doc-driven-dev/manifest.json"
[[ -f "$MF" ]] || { echo "verify-scaffold-manifest: skip (无 $MF,未做治理落地)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "verify-scaffold-manifest: 需要 jq"; exit 2; }

# manifest 里有一类产出物是**本机落地状态**而非仓库内容:典型是 .git/hooks/*,由脚手架
# 写进开发机的 .git 目录,从不入库。CI 是刚 clone 出来的干净检出,这些文件必然不存在
# (只有 *.sample),要求它们存在等于让门禁必红——docs-gate 曾因此连续多日全红,与代码
# 质量无关。所以:local_only 条目在 CI 里不参与判定(记一条 SKIP),本地照常校验,
# 本机上删掉钩子仍会被拦住。
IS_CI=0
[[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]] && IS_CI=1

MARKER="managed:doc-driven-dev"
FAIL=0
COUNT=0
SKIPPED=0
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
while IFS=$'\t' read -r path marker local_only; do
  [[ -z "$path" ]] && continue
  COUNT=$((COUNT + 1))
  if [[ "$IS_CI" -eq 1 && "$local_only" == "true" ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
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
done < <(jq -r '.artifacts[]? | [(.path // ""), ((.marker // false) | tostring), ((.local_only // false) | tostring)] | @tsv' "$MF" 2>/dev/null)

if [[ "$FAIL" -eq 0 ]]; then
  if [[ "$SKIPPED" -gt 0 ]]; then
    echo "verify-scaffold-manifest: OK ($COUNT artifact(s); $SKIPPED local-only skipped: 本机落地物在 CI 不适用)"
  else
    echo "verify-scaffold-manifest: OK ($COUNT artifact(s))"
  fi
fi
exit "$FAIL"
