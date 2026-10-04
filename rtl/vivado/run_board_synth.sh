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
#     rtl/vivado/_runs/board_synth.log      成功那一轮的日志（不提交）
#     rtl/vivado/_runs/board_synth_tryN.log 第 N 轮的日志（不提交）
#       ⚠️ **每轮单独一个日志文件**，不是共用一个 —— 2026-10-04 第一版共用一个，
#          结果第 1 轮「综合成功、死在最后一行 report_io」的真错被第 3 轮
#          「综合一开始就崩」的日志整个盖掉，看着像综合本身有问题。
#          分开写，失败时三轮的错各自都在。
#
#   环境变量:
#     VIVADO=<路径>         默认 E:/xilinx/Vivado/2020.2/bin/vivado.bat
#     PART=<器件>           默认 xc7z020clg400-2（板上那颗 Zynq-7020）
#     PERIOD=<ns>           不给就用 XDC 里的 20 ns。给了则本次运行覆盖它。
#     VIVADO_RUNS=<目录>    中间产物放哪，默认 rtl/vivado/_runs/
#     TRIES=<次数>          综合失败重试次数，默认 5，理由见下
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
#
#   ⚠️ 这不是「偶发一次」——`C:\fpga_work\sweep_utop.log` 记着 09/22 那次扫描
#      在**同一处**（`scripts/rt/fpga_tcl/rtSynthParallelPrep.tcl`）栽过，
#      另外还在 `.Xil/…/realtime/*.tcl` 和 `scripts/rt/data/unimacro/unimacro_vhdl.tcl`
#      上各栽过一次。三种都靠重试过去了。所以默认给 5 次。
#
#   ⚠️ 判据是「跑到最后一行 `RESULT board DONE` **且** bit 落了盘」，不是
#      「某个报告文件存在」—— 报告是在流程中段写的，`opt_design` 之前就已落盘，
#      拿它当判据会把「中段之后就死了」判成成功。
#   重试前把上一轮的产物**全部清掉**（报告、bit、`.Xil/`）—— 否则上一轮的
#   残留会让判据在本次失败时为真，把失败当成功。
# ===========================================================================

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$(cd "$HERE/../.." && pwd)"        # 仓库根

VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"
PART="${PART:-xc7z020clg400-2}"
PERIOD="${PERIOD:-}"
TRIES="${TRIES:-5}"
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
      "$RUNDIR/ntt_board.bit" "$RUNDIR/board_synth.log" "$RUNDIR"/board_synth_try*.log

attempt=1
ok=0
while [ "$attempt" -le "$TRIES" ]; do
    TRYLOG="$RUNDIR/board_synth_try$attempt.log"

    # .Xil/ 是 Vivado 的进程内暂存，**每轮都要从干净的开始**。
    # 两轮之间没有 Vivado 在跑，删掉是安全的。
    # ⚠️ 它会无限累积：2026-10-04 看的时候里面有 ~15 个历次运行留下的
    #    Vivado-<pid>-<user>/，从 09/22 一直堆到当天。其中带 realtime/ 子目录的
    #    那两个，正是 09/22 那次扫描抖动的落点
    #    （`…\.Xil\Vivado-50368-lanxiteacher\realtime\KyberHPM1PE_top.tcl`）。
    #    清干净比留着强。
    rm -rf "$SCRATCH/.Xil"

    if ( cd "$SCRATCH" && exec "$VIVADO" -mode batch -notrace -nolog -nojournal \
            -source "$(vpath "$HERE/synth_board.tcl")" \
            -tclargs "$PART" "$(vpath "$SRCDIR")" "$(vpath "$BRDDIR")" \
                     "$(vpath "$REPDIR")" "$(vpath "$RUNDIR")" "$PERIOD" ) \
            > "$TRYLOG" 2>&1 \
       && grep -q "^RESULT board DONE" "$TRYLOG" \
       && [ -s "$RUNDIR/ntt_board.bit" ]
    then
        ok=1
        cp "$TRYLOG" "$RUNDIR/board_synth.log"
        break
    fi

    why="$(grep -m1 -E "couldn't read file|Too many positional|invalid command name|^ERROR" "$TRYLOG" || echo '见日志')"
    echo "  … 第 $attempt 次失败（$why）"
    if [ "$attempt" -lt "$TRIES" ]; then
        echo "    重试 $((attempt + 1))/$TRIES …"
    fi

    # 清掉上一轮的**全部**产物，不只是报告 —— 判据里有 bit 和 DONE 行，
    # 残留会让下一次的判据在本次失败时为真。（.Xil/ 在循环开头清。）
    rm -f "$REPDIR/board_util.rpt" "$REPDIR/board_timing.rpt" "$REPDIR/board_io.rpt" \
          "$RUNDIR/ntt_board.bit"

    attempt=$((attempt + 1))
    if [ "$attempt" -le "$TRIES" ]; then
        sleep 3
    fi
done

if [ "$ok" -ne 1 ]; then
    echo "  ❌ 连续 $TRIES 次失败。各轮的首个错因："
    for i in 1 2 3 4 5 6 7 8; do
        f="$RUNDIR/board_synth_try$i.log"
        if [ ! -f "$f" ]; then continue; fi
        printf '     第 %s 轮  %s\n' "$i" \
            "$(grep -m1 -E "couldn't read file|Too many positional|^ERROR" "$f" || echo '（无 ERROR 行）')"
        echo "             日志 $f"
    done
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
