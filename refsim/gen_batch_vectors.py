# -*- coding: utf-8 -*-
"""
gen_batch_vectors.py —— 生成 INTT / PWM2 的批量对拍向量

背景：RTL 的域约定和 C 参考实现**不同**，直接拿参考实现的输出当期望值会得到
"256 个系数全错"的假失败。本脚本把两个约定差异显式写出来：

  ┌────────┬──────────────┬──────────────────────────────────────┐
  │ 运算   │ RTL 输入域   │ RTL 输出 与 参考实现的关系            │
  ├────────┼──────────────┼──────────────────────────────────────┤
  │ INTT   │ NTT 域       │ RTL = poly_invntt_tomont(x) × R^-1   │
  │        │              │     （即"真逆变换"，无 tomont 缩放）  │
  │ PWM2   │ NTT 域       │ RTL = poly_basemul_montgomery × R    │
  │        │              │     （即"少一级 Montgomery 归约"）    │
  └────────┴──────────────┴──────────────────────────────────────┘

  R = 2^16 mod q = 2285

这两个因子都是**反推得到并交叉验证过**的，不是猜的：
  · INTT：作者自带 testbench 断言 INTT(KYBER_DIN0_MFNTT) == KYBER_DIN0，
          即真逆；拿参考实现复算后比值恒为 R^-1（256/256 系数一致）。
  · PWM2：跑作者自带 PWM2 testbench 并 dump 其 RTL 输出，与参考实现 basemul
          逐系数比，比值恒为 R（256/256 系数一致）。

用法（在 refsim/ 下）：
    python gen_batch_vectors.py
"""

import os
import subprocess
import sys

# Windows 上 Python 默认用 GBK 编码控制台，本脚本的 ✅ 等字符会直接报
# UnicodeEncodeError 而不是打印失败提示。显式切到 UTF-8。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

Q = 3329
N = 256          # 多项式系数个数
NV = 16          # 向量组数
R = pow(2, 16, Q)          # = 2285
RINV = pow(R, -1, Q)       # = 169

KAT = "../research/mlkem_kat"
BATCH = "batch"
SCRATCH_IN  = "batch/_gen_scratch_in.txt"   # 生成器自己的中间文件，不是交付物
SCRATCH_OUT = "batch/_gen_scratch_out.txt"
SCRATCH_B   = "batch/_gen_scratch_b.txt"
SCRATCH_NTT = "batch/_gen_scratch_ntt.txt"


def rd(path):
    """读每行一个十六进制系数的文件"""
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def wr(path, lines):
    """写文本文件 —— 必须用 'wb' 强制 LF 行尾。

    Windows 文本模式会把 \\n 翻成 \\r\\n，而 RTL 测试数据是 LF。
    这个差异会让 diff 把 256 行全报成"不同"，数值却一个不差。
    """
    with open(path, "wb") as f:
        f.write(("\n".join(lines) + "\n").encode())


def run(cmd):
    # 不传 text=True：捕获的字节按 UTF-8 手工解码。
    # 交给 subprocess 自动解码的话，Windows 会用 GBK 去解工具输出的中文，
    # 在子线程里抛 UnicodeDecodeError —— 而且是以"线程异常"形式冒出，
    # 报错位置和真正原因对不上，极难排查。
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", errors="replace")
        print("  ❌ 命令失败: %s\n%s" % (" ".join(cmd), err))
        sys.exit(1)
    return r


def hexval(s):
    return int(s, 16)


