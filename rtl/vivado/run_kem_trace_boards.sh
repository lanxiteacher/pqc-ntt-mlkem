#!/bin/sh
# ===========================================================================
# run_kem_trace_boards.sh —— A 侧：把 B 的 ML-KEM trace（15 次正向 NTT）逐档送真板
#
#   PORT=COM10 sh rtl/vivado/run_kem_trace_boards.sh
#   PORT=COM10 OUTTAG=_02 sh rtl/vivado/run_kem_trace_boards.sh   # 重跑不覆盖旧证据
#
# 前置（缺一条都会表现为「串口没回话」）：
#   · 板子插好（CH340），底板 P5 跳 PL 档（3–5、4–6），启动拨码 JTAG 档（两位 ON）
#   · 串口没被别的程序占着（串口助手 / 上一次没退的 python）
#   · 本机有 _runs/pe{1,4,16}/ntt_board.bit —— 10-07 那三版 50 MHz 基线；
#     没有就先 `PE=<n> sh rtl/vivado/run_board_synth.sh` 重出（约 10 分钟/档）
#   · trace 用 B 在 10-18 固定下来的那份，不要现场重生成
#
# 每档做两步：
#   1) 烧 _runs/pe<N>/ntt_board.bit（BIT= 显式给，跳过「位流比源文件旧」护栏）
#   2) python refsim/run_kem_board.py … --build N --frequency-mhz 50
#      结果落 logs/verification_<日期>_A_kem_serial_pe<N><OUTTAG>/
#
# ⚠️ B 的入口**只做串口回放、不烧位流** —— 「先烧对应档位」这一步是本脚本补的。
#    对同一只位流只改 --build 冒充三档，会被 RDY 的 <build> 拒绝（工具自己会拦）。
# ⚠️ --frequency-mhz 是**人工声明**（基线位流是 50 MHz 设计）；工具不测实际时钟，
#    --bitstream 只记文件 SHA-256，不能证明 FPGA 此刻加载的就是它。
# ⚠️ 输出目录必须不存在；重跑换 OUTTAG，别覆盖旧证据（B 的规矩）。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT" || exit 1
export PYTHONIOENCODING=utf-8

TRACE="logs/verification_2026-10-18_B_kem_delivery_trace.json"
[ -f "$TRACE" ] || { echo "  ❌ 找不到 trace: $TRACE" >&2; exit 1; }

PORT="${PORT:-}"
if [ -z "$PORT" ]; then
    # 现查 CH340（口号会变，不写死）—— 走 B 的 link.find_port 同一套判据
    PORT=$(python -c "import sys;sys.path.insert(0,'host/src');import link;print(link.find_port())")
fi
[ -n "$PORT" ] || { echo "  ❌ 没找到 CH340 串口；用 PORT=COM10 显式指定" >&2; exit 1; }
echo "   串口   $PORT（现查/显式给）"

DATE=$(date +%F)
OUTTAG="${OUTTAG:-}"

for pe in 1 4 16; do
    BIT="rtl/vivado/_runs/pe$pe/ntt_board.bit"
    OUT="logs/verification_${DATE}_A_kem_serial_pe${pe}${OUTTAG}"

    [ -f "$BIT" ] || { echo "  ❌ 缺位流: $BIT（先 PE=$pe sh rtl/vivado/run_board_synth.sh）" >&2; exit 1; }
    if [ -e "$OUT" ]; then echo "  ❌ 输出目录已存在: $OUT（换 OUTTAG=...）" >&2; exit 1; fi

    echo ""
    echo "=============================================================="
    echo "  pe$pe：烧位流 → 送 15 次 trace"
    echo "=============================================================="

    # ⚠️ 烧录成败用**退出码**判，不用 grep 的退出码（那样会把失败当成功）。
    PROG_LOG=$(mktemp) || exit 1
    if ! BIT="$BIT" sh rtl/vivado/run_board_prog.sh > "$PROG_LOG" 2>&1; then
        echo "  ❌ 烧录失败 —— 原始输出：" >&2
        tail -20 "$PROG_LOG" >&2
        rm -f "$PROG_LOG"
        exit 1
    fi
    grep -E "RESULT prog PROGRAMMED" "$PROG_LOG" || true
    rm -f "$PROG_LOG"

    python refsim/run_kem_board.py \
        --trace "$TRACE" \
        --output "$OUT" \
        --port "$PORT" \
        --build "$pe" \
        --bitstream "$BIT" \
        --frequency-mhz 50 \
        --baud 115200
done

echo ""
echo "三档完成：每档 15 次 / 3840 系数，三档合计 45 次 / 11520 系数。"
echo "输出目录：logs/verification_${DATE}_A_kem_serial_pe{1,4,16}${OUTTAG}/"
echo "交给 B 复核：session.json + stdout/stderr + serial/replay.json（失败目录也保留）。"
