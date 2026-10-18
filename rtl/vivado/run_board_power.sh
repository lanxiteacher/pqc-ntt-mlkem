#!/bin/sh
# ===========================================================================
# run_board_power.sh —— 在**布线后的 checkpoint** 上跑 Vivado report_power
#
#   sh rtl/vivado/run_board_power.sh <输入.dcp> <输出.power.rpt>
#
#   例：
#     DCP=<目录> TAG=_pwr50 PE=1 sh rtl/vivado/run_board_synth.sh   # 先出 DCP
#     sh rtl/vivado/run_board_power.sh \
#        <目录>/ntt_board_pe1_pwr50.dcp rtl/vivado/reports/power_pe1_50mhz.rpt
#
# ⚠️ 为什么必须两步走
#   run_board_synth.sh 是非工程模式，**默认不写 checkpoint**；功耗又必须在
#   **布线后**的库上估（综合后没有真实走线电容，动态功耗会低估）。所以：
#   综合时给 DCP=<目录>，再用本脚本单独跑 report_power。
#
# ⚠️ 这是 **vectorless 估算**，不是实测：Vivado 默认开关活动率、25 °C、典型工艺角、
#   只算片内 PL。报告里写「估算」，不写「实测」。口径详述见
#   rtl/vivado/power_estimate.md。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
VIVADO="${VIVADO:-E:/xilinx/Vivado/2020.2/bin/vivado.bat}"

DCP="${1:-}"
OUT="${2:-}"
if [ -z "$DCP" ] || [ -z "$OUT" ]; then
    echo "用法: sh rtl/vivado/run_board_power.sh <输入.dcp> <输出.power.rpt>" >&2
    exit 2
fi
[ -f "$DCP" ] || { echo "  ❌ 找不到 checkpoint: $DCP" >&2; exit 1; }

vpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}
case "$DCP" in /*|[A-Za-z]:[/\\]*) ;; *) DCP="$PWD/$DCP" ;; esac
case "$OUT" in /*|[A-Za-z]:[/\\]*) ;; *) OUT="$PWD/$OUT" ;; esac

SCRATCH=${VIVADO_SCRATCH:-"$(printf '%s' "$HERE" | sed 's|^/\([a-zA-Z]\)/.*|/\1|')/vivado_scratch"}
mkdir -p "$SCRATCH"

( cd "$SCRATCH" && exec "$VIVADO" -mode batch -notrace -nolog -nojournal \
    -source "$(vpath "$HERE/report_power.tcl")" \
    -tclargs "$(vpath "$DCP")" "$(vpath "$OUT")" ) > "$SCRATCH/power_run.log" 2>&1

grep -a '^RESULT power' "$SCRATCH/power_run.log" || true
echo "  报告 $OUT"