def gen_intt():
    """INTT 向量：输入 = NTT 域系数；期望 = 参考实现输出 × R^-1

    关系由来（实测标定，非推导）：
        参考实现 poly_invntt_tomont(NTT(x)) = x * R      ← 比值恒为 R，256/256 系数
        RTL 的 INTT(NTT(x))                = x           ← 实测输出即原值
    ∴  RTL 输出 = 参考实现输出 × R^-1

    直觉：RTL 的 INTT 是**精确逆变换**（INTT(NTT(x)) == x，作者自带 testbench 也是
    这么断言的）；而参考实现的 poly_invntt_tomont 名字里的 _tomont 多带一级
    Montgomery 转换，所以多一个 R 因子。

    踩过的坑：曾把期望写成「输入 × R」，256 个系数全错 —— 因为输入是 NTT 域，
    「× R」那一步是拿 ntt_out 和 intt_out 比出来的，张冠李戴。
    正确关系见 run_intt_pwm2_check.sh ④ 的往返自检（不依赖任何标定因子）。
    """
    inp = rd("%s/intt_in.hex" % KAT)
    gold = rd("%s/intt_out.hex" % KAT)
    assert len(inp) == N * NV and len(gold) == N * NV
    assert inp == rd("%s/ntt_out.hex" % KAT), "intt_in 应等于 ntt_out（生成器的约定）"

    # 逐组复算，确认黄金向量本身自洽
    for v in range(NV):
        grp = inp[v * N:(v + 1) * N]
        wr(SCRATCH_IN, grp)
        run(["./ntt_once_tool.exe", SCRATCH_IN, SCRATCH_OUT, "--invntt"])
        got = [hexval(x) for x in rd(SCRATCH_OUT)]
        want = [hexval(x) for x in gold[v * N:(v + 1) * N]]
        if got != want:
            print("  ❌ INTT 向量 %d 与参考实现不符" % v)
            sys.exit(1)

    exp = ["%03x" % ((hexval(g) * RINV) % Q) for g in gold]

    # 自证：参考实现输出 × R^-1 应当正好回到时域原值（KAT 的 ntt_in.hex）
    t_in = rd("%s/ntt_in.hex" % KAT)
    assert exp == t_in, "期望值算错了：gold × R^-1 应等于 ntt_in.hex"
    # 而 RTL 输出 = 参考实现输出 × R^-1，也就是这个 exp

    wr("%s/intt_batch_in.txt" % BATCH, inp)
    wr("%s/intt_batch_exp.txt" % BATCH, exp)
    print("  ✅ INTT 向量 %d 组（输入 NTT 域，期望 = 参考实现输出 × R^-1 = 时域原值）" % NV)


def gen_pwm2():
    """PWM2 向量：输入 = NTT 域系数（A、B 同源）；期望 = basemul × R"""
    ntt_out = rd("%s/ntt_out.hex" % KAT)
    assert len(ntt_out) == N * NV

    exp = []
    for v in range(NV):
        grp = ntt_out[v * N:(v + 1) * N]
        wr(SCRATCH_IN, grp)
        run(["./basemul_nttdomain_tool.exe", SCRATCH_IN, SCRATCH_IN, SCRATCH_OUT])
        exp += ["%03x" % ((hexval(y) * R) % Q) for y in rd(SCRATCH_OUT)]

    wr("%s/pwm2_batch_a.txt" % BATCH, ntt_out)
    wr("%s/pwm2_batch_b.txt" % BATCH, ntt_out)
    wr("%s/pwm2_batch_exp.txt" % BATCH, exp)
    print("  ✅ PWM2 向量 %d 组（输入 NTT 域，期望已按 R 归一）" % NV)


