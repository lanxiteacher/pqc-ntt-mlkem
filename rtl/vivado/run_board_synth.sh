#!/bin/sh
# ===========================================================================
# run_board_synth.sh —— 板级 wrapper 的综合 → 实现 → bitstream
#
#   用法:
#     sh rtl/vivado/run_board_synth.sh
#     PERIOD=15 sh rtl/vivado/run_board_synth.sh      # 临时收紧时钟，看时序余量
#
#   产物:
#     rtl/vivado/reports/board_util.rpt     资源占用
#     rtl/vivado/reports/board_timing.rpt   时序 + 关键路径
#     rtl/vivado/reports/board_io.rpt       引脚落位（上板前核对用）
#     rtl/vivado/_runs/ntt_board.bit        bitstream（**不提交**，见 .gitignore）
#     rtl/vivado/_runs/board_synth.log      完整日志（不提交）
#
#   环境变量:
#     VIVADO=<路径>         默认 E:/xilinx/Vivado/2020.2/bin/vivado.bat
#     PART=<器件>           默认 xc7z020clg400-2（板上那颗 Zynq-7020）
#     PERIOD=<ns>           不给就用 XDC 里的 20 ns。给了则本次运行覆盖它。
#     VIVADO_RUNS=<目录>    中间产物放哪，默认 rtl/vivado/_runs/
#     TRIES=<次数>          综合失败重试次数，默认 3，理由见下
#
#   ── 为什么一定要从仓库外启动 Vivado ────────────────────────────────
#   Vivado 把 .Xil/<...>/realtime/tmp/ 交给综合引擎 ABC 当工作目录，路径是经
#   shell 传的。本机仓库路径里有撇号（C:\Users\l'x\...），撇号被 shell 当成
#   引号开头，路径被截断（日志里 l'x 变成 lx，并打 "ignoring unbalanced
#   quote"）。所以本脚本一律从 $SCRATCH 启动，源码与报告仍用仓库内的绝对路径
#   传进去 —— 只是**进程的工作目录**必须在仓库外。
#   （同一处理见 rtl/vivado/run_folding_sweep.sh，那边的注释更详细。）
#
#   ── 为什么带重试 ──────────────────────────────────────────────
#   本机 Vivado 2020.2 的综合 helper 子进程会间歇性报 "couldn't read file
#   ...: No error"（读的是它自己安装目录里确实存在的文件），同一份 RTL 重跑
#   就可能过。实测主进程的文件读写 1180/1180 全对，是工具层抖动而非路径问题。
#   重试前**先删掉本轮要重写的报告** —— 否则上一轮的旧报告会让「报告存在」
#   这个判据在本次失败时依然为真，把失败当成功。
# ===========================================================================

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$(cd "$HERE/../.." && pwd)"        # 仓库根

VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"
PART="${PART:-xc7z020clg400-2}"
PERIOD="${PERIOD:-}"
TRIES="${TRIES:-3}"
REPDIR="$HERE/reports"
RUNDIR="${VIVADO_RUNS:-$HERE/_runs}"
SRCDIR="$RTLDIR/rtl/ntt_core"
BRDDIR="$RTLDIR/rtl/board"

if [ ! -x "$VIVADO" ] && [ ! -f "$VIVADO" ]; then
    echo "  ❌ 找不到 Vivado: $VIVADO" >&2
    echo "     用 VIVADO=<路径> 指定，正常路径是 E:\\xilinx\\Vivado\\2020.2\\bin\\vivado.bat" >&2
    exit 1
fi

for d in "$SRCDIR" "$BRDDIR"; do
    [ -d "$d" ] || { echo "  ❌ 缺目录: $d" >&2; exit 1; }
done

# 从仓库所在盘符的根取一个短路径做工作目录（理由见文件头）
SCRATCH="${VIVADO_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then
    SCRATCH="$(printf '%s' "$HERE" | sed 's|^/\([a-zA-Z]\)/.*|/\1|')/vivado_scratch"
fi

mkdir -p "$REPDIR" "$RUNDIR" "$SCRATCH"

# 传给 Vivado 的路径要 Windows 正斜杠形式（C:/...）；Git Bash 的 /c/... 它不认。
# 用 -m 而不是 -w —— 反斜杠形式在带撇号的路径下更容易被 shell 咬。
vpath() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

echo "== 板级：综合 → 实现 → bitstream =="
echo "   器件   $PART"
echo "   顶层   ntt_board_top (PE_NUMBER=1)"
echo "   周期   ${PERIOD:-XDC 里的 20 ns}"
echo "   启动目录 $SCRATCH   （仓库路径含撇号，必须从仓库外启动）"

rm -f "$REPDIR/board_util.rpt" "$REPDIR/board_timing.rpt" "$REPDIR/board_io.rpt" \
      "$RUNDIR/ntt_board.bit"

attempt=1
ok=0
while [ "$attempt" -le "$TRIES" ]; do
    if ( cd "$SCRATCH" && exec "$VIVADO" -mode batch -notrace -nolog -nojournal \
            -source "$(vpath "$HERE/synth_board.tcl")" \
            -tclargs "$PART" "$(vpath "$SRCDIR")" "$(vpath "$BRDDIR")" \
                     "$(vpath "$REPDIR")" "$(vpath "$RUNDIR")" "$PERIOD" ) \
            > "$RUNDIR/board_synth.log" 2>&1 \
       && [ -s "$REPDIR/board_util.rpt" ]
    then
        ok=1
        break
    fi
    if [ "$attempt" -lt "$TRIES" ]; then
        why="$(grep -m1 -E "couldn't read file|invalid command name|ERROR" "$RUNDIR/board_synth.log" || echo '见日志')"
        echo "  … 第 $attempt 次失败，重试中（$why）"
        rm -f "$REPDIR/board_util.rpt" "$REPDIR/board_timing.rpt" "$REPDIR/board_io.rpt"
        sleep 3
    fi
    attempt=$((attempt + 1))
done

if [ "$ok" -ne 1 ]; then
    echo "  ❌ 连续 $TRIES 次失败 —— 完整日志 $RUNDIR/board_synth.log"
    grep -E "^ERROR|couldn't read file" "$RUNDIR/board_synth.log" | head -5 || true
    exit 1
fi

echo ""
echo "─── 结果 ───"
grep -E "^RESULT board|^  !!|^  NOTE" "$RUNDIR/board_synth.log" || true
echo ""
echo "  资源   $REPDIR/board_util.rpt"
echo "  时序   $REPDIR/board_timing.rpt"
echo "  引脚   $REPDIR/board_io.rpt"
if [ -s "$RUNDIR/ntt_board.bit" ]; then
    echo "  bit    $RUNDIR/ntt_board.bit"
else
    echo "  bit    **没有产出** —— 布线没走完，先看日志里的 ERROR"
    exit 1
fi
