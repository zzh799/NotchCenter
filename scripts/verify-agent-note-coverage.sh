#!/usr/bin/env bash
# doc-driven-dev: verify-agent-note-coverage.sh(决策记录引用门禁,决策 D2)
# 硬规则:触及 Sources/ 或 Plugins/ 的 commit,消息类型非 fix:/docs:/chore:/test: 的,
# 必须引用 "(note: <yyyy-mm-dd>-<slug>)",且 docs/agent-notes/proposed|implemented/ 下
# 存在同名文件(同 commit 新增的 note 算数,工作树存在即算)。
# 两种模式:
#   A(commit-msg 钩子): --message-file $1         检查本次 staged 变更 + 消息文件
#   B(CI 区间):         --range <before>..<after>  逐个检查区间内 commit
#                       (three-dot 亦可用;激活 commit 及更早一律跳过,见 D7 存量不回溯)
# 注意:macOS 自带 bash 3.2,禁用 mapfile/空数组展开等 bash 4 特性。
# 用法: scripts/verify-agent-note-coverage.sh --message-file <file> | --range <range>
# 退出码: 0 通过 | 1 违规 | 2 用法错误
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

MODE=""; MESSAGE_FILE=""; RANGE=""
case "${1:-}" in
  --message-file) MODE=hook; MESSAGE_FILE="${2:?缺少消息文件路径}";;
  --range) MODE=range; RANGE="${2:?缺少区间}";;
  *) echo "用法: $0 --message-file <file> | --range <before>..<after>"; exit 2;;
esac

# 判定单个(消息, 文件列表)是否满足覆盖要求。filelist 为换行分隔的路径串。
# 违规时输出原因并 exit 1;通过 exit 0。
judge() {
  local msg="$1" filelist="$2"
  local f touched=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      Sources/*|Plugins/*) touched=1; break;;
    esac
  done <<< "$filelist"
  [[ "$touched" -eq 0 ]] && return 0

  local subject
  subject="$(printf '%s\n' "$msg" | sed -n '1s/^[[:space:]]*//;1p')"
  # 豁免类型:fix/docs/chore/test,支持 scope(如 fix(ui):)与破坏性标记(如 fix!:)
  if printf '%s' "$subject" | grep -Eq '^(fix|docs|chore|test)(\([^)]*\))?!?:'; then
    return 0
  fi

  local refs x bad="" missing="" rc=0
  refs="$(printf '%s\n' "$msg" | grep -oE '\(note: [^)]+\)' | sed -E 's/^\(note: //; s/\)$//' || true)"
  if [[ -z "${refs//[[:space:]]/}" ]]; then
    echo "消息未引用决策记录:类型非 fix:/docs:/chore:/test:,须在消息中加 '(note: <日期>-<slug>)' 或改标为上述豁免类型"
    return 1
  fi
  while IFS= read -r x; do
    [[ -z "$x" ]] && continue
    if [[ ! "$x" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      bad="$bad (note: $x)"; rc=1; continue
    fi
    if [[ ! -f "docs/agent-notes/proposed/$x.md" && ! -f "docs/agent-notes/implemented/$x.md" ]]; then
      missing="$missing (note: $x)"; rc=1
    fi
  done <<< "$refs"
  [[ -n "$bad" ]] && echo "引用格式错误(应为 <yyyy-mm-dd>-<slug>):$bad"
  [[ -n "$missing" ]] && echo "引用的 note 不存在(docs/agent-notes/proposed/ 或 implemented/ 下无同名文件):$missing"
  [[ "$rc" -eq 0 ]] && return 0
  echo "两目录下可引用的文件名:"
  (cd docs/agent-notes && ls proposed/*.md implemented/*.md 2>/dev/null) | sed 's/^/  - /'
  return 1
}

if [[ "$MODE" == "hook" ]]; then
  msg="$(cat "$MESSAGE_FILE" 2>/dev/null || true)"
  filelist="$(git diff --cached --name-only 2>/dev/null || true)"
  if judge "$msg" "$filelist"; then
    exit 0
  fi
  echo "note 覆盖门禁失败(上述提交被拦截)"
  exit 1
fi

# ---- 模式 B:CI 区间 ----
# 激活点 = 本脚本首次进入历史的 commit;激活 commit 及更早提交跳过(D7 存量不回溯)。
ACTIVATION="$(git log --diff-filter=A --format='%H' -- scripts/verify-agent-note-coverage.sh 2>/dev/null | tail -n 1)"
if [[ -n "$ACTIVATION" ]]; then
  echo "note 覆盖门禁:区间 $RANGE,激活点 ${ACTIVATION:0:12}(激活 commit 及更早跳过)"
fi
FAIL=0; CHECKED=0
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  if [[ -n "$ACTIVATION" ]]; then
    if [[ "$c" == "$ACTIVATION" ]] || git merge-base --is-ancestor "$c" "$ACTIVATION" 2>/dev/null; then
      echo "SKIP ${c:0:12} (激活点或更早)"
      continue
    fi
  fi
  CHECKED=$((CHECKED + 1))
  msg="$(git log -1 --format=%B "$c")"
  filelist="$(git diff-tree --no-commit-id --name-only -r "$c" 2>/dev/null || true)"
  if judge "$msg" "$filelist"; then
    echo "PASS ${c:0:12} $(git log -1 --format=%s "$c")"
  else
    echo "FAIL ${c:0:12} $(git log -1 --format=%s "$c")"
    FAIL=1
  fi
done < <(git rev-list "$RANGE" 2>/dev/null || true)
echo "note 覆盖门禁:checked=$CHECKED fail=$FAIL"
exit "$FAIL"