def gen_polmul():
    """完整多项式乘法（时域进、时域出）—— 对应 RTL 的 ALL_FULL / ALL_HALF 通路

    FULL：A、B 都在时域  → FNTT(A) → FNTT(B) → PWM2 → INTT
    HALF：A 时域、B 在 NTT 域 → FNTT(A) → PWM2 → INTT
          （ML-KEM 里对已展开的 NTT 域密钥用的就是这种形态）

    ⭐ **这条链上没有任何缩放因子。**
       ② 标定出「RTL 点乘 = 参考实现 × R」，③ 标定出「RTL INTT = 参考实现 × R^-1」，
       串起来两个因子正好抵消，端到端与参考实现**逐比特相等**。
       这不是推导出来的，是实跑对上的 —— 也顺带反向印证了那两个因子没标错：
       若任一个错了，这里就不可能严丝合缝。

    向量来源：KAT 的 16 组时域多项式两两配对（A 取第 v 组，B 取第 v+1 组循环）。
    """
    # 先把工具链锚死：参考工具必须能复现作者自己的 KYBER_DOUT.txt
    run(["./polmul_full_tool.exe", "pe1/test_pe1/KYBER_DIN0.txt",
         "pe1/test_pe1/KYBER_DIN1.txt", SCRATCH_OUT, "--full"])
    got = rd(SCRATCH_OUT)
    want = rd("pe1/test_pe1/KYBER_DOUT.txt")
    if got != want:
        print("  ❌ 参考工具复现不了作者的 KYBER_DOUT.txt —— 工具本身有问题，先查它")
        sys.exit(1)
    run(["./polmul_full_tool.exe", "pe1/test_pe1/KYBER_DIN0.txt",
         "pe1/test_pe1/KYBER_DIN1_MFNTT.txt", SCRATCH_OUT, "--half"])
    if rd(SCRATCH_OUT) != want:
        print("  ❌ --half 复现不了 KYBER_DOUT.txt")
        sys.exit(1)

    t = rd("%s/ntt_in.hex" % KAT)          # 16 组时域多项式
    assert len(t) == N * NV

    fa, fb, fe = [], [], []                # FULL
    ha, hb, he = [], [], []                # HALF
    for v in range(NV):
        a = t[v * N:(v + 1) * N]
        # 配对的 B 取下一组（最后一组绕回第 0 组）。
        # 注意别写成 t[((v+1)%NV)*N : ((v+2)%NV)*N] —— v = NV-2 时上界回绕成 0，
        # 切片变成空区间，是个只在最后一组才炸的坑。先算出下标再切。
        j = (v + 1) % NV
        b = t[j * N:(j + 1) * N]

        wr(SCRATCH_IN, a)
        wr(SCRATCH_B, b)

        run(["./polmul_full_tool.exe", SCRATCH_IN, SCRATCH_B, SCRATCH_OUT, "--full"])
        fa += a
        fb += b
        fe += rd(SCRATCH_OUT)

        # HALF：B 先转到 NTT 域，再做 --half
        run(["./ntt_once_tool.exe", SCRATCH_B, SCRATCH_NTT, "--ntt"])
        b_ntt = rd(SCRATCH_NTT)
        run(["./polmul_full_tool.exe", SCRATCH_IN, SCRATCH_NTT, SCRATCH_OUT, "--half"])
        ha += a
        hb += b_ntt
        he += rd(SCRATCH_OUT)

    wr("%s/fullmul_a.txt" % BATCH, fa)
    wr("%s/fullmul_b.txt" % BATCH, fb)
    wr("%s/fullmul_exp.txt" % BATCH, fe)
    wr("%s/halfmul_a.txt" % BATCH, ha)
    wr("%s/halfmul_b.txt" % BATCH, hb)
    wr("%s/halfmul_exp.txt" % BATCH, he)
    print("  ✅ 完整乘法向量 %d 组 × 2（FULL / HALF，参考工具已复现作者的 KYBER_DOUT.txt）" % NV)


def check_nondegenerate():
    """非退化检查 —— "通过"必须配"非退化"才作数。

    向量若全是 0 或常量，"256/256 全中"可能只是巧合。
    """
    print("\n非退化检查：")
    for name in ("intt_batch_in", "intt_batch_exp", "pwm2_batch_a", "pwm2_batch_exp",
                 "fullmul_a", "fullmul_b", "fullmul_exp",
                 "halfmul_a", "halfmul_b", "halfmul_exp"):
        vals = rd("%s/%s.txt" % (BATCH, name))
        uniq = len(set(vals))
        top = max(vals.count(x) for x in set(vals))
        flag = "✅" if uniq > 1000 and top < len(vals) * 0.01 else "❌"
        print("  %s %-18s 行数=%-5d 不同值=%-5d 最常见占比=%.2f%%"
              % (flag, name, len(vals), uniq, 100.0 * top / len(vals)))


if __name__ == "__main__":
    os.makedirs(BATCH, exist_ok=True)
    print("生成批量对拍向量：")
    gen_intt()
    gen_pwm2()
    gen_polmul()
    check_nondegenerate()
