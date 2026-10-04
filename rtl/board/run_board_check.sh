#!/bin/sh
# ===========================================================================
# run_board_check.sh —— 板级 wrapper 冒烟台（A 的，上板前的闸门）
#
#   sh rtl/board/run_board_check.sh
#   sh rtl/board/run_board_check.sh +dump     # 诊断用，见 tb/smoke_tb.v 文件头
#   PE=4  sh rtl/board/run_board_check.sh     # 换折叠度（1 / 4 / 16，默认 1）
#
# 跑的是什么：位级假串口 → 真 uart_rx/uart_tx → 真协议机 → 真 NTT 核。
# 验三条（S1/S2/S3）：
#   S1  #PING 回帧逐字节正确
#   S2  #NTT 1       端到端 256 行对拍黄金向量（**一个** bank）
#   S3  #PMUL NTT 1  端到端 256 行对拍黄金向量（**A、B 两个** bank 都装）
# ⚠️ S3 是补出来的，不是一开始就有：S2 只装一个 bank，**A→B 的切 bank 支路
#    从未被行使** —— 而 `proto_fsm.v` 的 `S_LOAD` 里那处写死的间隔常数恰好只
#    在 pe1 上对（pe4 差 1 拍、pe16 差 13 拍）。「S2 过了」被拿去背书了一条
#    管两个 bank 的结论，这就是那个 bug 能在 pe4/pe16 上板后才暴露的原因。
#    已修（间隔改成随折叠度派生），S3 在修前**必挂** —— 无失败史的用例不可信。
# 用例清单与「故意没测什么」都写在 tb/smoke_tb.v 的文件头上。
#
# ⚠️ 折叠度是**编译期**开关，三档各跑一次、分别跑，不能一次跑三档。
#    随档位变的只有 READ_LAT（2*PE+3）与 FNTT 的读出顺序（pe1 交织，其余自然序），
#    都由 tb 从 PE_NUM 推出来 —— 这里只负责把 -D 传进去。
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

# ---- 折叠度 → 宏 ----------------------------------------------------------
#   1/4/16 之外的值直接拦在这里，别等 iverilog 报一堆 `TB_PE` 未定义的怪话。
PE="${PE:-1}"
case "$PE" in
    1)  PEDEF="" ;;
    4)  PEDEF="-DTB_PE4" ;;
    16) PEDEF="-DTB_PE16" ;;
    *)  echo "  ❌ 折叠度非法：PE='$PE' —— 只支持 1 / 4 / 16" >&2; exit 1 ;;
esac

echo "== 编译（PE=$PE）=="
# ---- 核只加 rtl/ntt_core/ 这一个目录 -------------------------------------
#   ⚠️ 绝不能把 rtl/pe1/ 一起加进来：那里有同名同类的一整套（上游原件），
#      两个都加会撞模块名。理由写在 rtl/board/ntt_board_top.v 的文件头。
#   ℹ️ vvp 文件名带档位 —— 三档的编译产物不互相覆盖，顺手也避免
#      「跑的是上一次编译出来的那份」这类看走眼。
#   ⚠️ 但**同一个档位不能同时跑两遍** —— 两遍会抢同一个 `tb/smoke_tb_pe$PE.vvp`，
#      一边写一边读。要并跑就并不同档（pe1‖pe4‖pe16 是安全的），
#      同档要么串行、要么把 vvp 名字改掉。另：ffi 波形 `tb/*.vcd` 同理。
# shellcheck disable=SC2086
iverilog -g2005 $PEDEF -o "tb/smoke_tb_pe$PE.vvp" \
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
vvp "smoke_tb_pe$PE.vvp" "$@"
