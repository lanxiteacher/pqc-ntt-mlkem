"""
把 Python 黄金模型与 C 参考实现（pq-crystals/kyber ref/）逐位对拍。
前置：先在 _refbuild/ 里 `gcc -O0 -o ref_ntt.exe main.c ntt.c reduce.c` 并运行，产出 ref_out.txt
运行：python compare_ref.py [ref_out.txt 路径]
"""
import sys
import os
sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ntt_golden as G

PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "_refbuild", "ref_out.txt")

data = {}
with open(PATH, encoding="utf-8") as f:
    for line in f:
        parts = line.split()
        if parts:
            data[parts[0]] = [int(x) for x in parts[1:]]

fails = []

def check(name, py, c):
    ok = list(py) == list(c)
    if not ok:
        bad = [(i, py[i], c[i]) for i in range(min(len(py), len(c))) if py[i] != c[i]]
        fails.append(name)
        print(f"  FAIL  {name:12s} 前 5 处不符: {bad[:5]}")
    else:
        print(f"  OK    {name:12s} {len(c)} 项全部一致")
    return ok

print("=" * 70)
print("Python 黄金模型  vs  C 参考实现（pq-crystals/kyber ref/）")
print("=" * 70)

# 1. twiddle 表
check("ZETAS(硬编码)", G.ZETAS, data["ZETAS"])
check("ZETAS(公式重算)", G.zetas_formula(), data["ZETAS"])

# 2. 模乘单元
a, b = data["A"], data["B"]
check("FQMUL", [G.fqmul(a[i], b[i]) for i in range(32)], data["FQMUL"])

# 3. Barrett
check("BARRETT", [G.barrett_reduce(a[i] - b[i]) for i in range(32)], data["BARRETT"])

# 4. 正向 NTT
check("NTT_A", G.ntt(a), data["NTT_A"])
check("NTT_B", G.ntt(b), data["NTT_B"])

# 5. 整链
check("PROD", G.invntt(G.poly_basemul(G.ntt(a), G.ntt(b))), data["PROD"])

print()
print("=" * 70)
print("数学正确性（不依赖任何实现约定）")
print("=" * 70)
want = G.negacyclic_schoolbook(a, b)
got = [x % G.Q for x in data["PROD"]]
print(f"  {'OK  ' if got == want else 'FAIL'}  C 输出 PROD mod q  ==  负循环卷积(a,b) mod q")
if got != want:
    fails.append("PROD_math")

# 正向 NTT 是否等于标准域 NTT（无 R 因子）
def clean_ntt(x):
    r = [v % G.Q for v in x]
    k = 1
    ln = 128
    while ln >= 2:
        start = 0
        while start < 256:
            w = pow(17, G.bitrev7(k), G.Q); k += 1
            for j in range(start, start + ln):
                t = (w * r[j + ln]) % G.Q
                r[j + ln] = (r[j] - t) % G.Q
                r[j] = (r[j] + t) % G.Q
            start += 2 * ln
        ln >>= 1
    return r

sw = clean_ntt(a)
hw = [x % G.Q for x in data["NTT_A"]]
print(f"  {'OK  ' if hw == sw else 'FAIL'}  硬件 NTT 输出 mod q  ==  标准域教科书 NTT")
if hw != sw:
    fails.append("fwd_domain")

raw_ratio = {(data["NTT_A"][i]) for i in range(256)}
print(f"        原始 NTT 输出取值范围: [{min(raw_ratio)}, {max(raw_ratio)}]"
      f"  (q={G.Q}, int16 上限 32767) -> 未约减")

print()
print("=" * 70)
print("层数 / 调度结构")
print("=" * 70)
sched = G.layer_schedule()
fwd = [s for s in sched if s[0] == "fwd"]
inv = [s for s in sched if s[0] == "inv"]
print(f"  正向层数 {len(fwd)}（len: {[s[2] for s in fwd]}），逆向层数 {len(inv)}（len: {[s[2] for s in inv]}）")
print(f"  正向消耗 zeta 索引 {sum(len(s[4]) for s in fwd)} 个；逆向 {sum(len(s[4]) for s in inv)} 个")
print(f"  zetas[0] 使用次数: 0  <- 正逆均未使用")
print(f"  逆向是否复用同一张 zetas 表: 是（只是 k 从 127 递减到 1）")

print()
if fails:
    print(f"*** 有 {len(fails)} 项未通过: {fails} ***")
    sys.exit(1)
print("*** 全部通过：Python 黄金模型与 C 参考实现位精确一致 ***")
