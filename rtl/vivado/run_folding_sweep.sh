#!/bin/sh
# run_folding_sweep.sh —— 三档折叠度各跑一次 Vivado 综合实现，出资源 / 频率报告
#
#   用法:
#     sh run_folding_sweep.sh                    # 参数化版，三档全跑（pe1 / pe4 / pe16）
#     sh run_folding_sweep.sh pe4                # 只跑一档，改一行不用重跑三个
#     TREE=upstream sh run_folding_sweep.sh      # 上游基线（rtl/peN/ 三份独立目录）
#
#   产物:
#     rtl/vivado/reports/<档>_util.rpt     ← 资源占用（要提交，H4 要交给 C）
#     rtl/vivado/reports/<档>_timing.rpt   ← 时序 + 关键路径（同上）
#     rtl/vivado/_runs/<档>.log            ← 完整日志（不提交，见 .gitignore）
#
#   ── TREE：量哪一棵树 ─────────────────────────────────────────────
#     ncore（默认）  量 rtl/ntt_core/ 的参数化版 —— 顶层都是 KyberHPMNTT_top，
#                    折叠度由 generic `PE_NUMBER` 选。报告自动带 `_nc` 后缀，
#                    不会盖掉上游那份。
#     upstream_top   量 rtl/peN/KyberHPMNPE_top.v（上游**顶层**：核 + 输入寄存级）。
#                    报告带 `_utop` 后缀。
#     upstream       量 rtl/peN/KyberHPMNPE.v（上游**核**本体，没有外面那级寄存）。
#                    `folding_comparison.md` 里那张基线表就是这么来的。
#
#   ⚠️ **核 / 顶层是两个不同的量法，别混着比。**
#      上游的 IOB 数两边一样（`_top` 不改变端口位宽，`din`/`dout` 仍是 12×PE），
#      但 LUT/FF 差一级寄存器的量。ncore 量的是**顶层**（含 12 位串行化的外壳），
#      所以要和 `upstream_top` 并排看，不是和 `upstream`。
#      三者同一器件、同一周期约束，只有**边界**不同 —— 表里必须标清是哪一行。
#
#   环境变量:
#     TREE=<ncore|upstream_top|upstream>  量哪棵树，见上。默认 ncore
#     VIVADO_RUNS=<目录>   工程中间产物放哪。默认 rtl/vivado/_runs/
#                          （C 盘紧张时可以指到别的盘）
#     PART=<器件>          默认 xc7z020clg400-2，也就是板上那颗 Zynq-7020
#     PERIOD=<ns>          默认 5（200MHz）
#     TAG=<后缀>           报告文件名加后缀，交叉核对跑用，见下。
#                          不给的话 ncore 档自动用 `_nc`
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
TREE="${TREE:-ncore}"
TRIES="${TRIES:-3}"
REPDIR="$HERE/reports"
RUNDIR="${VIVADO_RUNS:-$HERE/_runs}"

case "$TREE" in
    ncore|upstream_top|upstream) ;;
    *) echo "  ❌ 不认识的 TREE「$TREE」，只支持 ncore / upstream_top / upstream"; exit 1 ;;
esac

# 三棵树各自一个默认后缀 —— 不加的话会互相覆盖，而 `upstream`（核）那三份
# 报告早已提交、是交给 C 的产物清单（§八），盖掉就复现不出来了。
TAG="${TAG:-}"
if [ -z "$TAG" ]; then
    case "$TREE" in
        ncore)        TAG="_nc"   ;;
        upstream_top) TAG="_utop" ;;
        upstream)     TAG=""      ;;
    esac
fi

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

case "$TREE" in
    ncore)        TREEDESC="rtl/ntt_core 顶层 KyberHPMNTT_top（参数化版）" ;;
    upstream_top) TREEDESC="rtl/peN 顶层 KyberHPMNPE_top（上游基线）" ;;
    upstream)     TREEDESC="rtl/peN 核 KyberHPMNPE（上游基线）" ;;
esac

echo "═══════════════════════════════════════════════════════════"
echo "  折叠度扫描：器件 $PART   目标周期 ${PERIOD}ns   运行目录 $RUNDIR"
echo "  源码树：$TREEDESC"
echo "═══════════════════════════════════════════════════════════"

