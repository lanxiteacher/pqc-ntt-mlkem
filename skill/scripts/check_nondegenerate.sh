#!/bin/sh
# ===========================================================================
# check_nondegenerate.sh —— 「验证通过」必须配「非退化」才作数
#
# 为什么需要这个脚本：
#   「256/256 全中」「4096/4096 全对」这种话，在**向量本身没有区分度**的时候
#   是没有意义的 —— 一个把输入原样输出的设计，在全零向量上也能全中。
#   所以每次报「通过」之前，先统计输入里有多少个不同的值。
#
# 判据（本项目基准，可改）：
#   · 不同值 / 总行数 ≥ 30%      （本项目的实际值：4096 行里 2355~2374 个，约 58%）
#   · 最常见值的占比 ≤ 2%        （本项目实际 < 0.25%）
#   低于阈值不等于数据有问题，但**「全中」就不能再当成证据**。
#
# 用法：
#   sh check_nondegenerate.sh <文件或目录> [...]
#   sh check_nondegenerate.sh -r 50 -p 1.0 <文件...>     # 自定义阈值
#     -r <百分比>  要求 不同值/总行数 ≥ 该值（默认 30）
#     -p <百分比>  要求 最常见值占比 ≤ 该值（默认 2）
#
# 退出码：0 = 全部达标；1 = 有未达标；2 = 用法错
#
# 依赖：POSIX sh + awk（Linux / macOS / Git Bash 自带）
#
# ⚠️ 本脚本按**行**统计，假定每行一个数值（本项目的数据约定）。
#    若数据文件不是「一行一值」，先转成那个形状再跑。
# ===========================================================================

set -u

RATIO_MIN=30
TOP_MAX=2

while [ $# -gt 0 ]; do
    case "$1" in
        -r) RATIO_MIN="$2"; shift 2 ;;
        -p) TOP_MAX="$2";   shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "用法: sh check_nondegenerate.sh [-r 最少不同值占比%] [-p 最大最常见占比%] <文件或目录> [...]" >&2
    exit 2
fi

LIST=$(mktemp)
for arg in "$@"; do
    if [ -d "$arg" ]; then
        find "$arg" \( -name '*.txt' -o -name '*.hex' \) -type f >> "$LIST"
    elif [ -f "$arg" ]; then
        printf '%s\n' "$arg" >> "$LIST"
    else
        echo "跳过（不存在）: $arg" >&2
    fi
done
sort -o "$LIST" "$LIST"

if [ ! -s "$LIST" ]; then
    rm -f "$LIST"
    echo "没有找到要检查的数据文件。" >&2
    exit 2
fi

printf '判据：不同值占比 ≥ %s%%，最常见值占比 ≤ %s%%\n' "$RATIO_MIN" "$TOP_MAX"
printf '%-46s %7s %8s %8s %10s\n' "文件" "行数" "不同值" "占比" "最常见占比"
printf '%s\n' "------------------------------------------------------------------------------"

n_files=0
n_fail=0

# `done < "$LIST"` 而不是管道 —— 否则循环在子 shell 里，计数器读不到
while IFS= read -r f; do
    [ -n "$f" ] || continue

    # 机读输出：<总行数> <不同值个数> <最常见值的出现次数> <最常见值>
    res=$(awk '
        { sub(/\r$/, ""); c[$0]++ ; total++ }
        END {
            if (total == 0) { print "0 0 0 -"; exit }
            top = 0; topv = "-"
            for (k in c) if (c[k] > top) { top = c[k]; topv = k }
            printf "%d %d %d %s\n", total, length(c), top, topv
        }
    ' "$f")

    total=$(printf '%s' "$res" | cut -d' ' -f1)
    dist=$(printf '%s'  "$res" | cut -d' ' -f2)
    topn=$(printf '%s'  "$res" | cut -d' ' -f3)
    topv=$(printf '%s'  "$res" | cut -d' ' -f4)

    if [ "$total" -eq 0 ]; then
        printf '%-46s %7s %8s %8s %10s\n' "$f" "空" "-" "-" "-"
        n_fail=$((n_fail + 1))
        n_files=$((n_files + 1))
        continue
    fi

    ratio=$(awk -v d="$dist" -v t="$total" 'BEGIN { printf "%.1f", 100 * d / t }')
    toppct=$(awk -v n="$topn" -v t="$total" 'BEGIN { printf "%.2f", 100 * n / t }')

    verdict=ok
    awk -v r="$ratio" -v m="$RATIO_MIN" 'BEGIN { exit !(r >= m) }' || verdict=low_distinct
    awk -v p="$toppct" -v m="$TOP_MAX" 'BEGIN { exit !(p <= m) }' || verdict=too_concentrated

    mark="✅"
    [ "$verdict" != ok ] && mark="❌ $verdict"

    printf '%-46s %7d %8d %7s%% %9s%%  %s\n' "$f" "$total" "$dist" "$ratio" "$toppct" "$mark"
    [ "$verdict" != ok ] && n_fail=$((n_fail + 1))
    n_files=$((n_files + 1))
done < "$LIST"

rm -f "$LIST"

printf '%s\n' "------------------------------------------------------------------------------"
if [ "$n_fail" -eq 0 ]; then
    printf '✅ %d 个文件全部达标 —— 这种熵下「全中」不可能是巧合。\n' "$n_files"
    exit 0
fi
printf '❌ %d / %d 个文件未达标。\n' "$n_fail" "$n_files"
printf '   未达标不等于数据坏了，但**不能拿它的「全中」当证据**。\n'
exit 1
