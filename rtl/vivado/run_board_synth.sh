#!/bin/sh
# ===========================================================================
# run_board_synth.sh —— 板级 wrapper 的综合 → 实现 → bitstream
#
#   用法:
#     sh rtl/vivado/run_board_synth.sh
#     PE=4 sh rtl/vivado/run_board_synth.sh           # 出 pe4 那一档的 bitstream
#     PERIOD=15 sh rtl/vivado/run_board_synth.sh      # 临时收紧时钟，看时序余量
#
#   产物:
#     rtl/vivado/reports/board_pe<N>_util.rpt     资源占用
#     rtl/vivado/reports/board_pe<N>_timing.rpt   时序 + 关键路径
#     rtl/vivado/reports/board_pe<N>_io.rpt       引脚落位（上板前核对用）
#       ⚠️ **N 是折叠度，三份报告都带** —— 早先不带，于是「跑 pe4 就把 pe1 那三份
#          覆盖掉了」（2026-10-04 实际发生过：pe4 综合一启动就 rm 掉了已提交的 pe1 报告）。
#          三档的数字本来就不同（pe4 LUT 6203 vs pe1 5025），覆盖等于把对照关系删掉。
#     rtl/vivado/_runs/ntt_board.bit        bitstream（**不提交**，见 .gitignore）
#     <DCP>/ntt_board_pe<N>.dcp             布线后的 checkpoint（**只在给了 DCP 时出**，不提交）
#       ⚠️ 名字里**带折叠度**，与报告同一个理由：三档的关键路径在不同位置
#          （pe1/pe4 起点 `line_len_reg[2]`、pe16 是 `[3]`），同名会互相覆盖。
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
#     PE=<1|4|16>           折叠度，默认 1。传给 synth_design 的 -generic。
#                           板级 READ_LAT 由它派生（2*PE+3），不用另给。
#     PERIOD=<ns>           不给就用 XDC 里的 20 ns。给了则本次运行覆盖它。
#     VIVADO_RUNS=<目录>    中间产物放哪，默认 rtl/vivado/_runs/
#     TRIES=<次数>          综合失败重试次数，默认 5，理由见下
#     DCP=<目录>            给了才写布线后的 checkpoint：<目录>/ntt_board_pe<N>.dcp
#                           用途是「在 GUI 里打开设计、点开关键路径、截 Schematic」——
#                           非工程模式默认什么都不留，没有它就截不了图（03 §3.12 第 3 条）。
#                           不给就不写（上游对照那几轮不需要）。建议指到**仓库外**，如
#                           DCP=/c/vivado_work/dcp —— 打开它时 Vivado 要从仓库外启动。
#
#   ⚠️ bitstream 的**文件名不随档位变**（三档都叫 ntt_board.bit）——
#      每跑一次覆盖上一次。所以出完立刻会在同目录写一个一行的 `ntt_board.pe`
#      记着这一版是哪一档，`run_board_prog.sh` 烧录前会把它读出来报一下。
#      拿错档位上板的症状是「256 个值全错」，很像 RTL 挂了，值得这么防一手。
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
PE="${PE:-1}"
PERIOD="${PERIOD:-}"
TRIES="${TRIES:-5}"
DCP="${DCP:-}"

# 折叠度守卫放在**脚本**这一层，不只放在 Tcl 里 —— 给错值时宁可一行都不跑，
# 也别等 Vivado 起了 30 秒才在日志深处报错。
# ⚠️ 这三档**不是**「2 的幂的任意取值」：核的数据通路是「每档一份」而不是公式
#    （`KyberHPMNTT.v:90` 起，`TW_ADDR_W` 就是三路三目），所以 pe2/pe8 拿不到正确的
#    地址位宽。核与顶层各有一句 FATAL 守卫拦这件事。**别把这个 case 放宽成
#    「任意 2 的幂」** —— 那样 PE=8 会穿过这里，跑到综合深处才炸。
case "$PE" in
    1|4|16) ;;
    *) echo "  ❌ 折叠度非法：PE='$PE' —— 只支持 1 / 4 / 16" >&2; exit 1 ;;
