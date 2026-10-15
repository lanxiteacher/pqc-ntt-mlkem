#!/bin/sh
# ===========================================================================
# run_board_txn_report.sh —— 在真板子上跑「探活 + 五条计算事务」，落一份报告。
#
#   sh rtl/vivado/run_board_txn_report.sh              # pe1（H6 默认这一档）
#   PE=4 sh rtl/vivado/run_board_txn_report.sh         # 换折叠度（1 / 4 / 16）
#   PORT=COM10 sh rtl/vivado/run_board_txn_report.sh   # 不给就按设备名现找
#   FORCE=1 sh rtl/vivado/run_board_txn_report.sh      # 允许覆盖同名报告
#
# 产出：rtl/vivado/reports/board_pe<PE>_txn.txt
#
# 为什么要有它（2026-10-15 加）
#   10-04 那两份 `board_pe4/pe16_txn.txt` 是用一个**没进仓库**的本地脚本跑的 ——
#   全历史里搜不到产出它的脚本（`git log --all -S'装载 natural'` 只命中报告本身），
#   而 `host/src/board_run.py` 也没有任何写报告的选项。于是 H6 的验收证据
#   **用仓库里的东西复现不出来**，这对「可复现性」那一项是实打实的失分。本脚本补上这段。
#
# ⚠️ 它**只搬运，不判读**：解包口径、逐位比较、非退化，判据全在
#    `host/src/board_run.py --check` 里，本脚本一条都不重写。报告里的 ✅/❌
#    也直接由它的退出码决定，不在这里另判。
#
# ⚠️ 不覆盖既有报告：写之前若同名文件已存在，直接退出。10-04 那两份是**无失败史**的
#    参照，别让一次手滑把它冲掉。确实要重跑覆盖，加 FORCE=1。
#
# ⚠️ 行尾必须是 **LF**（与 10-04 那两份一致）。Python 在 Windows 上会把 `\n` 写成
#    `\r\n`，所以每条命令的输出都过一道 `tr -d '\r'`。判据一律用 python 读 `"rb"`，
#    别用 grep —— MSYS 下的 grep 数 CR 恒为 0（见 CLAUDE.md「约定」第 1 条）。
#
# ⚠️ 跑之前：位流要已烧、底板 P5 跳线在 PL 档、启动拨码在 JTAG 档。
#    烧位流用 `rtl/vivado/run_board_prog.sh`（那个脚本的 `BIT=` 要传**绝对路径**）。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# ⚠️ 必须 **cd 过去再用相对路径**调 python。Windows 版 Python 不认 MSYS 形式的路
#    （`/c/Users/...` 会被它拼成 `C:\c\Users\...` 然后说找不到文件）。
#    `board_run.py` 自己按 `__file__` 定位仓库内的路径，所以工作目录在哪都不影响它。
#    （别用 `cygpath` 绕 —— 那要多一个「cygpath 在不在」的假设。）
cd "$ROOT"

export PYTHONIOENCODING=utf-8

PE="${PE:-1}"
case "$PE" in
    1|4|16) ;;
    *) echo "  ❌ 折叠度非法：PE='$PE' —— 只支持 1 / 4 / 16" >&2; exit 1 ;;
esac

REPORT="$HERE/reports/board_pe${PE}_txn.txt"
if [ -e "$REPORT" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  ⚠️ 报告已存在，不覆盖："
    echo "     $REPORT"
    echo "     要重跑一遍覆盖它，加 FORCE=1（旧的那份先自己留个底）。"
    exit 1
fi

PORTARG=""
if [ -n "${PORT:-}" ]; then PORTARG="--port $PORT"; fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# 命令清单。`|` 后面是给人看的标签，只进报告正文，不参与任何判定。
cat > "$TMP/list.txt" <<'EOF'
#PING|探活 · 不带数据，只等一条回帧
#NTT 1|正向 NTT
#INTT 1|逆向 INTT
#PMUL NTT 1|点乘 · A/B 都在 NTT 域
#PMUL TIME 1|点乘 · A 时域、B 在 NTT 域
#PMUL FULL 1|点乘 · A/B 都在时域
EOF

{
    echo "=== 真板子：探活 + 五条计算事务 ==="
    echo "   折叠度：pe$PE（board_run.py 的 --build 显式给）"
    echo "   生成方式：sh rtl/vivado/run_board_txn_report.sh    （PE=$PE）"
    echo "   命令入口：host/src/board_run.py —— 判据全在它的 --check 里，本脚本只搬运"
    echo ""
} > "$TMP/body.txt"
: > "$TMP/summary.txt"

i=0
n_pass=0
while IFS='|' read -r cmd label; do
    [ -n "$cmd" ] || continue
    i=$((i + 1))

    # ⚠️ 先落原始输出再取码：写成 `python … | tr` 的话，`$?` 拿到的是 `tr` 的码。
    rc=0
    if [ "$cmd" = "#PING" ]; then
        python host/src/board_run.py "$cmd" $PORTARG > "$TMP/raw$i.txt" 2>&1 || rc=$?
    else
        python host/src/board_run.py "$cmd" --check --build "$PE" $PORTARG \
            > "$TMP/raw$i.txt" 2>&1 || rc=$?
    fi
    tr -d '\r' < "$TMP/raw$i.txt" > "$TMP/o$i.txt"

    if [ "$rc" -eq 0 ]; then
        verdict="✅ PASS"
        n_pass=$((n_pass + 1))
    else
        verdict="❌ FAIL（rc=$rc）"
    fi

    {
        echo "--- $cmd（$label）---"
        sed 's/^/    /' "$TMP/o$i.txt"
        echo "    → $verdict"
        echo ""
    } >> "$TMP/body.txt"
    printf '   %-18s %s\n' "$cmd" "$verdict" >> "$TMP/summary.txt"

    printf '  %-12s %s\n' "$cmd" "$verdict"
done < "$TMP/list.txt"

{
    cat "$TMP/body.txt"
    echo "========================================================"
    echo "汇总"
    echo "========================================================"
    cat "$TMP/summary.txt"
    echo "   $n_pass / $i 条全中"
} > "$TMP/report.txt"

mkdir -p "$HERE/reports"
cp "$TMP/report.txt" "$REPORT"

echo ""
echo "  报告已落：$REPORT"
echo "  （$n_pass / $i 条 PASS；行尾 LF。）"
echo "  报告正文是各条命令的**完整原始输出**（比 10-04 那两份长，因为那两份用的是"
echo "  已经不在仓库里的脚本、只留了摘要）。长一点没关系，别为了对齐行数把证据删掉。"

[ "$n_pass" -eq "$i" ]
