#!/bin/sh
# ===========================================================================
# run_board_prog.sh —— 把 bitstream 烧进 PL（JTAG 直配）
#
#   用法:
#     sh rtl/vivado/run_board_prog.sh scan        # 只扫链，确认下载器看得见
#     sh rtl/vivado/run_board_prog.sh             # 烧默认 bitstream
#     BIT=<别的.bit> sh rtl/vivado/run_board_prog.sh
#
#   产物:
#     rtl/vivado/_runs/board_prog.log   完整日志（不提交）
#
#   ⚠️ 上板前先核对三样（缺一条都表现为「看不到设备」）：
#     · 下载器插**底板右侧 14-Pin JTAG 座** —— USB_UART / USB_SLAVE 都不能下载
#     · 底板 **P5 跳 PL 档**（3–5、4–6 短接）
#     · 启动拨码 **JTAG 档**（两位都 ON）
#   ⚠️ 位流**掉电即失**，断电后要重烧。
#
#   ── 为什么从仓库外启动 ──────────────────────────────────────────────
#   与 run_board_synth.sh 同因：仓库路径含撇号，Vivado 交给子进程的工作目录
#   路径会被 shell 引号咬死。脚本自身放在仓库里没问题（`-source` 的参数路径
#   带撇号不影响），要把**进程工作目录**放到仓库外。
#
#   ── 默认 BIT 用的是哪个 ─────────────────────────────────────────────
#   `rtl/vivado/_runs/ntt_board.bit`，由 `run_board_synth.sh` 产出。
#   ⚠️ 它**不在 git 里**（`_runs/` 被忽略）—— 换台机器要先自己综合一遍。
#   ⚠️ 三档（pe1/pe4/pe16）的 bitstream **同名**，互相覆盖。所以烧之前本脚本
#      会读同目录的 `ntt_board.pe` 报一下这版是哪一档 —— 拿错档位的症状是
#      「256 个值全错」，很容易误判成 RTL 挂了。
# ===========================================================================

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$(cd "$HERE/../.." && pwd)"

VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"
RUNDIR="${VIVADO_RUNS:-$HERE/_runs}"
BIT="${BIT:-$RUNDIR/ntt_board.bit}"

# 档位戳：与 bitstream 同目录的一行文件 `ntt_board.pe`，由 synth_board.tcl 写。
# ⚠️ 为什么值得在这里读一遍：bitstream 的文件名**三档都一样**（ntt_board.bit），
#    拿 pe1 的位流去测 pe4，症状是「256 个值全错」—— 看着像 RTL 挂了，其实是
#    档位不对。烧之前报一下，省掉一轮排查。
PESTAMP="$(dirname "$BIT")/ntt_board.pe"

MODE="program"
case "${1:-}" in
    scan|--scan|-s) MODE="scan" ;;
    program|--program|"") MODE="program" ;;
    *) echo "  ❌ 不认识的动作：$1（只有 scan / program）" >&2; exit 2 ;;
esac

if [ ! -f "$VIVADO" ]; then
    echo "  ❌ 找不到 Vivado: $VIVADO" >&2
    echo "     用 VIVADO=<路径> 指定，正常路径是 E:\\xilinx\\Vivado\\2020.2\\bin\\vivado.bat" >&2
    exit 1
fi

# scan 模式不看 bitstream；program 模式必须先有
if [ "$MODE" = "program" ] && [ ! -f "$BIT" ]; then
    echo "  ❌ 没有 bitstream：$BIT" >&2
    echo "     先跑 sh rtl/vivado/run_board_synth.sh 产出它（_runs/ 不进 git，换机器要自己综合）" >&2
    exit 1
fi

SCRATCH="${VIVADO_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then
    SCRATCH="$(printf '%s' "$HERE" | sed 's|^/\([a-zA-Z]\)/.*|/\1|')/vivado_scratch"
fi
mkdir -p "$RUNDIR" "$SCRATCH"

vpath() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

if [ "$MODE" = "scan" ]; then
    echo "== 板级：只扫 JTAG 链（不烧任何东西）=="
else
    echo "== 板级：烧 bitstream 进 PL =="
    echo "   bit   $BIT"
    if [ -s "$PESTAMP" ]; then
        echo "   档位   pe$(cat "$PESTAMP")   （读自 $PESTAMP）"
        echo "          ⚠️ 上位机的装载/读出顺序表要按这一档给，三档不一样"
    else
        echo "   档位   ⚠️ 没有档位戳 $PESTAMP —— 这版是哪一档**没有记录**，"
        echo "          拿不准就重跑一次 run_board_synth.sh（它必然写这个戳）"
    fi
    echo "   注意  位流掉电即失，断电后要重烧"
fi
echo "   启动目录 $SCRATCH   （仓库路径含撇号，必须从仓库外启动）"

set +e
( cd "$SCRATCH" && exec "$VIVADO" -mode batch -notrace -nolog -nojournal \
        -source "$(vpath "$HERE/board_prog.tcl")" \
        -tclargs "$(vpath "$BIT")" "$MODE" ) \
    > "$RUNDIR/board_prog.log" 2>&1
rc=$?
set -e

echo ""
echo "─── 结果 ───"
# ⚠️ 三个 grep 都要 `-a`：Vivado 的日志里有控制字节，grep 会判定成
#    「二进制文件」，于是**不打印匹配行**、只回一句 `Binary file ... matches`。
#    那样下面两条判据看着像没命中，实际是没打印。（2026-10-04 scan 时踩到。）
grep -a -E "^RESULT prog|^    (target|device):|^  !!|^      [①②③④]" "$RUNDIR/board_prog.log" || true

# 27-3164 / "End of startup status: HIGH" 是 Zynq PL 配置完成的标志
if grep -a -q "End of startup status: HIGH" "$RUNDIR/board_prog.log"; then
    echo "   ✅ PL 配置完成（End of startup status: HIGH）"
fi
echo ""
echo "  日志  $RUNDIR/board_prog.log"

if [ "$MODE" = "program" ]; then
    if grep -a -q "^RESULT prog PROGRAMMED" "$RUNDIR/board_prog.log"; then
        echo ""
        echo "  下一步：真串口跑一条事务 —— 串口号先查，别写死："
        echo "    powershell -NoProfile -Command \"[System.IO.Ports.SerialPort]::GetPortNames()\""
    else
        echo "  ❌ 没烧进去 —— 看日志里的 FAIL 行" >&2
        exit 1
    fi
fi
