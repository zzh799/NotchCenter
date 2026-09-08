#!/usr/bin/env bash
# UI token 规范扫描(警告级,不挂门禁):
#   扫描宿主与插件 UI 源码中的"内联样式字面量",推动优先迁移到 NotchCenterKit
#   的 `NotchTokens`(DESIGN.md spec 的代码化唯一事实源)。
#   宿主 UI 一律引用 token;插件 UI 推荐引用,插件自有视觉(含数据可视化语义色)
#   可收敛为插件内命名常量/调色板——此类命中仍计数,按基线/豁免口径登记于
#   docs/UI规范整改追踪.md。
#
# 规则:
#   color-rgb  硬编码 RGB 色值构造(Color(red: / Color(white: / NSColor(srgbRed:)
#              ——优先改用 NotchTokens.Foreground/Surface/Semantic,数据可视化
#              语义色经审计后留在插件本地调色板(基线豁免)。
#   font-raw   裸 .font(.system(size:...) ——优先改用 NotchTokens.Text 预设或
#              Text.system(...) 工厂。
#   spring-raw 裸 spring 动画字面量(.animation/.withAnimation + .spring(response:)
#              ——优先改用 NotchTokens.Motion(expand/shelfAppear/removal/tabSwitch)。
#
# 豁免:纯注释行;Sources/NotchCenterKit/、Tests/、Vendor/、Derived/、dist.noindex/。
#
# 基线:根目录 ui-token-baseline.json 按 文件→规则 记录存量上限,存量只降不升;
#   超基线在 --strict 下 exit 1(未来接门禁用),默认仅警告 exit 0。
# 用法:
#   scripts/scan-ui-tokens.sh                    # 扫描 + 对比基线(警告)
#   scripts/scan-ui-tokens.sh --update-baseline  # 以当前计数重写基线快照
#   scripts/scan-ui-tokens.sh --strict           # 超基线 exit 1
# 退出码: 默认 0 | --strict 时超基线 1
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 2

BASELINE="ui-token-baseline.json"
UPDATE_BASELINE=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --strict) STRICT=1 ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done

