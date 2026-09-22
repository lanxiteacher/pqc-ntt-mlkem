#!/bin/sh
# run_folding_sweep.sh —— 三档折叠度各跑一次 Vivado 综合实现，出资源 / 频率报告
#
#   用法:
#     sh run_folding_sweep.sh              # 三档全跑（pe1 / pe4 / pe16）
#     sh run_folding_sweep.sh pe4          # 只跑一档，改一行不用重跑三个
#
#   产物:
#     rtl/vivado/reports/<档>_util.rpt     ← 资源占用（要提交，H4 要交给 C）
#     rtl/vivado/reports/<档>_timing.rpt   ← 时序 + 关键路径（同上）
#     rtl/vivado/_runs/<档>.log            ← 完整日志（不提交，见 .gitignore）
#
#   环境变量:
#     VIVADO_RUNS=<目录>   工程中间产物放哪。默认 rtl/vivado/_runs/
#                          （C 盘紧张时可以指到别的盘）
#     PART=<器件>          默认 xc7z020clg400-2，也就是板上那颗 Zynq-7020
#     PERIOD=<ns>          默认 5（200MHz）
#     TAG=<后缀>           报告文件名加后缀，交叉核对跑用，见下
#
#   ── 关于「周期给 5ns」────────────────────────────────────────────
#   5ns 比这块设计能达到的更快（论文同量级设计在 Artix-7 上是 127–192MHz），
#   所以它一定不收敛。这是故意的：从 WNS 反推真实最高频率 ——
#       最小时钟周期 T_min ≈ 目标周期 - WNS      Fmax = 1000 / T_min  (MHz)
#   若 WNS 为正，说明 5ns 太松，把 PERIOD 收紧再跑一次。
#
#   ── 交叉核对（可选）──────────────────────────────────────────────
#   论文用的是 Artix-7 xc7a200tffg1156-3，本机装了。想验证「我们的流程能复现
#   论文数字」，对 pe1 再跑一轮：
#       PART=xc7a200tffg1156-3 TAG=_a7 sh run_folding_sweep.sh pe1
#
#   三档的器件必须一致，否则资源数字不可比 —— 所以 PART 只做整体覆盖，不按档调。

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$(cd "$HERE/.." && pwd)"

VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"
PART="${PART:-xc7z020clg400-2}"
PERIOD="${PERIOD:-5}"
TAG="${TAG:-}"
TRIES="${TRIES:-3}"
REPDIR="$HERE/reports"
RUNDIR="${VIVADO_RUNS:-$HERE/_runs}"

# ── 为什么必须有一个「仓库之外」的启动目录 ──────────────────────────
# Vivado 把 .Xil/<...>/realtime/tmp/ 交给综合引擎 ABC 当工作目录，路径是经 shell
# 传的。本机仓库路径里有撇号（C:\Users\l'x\...），撇号被 shell 当成引号开头，
# 于是 ABC 拿到一个被拼坏的路径：
#     .../realtime/tmp/C:/Users/lx/Desktop/.../realtime/tmp\genlib.B104.0
# 注意 l'x 变成了 lx（撇号被吃掉），上一行还打了 "ignoring unbalanced quote"。
# 结果: ABC: Error - cannot open file ... → Vivado Synthesis failed。
# 已验证：同一份 RTL、同一个脚本，只要从仓库外的干净路径启动就正常跑完。
# 所以 Vivado 一律从 $SCRATCH 启动；源码与报告仍用仓库内的绝对路径传进去。
SCRATCH="${VIVADO_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then
    # 取仓库所在盘符的根：/c/Users/l'x/Desktop/FPGA/rtl/vivado → /c/vivado_scratch
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

top_of() {
    case "$1" in
        pe1)  printf 'KyberHPM1PE\n'  ;;
        pe4)  printf 'KyberHPM4PE\n'  ;;
        pe16) printf 'KyberHPM16PE\n' ;;
        *)    printf '\n'             ;;
    esac
}

bflies_of() {
    case "$1" in
        pe1)  printf '1\n'  ;;
        pe4)  printf '4\n'  ;;
        pe16) printf '16\n' ;;
        *)    printf '?\n'  ;;
    esac
}

