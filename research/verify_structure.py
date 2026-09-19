"""
验证 Kyber NTT 的结构性事实：为什么只有 7 层（不完整 NTT）、为什么需要 basemul。
运行：python verify_structure.py
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import ntt_golden as G

Q = G.Q
N = 256
ZETA = 17

def v2(x):
    """2-adic 赋值"""
    c = 0
    while x % 2 == 0:
        x //= 2; c += 1
    return c

def legendre(a):
    r = pow(a % Q, (Q - 1) // 2, Q)
    return -1 if r == Q - 1 else r

print("=" * 70)
print("1. 为什么只有 7 层？—— 从 q-1 的 2-adic 赋值推")
print("=" * 70)
print(f"  q              = {Q}")
print(f"  q - 1          = {Q-1}")
print(f"  q - 1 分解      = 2^{v2(Q-1)} × {(Q-1) >> v2(Q-1)}")
print(f"  2 的幂次部分    = 2^{v2(Q-1)} = {2**v2(Q-1)}")
print(f"  负循环卷积长度 n = {N}，需要 n 次单位根 -> 2^{v2(Q-1)} >= {N} ? {2**v2(Q-1) >= N}")
print(f"  完整分裂需要 2n = {2*N} 次单位根 -> 2^{v2(Q-1)} >= {2*N} ? {2**v2(Q-1) >= 2*N}")
print()
print(f"  结论: q-1 只含 2^8，够做 {N} 点变换，不够做 512 次单位根")
print(f"        -> X^{N}+1 无法完全分解成 {N} 个一次因子")
print(f"        -> 只能分解成 {N//2} 个二次因子 X^2 - zeta^(2i+1)")
print(f"        -> NTT 只做 log2({N//2}) = {(N//2).bit_length()-1} 层  <-- 这就是「不完整 NTT」")

print()
print("=" * 70)
print("2. 逐个验证上面每条断言")
print("=" * 70)
print(f"  17 是 mod q 的本原 256 次单位根 ? 17^256={pow(17,256,Q)}, 17^128={pow(17,128,Q)}"
      f"  -> {'是' if pow(17,256,Q)==1 and pow(17,128,Q)==Q-1 else '否'}")

# x^256 = -1 是否有解
k, g = 256, __import__("math").gcd(256, Q - 1)
solvable = pow(Q - 1, (Q - 1) // g, Q) == 1
print(f"  方程 x^256 = -1 (mod q) 有解 ? {solvable}   (gcd(256,q-1)={g}, 判据 (-1)^((q-1)/g)=(-1)^{(Q-1)//g}={(-1)**((Q-1)//g)})")
print(f"    -> {'存在' if solvable else '不存在'}本原 512 次单位根，所以二次因子不可再分")

# 128 个 zeta^(2i+1) 互不相同且都是非二次剩余
roots = [pow(ZETA, 2 * i + 1, Q) for i in range(128)]
print(f"  zeta^(2i+1) 共 {len(set(roots))} 个互不相同的值（应 128）")
leg = {legendre(r) for r in roots}
print(f"  这些值的 Legendre 符号集合 = {leg}  -> 全为 -1 表示 X^2 - zeta^(2i+1) 在 Z_q 上不可约")
print(f"  -> 二次因子确实不可再分，{N//2} 个因子两两互素")

# 分解恒等式数值验证：随机取 x，验证 prod (x^2 - r_i) == x^256 + 1
import random
random.seed(1)
ok = True
for _ in range(30):
    x = random.randrange(Q)
    lhs = 1
    for r in roots:
        lhs = (lhs * ((x * x - r) % Q)) % Q
    if lhs != (pow(x, 256, Q) + 1) % Q:
        ok = False; break
print(f"  数值验证: prod_i (x^2 - zeta^(2i+1)) == x^256 + 1 (mod q)  ? {ok}")

print()
print("=" * 70)
print("3. 层数与规模")
print("=" * 70)
print(f"  层数        = 7   (2^7 = 128)")
print(f"  每层蝶形数   = 128 (共 128×7 = 896 个蝶形)")
print(f"  每个蝶形     = 1 次模乘 + 1 次模加 + 1 次模减")
print(f"  正向模乘总数 = 896")
print(f"  逆向模乘总数 = 896 + 256(末尾统一缩放 f=1441) = 1152")
print(f"  basemul 逐点乘 = 64 组 × 2 = 128 次 basemul，每次 5 次模乘 = 640 次模乘")

print()
print("=" * 70)
print("4. basemul 的索引规则（来自 ref/poly.c，已核对）")
print("=" * 70)
print("  for i in 0..63:")
print("      basemul(r[4i..4i+1], a[4i..4i+1], b[4i..4i+1],  zetas[64+i])")
print("      basemul(r[4i+2..4i+3], a[4i+2..4i+3], b[4i+2..4i+3], -zetas[64+i])")
print("  -> 只用 zetas[64..127] 这一段，且成对取相反数")
print()
print("  验证最后一项: zetas[127] =", G.ZETAS[127], "  -zetas[127] =", -G.ZETAS[127])
