#!/bin/sh
# ===========================================================================
# package_submission_bits.sh —— 把 6 个提交用位流 + 烧录说明 + SHA-256 打进目录
#
#   sh rtl/vivado/package_submission_bits.sh                 # 默认 ./../submission/bitstream
#   OUT=~/Desktop/submission/bits sh rtl/vivado/package_submission_bits.sh
#
# 产物（OUT 下）：
#   pqc_ntt_pe{1,4,16}_50mhz.bit     50 MHz 基线
#   pqc_ntt_pe{1,4,16}_<f>mhz.bit    80 / 75 / 62.5 MHz 提频版
#   BURN.md                          烧录说明（源文件 rtl/vivado/submission_burn.md）
#   SHA256SUMS.txt                   逐文件 SHA-256
#
# ⚠️ 位流在 _runs/ 下、**不在 git 里**（换台机器要先自己综合）；本脚本只搬运与记账，
#    不重新综合、不改位流。
# ⚠️ 目标目录必须**不存在或为空**，避免把旧位流混进提交包。
# ===========================================================================
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

OUT="${OUT:-$ROOT/../submission/bitstream}"
mkdir -p "$OUT"
if [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    echo "  ❌ 目录非空：$OUT（先清空或换 OUT=）" >&2
    exit 1
fi

copy() {  # $1=源 $2=目标名
    [ -f "$1" ] || { echo "  ❌ 缺位流：$1" >&2; exit 1; }
    cp "$1" "$OUT/$2"
    echo "  ✅ $2"
}

copy rtl/vivado/_runs/pe1/ntt_board.bit      pqc_ntt_pe1_50mhz.bit
copy rtl/vivado/_runs/pe4/ntt_board.bit      pqc_ntt_pe4_50mhz.bit
copy rtl/vivado/_runs/pe16/ntt_board.bit     pqc_ntt_pe16_50mhz.bit
copy rtl/vivado/_runs/f80_pe1/ntt_board.bit  pqc_ntt_pe1_80mhz.bit
copy rtl/vivado/_runs/f75_pe4/ntt_board.bit  pqc_ntt_pe4_75mhz.bit
copy rtl/vivado/_runs/f62.5_pe16/ntt_board.bit pqc_ntt_pe16_62.5mhz.bit

cp rtl/vivado/submission_burn.md "$OUT/BURN.md"
echo "  ✅ BURN.md"

( cd "$OUT" && sha256sum *.bit > SHA256SUMS.txt )
echo "  ✅ SHA256SUMS.txt"
echo ""
echo "提交包位流目录：$OUT"
ls -la "$OUT"
