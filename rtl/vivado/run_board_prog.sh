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
# ===========================================================================

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
RTLDIR="$(cd "$HERE/../.." && pwd)"

VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"
RUNDIR="${VIVADO_RUNS:-$HERE/_runs}"
BIT="${BIT:-$RUNDIR/ntt_board.bit}"

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
grep -E "^RESULT prog|^    (target|device):|^  !!|^      [①②③④]" "$RUNDIR/board_prog.log" || true

# 27-3164 / "End of startup status: HIGH" 是 Zynq PL 配置完成的标志
if grep -q "End of startup status: HIGH" "$RUNDIR/board_prog.log"; then
    echo "   ✅ PL 配置完成（End of startup status: HIGH）"
fi
echo ""
echo "  日志  $RUNDIR/board_prog.log"

if [ "$MODE" = "program" ]; then
    if grep -q "^RESULT prog PROGRAMMED" "$RUNDIR/board_prog.log"; then
        echo ""
        echo "  下一步：真串口跑一条事务 —— 串口号先查，别写死："
        echo "    powershell -NoProfile -Command \"[System.IO.Ports.SerialPort]::GetPortNames()\""
    else
        echo "  ❌ 没烧进去 —— 看日志里的 FAIL 行" >&2
        exit 1
    fi
fi
