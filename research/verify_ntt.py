"""
ML-KEM (CRYSTALS-Kyber) NTT —— 黄金模型 + 常数全量验证
逐位复刻 pq-crystals/kyber ref/ 的 C 语义（int16/int32 截断、算术右移）。

用途：
  1. 验证指导文档里所有常数
  2. 由 tree[] 反解 zetas 生成公式（硬件可据此重算整张表）
  3. 输出逐层 twiddle 索引调度表（写 RTL 时直接照抄）
  4. 黄金模型自检：INTT(NTT(a) ⊙ NTT(b)) == 负循环卷积
运行：python verify_ntt.py
"""

import sys
sys.stdout.reconfigure(encoding="utf-8")   # 避免 Windows 控制台 GBK 乱码

Q = 3329
N = 256
R = 1 << 16  # 65536

# ---------- C 整数语义模拟 ----------
def i16(x):
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x

def i32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x >= 0x80000000 else x

MONT_SIGNED = -1044     # reduce.h: #define MONT -1044
QINV_SIGNED = -3327     # reduce.h: #define QINV -3327

def montgomery_reduce(a):
    """逐位复刻 ref/reduce.c"""
    t = i16(i16(a) * QINV_SIGNED)
    t = i32(a - i32(t * Q))
    t = t >> 16          # 算术右移
    return i16(t)