esac
REPDIR="$HERE/reports"
# 报告一律带折叠度前缀：三档的数字不同，同名会互相覆盖（见文件头）。
# 与 `run_folding_sweep.sh` 的 pe<N>_*.rpt 是同一套思路。
REPNAME="board_pe$PE"
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

# 可选的 checkpoint 落点。必须在 vpath() 定义之后算 —— 要转成 C:/ 正斜杠形式。
# 名字带折叠度（理由见文件头）；DCP 为空则整段不写，一个字都不多占。
DCPFILE=""
if [ -n "$DCP" ]; then
    DCPFILE="$(vpath "$DCP")/ntt_board_pe$PE.dcp"
fi

echo "== 板级：综合 → 实现 → bitstream =="
echo "   器件   $PART"
echo "   顶层   ntt_board_top (PE_NUMBER=$PE)"
echo "   读出   READ_LAT = 2*$PE+3 = $((2 * PE + 3)) 拍（由折叠度派生）"
echo "   周期   ${PERIOD:-XDC 里的 20 ns}"
echo "   启动目录 $SCRATCH   （仓库路径含撇号，必须从仓库外启动）"
if [ -n "$DCPFILE" ]; then
    echo "   checkpoint $DCPFILE"
else
    echo "   checkpoint 不写（没给 DCP=）—— GUI 截图要用的话给一个"
fi

rm -f "$REPDIR/$REPNAME"_util.rpt "$REPDIR/$REPNAME"_timing.rpt "$REPDIR/$REPNAME"_io.rpt \
      "$RUNDIR/ntt_board.bit" "$RUNDIR/ntt_board.pe" \
      "$RUNDIR/board_synth.log" "$RUNDIR"/board_synth_try*.log

# 上一轮的 checkpoint 也清掉。判据里没有它，但留着会被误当成「这一轮跑出来的」——
# .dcp 名字不随时间变，GUI 打开看到的是**上一次**的布线，与报告数字对不上，
# 而那种错非常难看出来（图像本身完全正常）。
if [ -n "$DCPFILE" ]; then rm -f "$DCPFILE"; fi

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
                     "$(vpath "$REPDIR")" "$(vpath "$RUNDIR")" "$PERIOD" "$PE" "$DCPFILE" ) \
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
    # ⚠️ 档位戳 ntt_board.pe 也要一起清：它和 bit 是一对，留着一个旧的
    #    比没有更坏 —— 烧录脚本会拿着**上一次**的档位去报「这版是 pe4」。
    rm -f "$REPDIR/$REPNAME"_util.rpt "$REPDIR/$REPNAME"_timing.rpt "$REPDIR/$REPNAME"_io.rpt \
          "$RUNDIR/ntt_board.bit" "$RUNDIR/ntt_board.pe"
    if [ -n "$DCPFILE" ]; then rm -f "$DCPFILE"; fi

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
echo "  资源   $REPDIR/${REPNAME}_util.rpt"
echo "  时序   $REPDIR/${REPNAME}_timing.rpt"
echo "  引脚   $REPDIR/${REPNAME}_io.rpt"
if [ -s "$RUNDIR/ntt_board.bit" ]; then
    echo "  bit    $RUNDIR/ntt_board.bit"
    if [ -s "$RUNDIR/ntt_board.pe" ]; then
        echo "  档位   pe$(cat "$RUNDIR/ntt_board.pe")   （$RUNDIR/ntt_board.pe）"
    else
        echo "  档位   ⚠️ 没有档位戳 ntt_board.pe —— 烧录前先确认这版是哪一档"
    fi
    # checkpoint 不进判据（写失败不该让整轮 10 分钟重来），但要报出来 ——
    # 没给 DCP 时是「没要」，给了却没出来才是问题，两种情况不能都沉默。
    if [ -n "$DCPFILE" ]; then
        if [ -s "$DCPFILE" ]; then
            echo "  检查点 $DCPFILE"
        else
            echo "  检查点 ⚠️ 没写出来 —— 看日志里的 write_checkpoint（GUI 截图要用它）"
        fi
    fi
else
    echo "  bit    **没有产出** —— 布线没走完，先看日志里的 ERROR"
    exit 1
fi