# ---- 收集目标文件(插件 + 宿主 UI,豁免 Kit/Tests/Vendor 等)----
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(
  find Plugins Sources -type f -name '*.swift' 2>/dev/null \
    | grep -vE '^Sources/NotchCenterKit/' \
    | grep -vE '^Tests/' \
    | grep -vE '^Vendor/' \
    | grep -vE '^Derived/' \
    | grep -vE '^dist\.noindex/' \
    | sort
)
if (( ${#FILES[@]} == 0 )); then echo "scan-ui-tokens: no files"; exit 0; fi

HITS="$(mktemp)"
trap 'rm -f "$HITS"' EXIT

# ---- 扫描:逐规则 grep,awk 过滤纯注释行并归一为 file<TAB>line<TAB>rule<TAB>text ----
scan_rule() {
  local rule="$1" pattern="$2"
  grep -nE "$pattern" "${FILES[@]}" 2>/dev/null | awk -v rule="$rule" '
    {
      i1 = index($0, ":")
      f = substr($0, 1, i1 - 1)
      rest = substr($0, i1 + 1)
      i2 = index(rest, ":")
      line = substr(rest, 1, i2 - 1)
      text = substr(rest, i2 + 1)
      if (text !~ /^[[:space:]]*\/\//)
        print f "\t" line "\t" rule "\t" text
    }'
}
{
  scan_rule color-rgb  'Color\(red:|Color\(white:|NSColor\(srgbRed:'
  scan_rule font-raw   '\.font\(\.system\(size:'
  scan_rule spring-raw '(\.animation|withAnimation)\(\.spring\('
} > "$HITS"

# ---- 输出明细与汇总 ----
awk -F'\t' '{printf "%s:%s: [%s] ", $1, $2, $3; sub(/^[[:space:]]+/, "", $4); print $4}' "$HITS" | sort

echo ""
echo "==== scan-ui-tokens 汇总 ===="
awk -F'\t' '{c[$1 "|" $3]++} END { for (k in c) print k " " c[k] }' "$HITS" | sort \
| awk '
  {
    split($1, p, "|"); f = p[1]; rule = p[2]; n = $2
    total[f] += n; count[f, rule] = n
    if (!(f in seen)) { order[++idx] = f; seen[f] = 1 }
  }
  END {
    for (i = 1; i <= idx; i++) {
      f = order[i]
      extra = ""
      for (r in count) {
        split(r, rp, SUBSEP)
        if (rp[1] == f && count[r] > 0) extra = extra " " rp[2] "=" count[r]
      }
      printf "%s: total=%d%s\n", f, total[f], extra
    }
  }'
TOTAL="$(awk -F'\t' 'END { print NR }' "$HITS")"
echo "---- 命中合计: $TOTAL (豁免: 注释行 / NotchCenterKit / Tests / Vendor) ----"

# ---- 基线对比 / 更新 ----
OVER=0
if (( UPDATE_BASELINE == 1 )); then
  {
    echo '{'
    echo '  "comment": "UI token 扫描基线(存量快照,只降不升)。更新: scripts/scan-ui-tokens.sh --update-baseline",'
    echo '  "files": {'
    awk -F'\t' '{c[$1 "|" $3]++} END { for (k in c) print k " " c[k] }' "$HITS" | sort \
    |     awk '
      {
        split($1, p, "|")
        wrote[p[1], p[2]] = $2
        if (!(p[1] in seen)) { order[++idx] = p[1]; seen[p[1]] = 1 }
      }
      END {
        first = 1
        for (i = 1; i <= idx; i++) {
          f = order[i]
          if (first == 0) printf ",\n"
          first = 0
          printf "    \"%s\": { \"color-rgb\": %d, \"font-raw\": %d, \"spring-raw\": %d }", \
            f, wrote[f, "color-rgb"], wrote[f, "font-raw"], wrote[f, "spring-raw"]
        }
        if (first == 0) printf "\n"
      }'
    echo '  }'
    echo '}'
  } > "$BASELINE"
  rm -f "$BASELINE.tmp"
  echo "scan-ui-tokens: 基线已更新 → $BASELINE"
elif [[ -f "$BASELINE" ]]; then
  # 基线为脚本自生成固定格式,直接 sed 解析,不依赖 jq。
  BASELINE_TS="$(mktemp)"; CURRENT_TS="$(mktemp)"
  trap 'rm -f "$HITS" "$BASELINE_TS" "$CURRENT_TS"' EXIT
  sed -nE 's/^ *"([^"]+)": \{ "color-rgb": ([0-9]+), "font-raw": ([0-9]+), "spring-raw": ([0-9]+) *\},?$/\1|\2|\3|\4/p' "$BASELINE" > "$BASELINE_TS"
  # 当前计数也归一为 path|rgb|font|spring(缺失规则按 0)。
  awk -F'\t' '
    { c[$1 "|" $3]++ }
    END {
      for (k in c) {
        split(k, p, "|")
        cnt[p[1], p[2]] = c[k]
        if (!(p[1] in seen)) { order[++idx] = p[1]; seen[p[1]] = 1 }
      }
      for (i = 1; i <= idx; i++) {
        f = order[i]
        printf "%s|%d|%d|%d\n", f, cnt[f, "color-rgb"], cnt[f, "font-raw"], cnt[f, "spring-raw"]
      }
    }' "$HITS" > "$CURRENT_TS"
  OVER_LINES="$(awk -F'|' '
    FNR == NR { base[$1] = $2 SUBSEP $3 SUBSEP $4; next }
    {
      b = ($1 in base) ? base[$1] : 0 SUBSEP 0 SUBSEP 0
      split(b, bv, SUBSEP)
      if ($2 + 0 > bv[1] + 0) printf "超基线: %s [color-rgb] 当前 %d > 基线 %d (只降不升;迁移 NotchTokens 或收敛为本地命名常量并在 UI规范整改追踪 登记豁免)\n", $1, $2, bv[1]
      if ($3 + 0 > bv[2] + 0) printf "超基线: %s [font-raw] 当前 %d > 基线 %d (只降不升;迁移 NotchTokens 或收敛为本地命名常量并在 UI规范整改追踪 登记豁免)\n", $1, $3, bv[2]
      if ($4 + 0 > bv[3] + 0) printf "超基线: %s [spring-raw] 当前 %d > 基线 %d (只降不升;迁移 NotchTokens 或收敛为本地命名常量并在 UI规范整改追踪 登记豁免)\n", $1, $4, bv[3]
    }' "$BASELINE_TS" "$CURRENT_TS")"
  if [[ -n "$OVER_LINES" ]]; then
    printf '%s\n' "$OVER_LINES"
    OVER=1
  else
    echo "scan-ui-tokens: 存量未超基线($BASELINE)"
  fi
else
  echo "scan-ui-tokens: 无基线,跳过对比;可运行 --update-baseline 生成快照"
fi

if (( STRICT == 1 && OVER > 0 )); then exit 1; fi
exit 0
