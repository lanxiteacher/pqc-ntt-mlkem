#!/bin/sh
# ===========================================================================
# run_board_check.sh —— 板级 wrapper 冒烟台（A 的，上板前的闸门）
#
#   sh rtl/board/run_board_check.sh
#   sh rtl/board/run_board_check.sh +dump     # 诊断用，见 tb/smoke_tb.v 文件头
#
# 跑的是什么：位级假串口 → 真 uart_rx/uart_tx → 真协议机 → 真 NTT 核。
# 只验两条：#PING 回帧逐字节正确、#NTT 1 端到端 256 行对拍黄金向量。
# 用例清单与「故意没测什么」都写在 tb/smoke_tb.v 的文件头上。
#
# ⚠️ 协议验收（§5.5 三条注入错误、校验和、错误码、超时）**不在这里** ——
#    那是 B 的 W2 活（`host/proto.md` §六第 12 条第 3 问）。A 起草的那版在
#    `tb/uart_proto_tb.v` + `tb/run_uart_check.sh`，等 B 取走，A 不维护。
#
# ⚠️ 为什么必须 cd 到 tb/ 再跑：`$readmemh` 的相对路径是按**进程工作目录**
#    解析的，不是按 .v 文件的位置。tb 里写的是
#    `../../../refsim/batch/ntt_batch_*.txt`，所以工作目录必须是 rtl/board/tb。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)

export PATH="/c/iverilog/bin:$PATH"
export PYTHONIOENCODING=utf-8

if ! command -v iverilog >/dev/null 2>&1; then
    echo "找不到 iverilog。它不在 PATH 里，正常路径是 C:\\iverilog\\bin" >&2
    exit 1
fi

cd "$HERE"

echo "== 编译 =="
# ---- 核只加 rtl/ntt_core/ 这一个目录 -------------------------------------
#   ⚠️ 绝不能把 rtl/pe1/ 一起加进来：那里有同名同类的一整套（上游原件），
#      两个都加会撞模块名。理由写在 rtl/board/ntt_board_top.v 的文件头。
iverilog -g2005 -o tb/smoke_tb.vvp \
    tb/smoke_tb.v \
    ntt_board_top.v \
    proto_fsm.v \
    cmd_parse.v \
    uart_line_rx.v \
    tx_line.v \
    hex3.v \
    poly_buf.v \
    ../uart_rx.v \
    ../uart_tx.v \
    ../ntt_core/*.v

echo "== 运行 =="
cd tb
vvp smoke_tb.vvp "$@"
