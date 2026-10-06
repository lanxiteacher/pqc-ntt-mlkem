#!/bin/sh
# ===========================================================================
# run_fntt_check.sh —— 一条命令跑完 "RTL 的 NTT 是否符合 FIPS 203"
#
# 做三件事，缺一不可：
#   ① 用 KAT 校验过的 C 参考实现复算黄金向量，确认向量本身自洽
#   ② 用参考实现复算 RTL 作者自带的输入，跟作者的期望输出对拍
#   ③ 把自己生成的 16 组向量灌进 RTL，逐系数比对
#
# 用法：sh run_fntt_check.sh
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

echo "═══ ① 编译参考实现外壳 ═══"
gcc -O2 -Wall -I"$REF" -o ntt_ref_tool.exe ntt_ref_tool.c \
    "$REF/poly.c" "$REF/polyvec.c" "$REF/ntt.c" "$REF/reduce.c" "$REF/cbd.c" \
    "$REF/indcpa.c" "$REF/kem.c" "$REF/verify.c" "$REF/fips202.c" \
    "$REF/symmetric-shake.c" "$KAT/randombytes_stub.c"
echo "  ✅ ntt_ref_tool.exe"

echo
echo "═══ ② 复算作者的 2 组输入，与作者期望输出对拍 ═══"
D="pe1/test_pe1"
./ntt_ref_tool.exe "$D/KYBER_DIN0.txt" ref_ntt0.txt 2>&1 | sed 's/^/  /'
./ntt_ref_tool.exe "$D/KYBER_DIN1.txt" ref_ntt1.txt 2>&1 | sed 's/^/  /'
diff "$D/KYBER_DIN0_MFNTT.txt" ref_ntt0.txt >/dev/null \
    && echo "  ✅ DIN0：作者期望输出 == 参考实现（256/256）" \
    || { echo "  ❌ DIN0 不一致"; exit 1; }
diff "$D/KYBER_DIN1_MFNTT.txt" ref_ntt1.txt >/dev/null \
    && echo "  ✅ DIN1：作者期望输出 == 参考实现（256/256）" \
    || { echo "  ❌ DIN1 不一致"; exit 1; }

echo
echo "═══ ③ 把我方 16 组向量灌进 RTL ═══"
mkdir -p batch
python - <<'PY'
# -*- coding: utf-8 -*-
import os, subprocess, sys
sys.stdout.reconfigure(encoding="utf-8")

KAT, N, NV = "../research/mlkem_kat", 256, 16
rd = lambda p: [l.strip() for l in open(p) if l.strip()]

inp, exp = rd(f"{KAT}/ntt_in.hex"), rd(f"{KAT}/ntt_out.hex")
assert len(inp) == N*NV and len(exp) == N*NV

# 逐组用参考实现复算，确认黄金向量自洽（防止向量文件本身就是错的）
for v in range(NV):
    fi, fo = f"batch/vin_{v:02d}.txt", f"batch/vref_{v:02d}.txt"
    open(fi, "wb").write(("\n".join(inp[v*N:(v+1)*N]) + "\n").encode())
    r = subprocess.run(["./ntt_ref_tool.exe", fi, fo],
                       capture_output=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(f"  ❌ 向量 {v} 参考实现失败: {r.stderr}"); sys.exit(1)
    got, want = rd(fo), exp[v*N:(v+1)*N]
    bad = [i for i in range(N) if got[i].lstrip('0') != want[i].lstrip('0')]
    if bad:
        print(f"  ❌ 向量 {v}: {len(bad)} 处不符"); sys.exit(1)
print(f"  ✅ 16 组黄金向量自洽（ntt_out.hex == poly_ntt(ntt_in.hex)）")

for src, dst in ((f"{KAT}/ntt_in.hex",  "batch/ntt_batch_in.txt"),
                 (f"{KAT}/ntt_out.hex", "batch/ntt_batch_exp.txt")):
    open(dst, "wb").write(("\n".join(rd(src)) + "\n").encode())
PY

SRC="pe1/addressgenerator.v pe1/BRAM.v pe1/BROM.v pe1/butterfly.v pe1/div2.v \
pe1/dt0.v pe1/dt1.v pe1/dt2.v pe1/dt3.v pe1/FA.v pe1/HA.v pe1/intmul.v \
pe1/modadd.v pe1/modmul.v pe1/modred.v pe1/modsub.v pe1/shiftreg.v pe1/KyberHPM1PE.v"

iverilog -g2012 -o batch_fntt.vvp $SRC pe1/fntt_batch_tb.v
echo "  ✅ 编译 batch_fntt.vvp"
echo
_vvp_capture vvp batch_fntt.vvp || exit 1
_vvp_show
vvp_verdict_batch "FNTT" 16 "$_VVP_LOG" || exit 1

echo
echo "═══ 完成 ═══"
