#!/bin/sh
# ===========================================================================
# check_data_format.sh —— 校验数据文件的格式约定
#
# 约定：每行**恰好 3 位小写十六进制**（0-9a-f），行尾 LF，文件以 LF 结尾。
#
# 为什么需要这个脚本：
#   本项目的格式坑全部表现为「数值全对、比对全错」，肉眼几乎看不出来 ——
#     · 十六进制没补零（`27` vs `027`）→ 按字符串逐行比就假失败
#     · 行尾 CRLF → `diff` 报「256 行全不同」，其实每个数都一样
#   脚本一秒能把它们列出来；人对着一屏数字看十分钟也看不出来。
#
# 用法：
#   sh check_data_format.sh <文件或目录> [...]
#   目录会递归扫 *.txt / *.hex / *.csv
#
# 退出码：0 = 全部合规；1 = 有不合规；2 = 用法错
#
# 依赖：POSIX sh + awk（Linux / macOS / Git Bash 自带，不需要额外安装）
#
# ⚠️ 本脚本只做**格式判定**，不改任何文件。发现不合规时先分清
#    「只是没补零」还是「值真的不同」—— 处理方式完全不同；
#    而且若那是**已冻结**的数据文件，改一个字节都要相关的人知情。
# ===========================================================================

set -u

if [ $# -eq 0 ]; then
    echo "用法: sh check_data_format.sh <文件或目录> [...]" >&2
    exit 2
fi

# ---- 收集待查文件 ---------------------------------------------------------
LIST=$(mktemp)
for arg in "$@"; do
    if [ -d "$arg" ]; then
        find "$arg" \( -name '*.txt' -o -name '*.hex' -o -name '*.csv' \) -type f >> "$LIST"
    elif [ -f "$arg" ]; then
        printf '%s\n' "$arg" >> "$LIST"
    else
        echo "跳过（不存在）: $arg" >&2
    fi
done
sort -o "$LIST" "$LIST"

if [ ! -s "$LIST" ]; then
    echo "没有找到要检查的数据文件。" >&2
    rm -f "$LIST"
    exit 2
fi

# ---- 逐文件判定 -----------------------------------------------------------
# 注意：用 `done < "$LIST"` 而不是 `cat "$LIST" | while ...` ——
# 后者会把循环放进子 shell，计数变量在外面读不到（这个坑很常见）。
n_files=0
n_bad=0
n_total_lines=0
n_bad_lines=0
n_crlf_files=0
n_no_final_nl=0

printf '%-46s %8s %8s  %s\n' "文件" "行数" "不合规" "备注"
printf '%s\n' "----------------------------------------------------------------------------"

while IFS= read -r f; do
    [ -n "$f" ] || continue

    # awk 逐行查内容，输出一行机读汇总：<总行数> <不合规行数>
    # ⚠️ 明细必须写 /dev/stderr：stdout 被 $(...) 收走了，
    #    写 stdout 的话「哪一行、什么原因」会被吞掉，只剩一个数字。
    # 里面的 sub(/\r$/) 是给 Linux 用的（Linux 的 awk 不会替你剥 CR）；
    # Windows 上的 gawk **读文件时会自动把 CRLF 折成 LF**，所以它在那儿是空操作
    # —— 也正因为如此，**不能用 awk 数 CRLF**，见下面 cr 那一行。
    res=$(awk '
        {
            sub(/\r$/, "")
            total++
            if ($0 ~ /^[0-9a-f][0-9a-f][0-9a-f]$/) next
            bad++
            if (bad <= 5) {
                if      ($0 ~ /^[[:space:]]*$/)                   why = "空行"
                else if ($0 ~ /^[0-9A-F][0-9A-F][0-9A-F]$/)       why = "大写十六进制（约定是小写）"
                else if ($0 ~ /^[0-9a-fA-F]+$/ && length($0) < 3) why = "位数不足（未补零）"
                else if ($0 ~ /^[0-9a-fA-F]+$/ && length($0) > 3) why = "位数过多"
                else if ($0 ~ /[^0-9a-fA-F]/)                     why = "含非十六进制字符"
                else                                              why = "未知"
                printf "    %s:%d：「%s」 %s\n", FILENAME, FNR, $0, why > "/dev/stderr"
            }
        }
        END { printf "%d %d\n", total + 0, bad + 0 }
    ' "$f")

    total=$(printf '%s' "$res" | cut -d' ' -f1)
    bad=$(printf '%s'   "$res" | cut -d' ' -f2)

    # CR 的个数按**字节**数，不按行数 —— 保留全部 CR 字节后数长度。
    # 这样 Windows 的 awk 折行与否都不影响结果。
    cr=$(tr -dc '\r' < "$f" | wc -c | tr -d ' ')

    # 末行是否缺换行：wc 只数 \n，awk 数「行」，两者不等就说明末行没收尾
    n_wc=$(wc -l < "$f" | tr -d ' ')
    no_nl=0
    if [ "$total" -gt 0 ] && [ "$n_wc" -lt "$total" ]; then
        no_nl=1
        echo "    $f：末行没有以换行符结尾（很多工具会漏读最后一行）"
    fi

    note=""
    # 只有「内容、行尾、末行收尾」三项都干净才打 ✅
    [ "$bad" -eq 0 ] && [ "$no_nl" -eq 0 ] && [ "$cr" -eq 0 ] && note="✅"
    if [ "$cr" -gt 0 ]; then
        note="$note ⚠️ 有 $cr 行是 CRLF 行尾"
        n_crlf_files=$((n_crlf_files + 1))
    fi
    [ "$no_nl" -eq 1 ] && n_no_final_nl=$((n_no_final_nl + 1))

    printf '%-46s %8d %8d  %s\n' "$f" "$total" "$bad" "$note"

    n_files=$((n_files + 1))
    n_total_lines=$((n_total_lines + total))
    n_bad_lines=$((n_bad_lines + bad))
    [ "$bad" -gt 0 ] && n_bad=$((n_bad + 1))
done < "$LIST"

rm -f "$LIST"

# ---- 汇总 ----------------------------------------------------------------
printf '%s\n' "----------------------------------------------------------------------------"
printf '共 %d 个文件 / %d 行；不合规文件 %d 个 / 不合规行 %d 行\n' \
    "$n_files" "$n_total_lines" "$n_bad" "$n_bad_lines"
[ "$n_crlf_files" -gt 0 ] && printf '⚠️ %d 个文件含 CRLF 行尾（约定是纯 LF）\n' "$n_crlf_files"
[ "$n_no_final_nl" -gt 0 ] && printf '⚠️ %d 个文件末行缺换行\n' "$n_no_final_nl"

if [ "$n_bad" -eq 0 ] && [ "$n_crlf_files" -eq 0 ] && [ "$n_no_final_nl" -eq 0 ]; then
    printf '✅ 全部合规（每行恰好 3 位小写十六进制 + LF）\n'
    exit 0
fi
printf '❌ 有不合规项，见上。\n'
exit 1
