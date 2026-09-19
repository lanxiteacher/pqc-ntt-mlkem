#!/bin/sh
# 编译 NTT 黄金向量生成器（供 FPGA testbench 对拍用）
set -e
cd "$(dirname "$0")"

REF=../kyber_ref

gcc -O2 -Wall -Wextra -I"$REF" \
    -o gen_ntt_vectors.exe \
    gen_ntt_vectors.c \
    "$REF/poly.c" \
    "$REF/polyvec.c" \
    "$REF/ntt.c" \
    "$REF/reduce.c" \
    "$REF/cbd.c" \
    "$REF/verify.c" \
    "$REF/fips202.c" \
    "$REF/symmetric-shake.c" \
    randombytes_stub.c

echo "已生成 gen_ntt_vectors.exe"
