#!/bin/sh
# ===========================================================================
# run_board_freq_sweep.sh —— 三档提频：每档用各自的 MMCM 倍频/分频重综合
#
#   用法:
#     sh rtl/vivado/run_board_freq_sweep.sh          # 三档顺序跑（约 30 分钟）
#     PE=4 sh rtl/vivado/run_board_freq_sweep.sh     # 只跑一档
#
#   频率表（2026-10-18 实测；判据见 rtl/vivado/board_freq_sweep.md）:
#     pe1   80.0 MHz   MMCM_MULT=24 DIV=15   （VCO 1200）
#     pe4   75.0 MHz   MMCM_MULT=24 DIV=16   （VCO 1200）
#     pe16  62.5 MHz   MMCM_MULT=20 DIV=16   （VCO 1000）
#
#   产物（带折叠度 + 频率签名，与 50 MHz 基线三份报告并存）:
#     rtl/vivado/reports/board_pe<N>_f<MHz>_{util,timing,io}.rpt
#     rtl/vivado/_runs/f<MHz>_pe<N>/ntt_board.bit   （+ ntt_board.pe 档位戳）
#
#   ⚠️ 每档必须用**独立的 VIVADO_RUNS / VIVADO_SCRATCH**。
#      2026-10-18 实际踩过：两条 run_board_synth.sh 并跑，共用同一个 scratch 与
#      _runs/，第二轮的 `rm -rf .Xil` 撞上第一轮正在写的文件（Device or resource
#      busy），整轮 set -e 直接退出；两轮还会互相覆盖 board_synth_try1.log、
#      ntt_board.bit、ntt_board.pe。**同名的中间产物比没有中间产物更坏。**
#      另外 bitstream 落进各自的 _runs/f<MHz>_pe<N>/，三档不会只剩最后一档。
#
#   ⚠️ 本脚本**只做综合**，不碰板子。上板（烧录 + 五条事务）另见
#      rtl/vivado/run_board_prog.sh 与 run_board_txn_report.sh。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SCRATCH_ROOT=$(printf '%s' "$HERE" | sed 's|^/\([a-zA-Z]\)/.*|/\1|')/vivado_scratch

PE_LIST="${PE:-1 4 16}"

for pe in $PE_LIST; do
    case "$pe" in
        1)  MULT=24; DIV=15; MHZ=80    ;;
        4)  MULT=24; DIV=16; MHZ=75    ;;
        16) MULT=20; DIV=16; MHZ=62.5  ;;
        *)  echo "  ❌ 折叠度非法：PE='$pe' —— 只支持 1 / 4 / 16" >&2; exit 1 ;;
    esac

    TAG="_f$MHZ"
    DIR="f${MHZ}_pe$pe"
    echo ""
    echo "=========================================================="
    echo "  pe$pe → $MHZ MHz  （MULT=$MULT DIV=$DIV）"
    echo "=========================================================="

    VIVADO_RUNS="$HERE/_runs/$DIR" \
    VIVADO_SCRATCH="${SCRATCH_ROOT}_$DIR" \
    TOP=ntt_board_top_mmcm MMCM_MULT=$MULT MMCM_DIV=$DIV TAG=$TAG PE=$pe \
        sh "$HERE/run_board_synth.sh"
done

echo ""
echo "三档提频综合完成。报告：rtl/vivado/reports/board_pe<N>_f<MHz>_*.rpt"
echo "位流：rtl/vivado/_runs/f<MHz>_pe<N>/ntt_board.bit"