# 注意用 $* 而不是 $1 —— 用 $1 的话 `sh run_folding_sweep.sh pe1 pe16` 只会跑 pe1
if [ $# -gt 0 ]; then
    TARGETS="$*"
else
    TARGETS="pe1 pe4 pe16"
fi

echo "═══════════════════════════════════════════════════════════"
echo "  折叠度扫描：器件 $PART   目标周期 ${PERIOD}ns   运行目录 $RUNDIR"
echo "═══════════════════════════════════════════════════════════"

for d in $TARGETS; do
    top="$(top_of "$d")"
    if [ -z "$top" ]; then
        echo "  ❌ 不认识的档位「$d」，只支持 pe1 / pe4 / pe16"
        exit 1
    fi
    label="$d$TAG"
    srcdir="$RTLDIR/$d"
    if [ ! -d "$srcdir" ]; then
        echo "  ❌ 源码目录不存在：$srcdir"
        exit 1
    fi

    echo ""
    echo "─── $label  |  $top  |  $(bflies_of "$d") 个蝶形单元 ───"

    # 重试：本机 Vivado 2020.2 的综合 helper 子进程会间歇性报
    # "couldn't read file ...: No error"（读的是它自己安装目录里确实存在的文件），
    # 同一份 RTL 重跑就可能过。实测主进程的文件读写 1180/1180 全对，
    # 所以是工具层抖动而非路径/权限问题，重试是正当应对。
    # 先清掉本轮要重写的报告 —— 否则上一轮的旧报告会让「报告存在」这个判据
    # 在本次失败时依然为真，把失败当成功
    rm -f "$REPDIR/${label}_util.rpt" "$REPDIR/${label}_timing.rpt"

    attempt=1
    ok=0
    while [ "$attempt" -le "$TRIES" ]; do
        # 从 $SCRATCH 启动（见上文撇号说明），不是从仓库目录。
        # -nolog -nojournal：不往当前目录丢 vivado.log / vivado.jou，输出全在我们的日志里
        if ( cd "$SCRATCH" && exec "$VIVADO" -mode batch -notrace -nolog -nojournal \
                -source "$(vpath "$HERE/synth_one.tcl")" \
                -tclargs "$label" "$top" "$PART" "$PERIOD" \
                         "$(vpath "$srcdir")" "$(vpath "$REPDIR")" ) \
                > "$RUNDIR/$label.log" 2>&1 \
           && [ -s "$REPDIR/${label}_util.rpt" ]
        then
            ok=1
            break
        fi
        if [ "$attempt" -lt "$TRIES" ]; then
            why="$(grep -m1 -E "couldn't read file|invalid command name" "$RUNDIR/$label.log" || echo '见日志')"
            echo "  … 第 $attempt 次失败，重试中（$why）"
            sleep 3
        fi
        attempt=$((attempt + 1))
    done
    if [ "$ok" -ne 1 ]; then
        echo "  ❌ $label 连续 $TRIES 次失败 —— 完整日志 $RUNDIR/$label.log"
        grep -E "^ERROR|couldn't read file" "$RUNDIR/$label.log" | head -3 || true
        exit 1
    fi

    if [ ! -s "$REPDIR/${label}_util.rpt" ]; then
        echo "  ❌ $label 跑完了但没生成资源报告，看 $RUNDIR/$label.log"
        exit 1
    fi

    wns="$(grep -m1 "^RESULT $label WNS_NS" "$RUNDIR/$label.log" | awk '{print $4}')"
    impl="$(grep -m1 "^RESULT $label IMPL_OK" "$RUNDIR/$label.log" | awk '{print $4}')"
    if [ "$impl" = "1" ]; then
        echo "  ✅ $label 完成（布局布线走完）    WNS = ${wns} ns"
    else
        echo "  ⚠️  $label 综合完成，但布局布线没走完（多半是装不下）—— 资源报告仍然有效"
    fi
done

# ── 汇总：把 .rpt 里的数字抽成一张表 ────────────────────────────────
# 只读 .rpt 的表格首列做精确匹配，不整份读日志
rpt_cell() {
    awk -v k="$2" '
        /^\|/ {
            n = split($0, a, "|")
            if (n < 3) next
            c = a[2]; gsub(/^[ \t]+|[ \t]+$/, "", c)
            # 「Slice LUTs*」这种带星号的行名，星号是 Vivado 的脚注标记
            # （表示该行含 LUT 当存储器/移位寄存器用的部分），不是行名的一部分。
            # 不去掉的话 pe16 的 LUT 会抽成空 —— 表格里看着像「报告缺行」。
            sub(/\*$/, "", c)
            if (c == k) { v = a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
        }' "$1"
}

fmax_of() {
    w="$1"
    if [ -z "$w" ] || [ "$w" = "NO_PATH" ] || [ "$w" = "QUERY_FAILED" ]; then
        printf '?\n'
    else
        awk -v p="$PERIOD" -v w="$w" 'BEGIN {
            t = p - w
            if (t <= 0) printf ">%.0f\n", 1000/p
            else        printf "%.0f\n",  1000/t
        }'
    fi
}

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  汇总（器件 $PART，目标周期 ${PERIOD}ns）"
echo "═══════════════════════════════════════════════════════════"
printf '  %-8s %10s %8s %6s %6s %8s %10s\n' 档 LUT FF DSP BRAM WNS_ns Fmax_MHz
for d in $TARGETS; do
    label="$d$TAG"
    f="$REPDIR/${label}_util.rpt"
    wns="$(grep -m1 "^RESULT $label WNS_NS" "$RUNDIR/$label.log" | awk '{print $4}')"
    printf '  %-8s %10s %8s %6s %6s %8s %10s\n' \
        "$label" \
        "$(rpt_cell "$f" 'Slice LUTs')" \
        "$(rpt_cell "$f" 'Slice Registers')" \
        "$(rpt_cell "$f" 'DSPs')" \
        "$(rpt_cell "$f" 'Block RAM Tile')" \
        "${wns:--}" \
        "$(fmax_of "$wns")"
done
echo ""
echo "  Fmax 是反推值：T_min ≈ ${PERIOD}ns - WNS，Fmax = 1000/T_min（MHz）"
echo "  完整报告在 $REPDIR/"