for d in $TARGETS; do
    bflies="$(bflies_of "$d")"
    if [ "$bflies" = "?" ]; then
        echo "  ❌ 不认识的档位「$d」，只支持 pe1 / pe4 / pe16"
        exit 1
    fi
    label="$d$TAG"

    case "$TREE" in
        ncore)
            # 第 7 个 tclarg = 蝶形数，synth_one.tcl 自己拼成 generic PE_NUMBER=N。
            # ⚠️ 不要把 `PE_NUMBER=N` 整串从命令行传进去 —— 见 synth_one.tcl 的注释。
            srcdir="$RTLDIR/ntt_core"
            top="KyberHPMNTT_top"
            pearg="$bflies"
            ;;
        upstream_top)
            # 上游顶层。它自己带 `parameter PE_NUMBER`，**但顶层没有实例化者**，
            # 所以 generic 传不进去（`-generic` 只作用于顶层模块的参数）。
            # 好在每个 peN 目录里的 `_top` 默认值本来就是对的（1 / 4 / 16），
            # 而目录名已经决定了是哪一档 —— 不会串。
            srcdir="$RTLDIR/$d"
            top="$(top_of "$d")_top"
            pearg=""
            ;;
        upstream)
            srcdir="$RTLDIR/$d"
            top="$(top_of "$d")"
            pearg=""
            ;;
    esac

    if [ ! -d "$srcdir" ]; then
        echo "  ❌ 源码目录不存在：$srcdir"
        exit 1
    fi

    echo ""
    echo "─── $label  |  $top  |  $bflies 个蝶形单元 ───"

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
                         "$(vpath "$srcdir")" "$(vpath "$REPDIR")" "$pearg" ) \
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

# ⚠️ 最后一行不能写 `rpt_cell ... | head -1` 这类：报告里 `Block RAM Tile` 与
#    `Block RAM Tile | DSP48E1 only` 之类会撞名，所以 rpt_cell 取的是**第一次**匹配
#    就 exit，别在外面再叠一层过滤。
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  汇总（源码树：$TREEDESC）"
echo "  器件 $PART，目标周期 ${PERIOD}ns，引脚预算 125"
echo "═══════════════════════════════════════════════════════════"
printf '  %-8s %10s %8s %6s %6s %8s %8s %10s\n' 档 LUT FF DSP BRAM WNS_ns IOB Fmax_MHz
iob_fail=0
for d in $TARGETS; do
    label="$d$TAG"
    f="$REPDIR/${label}_util.rpt"
    wns="$(grep -m1 "^RESULT $label WNS_NS" "$RUNDIR/$label.log" | awk '{print $4}')"
    iob="$(rpt_cell "$f" 'Bonded IOB')"
    # 判据 1：三档 IOB 都必须落在 7020 的 125 个引脚预算里。
    # 上游 pe16 是 397 → place 直接失败，所以这一格是本轮改造的验收点。
    if [ -n "$iob" ] && [ "$iob" -gt 125 ] 2>/dev/null; then
        iob="$iob ⚠️超"
        iob_fail=1
    fi
    printf '  %-8s %10s %8s %6s %6s %8s %8s %10s\n' \
        "$label" \
        "$(rpt_cell "$f" 'Slice LUTs')" \
        "$(rpt_cell "$f" 'Slice Registers')" \
        "$(rpt_cell "$f" 'DSPs')" \
        "$(rpt_cell "$f" 'Block RAM Tile')" \
        "${wns:--}" \
        "${iob:-?}" \
        "$(fmax_of "$wns")"
done
echo ""
echo "  Fmax 是反推值：T_min ≈ ${PERIOD}ns - WNS，Fmax = 1000/T_min（MHz）"
echo "  完整报告在 $REPDIR/"
# ⚠️ 判据 1 只对**参数化版**（TREE=ncore）下结论。上游两棵树本来就超预算
#    （pe4 109 / pe16 397），跑对照那一轮不该打印「判据 1 通过/不通过」——
#    打印 ✅ 会把「上游本来就不达标」说成达标，打印 ❌ 会被读成「参数化版退步了」。
#    所以先判 TREE，再判数字。
if [ "$TREE" = "ncore" ]; then
    if [ "$iob_fail" -eq 0 ]; then
        echo "  ✅ 判据 1（引脚预算）：三档 Bonded IOB 全部 ≤ 125"
    else
        echo "  ❌ 判据 1（引脚预算）：有档位的 Bonded IOB 超过 125 —— 见上表标 ⚠️ 的行"
    fi
else
    echo "  ℹ️  上游基线（$TREE）：pe4 / pe16 的 Bonded IOB 本就超 125（109 / 397）——"
    echo "      这是 §五 那条结论的复现，不是回归。判据 1 只对 TREE=ncore 下结论。"
fi
