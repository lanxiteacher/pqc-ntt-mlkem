#!/bin/sh
# ===========================================================================
# run_uart_check.sh —— 串口协议验收台（**B 的资产**，从 A 处取来）
#
# 归属：`host/proto.md` §六第 12 条第 3 问 —— 「§5.5 三种注入错误属 B 的 W2 活」，
#       落点 `refsim/pe1/uart_proto_tb.v` + `refsim/run_uart_check.sh`（A 已回「认」）。
#       原稿放在 A 的 `rtl/board/tb/` 下等 B 取走；2026-10-06 取来，自此归 B。
#       原件仍在原处未删（等 A 点头再清），内容以本目录为准。
#
# 跑的是什么：位级假串口 → 真 uart_rx/uart_tx → 真协议机 → 真 NTT 核。
# 用例清单、覆盖不到的地方，都写在 `pe1/uart_proto_tb.v` 的文件头上。
#
# 跑法（**从哪跑都行**，脚本自己 cd 到 refsim/）：
#   sh refsim/run_uart_check.sh            # 全套（含 T5 端到端 NTT，慢，几分钟）
#   sh refsim/run_uart_check.sh +fast      # 跳过 T5，只跑协议与错误处理（秒级）
#
# 判据看**结尾两行**（不是看有没有报错文本）：
#   「比对点 N 个，失败 0 个」 + 「结论：全部通过。」
#   ⚠️ 基线：全套 N=274，+fast N=15
#      （2026-10-06 实测 273 / 14；**2026-10-07 加 T0b「收掉开机那行 `#RDY`」+1**）。
#      **N 变小 = 有检查没跑**，那是假绿，不是通过。
#   👉 这四条判据**脚本现在自己判**（`vvp_verdict_uart`，见 vvp_verdict.sh），
#      不用人拿眼睛看结尾两行；不符就 exit 1。基线写在本文件末尾的 BASE 里。
#
# ⚠️ 为什么工作目录必须是 refsim/：`$readmemh` 的相对路径是按**进程工作目录**
#    解析的，**不是**按 .v 文件的位置（这是 iverilog 的行为，坑过好几次）。
#    tb 里写的是 `batch/ntt_batch_*.txt` —— 与 `refsim/pe1/` 下几个兄弟 tb
#    （`fntt_batch_tb.v` / `intt_batch_tb.v` / `pwm2_batch_tb.v`）**完全一致**。
#    A 的原稿在 `rtl/board/tb/` 下写的是 `../../../refsim/batch/...`；搬过来时
#    按本仓库既有惯例改成了 `batch/...`，**不是**改成 `../../refsim/batch/...`。
# ===========================================================================

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# 判定函数（`$finish` 不改变退出码，光看 vvp 的退出码是假绿，见该文件头）。
. "$HERE/vvp_verdict.sh"

export PATH="/c/iverilog/bin:$PATH"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "找不到 iverilog。它不在 PATH 里，正常路径是 C:\\iverilog\\bin" >&2
    exit 1
fi

echo "== 编译 =="
# ---- 核只加 rtl/ntt_core/ 这一个目录 -------------------------------------
#   ⚠️ 绝不能把 rtl/pe1/ 一起加进来：那里有同名同类的一整套（上游原件），
#      两个都加会撞模块名。理由写在 rtl/board/ntt_board_top.v 的文件头。
iverilog -g2005 -o uart_proto_tb.vvp \
    pe1/uart_proto_tb.v \
    ../rtl/board/ntt_board_top.v \
    ../rtl/board/proto_fsm.v \
    ../rtl/board/cmd_parse.v \
    ../rtl/board/uart_line_rx.v \
    ../rtl/board/tx_line.v \
    ../rtl/board/hex3.v \
    ../rtl/board/poly_buf.v \
    ../rtl/uart_rx.v \
    ../rtl/uart_tx.v \
    ../rtl/ntt_core/*.v

echo "== 运行 =="
# 基线随参数走：带 +fast 时 T5（端到端 NTT，慢）不跑，比对点从 274 掉到 15。
# 这两个数是 2026-10-07 实测的（见文件头），**改 tb 就要同步改这里**。
BASE=274
for _a in "$@"; do
    case "$_a" in
        +fast*) BASE=15 ;;
    esac
done

_vvp_capture vvp uart_proto_tb.vvp "$@" || exit 1
_vvp_show
vvp_verdict_uart "UART 协议" "$BASE" "$_VVP_LOG" || exit 1
