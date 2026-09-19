"""
用 Python 的 cryptography 库生成 AES-256-ECB 随机测试向量，
供 test_aes.c 交叉验证自研 C 实现。
运行：PYTHONIOENCODING=utf-8 python gen_testvec.py
"""
import sys, os, random
sys.stdout.reconfigure(encoding="utf-8")

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

N = 500
random.seed(20260918)

lines = []
for _ in range(N):
    key = bytes(random.randrange(256) for _ in range(32))
    pt  = bytes(random.randrange(256) for _ in range(16))
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    ct  = enc.update(pt) + enc.finalize()
    lines.append(f"{key.hex()} {pt.hex()} {ct.hex()}")

with open("testvec.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

# 顺带把 FIPS-197 C.3 也放进来做二次确认
key = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
pt  = bytes.fromhex("00112233445566778899aabbccddeeff")
enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
ct  = enc.update(pt) + enc.finalize()
print(f"已写出 testvec.txt: {N} 条随机向量")
print(f"FIPS-197 C.3 用 cryptography 库独立复算: {ct.hex()}")
print(f"  （应等于 8ea2b7ca516745bfeafc49904b496089）"
      f" {'✅' if ct.hex() == '8ea2b7ca516745bfeafc49904b496089' else '❌'}")
