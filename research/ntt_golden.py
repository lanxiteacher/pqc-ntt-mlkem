"""
ML-KEM (CRYSTALS-Kyber) NTT 黄金模型 —— 与 pq-crystals/kyber ref/ 位精确对齐

设计原则（重要，别改）：
  * 逐位复刻 C 的 int16_t / int32_t 截断语义与算术右移，不做"干净的数学实现"
  * zetas 表直接取自 ref/ntt.c 的硬编码值，同时提供公式 zetas[i]=centered(R*17^bitrev7(i) mod q)
  * 所有函数纯函数，无全局状态，可安全 import

已验证（见 compare_ref.py）：本模块输出与 C 参考实现 bit 级一致。
"""

Q = 3329
N = 256
R = 1 << 16                 # 65536
MONT_SIGNED = -1044         # ref/reduce.h: #define MONT -1044   (== 2285 mod q)
QINV_SIGNED = -3327         # ref/reduce.h: #define QINV -3327   (== 62209 mod 2^16)
F_INVNTT = 1441             # ref/ntt.c:  const int16_t f = 1441;  // mont^2/128
BARRETT_V = ((1 << 26) + Q // 2) // Q     # = 20159
R2_MOD_Q = (R * R) % Q                    # = 1353, poly_tomont 用


# ---------- C 整数语义 ----------
def i16(x):
    """模拟 C 的 (int16_t) 强制转换"""
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x


def i32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x >= 0x80000000 else x


def centered(x):
    """取 [-q/2, q/2] 中心化代表"""
    x %= Q
    if x > Q // 2:
        x -= Q
    if x < -Q // 2:
        x += Q
    return x


# ---------- 模约减（逐行复刻 ref/reduce.c） ----------
def montgomery_reduce(a):
    """input: int32, 输出 int16，值 ≡ a * R^-1 mod q"""
    t = i16(i16(a) * QINV_SIGNED)
    t = i32(a - i32(t * Q))
    return i16(t >> 16)


def barrett_reduce(a):
    """输出带中心化代表的 int16，值 ≡ a mod q"""
    t = (BARRETT_V * i16(a) + (1 << 25)) >> 26
    t = i16(t) * Q
    return i16(i16(a) - t)


def fqmul(a, b):
    """a*b*R^-1 mod q"""
    return montgomery_reduce(a * b)


def tomont(x):
    """乘 R（等价 ref/poly.c 的 poly_tomont）"""
    return montgomery_reduce(x * R2_MOD_Q)


# ---------- twiddle 表 ----------
def bitrev7(x):
    return int(format(x, "07b")[::-1], 2)


TREE = [bitrev7(i) for i in range(128)]     # 与原文件硬编码 tree[] 逐项一致（已验证）

ZETAS = [
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


def zetas_formula():
    """独立重算整张 zetas 表：zetas[i] = centered(R * 17^bitrev7(i) mod q)"""
    return [centered((R * pow(17, bitrev7(i), Q)) % Q) for i in range(128)]


# ---------- NTT / INTT ----------
def ntt(r):
    """正向 NTT（Cooley-Tukey / DIT），原地，输入自然序、输出位反转序。
    输出未做 Barrett 约减，位宽可超出 int16 -> 需 poly_reduce（见下游）。"""
    r = list(r)
    k = 1
    ln = 128
    while ln >= 2:
        start = 0
        while start < 256:
            zeta = ZETAS[k]; k += 1
            for j in range(start, start + ln):
                t = fqmul(zeta, r[j + ln])
                r[j + ln] = i16(r[j] - t)
                r[j] = i16(r[j] + t)
            start += 2 * ln
        ln >>= 1
    return r


def invntt(r):
    """逆向 NTT（Gentleman-Sande / DIF）+ 乘 R（即 invntt_tomont）。
    输入位反转序、输出自然序。末尾统一乘 f=1441。"""
    r = list(r)
    k = 127
    ln = 2
    while ln <= 128:
        start = 0
        while start < 256:
            zeta = ZETAS[k]; k -= 1
            for j in range(start, start + ln):
                t = r[j]
                r[j] = barrett_reduce(i16(t + r[j + ln]))
                r[j + ln] = i16(r[j + ln] - t)
                r[j + ln] = fqmul(zeta, r[j + ln])
            start += 2 * ln
        ln <<= 1
    return [fqmul(x, F_INVNTT) for x in r]


def basemul(a0, a1, b0, b1, zeta):
    """Zq[X]/(X^2 - zeta) 上的乘法，输出 2 个系数"""
    r0 = fqmul(fqmul(a1, b1), zeta)
    r0 = i16(r0 + fqmul(a0, b0))
    r1 = i16(fqmul(a0, b1) + fqmul(a1, b0))
    return r0, r1


def poly_basemul(a, b):
    """NTT 域上两个多项式的逐点乘，复刻 ref/poly.c poly_basemul_montgomery"""
    r = [0] * 256
    for i in range(64):
        z = ZETAS[64 + i]
        r[4 * i], r[4 * i + 1] = basemul(a[4 * i], a[4 * i + 1],
                                         b[4 * i], b[4 * i + 1], z)
        r[4 * i + 2], r[4 * i + 3] = basemul(a[4 * i + 2], a[4 * i + 3],
                                             b[4 * i + 2], b[4 * i + 3], -z)
    return r


def poly_mul(a, b):
    """端到端多项式乘法（负循环卷积 mod q）。整条链路净缩放 = 1，无需后处理。"""
    return [x % Q for x in invntt(poly_basemul(ntt(a), ntt(b)))]


def negacyclic_schoolbook(a, b):
    """教科书负循环卷积 mod q —— 数学上唯一确定的判据，不依赖任何实现约定"""
    c = [0] * 256
    for i in range(256):
        ai = a[i]
        if ai == 0:
            continue
        for j in range(256):
            k = i + j
            if k < 256:
                c[k] += ai * b[j]
            else:
                c[k - 256] -= ai * b[j]
    return [x % Q for x in c]


# ---------- 逐层 twiddle 调度（写 RTL 直接照抄） ----------
def layer_schedule():
    """返回 [(方向, 层号, len, 本层块数, zeta 索引列表), ...]"""
    out = []
    k = 1
    for layer, ln in enumerate([128, 64, 32, 16, 8, 4, 2]):
        nb = 256 // (2 * ln)
        out.append(("fwd", layer, ln, nb, list(range(k, k + nb))))
        k += nb
    k = 127
    for layer, ln in enumerate([2, 4, 8, 16, 32, 64, 128]):
        nb = 256 // (2 * ln)
        out.append(("inv", layer, ln, nb, list(range(k, k - nb, -1))))
        k -= nb
    return out
