#!/bin/sh
# ===========================================================================
# run_uart_check.sh —— 串口协议验收台（**B 的资产，A 只是起草**）
#
# ⚠️ 归属：`host/proto.md` §六第 12 条第 3 问写明「§5.5 三条注入错误属 B 的 W2 活」，
#    落点 `refsim/pe1/uart_proto_tb.v` + `refsim/run_uart_check.sh`（A 已回「认」）。
#    这个文件现在临时放在 A 的目录里**等 B 取走**；B 取走后归 B，可任意改写。
#    详见同目录 `uart_proto_tb.v` 的文件头与文件末「移交说明」。
#
# 跑法：
#   sh tb/run_uart_check.sh            # 全套（含 T5 端到端 NTT，慢）
#   sh tb/run_uart_check.sh +fast      # 跳过 T5，只跑协议与错误处理
#
# 跑的是什么：位级假串口 → 真 uart_rx/uart_tx → 真协议机 → 真 NTT 核。
# 用例清单、覆盖不到的地方，都写在 tb/uart_proto_tb.v 的文件头上。
#
# ⚠️ 为什么必须 cd 到 tb/ 再跑：`$readmemh` 的相对路径是按**进程工作目录**
#    解析的，不是按 .v 文件的位置。tb 里写的是
#    `../../../refsim/batch/ntt_batch_*.txt`，所以工作目录必须是 rtl/board/tb。
#
# ---------------------------------------------------------------------------
# ⚠️ B 把这个脚本挪到 `refsim/run_uart_check.sh` 时要改三处：
#    ① 下面 HERE 要指到 `refsim/pe1`（tb 所在目录），不是脚本自己所在的 refsim/
#    ② tb 里的两条 `$readmemh` 相对深度（`../../../refsim/batch/` → 视新位置而定）
#    ③ 核的源文件路径（现在从 rtl/board/ 出发写的是 `../ntt_core/*.v`）
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)

export PATH="/c/iverilog/bin:$PATH"
export PYTHONIOENCODING=utf-8

if ! command -v iverilog >/dev/null 2>&1; then
    echo "找不到 iverilog。它不在 PATH 里，正常路径是 C:\\iverilog\\bin" >&2
    exit 1
fi

# 本脚本现在放在 rtl/board/tb/，RTL 在上层；tb 在脚本自己所在目录
cd "$HERE"
BOARD=..

echo "== 编译 =="
# ---- 核只加 rtl/ntt_core/ 这一个目录 -------------------------------------
#   ⚠️ 绝不能把 rtl/pe1/ 一起加进来：那里有同名同类的一整套（上游原件），
#      两个都加会撞模块名。理由写在 rtl/board/ntt_board_top.v 的文件头。
iverilog -g2005 -o uart_proto_tb.vvp \
    uart_proto_tb.v \
    "$BOARD/ntt_board_top.v" \
    "$BOARD/proto_fsm.v" \
    "$BOARD/cmd_parse.v" \
    "$BOARD/uart_line_rx.v" \
    "$BOARD/tx_line.v" \
    "$BOARD/hex3.v" \
    "$BOARD/poly_buf.v" \
    "$BOARD/../uart_rx.v" \
    "$BOARD/../uart_tx.v" \
    "$BOARD/../ntt_core"/*.v

echo "== 运行 =="
vvp uart_proto_tb.vvp "$@"
