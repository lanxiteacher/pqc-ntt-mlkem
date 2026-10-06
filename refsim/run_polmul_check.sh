#!/bin/sh
# ===========================================================================
# run_polmul_check.sh —— 验 RTL 的**完整多项式乘法通路**（端到端）
#
# 前面两个脚本是把 FNTT / INTT / PWM2 拆开各验各的。这一条验的是它们
# **串起来**的样子，也就是 ML-KEM 里真正会跑的那条链：
#
#   FULL：A、B 都在时域     → FNTT(A) → FNTT(B) → PWM2 → INTT
#   HALF：A 时域、B 在 NTT 域 → FNTT(A) → PWM2 → INTT
#
# ⭐ 关键差别：**这条链上没有任何缩放因子。**
#    run_intt_pwm2_check.sh 里 INTT 差一个 R^-1、点乘差一个 R，两个因子串起来
#    正好抵消，所以这里期望值就是参考实现的输出，逐比特直接比 —— 不需要标定。
#    反过来说，如果那两个因子有一个标错了，这里就不可能严丝合缝地全过。
#
# 做三件事：
#   ① 编译参考实现外壳、生成向量（含一道自检：参考工具必须能复现作者的 KYBER_DOUT.txt）
#   ② 16 组灌 RTL 验 FULL 通路
#   ③ 16 组灌 RTL 验 HALF 通路
#
# 用法：sh run_polmul_check.sh
# 依赖：gcc、iverilog（/c/iverilog/bin）、python
# ===========================================================================
set -e
export PATH="/c/iverilog/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
REF="../research/kyber_ref"
KAT="../research/mlkem_kat"

# 判定函数（`$finish` 不改变退出码，光看 vvp 的退出码是假绿，见该文件头）。
. "$HERE/vvp_verdict.sh"

SRC="pe1/addressgenerator.v pe1/BRAM.v pe1/BROM.v pe1/butterfly.v pe1/div2.v \
pe1/dt0.v pe1/dt1.v pe1/dt2.v pe1/dt3.v pe1/FA.v pe1/HA.v pe1/intmul.v \
pe1/modadd.v pe1/modmul.v pe1/modred.v pe1/modsub.v pe1/shiftreg.v pe1/KyberHPM1PE.v"

echo "═══ ① 编译参考工具 + 生成向量 ═══"
# gen_batch_vectors.py 的 __main__ 无条件跑 gen_intt / gen_pwm2 / gen_polmul
# 三个生成器，所以下面这三个工具**都得先编出来**。
# 少编一个不会立刻报错，而是在跑到对应生成器时才抛 FileNotFoundError ——
# 且 .exe 被 .gitignore 挡在仓库外，在本机靠遗留的 exe 看不出问题，
# 只有全新 clone 才会暴露。三个一起编。
LIBS="$REF/poly.c $REF/polyvec.c $REF/ntt.c $REF/reduce.c $REF/cbd.c \
$REF/indcpa.c $REF/kem.c $REF/verify.c $REF/fips202.c \
$REF/symmetric-shake.c $KAT/randombytes_stub.c"

gcc -O2 -Wall -I"$REF" -o ntt_once_tool.exe          ntt_once_tool.c          $LIBS
echo "  ✅ ntt_once_tool.exe"
gcc -O2 -Wall -I"$REF" -o basemul_nttdomain_tool.exe basemul_nttdomain_tool.c $LIBS
echo "  ✅ basemul_nttdomain_tool.exe"
gcc -O2 -Wall -I"$REF" -o polmul_full_tool.exe       polmul_full_tool.c       $LIBS
echo "  ✅ polmul_full_tool.exe"
echo

python gen_batch_vectors.py

echo
echo "═══ ② 完整乘法 FULL：A、B 都在时域（16 组）═══"
iverilog -g2012 -o batch_fullmul.vvp $SRC pe1/fullmul_batch_tb.v
_vvp_capture vvp batch_fullmul.vvp || exit 1
_vvp_show
vvp_verdict_batch "FULL（完整乘法）" 16 "$_VVP_LOG" || exit 1

echo
echo "═══ ③ 半程乘法 HALF：A 时域、B 在 NTT 域（16 组）═══"
iverilog -g2012 -o batch_halfmul.vvp $SRC pe1/halfmul_batch_tb.v
_vvp_capture vvp batch_halfmul.vvp || exit 1
_vvp_show
vvp_verdict_batch "HALF（半程乘法）" 16 "$_VVP_LOG" || exit 1

echo
echo "═══ 完成 ═══"
echo "  ② FULL 16 组 · ③ HALF 16 组 —— 端到端逐比特一致才算数"
