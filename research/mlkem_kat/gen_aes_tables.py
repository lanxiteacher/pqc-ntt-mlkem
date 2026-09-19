"""
生成 AES-256 需要的 S-box 表，写成 C 头文件。
用 GF(2^8) 求逆 + 仿射变换算出来，不手打表格，避免转录错误。
运行：PYTHONIOENCODING=utf-8 python gen_aes_tables.py
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

def gmul(a, b):
    """GF(2^8) 乘法，模 x^8+x^4+x^3+x+1 (0x11b)"""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p

def gpow(a, n):
    r = 1
    for _ in range(n):
        r = gmul(r, a)
    return r

def rotl8(x, n):
    return ((x << n) | (x >> (8 - n))) & 0xFF

# --- 构造 S-box：先求乘法逆元（0 映射到 0），再做仿射变换 ---
sbox = []
for i in range(256):
    inv = 0 if i == 0 else gpow(i, 254)     # a^254 = a^-1 (费马小定理)
    s = inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63
    sbox.append(s)

# --- 自检：对照 AES 规范里的已知值 ---
KNOWN = {0x00: 0x63, 0x01: 0x7C, 0x53: 0xED, 0x10: 0xCA, 0x7F: 0xD2, 0xFF: 0x16}
bad = [(k, sbox[k], v) for k, v in KNOWN.items() if sbox[k] != v]
print("S-box 已知值自检:", "全部通过 ✅" if not bad else f"失败 ❌ {bad}")
assert not bad
assert len(set(sbox)) == 256, "S-box 不是双射！"
print("S-box 双射性检查: 通过 ✅ (256 个互不相同的值)")

# --- 逆向 S-box（解密用，本工程暂不需要，但一并生成便于日后扩展） ---
inv_sbox = [0] * 256
for i, v in enumerate(sbox):
    inv_sbox[v] = i

# --- 写头文件 ---
def fmt_table(name, vals, per_line=8):
    lines = [f"static const uint8_t {name}[256] = {{"]
    for i in range(0, 256, per_line):
        row = ", ".join(f"0x{v:02x}" for v in vals[i:i + per_line])
        lines.append(f"    {row},")
    lines.append("};")
    return "\n".join(lines)

out = f"""/* ===========================================================================
 * aes_tables.h —— AES S-box 表（由 gen_aes_tables.py 生成，勿手改）
 *
 * 生成方式：GF(2^8) 上求乘法逆元（a^254）+ 仿射变换，已对照 AES 规范自检通过。
 * 用途：替换 rng.c 里的 OpenSSL 依赖，使 NIST CTR_DRBG 可独立编译。
 * =========================================================================== */

#ifndef AES_TABLES_H
#define AES_TABLES_H

#include <stdint.h>

{fmt_table("aes_sbox", sbox)}

{fmt_table("aes_inv_sbox", inv_sbox)}

#endif /* AES_TABLES_H */
"""
with open("aes_tables.h", "w", encoding="utf-8") as f:
    f.write(out)
print(f"\n已写出 aes_tables.h ({len(out)} 字节)")
print(f"前 8 项: {[hex(x) for x in sbox[:8]]}")
print(f"末 2 项: {[hex(x) for x in sbox[-2:]]}")