def barrett_reduce(a):
    """逐位复刻 ref/reduce.c"""
    v = ((1 << 26) + Q // 2) // Q
    t = (v * i16(a) + (1 << 25)) >> 26
    t = i16(t) * Q
    return i16(i16(a) - t)

def fqmul(a, b):
    return montgomery_reduce(a * b)

# ---------- 1. 常数验证 ----------
print("=" * 68)
print("1. 常数验证")
print("=" * 68)
checks = [
    ("R = 2^16",                    R,                     65536),
    ("MONT 无符号 = R mod q",        R % Q,                 2285),
    ("MONT 有符号 (reduce.h)",       MONT_SIGNED,           -1044),
    ("QINV 无符号 = q^-1 mod 2^16", 62209,                 62209),
    ("QINV 有符号 (reduce.h)",       QINV_SIGNED,           -3327),
    ("Barrett v",                   ((1 << 26) + Q // 2) // Q, 20159),
    ("f = R^2/128 mod q",           (R * R // 128) % Q if (R*R) % 128 == 0 else pow(128, -1, Q) * (R * R % Q) % Q, 1441),
    ("R^2 mod q",                   (R * R) % Q,           1353),
]
for name, got, want in checks:
    print(f"  {'OK ' if got == want else 'FAIL'}  {name:32s} = {got:>8}  (文档值 {want})")

print(f"\n  同余性: MONT 有符号≡无符号 ? {MONT_SIGNED % Q == 2285 % Q}")
print(f"  同余性: QINV 有符号≡无符号 ? {QINV_SIGNED % R == 62209 % R}")
print(f"  q*QINV mod 2^16 = {(Q * QINV_SIGNED) % R}   (应为 1)")
print(f"  17 是 mod 3329 的本原 256 次单位根 ? {pow(17, 256, Q) == 1 and pow(17, 128, Q) != 1}")
print(f"  f=1441 校验: 128*1441 mod q = {(128 * 1441) % Q}, R^2 mod q = {(R*R) % Q}  (应相等)")

# ---------- 2. 由 tree[] 反解 zetas 生成公式 ----------
print()
print("=" * 68)
print("2. zetas 生成公式反解")
print("=" * 68)
TREE = [
    0, 64, 32, 96, 16, 80, 48, 112, 8, 72, 40, 104, 24, 88, 56, 120,
    4, 68, 36, 100, 20, 84, 52, 116, 12, 76, 44, 108, 28, 92, 60, 124,
    2, 66, 34, 98, 18, 82, 50, 114, 10, 74, 42, 106, 26, 90, 58, 122,
    6, 70, 38, 102, 22, 86, 54, 118, 14, 78, 46, 110, 30, 94, 62, 126,
    1, 65, 33, 97, 17, 81, 49, 113, 9, 73, 41, 105, 25, 89, 57, 121,
    5, 69, 37, 101, 21, 85, 53, 117, 13, 77, 45, 109, 29, 93, 61, 125,
    3, 67, 35, 99, 19, 83, 51, 115, 11, 75, 43, 107, 27, 91, 59, 123,
    7, 71, 39, 103, 23, 87, 55, 119, 15, 79, 47, 111, 31, 95, 63, 127,
]
def bitrev7(x):
    return int(format(x, "07b")[::-1], 2)

tree_is_bitrev = all(TREE[i] == bitrev7(i) for i in range(128))
print(f"  tree[i] == bitrev7(i) ?  {tree_is_bitrev}   <-- 若 True，整张表可用一条公式重算")

# 用 ref 的 init_ntt() 逐行复刻生成 zetas
tmp = [0] * 128
tmp[0] = MONT_SIGNED
root_step = i16((MONT_SIGNED * 17) % Q)   # MONT*KYBER_ROOT_OF_UNITY % KYBER_Q
for i in range(1, 128):
    tmp[i] = fqmul(tmp[i - 1], root_step)

def centered(x):
    x %= Q
    if x > Q // 2:  x -= Q
    if x < -Q // 2: x += Q
    return x

zetas_gen = [centered(tmp[TREE[i]]) for i in range(128)]

ZETAS_HARDCODED = [
    -1044, -758, -359, -1517, 1493, 1422, 287, 202,
    -171, 622, 1577, 182, 962, -1202, -1474, 1468,
    573, -1325, 264, 383, -829, 1458, -1602, -130,
    -681, 1017, 732, 608, -1542, 411, -205, -1571,
    1223, 652, -552, 1015, -1293, 1491, -282, -1544,
    516, -8, -320, -666, -1618, -1162, 126, 1469,
    -853, -90, -271, 830, 107, -1421, -247, -951,
    -398, 961, -1508, -725, 448, -1065, 677, -1275,
    -1103, 430, 555, 843, -1251, 871, 1550, 105,
    422, 587, 177, -235, -291, -460, 1574, 1653,
    -246, 778, 1159, -147, -777, 1483, -602, 1119,
    -1590, 644, -872, 349, 418, 329, -156, -75,
    817, 1097, 603, 610, 1322, -1285, -1465, 384,
    -1215, -136, 1218, -1335, -874, 220, -1187, -1659,
    -1185, -1530, -1278, 794, -1510, -854, -870, 478,
    -108, -308, 996, 991, 958, -1460, 1522, 1628,
]
match = zetas_gen == ZETAS_HARDCODED
print(f"  由公式生成的 128 项 == 源码硬编码表 ?  {match}")
if not match:
    for i, (a, b) in enumerate(zip(zetas_gen, ZETAS_HARDCODED)):
        if a != b:
            print(f"    [{i}] 生成={a} 源码={b}")
    raise SystemExit("zetas 生成公式不匹配，后续验证终止")

# 独立核验公式：zetas[i] ≡ R * 17^bitrev7(i) (mod q)
formula_ok = all(centered((R * pow(17, bitrev7(i), Q)) % Q) == ZETAS_HARDCODED[i]
                 for i in range(128))
print(f"  独立核验 zetas[i] = centered(R * 17^bitrev7(i) mod q) ?  {formula_ok}")

# ---------- 3. 逐层 twiddle 索引调度表（写 RTL 直接照抄） ----------
print()
print("=" * 68)
print("3. 逐层 twiddle 索引调度表")
print("=" * 68)
print("\n  正向 NTT (Cooley-Tukey / DIT)，k 从 1 升到 127：")
print(f"  {'层':>3} {'len':>5} {'本层蝶形数':>10} {'zetas 索引用到':>20} {'个数':>5}")
LAYERS = []
k = 1
for layer, ln in enumerate([128, 64, 32, 16, 8, 4, 2]):
    nblk = 256 // (2 * ln)
    idx = list(range(k, k + nblk))
    LAYERS.append(("fwd", layer, ln, nblk, idx))
    rng = f"zetas[{idx[0]}..{idx[-1]}]" if nblk > 1 else f"zetas[{idx[0]}]"
    print(f"  {layer:>3} {ln:>5} {nblk:>10} {rng:>20} {len(idx):>5}")
    k += nblk
print(f"  合计消耗 {k-1} 个 -> zetas[1..127]；zetas[0] 正向未使用")

print("\n  逆向 NTT (Gentleman-Sande / DIF)，k 从 127 降到 1：")
k = 127
for layer, ln in enumerate([2, 4, 8, 16, 32, 64, 128]):
    nblk = 256 // (2 * ln)
    idx = list(range(k, k - nblk, -1))
    LAYERS.append(("inv", layer, ln, nblk, idx))
    rng = f"zetas[{idx[0]}..{idx[-1]}]" if len(idx) > 1 else f"zetas[{idx[0]}]"
    print(f"  {layer:>3} {ln:>5} {nblk:>10} {rng:>20} {len(idx):>5}")
    k -= nblk
print(f"  合计消耗 127 个 -> zetas[127..1]；zetas[0] 逆向也未使用")
print("\n  *** 关键结论：当前 ref 只有一张 zetas[128]，正逆共用，逆向只是反向遍历 ***")
print("  *** 不存在单独的 zetas_inv 表 ***")

# ---------- 4. 黄金模型 ----------
def ntt(r):
    r = list(r)
    k = 1
    ln = 128
    while ln >= 2:
        start = 0
        while start < 256:
            zeta = ZETAS_HARDCODED[k]; k += 1
            for j in range(start, start + ln):
                t = fqmul(zeta, r[j + ln])
                r[j + ln] = i16(r[j] - t)
                r[j] = i16(r[j] + t)
            start = start + 2 * ln
        ln >>= 1
    return r

def invntt(r):
    r = list(r)
    f = 1441                      # mont^2/128
    k = 127
    ln = 2
    while ln <= 128:
        start = 0
        while start < 256:
            zeta = ZETAS_HARDCODED[k]; k -= 1
            for j in range(start, start + ln):
                t = r[j]
                r[j] = barrett_reduce(i16(t + r[j + ln]))
                r[j + ln] = i16(r[j + ln] - t)
                r[j + ln] = fqmul(zeta, r[j + ln])
            start = start + 2 * ln
        ln <<= 1
    return [fqmul(x, f) for x in r]

def basemul(a0, a1, b0, b1, zeta):
    r0 = fqmul(fqmul(a1, b1), zeta)
    r0 = i16(r0 + fqmul(a0, b0))
    r1 = i16(fqmul(a0, b1) + fqmul(a1, b0))
    return r0, r1

def poly_basemul(a, b):
    r = [0] * 256
    for i in range(64):
        z = ZETAS_HARDCODED[64 + i]
        r[4*i], r[4*i+1]     = basemul(a[4*i],   a[4*i+1], b[4*i],   b[4*i+1],  z)
        r[4*i+2], r[4*i+3] = basemul(a[4*i+2], a[4*i+3], b[4*i+2], b[4*i+3], -z)
    return r

def negacyclic_schoolbook(a, b):
    """教科书负循环卷积 mod q —— 数学上唯一确定，不依赖任何实现约定"""
    c = [0] * 256
    for i in range(256):
        for j in range(256):
            k = i + j
            if k < 256:
                c[k] += a[i] * b[j]
            else:
                c[k - 256] -= a[i] * b[j]
    return [x % Q for x in c]

# ---------- 5. 端到端自检 ----------
print()
print("=" * 68)
print("5. 黄金模型端到端自检（随机多项式）")
print("=" * 68)
import random
random.seed(20260918)

def tomont(x):
    """乘 R：等价 poly_tomont，montgomery_reduce(x * (R^2 mod q)) = x*R^2*R^-1 = x*R"""
    return montgomery_reduce(x * ((R * R) % Q))

ok_mul = 0
TRIALS = 20
for t in range(TRIALS):
    a = [random.randrange(Q) for _ in range(256)]
    b = [random.randrange(Q) for _ in range(256)]
    prod = invntt(poly_basemul(ntt(a), ntt(b)))
    got = [x % Q for x in prod]                # 整条链路净缩放为 1，直接比
    want = negacyclic_schoolbook(a, b)
    if got == want:
        ok_mul += 1
print(f"  多项式乘法对拍 (NTT->basemul->INTT 直接 vs 负循环卷积): {ok_mul}/{TRIALS} 通过")

# ---- 精确定位每一步的缩放因子 ----
print("\n  逐级缩放因子实测（随机多项式，全部 256 点应为同一常数）:")
def clean_ntt(a):
    """标准域教科书 NTT：w = 17^bitrev7(k)，不含任何 R 因子"""
    r = [x % Q for x in a]
    k = 1
    ln = 128
    while ln >= 2:
        start = 0
        while start < 256:
            w = pow(17, bitrev7(k), Q); k += 1
            for j in range(start, start + ln):
                t = (w * r[j + ln]) % Q
                r[j + ln] = (r[j] - t) % Q
                r[j] = (r[j] + t) % Q
            start += 2 * ln
        ln >>= 1
    return r

a = [random.randrange(Q) for _ in range(256)]
b = [random.randrange(Q) for _ in range(256)]
hw_fwd = [x % Q for x in ntt(a)]
sw_fwd = clean_ntt(a)
ratios = {(hw_fwd[i] * pow(sw_fwd[i], -1, Q)) % Q for i in range(256) if sw_fwd[i] % Q != 0}
print(f"    正向 ntt(a)  / 标准NTT(a)        比值集合 = {ratios}  (R mod q = {R % Q})")

hw_inv = [x % Q for x in invntt(hw_fwd)]
ratio_inv = {(hw_inv[i] * pow(a[i] % Q, -1, Q)) % Q for i in range(256) if a[i] % Q != 0}
print(f"    逆向 invntt(ntt(a)) / a          比值集合 = {ratio_inv}")

full = [x % Q for x in invntt(poly_basemul(ntt(a), ntt(b)))]
sw_mul = negacyclic_schoolbook(a, b)
ratio_full = {(full[i] * pow(sw_mul[i], -1, Q)) % Q for i in range(256) if sw_mul[i] != 0}
print(f"    整链 invntt(basemul(...)) / a*b  比值集合 = {ratio_full}")
print(f"    整链比值的逆元 = {[pow(x, -1, Q) for x in ratio_full]}  (R mod q = {R % Q})")

# ---------- 6. 域陷阱验证 ----------
print()
print("=" * 68)
print("6. 指导文档第 3.2 节'域陷阱'的说法验证")
print("=" * 68)
x = 1234
with_fqmul = fqmul(x, 1441) % Q
plain_mul = (x * 1441) % Q
target_128 = (x * pow(128, -1, Q)) % Q
target_128_R = (x * pow(128, -1, Q) * R) % Q
print(f"  fqmul(x, 1441) mod q        = {with_fqmul}")
print(f"  x * 1441 mod q (普通模乘)   = {plain_mul}")
print(f"  x * 128^-1 mod q            = {target_128}")
print(f"  x * R * 128^-1 mod q        = {target_128_R}")
print(f"  --> fqmul 结果 == x*R*128^-1 ? {with_fqmul == target_128_R}")
print(f"  --> 文档'1441 配 fqmul 得到 x*R/128' 的说法: {'成立' if with_fqmul == target_128_R else '不成立'}")
print(f"  逆向 NTT 输出整体差一个 R 因子 (相对标准域): "
      f"{'是' if with_fqmul != target_128 else '否'}")
print("\n验证完成。")
