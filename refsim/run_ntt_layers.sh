#!/bin/sh
# ===========================================================================
# run_ntt_layers.sh —— 打印并验证 NTT/INTT 的 twiddle 层序表
#
# 用途：写 RTL 的 NTT 时，照着这张表填 twiddle 索引，别凭记忆推。
# 项目记录里那条"W1 最高优先级、无捷径"的待办，答案就在这里。
#
# 用法：sh run_ntt_layers.sh
# ===========================================================================
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
REF="../research/kyber_ref"
KAT="../research/mlkem_kat"

gcc -O2 -Wall -I"$REF" -o ntt_layers.exe ntt_layers.c \
    "$REF/poly.c" "$REF/polyvec.c" "$REF/ntt.c" "$REF/reduce.c" "$REF/cbd.c" \
    "$REF/indcpa.c" "$REF/kem.c" "$REF/verify.c" "$REF/fips202.c" \
    "$REF/symmetric-shake.c" "$KAT/randombytes_stub.c"

./ntt_layers.exe
