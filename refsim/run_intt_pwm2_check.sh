#!/bin/sh
# ===========================================================================
# run_intt_pwm2_check.sh —— 一条命令验完 RTL 的 INTT 和点乘（PWM2）
#
# 做四件事：
#   ① 编译参考工具、生成批量对拍向量（RTL 的域约定与 C 参考实现不同，见 gen_batch_vectors.py）
#   ② 16 组向量灌 RTL 验 INTT
#   ③ 16 组向量灌 RTL 验 PWM2
#   ④ **RTL 往返自检**：RTL 的 FNTT → RTL 的 INTT，必须回到原值
#
# 第 ④ 步是独立的交叉验证 —— 它完全不碰 C 参考实现，只依赖"FNTT 已经用
# FIPS 203 验过"这个事实（见 run_fntt_check.sh）。②③ 的期望值是按反推的
# 约定生成的，④ 用来证明那个反推没有自欺。
#
# 👉 四处 `vvp`（② 一处、③ 一处、④ 两趟）都由 `vvp_verdict.sh` 的判定函数
#    **自己判**（基线都是 16 组），不符就 exit 1 —— 不能看 vvp 的退出码：
#    `$finish` 不改退出码，那是假绿（见该文件头）。④ 两趟各 19 行输出，显示上
#    只留末尾几行，但**判定用的是完整日志**。
#
# 用法：sh run_intt_pwm2_check.sh
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

echo "═══ ① 编译参考工具 + 生成批量对拍向量 ═══"
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
echo "═══ ② INTT：16 组向量灌 RTL ═══"
iverilog -g2012 -o batch_intt.vvp $SRC pe1/intt_batch_tb.v
_vvp_capture vvp batch_intt.vvp || exit 1
_vvp_show
vvp_verdict_batch "INTT" 16 "$_VVP_LOG" || exit 1

echo
echo "═══ ③ PWM2（点乘）：16 组向量灌 RTL ═══"
iverilog -g2012 -o batch_pwm2.vvp $SRC pe1/pwm2_batch_tb.v
_vvp_capture vvp batch_pwm2.vvp || exit 1
_vvp_show
vvp_verdict_batch "PWM2" 16 "$_VVP_LOG" || exit 1

echo
echo "═══ ④ RTL 往返自检：FNTT → INTT 是否回到原值 ═══"
# 用 RTL 的 FNTT 把时域向量变到 NTT 域，再把结果灌回 RTL 的 INTT，
# 期望原样返回。这一路完全不经过 C 参考实现。
#
# 这里编译的是 fntt_batch_tb_dump.v —— 与 fntt_batch_tb.v 逻辑完全相同，
# 只是多支持一个 +dump=1 开关，把 RTL 实际吐出的系数落盘。
# 没有它就只能拿到"是否通过"，拿不到 RTL 的真实输出，往返自检无从谈起。
iverilog -g2012 -o batch_fntt_dump.vvp $SRC pe1/fntt_batch_tb_dump.v

# 第 1 趟：时域向量 → RTL FNTT（边跑边 dump）→ 同时对照 ntt_out.hex
#
# ⚠️ 落盘用 tr 去 CR，**不要用 cp**（KNOWN_ISSUES.md B3，C 报的）：
#    $KAT 那两个 .hex 本身是 CRLF（各 4096 个 CR），而 batch/ntt_batch_{in,exp}.txt
#    是**已入库**的文件；兄弟脚本 run_fntt_check.sh:68-70 用 python "wb" 写**同一对**
#    文件、落的是 LF。cp 原样拷字节 → 把入库的 LF 盖成 CRLF，跑完 git status 冒黄字。
#    数值不受影响（内容逐字节相同），脏的是工作区 —— 所以这条只在「跑完整条链」时才现形。
tr -d '\r' < "$KAT/ntt_in.hex"  > batch/ntt_batch_in.txt
tr -d '\r' < "$KAT/ntt_out.hex" > batch/ntt_batch_exp.txt
# 这一趟 19 行输出（16 组明细 + 汇总行），照旧只显示末尾 3 行；
# 但**判定用的是完整日志** $_VVP_LOG，不是被 tail 截过的三行。
_vvp_capture vvp batch_fntt_dump.vvp +dump=1 || exit 1
printf '%s\n' "$_VVP_LOG" | tail -3 | sed 's/^/  FNTT: /'
vvp_verdict_batch "FNTT（往返第 1 趟）" 16 "$_VVP_LOG" || exit 1

if [ ! -s batch/fntt_rtl_out.txt ]; then
    echo "  ❌ batch/fntt_rtl_out.txt 没生成，往返自检无法继续"
    exit 1
fi

# 第 2 趟：把 RTL 的 FNTT **输出**灌进 RTL 的 INTT，期望回到时域原值。
# 这是真正的往返性质：x --FNTT--> NTT(x) --INTT--> x，不依赖任何标定因子。
python - <<'PY'
import sys
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
# 注意：dump 是 testbench 用 $fdisplay 写的，Windows 下带 CRLF —— 这里是
# 唯一的例外，因为写它的是仿真器不是本仓库的脚本。下面的 .strip() 会吃掉
# \r，但别把这份文件直接拿去 diff（见 CLAUDE.md 约定 1）。
rd = lambda p: [l.strip() for l in open(p) if l.strip()]

fwd = rd("batch/fntt_rtl_out.txt")                 # RTL 实际产出的 NTT 域系数
orig = rd("../research/mlkem_kat/ntt_in.hex")      # 对应的时域原值

if len(fwd) != len(orig):
    print("  ❌ dump 行数 %d != 原值行数 %d" % (len(fwd), len(orig)))
    sys.exit(1)

# 期望：原样返回（RTL 的 INTT 是精确逆变换，实测输出即原值）
open("batch/intt_batch_in.txt", "wb").write(("\n".join(fwd) + "\n").encode())
open("batch/intt_batch_exp.txt", "wb").write(("\n".join(orig) + "\n").encode())
print("  INTT 输入 = RTL FNTT 的输出（%d 个），期望原样回到时域值" % len(fwd))
PY
_vvp_capture vvp batch_intt.vvp || exit 1
printf '%s\n' "$_VVP_LOG" | tail -2 | sed 's/^/  INTT: /'
vvp_verdict_batch "INTT（往返第 2 趟）" 16 "$_VVP_LOG" || exit 1
echo "  ⚠️  这一步覆盖了 batch/intt_batch_in.txt。重跑本脚本时 ① 会重新生成它。"

echo
echo "═══ 完成 ═══"
echo "  ② INTT 16 组 · ③ PWM2 16 组 · ④ 往返自检 —— 全部通过才算数"
