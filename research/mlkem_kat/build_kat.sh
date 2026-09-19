#!/bin/sh
# 编译 ML-KEM-768 KAT 校验器。
# 依赖：kyber_ref/ 下的参考实现源码（除 randombytes.c，用本目录的桩替代）
set -e
cd "$(dirname "$0")"

REF=../kyber_ref

gcc -O2 -Wall -Wextra -I"$REF" \
    -o kat_verify.exe \
    kat_verify.c \
    "$REF/kem.c" \
    "$REF/indcpa.c" \
    "$REF/poly.c" \
    "$REF/polyvec.c" \
    "$REF/ntt.c" \
    "$REF/reduce.c" \
    "$REF/cbd.c" \
    "$REF/verify.c" \
    "$REF/fips202.c" \
    "$REF/symmetric-shake.c" \
    randombytes_stub.c

echo "已生成 kat_verify.exe"
