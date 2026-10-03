# PQC-NTT / ML-KEM 技术资料汇编

> **用途**：ML-KEM 数论变换（NTT）FPGA 加速核的施工手册。
> **深度**：手册级——给结论、参数表、公式、索引规则、资源对比表，**不写推导**。
> **标注**：`【已验证】`= 本机实跑/源码比对确认；`【文献】`= 来自论文；`【待核实】`= 存疑。
> **生成**：2026-09-18

---

# 第一部分 · 算法本体

## 1.1 ML-KEM 全景

### 三层结构

ML-KEM（FIPS 203）不是一个算法，是**三层套娃**：

```
┌─────────────────────────────────────────────┐
│  ML-KEM（KEM，CCA 安全）                      │
│  KeyGen / Encaps / Decaps                    │
│  外层套了 FO 变换：哈希 + 重加密 + 密文校验      │
├─────────────────────────────────────────────┤
│  K-PKE（公钥加密，仅 IND-CPA 安全）            │
│  keypair / enc / dec                          │
│  真正的格运算在这里：矩阵乘 + 加解密             │
├─────────────────────────────────────────────┤
│  底层原语                                     │
│  NTT/INTT · basemul · CBD 采样 · 压缩编解码    │
│  Keccak(SHAKE-128/256, SHA3-256/512)          │
└─────────────────────────────────────────────┘
```

**关键认知**：NTT 只出现在**第二层**（K-PKE）。FO 变换那一层全是哈希，没有任何格运算。这决定了你在硬件里省不掉 Keccak——NTT 核再快，外面还包着一圈哈希。

### 参数表（ML-KEM-768 为竞赛目标）

| 参数 | ML-KEM-512 | **ML-KEM-768** | ML-KEM-1024 |
|---|---|---|---|
| 模块秩 `k` | 2 | **3** | 4 |
| 多项式次数 `n` | 256 | **256** | 256 |
| 模数 `q` | 3329 | **3329** | 3329 |
| 噪声参数 `η1` | 3 | **2** | 2 |
| 噪声参数 `η2` | 2 | **2** | 2 |
| 压缩位宽 `du` | 10 | **10** | 11 |
| 压缩位宽 `dv` | 4 | **4** | 5 |
| 公钥 `pk` | 800 B | **1184 B** | 1568 B |
| 私钥 `sk` | 1632 B | **2400 B** | 3168 B |
| 密文 `ct` | 768 B | **1088 B** | 1568 B |
| 共享密钥 `ss` | 32 B | **32 B** | 32 B |

> 768 这一列的四个长度均已与官方 KAT 文件**逐字节核对**【已验证】。

### 三个操作的流程

**KeyGen**
```
d ← 随机 32B
(ρ, σ) ← G(d ‖ k)          ← 注意这个 ‖ k，是 ML-KEM 相对 Kyber v3.0 的改动
Â ← 由 ρ 通过 SHAKE-128 采样出 k×k 个多项式（拒绝采样）
s, e ← 由 σ 通过 CBD 采样
ŝ ← NTT(s),  ê ← NTT(e)
t̂ ← Â∘ŝ + ê               ← 矩阵乘，全部在 NTT 域做
pk ← (t̂, ρ) 序列化
sk ← (ŝ, pk, H(pk), z) 序列化
```
**NTT 出现次数**：`poly_ntt` × 6，`poly_basemul` × 9

**Encaps**
```
m ← 随机 32B
(m, K̄) ← G(m ‖ H(pk))
r ← CBD 采样
r̂ ← NTT(r)
u ← INTT(Âᵀ∘r̂) + e1      ← 注意：基变换后要 INTT 回普通域再压缩
v ← INTT(t̂ᵀ∘r̂) + e2 + Decompress(m)
c ← (Compress(u), Compress(v)) 序列化
ss ← KDF(K̄ ‖ H(c))
```
**NTT 出现次数**：`poly_ntt` × 3，`poly_basemul` × 12，`poly_invntt` × 4

**Decaps**
```
ŝ ← 反序列化
u' ← Decompress + NTT              ← 又变回 NTT 域
m' ← 解码(INTT(ŝᵀ∘û) )            ← 再 INTT 回来
(m', K̄') ← G(m' ‖ H(pk))
r' ← CBD 采样; r̂' ← NTT(r')
c' ← 重加密(m', r')                 ← 重加密一遍！
K̄ ← 常数时间选择(校验 c==c' ? K̄' : ⊥)
ss ← KDF(K̄ ‖ H(c))
```
**NTT 出现次数**：`poly_ntt` × 6，`poly_basemul` × 15，`poly_invntt` × 5

> **Decaps 为什么这么贵**：为了抗选择密文攻击，它必须**把整个加密流程重跑一遍**（"重加密"）。所以 decaps ≈ dec + enc。

### 实测各阶段开销占比【已验证】

x86 平台，`-O2`，ML-KEM-768：

| 操作 | 总耗时 | NTT 家族耗时 | **NTT 占比** |
|---|---|---|---|
| KeyGen | 36.7 µs | 15.51 µs | **42.3%** |
| Encaps | 40.0 µs | 21.46 µs | **53.6%** |
| Decaps | 90.3 µs | 30.07 µs | **33.3%** |

单个原语耗时：`ntt()` 1.340 µs · `poly_ntt()` 1.445 µs · `poly_invntt()` 2.000 µs · `poly_basemul()` 0.760 µs

> **这张表是你立项的依据**：NTT 家族吃掉整条链路三分之一到一半的时间，且是**纯算术、无分支、访存规整**——最适合硬件化。剩下的 SHAKE/Keccak 虽然在 decaps 里占比更大，但它是位运算密集型，硬件化的收益曲线完全不同。

---

## 1.2 聚焦：NTT 本体

### 为什么是"不完整 NTT"【已验证】

这是理解 Kyber NTT 的**唯一关键**，必须先讲清：

```
q − 1 = 3328 = 2^8 × 13
        2 的幂次部分只有 2^8 = 256

要做 n = 256 点负循环卷积，需要 2n = 512 次单位根
        → 2^8 = 256 < 512，不存在本原 512 次单位根
        → X^256 + 1 无法分解成 256 个一次因子
        → 只能分解成 128 个不可约二次因子：X² − ζ^(2i+1)
        → NTT 只能做 log2(128) = 7 层，不是 8 层
```

**验证过的三条断言**【已验证】：
- 17 是 mod q 的本原 256 次单位根（17²⁵⁶ ≡ 1，17¹²⁸ ≡ −1）
- 方程 x²⁵⁶ = −1 (mod q) **无解**
- 128 个 ζ^(2i+1) 的 Legendre 符号**全为 −1**，即 X² − ζ^(2i+1) 全部不可约
- 数值验证：∏ᵢ (x² − ζ^(2i+1)) ≡ x²⁵⁶ + 1 (mod q) ✓

**这两个直接后果，决定了你硬件的形状：**

1. **只有 7 层**（不是教科书 NTT 的 8 层）→ 蝶形总数 128×7 = **896 个**
2. **输出是 128 个二次多项式**，不是 256 个标量 → 所以必须有 `basemul` 这个"二次域乘法"单元

### 蝶形运算与索引规则【已验证】

**正向：Cooley-Tukey（DIT）**

```c
k = 1;
for (len = 128; len >= 2; len >>= 1)          // 7 层
  for (start = 0; start < 256; start = j + len)
    for (j = start; j < start + len; j++) {
      zeta = zetas[k++];                       // 索引递增
      t = fqmul(zeta, r[j + len]);             // 1 次模乘
      r[j + len] = r[j] - t;                   // 模减
      r[j]       = r[j] + t;                   // 模加
    }
```

**逆向：Gentleman-Sande（DIF）**

```c
k = 127;
for (len = 2; len <= 128; len <<= 1)          // 7 层
  for (start = 0; start < 256; start = j + len)
    for (j = start; j < start + len; j++) {
      zeta = zetas[k--];                       // 索引递减！
      t = r[j];
      r[j]       = barrett_reduce(t + r[j + len]);
      r[j + len] = r[j + len] - t;
      r[j + len] = fqmul(zeta, r[j + len]);
    }
for (j = 0; j < 256; j++) r[j] = fqmul(r[j], 1441);   // 末尾统一缩放
```

> ⚠️ **根本不存在 `zetas_inv` 表。** 逆变换复用**同一张** `zetas[128]`，只是索引从 127 **递减**到 1。`zetas[0]` 正逆都不用。

### 逐层索引调度表（地址生成逻辑直接照抄）

| 层 | 正向 len | 块数 | zetas 索引 | 逆向 len | 块数 | zetas 索引 |
|---|---|---|---|---|---|---|
| 0 | 128 | 1 | `[1]` | 2 | 64 | `[127..64]` |
| 1 | 64 | 2 | `[2..3]` | 4 | 32 | `[63..32]` |
| 2 | 32 | 4 | `[4..7]` | 8 | 16 | `[31..16]` |
| 3 | 16 | 8 | `[8..15]` | 16 | 8 | `[15..8]` |
| 4 | 8 | 16 | `[16..31]` | 32 | 4 | `[7..4]` |
| 5 | 4 | 32 | `[32..63]` | 64 | 2 | `[3..2]` |
| 6 | 2 | 64 | `[64..127]` | 128 | 1 | `[1]` |

> 每层的块数 = 该层需要的 twiddle 个数 = 该层跨距。正向从大 len 到小 len，逆向反过来。

**★ 上表已机器验证（2026-09-18）**：`refsim/ntt_layers.c` 从 `ref/ntt.c` 原样导出层序、
按表重新实现一遍 `ntt`/`invntt`，再与参考实现的裸 `ntt()`/`invntt()` 对拍 **200 组随机输入，
逐比特完全一致**。跑：

```sh
cd ../../refsim && sh run_ntt_layers.sh
```

表里有个漂亮的对称性，写 RTL 的地址生成器时可以直接利用：
**正向第 i 层的下标区间 == 逆向第 (7−i) 层的下标区间，只是取用方向相反。**

| | 正向 | | 逆向 |
|---|---|---|---|
| L0 | `zetas[1]→[1]` ↑ | ↔ | L6 `zetas[1]→[1]` ↓ |
| L1 | `zetas[2]→[3]` ↑ | ↔ | L5 `zetas[3]→[2]` ↓ |
| L2 | `zetas[4]→[7]` ↑ | ↔ | L4 `zetas[7]→[4]` ↓ |
| L3 | `zetas[8]→[15]` ↑ | ↔ | L3 `zetas[15]→[8]` ↓ |
| L4 | `zetas[16]→[31]` ↑ | ↔ | L2 `zetas[31]→[16]` ↓ |
| L5 | `zetas[32]→[63]` ↑ | ↔ | L1 `zetas[63]→[32]` ↓ |
| L6 | `zetas[64]→[127]` ↑ | ↔ | L0 `zetas[127]→[64]` ↓ |

> ⚠️ **对拍时要分清比的是哪个函数**：`poly_ntt()` = 裸 `ntt()` **+ `poly_reduce()`**，
> 两者输出**不相等**。RTL 作者的期望输出对应的是 **`poly_ntt()`（带约减）** 那一支。

### Twiddle 表生成公式【已验证】

```
zetas[i] = centered( R · 17^bitrev7(i) mod q )
```

- `R = 2^16 = 65536`
- `centered(x)` = 取 `[−q/2, q/2]` 内的有符号代表
- `bitrev7(i)` = 7 位比特反转
- **i = 0..127，但 `zetas[0]` 从不使用**

完整 128 项已生成并逐项核对，见 `../rtl/zetas_tables_verified.v`（含逐层展开版本）。

### 域与缩放：三个反直觉的事实【已验证】

这三点推翻了此前指导文档的说法，**写 RTL 前务必看**：

1. **正向 NTT 的输出，可以直接和教科书 NTT 逐点比对。**
   因为 `zetas` 存的是 Montgomery 形式 `R·17^bitrev7`，而 `fqmul` 内含 `R⁻¹`，两者恰好抵消。实测 `ntt(a) mod q` 与标准域教科书 NTT **完全相等**，比值集合 = {1}。

2. **整条 NTT → basemul → INTT 链路的净缩放恰好是 1。**
   不需要任何后处理，不需要乘 R 或 R⁻¹。实测 20 组随机多项式对拍，全部通过。

3. **`1441` 必须配 `fqmul` 用，不能用普通模乘。**
   `f = 1441 = R²/128 mod q`。`fqmul(x, 1441)` 的效果 = `x · R · 128⁻¹`，不是 `x · 128⁻¹`。用错域 → 结果整体差一个 R，**仿真看着很对，上板全错**。

### 常数表（以参考实现为准）【已验证】

| 常数 | 值（正确） | 说明 |
|---|---|---|
| `KYBER_Q` | 3329 | |
| `KYBER_QINV` | **−3327**（无符号 62209） | q⁻¹ mod 2¹⁶ |
| `MONT` | **−1044**（无符号 2285） | R mod q |
| `F`（INV NTT 缩放） | 1441 | R²/128 mod q |
| `BARRETT_V` | 20159 | ((1<<26) + q/2)/q |
| `R2_MOD_Q` | 1353 | R² mod q，`poly_tomont` 用 |

> ⚠️ 旧指导文档写的是 `MONT = 2285`、`QINV = 62209`——两个 **mod 意义下等价，但位宽截断行为不同**，直接写进 RTL 会出错。以本表为准（本表取自 `ref/reduce.h`）。
> ⚠️ 表中是 **int16 有符号中心化代表**，不是 `[0, q−1]` 无符号。

### basemul：二次域乘法【已验证】

因为 NTT 输出的是 128 个二次多项式，点乘要在**二次域**里做：

```c
void basemul(int16_t r[2], const int16_t a[2], const int16_t b[2], int16_t zeta) {
  r[0]  = fqmul(a[1], b[1]);
  r[0]  = fqmul(r[0], zeta);
  r[0] += fqmul(a[0], b[0]);
  r[1]  = fqmul(a[0], b[1]);
  r[1] += fqmul(a[1], b[0]);
}
```

**索引规则**（来自 `ref/poly.c`，已核对）：
```c
for (i = 0; i < 64; i++) {
  basemul(r[4i   .. 4i+1], a[4i   .. 4i+1], b[4i   .. 4i+1],  zetas[64+i]);
  basemul(r[4i+2 .. 4i+3], a[4i+2 .. 4i+3], b[4i+2 .. 4i+3], -zetas[64+i]);
}
```
- **只用 `zetas[64..127]` 这一段**
- 成对取**相反数**——所以硬件里不需要额外存一张表，取负即可

### 运算量清单（资源估算的起点）

| 项目 | 正向 | 逆向 |
|---|---|---|
| 蝶形数 | 896 | 896 |
| 模乘次数 | 896 | 896 |
| 末尾统一缩放 | — | +256 |
| **模乘合计** | **896** | **1152** |
| basemul | 128 次 × 5 模乘 = **640 次模乘** | 同 |

> 一次 `poly_basemul` 的 640 次模乘，接近一次完整 NTT 的 896 次。**别只优化蝶形，basemul 是隐藏的大头。**

---

## 1.3 正确性判据（验收用什么）

### 三个层次，越靠前越容易 debug

| 层次 | 判据 | 说明 |
|---|---|---|
| ① **数学唯一判据** | 与朴素**负循环卷积**结果比对 | 该值数学上唯一，无法糊弄。黄金模型里有 `negacyclic_schoolbook()` |
| ② **黄金模型逐点对拍** | 与 `ntt_golden.py` 位精确比对 | 已证明与 C 参考位精确一致【已验证】 |
| ③ **官方 KAT** | 见下方警告 | ⚠️ 有坑 |

### ⚠️ 关于官方 KAT 的两个坑【已验证】

**坑一：Round-3 的 KAT 不是 ML-KEM 的 KAT。**

`Kyber-Round3.zip`（2020-10-21 提交版）的 KAT 对应 Kyber **v3.0**，而 FIPS 203 有一处关键改动：

```c
/* 2020 Round-3 版 */          hash_g(buf, buf, KYBER_SYMBYTES);       // G(d)
/* ML-KEM / FIPS 203 版 */     buf[KYBER_K] = KYBER_K;
                               hash_g(buf, buf, KYBER_SYMBYTES+1);   // G(d ‖ k)
```

多了模块秩的域分隔 → 种子不同 → **pk/sk/ct/ss 全不同**。要对拍 ML-KEM-768 必须换 ML-KEM 自己的 KAT。

**坑二（更根本）：KAT 验证不了"只有 NTT 核"的硬件。**

KAT 里的字段是 `pk/sk/ct/ss`——**KEM 层的产物**。要复现它们，得实现完整的 ML-KEM（K-PKE + FO + SHAKE + CBD + 压缩编解码 + 序列化）。一个纯 NTT 核**既喂不进也吐不出**。

→ 所以：**NTT 核的正确性靠 ①② 两层判据；③ 只有在你们做出完整 ML-KEM 后才用得上。**

### KAT 文件格式【已验证】

两代格式**不通用**，认准哪一代很重要：

| | Round-3（旧） | **FIPS 203（现用）** |
|---|---|---|
| 文件 | `PQCkemKAT_2400.rsp` | `kat_MLKEM_768.rsp` |
| 字段 | `count / seed / pk / sk / ct / ss` | `count / z / d / msg / seed / pk / sk / ct / ss / **ct_n** / ss_n` |
| 随机性 | 48 字节 `seed` 喂给 **AES256-CTR DRBG** | `d / z / msg` **显式给出** |

字段字节数两代一致：pk **1184** / sk **2400** / ct **1088** / ss **32** ✓

**关键点：`d ‖ z` 是 KeyGen 的输入，不是一个 DRBG 种子。**

```c
memcpy(coins,      d, 32);      /* 前 32 字节：公开矩阵 A 的种子 */
memcpy(coins + 32, z, 32);      /* 后 32 字节：隐式拒绝时派生伪随机输出用 */
crypto_kem_keypair_derand(pk, sk, coins);
crypto_kem_enc_derand(ct, ss, pk, msg);   /* msg 就是 Encaps 的随机性 */
```

顺序写反的话，只有 KeyGen 那一步会失败，Encaps/Decaps 全过 —— 这个失败特征本身
就是个诊断信号。落进 sk 尾部的是 `z` 而不是 `d`。

**`ct_n` / `ss_n` 是隐式拒绝的测试向量**：`ct_n` 是无效密文，正确实现必须让它
解出 `ss_n`（用 `z` 派生的伪随机值），而**不能**等于真 `ss`。这是 FO 变换唯一
的正面证据，别漏。

### ✅ 本机已建好的校验环境

`mlkem_kat/` 目录，已跑通：**1000/1000 条向量逐比特通过**（KeyGen + Encaps +
Decaps + 隐式拒绝四项全过，耗时约 1.3 秒）。细节见 `mlkem_kat/README.md`。

⚠️ **出处措辞**：该向量集来自社区仓库 `post-quantum-cryptography/KAT`（Rust 实现
生成，自称兼容 FIPS 203），**不是 NIST 官方发布的文件**。可信度来自我们已用参考
实现独立复算通过 —— 答辩时应说「社区维护的 FIPS 203 兼容向量集，已独立复算验证」，
不要说成「NIST 官方 KAT」。NIST 官方的走 ACVP（JSON 格式，面向算法验证系统）。

```sh
cd mlkem_kat && sh build_kat.sh && ./kat_verify.exe kat_MLKEM_768.rsp
```

**NTT 核怎么验**（KAT 覆盖不到的那一层）：`mlkem_kat/gen_ntt_vectors.c` 产出
`ntt_in/out.hex`、`intt_in/out.hex`、`basemul_*.hex`，每行一个系数的 12 位
十六进制，可直接喂 `$readmemh`。全部为规范形式 `[0, q)`。
（注意与上一级的 `ntt_golden.py` 区分：那是独立黄金模型，这是给 testbench 的激励。）
顺带实测确认：

- `invntt(ntt(f)) = f × 2285 (mod q)`，而 **2285 = 2¹⁶ mod q**，即 Montgomery 因子 R
  （全部 16 个向量 × 256 个系数都严格满足同一常数，说明往返是纯缩放、无畸变）
- `R² mod q = 1353`，与 `poly_tomont` 里硬编码的 `1353` 对上
- `128⁻¹ mod q = 3303`

---

# 第二部分 · FPGA 优化方法论

> 本部分综合 22 篇文献。`【文献】`标注的数字全部来自原文，**未报告的一律写"未报告"，没有估算**。
> ⚠️ 跨器件比较有陷阱，见 §2.5 的读表警告。

## 2.1 结论先行：推荐方案

| 环节 | 推荐 | 出处 | 理由 |
|---|---|---|---|
| **整体骨架** | 单蝶形 + 7 级流水 + ping-pong BRAM18 地址 FSM | `elec`（Sonbul 2026） | 唯一"同档器件 + post-PAR + 完整周期/频率"的论文；结构对新手最友好 |
| **模乘/约减** | **LUT6 先约 + K-RED 后约 + 一次条件加法** | `butterfly`（Bertels 2024）/ `ni`（Ni 2023） | 49 LUT + 1 DSP（Bertels）／50 LUT + 0 DSP（Ni）。**绝不要 Montgomery**，见 §2.3 |
| **存储** | 2 个 BRAM18 乒乓，原地读写 | `elec` / `j49` | 无需额外 BRAM 做转置 |
| **域处理** | twiddle 表直接存 Montgomery 形式，净缩放为 1 | 第一部分 §1.2 | 省掉全链路缩放电路 |
| **吞吐不够时** | 复制蝶形单元到 2 / 4 份 | `j49` 方法二 | 7020 有 220 个 DSP，撑得住；`j49` 用此法把 NTT 从 940 砍到 474 周期 |

**一句话落地路线**：`elec` 的骨架 → 把它的 Barrett 换成 Bertels 的 LUT+K-RED → 跑通 → 需要吞吐再复制蝶形。

## 2.2 架构选型

### 横向对比（全部为 N=256 单次变换，除注明外）

| 论文 | 架构 | 折叠因子 | LUT | DSP | BRAM | 频率 | 周期 | 器件 |
|---|---|---|---|---|---|---|---|---|
| `ht` ePrint 2025/1763 | 全展开 radix-256，896 蝶形 | **无折叠** | 67210 | **0** | 0 | 400 MHz | 1（摊销） | Alveo U55c ⚠️ |
| `j49` TCAS-I 2021 | 迭代 7 级，乒乓 RAM，CT/GS 统一 | 折叠 128 | **360** | 3 | 2 | 115 MHz | NTT 940 / INTT 1203 | Artix-7 XC7A100T-3 |
| `j49` 方法二 | 同上 + 并行蝶形 | — | 737 | 6 | 4 | 115 MHz | **NTT 474 / INTT 602** | Artix-7 |
| `elec` Electronics 2026 | 单蝶形 7 级深流水 + ping-pong BRAM18 | 折叠 128 | 503 | **1** | 2 | **200 MHz** | FNTT 1029 / INTT 1285 | **Artix-7 XC7A100T-3** |
| `xl` TCHES 2021 | 迭代 7 级，2 个统一蝶形（偶/奇并行） | — | 1737(NTT核) | 2 | 3 | 161/167 MHz | NTT 512 / INTT 576 | Artix-7 XC7A12T-1 |
| `foldntt` arXiv 2026 | 单流水蝶形 + 原地双 bank（**N=1024**） | 折叠 512 | 819 | 1 | 2 | 138 MHz | 5290 | Artix-7（**yosys 流程**）⚠️ |
| `ma_tcas` TCAS-I 2023 | 沿用 Kyber-HDL 双蝶形 + 掩码 | 折叠 128 | 7653（整机） | 未报告 | 11 | 20 MHz | 10000（整流程） | Spartan-6 ⚠️ |
| `butterfly` FPL 2024 | **仅蝶形单元，非完整 NTT** | — | 49(模乘)/151(蝶形) | 1 | 0 | 未报告 | 未报告 | Artix-7 综合 |

### 三种架构取向

**① 全展开**（`ht`）—— 每周期出一个 NTT，但 67210 LUT **塞不进 7020**（53200 LUT）。
→ **只能抄它的单元**：30 LUT / 14 FF / **0 DSP** 的模乘、69 LUT 的蝶形。这是目前已知最小的无 DSP 方案，值得研究。

**② 折叠迭代**（`elec` / `j49` / `xl`）—— 一个蝶形反复用 128 次，7 层迭代。
→ **这是你们的路线**。面积小、好验证、好排错。

**③ 部分并行**（`j49` 方法二）—— 复制蝶形换吞吐。`xl` 用 2 个单元做到 512 周期。

### `elec` 为何是首选

- **器件同档**：Artix-7 XC7A100T-3，与 Zynq-7020 的 PL 是同一 7 系列架构、同一 LUT6/DSP48E1/BRAM36 原语
- **数据完整**：post-place-and-route，连 slice 数（184）都给了，是唯一"周期/频率/面积三全"的论文
- **结构最简**：1 蝶形 + 1 DSP + 2 个 BRAM18 + 一个 FSM。对比 `ht` 的 896 个蝶形、`xl` 的双蝶形加 FIFO 调度，新手写对的概率高得多
- **细分**：蝶形 322 LUT / 258 FF；Barrett 175 LUT / 82 FF

## 2.3 模乘与模约减：本题最重要的一个决策

### 为什么不能用 Montgomery（核心结论）

```
Kyber q = 3329 只有 12 位
DSP48E1 的乘法器是 25×18 —— 一次装下，乘法本身只吃 1 个 DSP

但 Montgomery 约减按定义还要再做两次乘法（q'·a 和 t·q）
→ 一个模乘 = 3 个 DSP

在 220 个 DSP 的板子上，可并行的蝶形数量直接砍到 1/3
```

**这个代价比任何 LUT 优化都致命。** 文献佐证：Kyber 系的四篇（Yaman / Ni / Nguyen / Bertels）**无一采用 Montgomery**；`j49` 明确写了"拒绝 Montgomery，省掉域转换"。

### 方案对比

| 方案 | 延迟(周期) | LUT | DSP | 参数化 | 出处 |
|---|---|---|---|---|---|
| **Bertels 模乘单元** | 未报告（组合） | **49** | **1** | 否（仅 q=3329） | `butterfly` Table IV |
| Bertels butterfly 整单元 | 未报告 | 151 | 1 | 否 | `butterfly` Table III |
| **Ni 约减单元** | **2** | **50** | **0** | 否 | `ni` Table II |
| Ni 整核 NTT/INTT/PWM | 456 / 456 / 265 | 1154 | 2 | 否 | `ni` Table III |
| **ht 常数乘法器** | 未报告 | **30** | **0** | 否 | `ht` |
| ht butterfly 整单元 | 未报告 | **69** | **0** | 否 | `ht` |
| Nguyen K-DSP（q=3329） | 未报告 | 228 | 0 | **是** | `nph23` Table 5 |
| Yaman 约减单元 | 1 | 195 | 0（乘法另需 1 DSP） | 否 | `yaman` §III-1 |
| Yaman butterfly | 3 | 312 | 1 | 否 | `yaman` §III-2 |
| `elec` 的 Barrett | 4 级流水 | 175 | 0（乘法另需 1 DSP） | 否 | `elec` |
| Tosun WLM-Mixed | 5 | 315 | 3 | 是（32/64 位 Proth） | `kred24` ⚠️ |
| Tosun K2RED | 5 | 411 | 6 | 是 | `kred24` ⚠️ |

### 为什么 q=3329 特别适合 K-RED

```
q − 1 = 3328 = 13 · 2^8        ← m = 8 是"免费切点"

K-RED(C):  C0 = C mod 2^m,  C1 = C / 2^m
           返回 k·C0 − C1  ≡  k·C  (mod q)

m = 8 时，"取 mod 2^8"和"除以 2^8"退化成取 bit[7:0] 和 bit[23:8]
—— 纯连线，零成本
```

四个"免费"的地方：
1. **切点免费**：m=8 是纯连线
2. **乘 13 免费**：`13 = 8 + 4 + 1`，两次移位 + 两次加法，无乘法器
3. **层级对齐**：8 恰好等于 log₂(256)，NTT 层级与 twiddle 归并天然对齐
4. **缩放可预乘**：由 `−13·2⁸ ≡ 1` 可推出 `k⁻¹` 与 `N⁻¹ = 128⁻¹` 都能预乘进 twiddle 表 —— Nguyen 用这招把 INTT 的收尾乘法**整个消掉**

> ⚠️ **别照抄 Longa 的 m=12 参数**：Longa 原文实例化的是 q=12289=3·2¹²+1。搬到 Kyber 上 k 会变成非整数。必须按 `3329−1 = 13·2⁸` 重新分解。
> 另一个精确等式 `2¹² ≡ 2⁹+2⁸−1 (mod 3329)`（因为 4096−3329 = 767 = 512+256−1）是 Yaman 位树方案的基础——**2¹² 只是"再切一刀"的选项，Kyber 的自然切点是 2⁸**。

### 两个已知陷阱

1. **Ni 的电路输出落在 `[0, 2¹²)` 而非 `[0, q)`** —— 必须补条件减法才算真正约减
2. **`butterfly` 论文点名纠正**：合并 CT/GS 蝶形**不能**省掉 bit-reversal。别信"统一蝶形免重排"的说法

## 2.4 存储与调度

| 做法 | 出处 | 要点 |
|---|---|---|
| 双 BRAM18 乒乓 + 原地读写 | `elec` / `j49` | 无需额外 BRAM 做转置；FSM 控制两个双口 BRAM |
| 三个 FIFO 替掉全部 BRAM | `ni` | BRAM=0 的实现，省 2 个 BRAM18 |
| RAM 分两 bank 严格原地 | `xl` | 偶/奇两组 128 点 NTT 并行 |
| Keccak 采样藏进 NTT 后面 | `xl` | 把哈希采样与 NTT 排成流水，是省周期的大招 |

> **`xl` 那条最值得记住**：NTT 核再快，外面还包着一圈 SHAKE。把采样与 NTT 重叠，比单纯压 NTT 周期收益更大。

## 2.5 ⚠️ 读表警告（不读会误判）

**警告一：跨器件不可直接比。**
- `ht` 是 **Alveo U55c**（服务器档 UltraScale+，400 MHz），LUT 容量档位比 7020 大 3 倍以上。它的"1 周期/NTT"是**稳态摊销吞吐，不是端到端延迟**
- `ma_tcas` 是 **Spartan-6**（老 DSP48A1 原语）
- `foldntt` 的面积数出自 **yosys + openXC7 开源流程**，作者自己写明"vendor timing 与板级执行在 scope 之外"，与 Vivado 计数**不可比**
- `kred24`(Tosun) 的 LUT/DSP 是 **β=64 位模乘全文**的代价，跑在 DSP48E2 上，与 Kyber 组（12 位系数、24 位积、DSP48E1）**不可比大小**

**警告二：论文理想值 vs 器件实测。**

| 可信度 | 论文 | 依据 |
|---|---|---|
| ✅ **器件实测** | `elec` | post-PAR，200 MHz，Artix-7，连切片数都给了 |
| ✅ **器件实测** | `j49` | post-PAR，Artix-7 XC7A100T-3，115 MHz，区分了两档方法 |
| ✅ **器件实测** | `xl` | Vivado 2017.3，最小 Artix-7，**过了 KAT** |
| ✅ 真板实测 | `ma_tcas` | SAKURA-G 实测功耗/电磁曲线 |
| ⚠️ 要打折 | `ht` | 稳态摊销吞吐 ≠ 端到端延迟；且放不进 7020 |
| ⚠️ 要打折 | `foldntt` | yosys 流程，作者自述有 scope 限制 |
| ⚠️ 无周期数据 | `butterfly` | 49 LUT 是综合值，但**没有周期**，做不出完整核 |

**警告三：没有一篇是 Zynq-7020 的 NTT 实现。**

最接近的基线是 **Fritzmann RISQ-V**（被 `elec`/`j49` 共同引用）：Zynq-7000 上的 Kyber NTT，**2908 LUT / 170 FF / 9 DSP / 1935 周期 / 45 MHz / 43 µs**。

`j49` 还给了一条有用的换算：**同一设计在 Zynq-7000 上比 Artix-7 慢约 1.35×**。可作为你们估算 7020 表现的折扣系数。

> **保守预期**：7020 速度等级 -2 介于 `elec` 的 -3 和 `j49` 的 -3 之间（注：Xilinx 速度等级数字越大越快，7020 常见为 -1/-2）。频率保守取 **150 MHz**，NTT 周期数直接对标 `elec` 的 **1029** / `j49` 的 **940**。

## 2.6 侧信道与常数时间（答辩防守用）

> **定位**：你们**不需要实现**这些。这一节的作用是"知道有这回事 + 答辩能接住提问"。

### 核心结论

| 对策 | 硬件代价 | 依据 |
|---|---|---|
| **1. 常数时间设计**（最低） | 几乎为零，只改控制逻辑 | 攻击正是利用模约减里 DIV 的数据相关运行时间。**但只堵一条路，挡不住模板攻击** |
| **2. 洗牌**（中） | **+260 Slices / ATP +8.7%**（Kyber-512 整核，DSP+BRAM 不变） | `shuffle_hw` TCAS-II 2025 |
| **3. 掩码**（最高） | 软件 NTT 单模块 **+451.7%**；纯硬件一阶掩码 Kyber-512 需 **152,860 LUT** | `ravi_shuffle` / `kamucheka` |

> **Kamucheka 那 152,860 LUT 是你们最好的论据**——不是不想做，是物理上放不进 Zynq-7020。

### 四条必背结论

1. **洗牌是唯一已知对 NTT 单迹攻击有效的对策**
2. **掩码挡不住单迹攻击**（Primas CHES 2017：单迹下两个 share 各自恢复再合并）
3. **洗牌也可被反向破解**（`bp_shuffle` TCHES 2023：置信传播能"学会"置换，细粒度洗牌已被攻破）——别吹成绝对安全
4. **掩码了 NTT ≠ 整核安全**（`masked_kem_sca`：真正的突破口是消息解码模块，不是 NTT）

### 评委问"你们的 NTT 核抗侧信道吗"——可直接背的话

> 「这一版我们定位功能与性能验证，NTT 核没做侧信道防护。威胁是真实的：文献里单条功耗迹就能恢复密钥，一阶掩码也挡不住。后续路线优先加洗牌——硬件代价最低，TCAS-II 报告只需多约 9% 面积时间积；掩码作为第二步。」

**若追问"为什么不做掩码"**：

> 「掩码面积太大，公开的纯硬件一阶掩码 Kyber-512 占 15 万 LUT，放不进我们的板子；而且 CHES 2017 已证明掩码不能防单迹攻击。」

---

# 第三部分 · 论文与开源代码清单

## 3.1 必读（按优先级）

| 优先级 | 论文 | 一句话 | 为什么读 |
|---|---|---|---|
| **★★★** | `elec` — Deeply Pipelined NTT Accelerator with Ping-Pong Memory and LUT-Only Barrett Reduction<br>*MDPI Electronics 2026 · Sonbul* | 单 DSP 蝶形 + 七级流水 + BRAM18 乒乓 | **你们的主骨架**。同档器件、数据最全 |
| **★★★** | `butterfly` — A Better Kyber Butterfly for FPGAs<br>*FPL 2024 · Bertels, COSIC* | 49 LUT + 1 DSP 的最小模乘 | **模乘单元直接抄**。附开源 RTL |
| **★★★** | `j49` — 指令集式 Kyber NTT 核<br>*IEEE TCAS-I 68(11) 2021 · Bisheh-Niasar* | NTT/INTT/PWM 三合一 + 乒乓双 RAM | 控制码套路 + 扩展吞吐的方法二 |
| **★★** | `xl` — 最小 Artix-7 全 Kyber 硬件<br>*IACR TCHES 2021(2) · Xing & Li* | Keccak 采样藏进 NTT 后面 | 系统级调度思路；**过了 KAT** |
| **★★** | `ni` — LUT+K-RED 约减与免 BRAM NTT<br>*IEEE ISCAS 2023 · Ni* | 50 LUT 约减 + 三 FIFO 免 BRAM | 省 BRAM 的备选；含 K2-RED/Barrett 对比 |
| **★★** | `ht` — A High Throughput Kyber NTT<br>*IACR ePrint 2025/1763 · Bertels* | 全展开 radix-256，**0 DSP** | 最新工作。整块放不进 7020，**抄单元** |
| **★** | `yaman` — Kyber 多项式乘法硬件加速器<br>*DATE 2021 · Yaman* | 位树约减 + 单乘法器 butterfly | 开源 RTL 最成熟（53★） |
| **★** | `longa` — Speeding up the NTT<br>*CANS 2016 · Longa & Naehrig* | K-RED 的源头论文 | 理论根基。**注意它针对 q=12289** |
| **★** | `nph23` — 免 DSP 模乘 | 228 LUT / 0 DSP / 283 MHz | 想彻底不用 DSP 时的唯一完整数据 |
| — | `kred24` — Tosun 模约减横评 | 五种方案的量化权衡 | ⚠️ 面向 FHE 的 32/64 位素数，**Kyber 用不上**，只读方法论 |

## 3.2 侧信道（知道结论即可）

| 论文 | 结论 |
|---|---|
| `ravi_shuffle` SPACE 2020 | 掩码/洗牌代价基准；NTT Fine-Masked **+451.7%** |
| `primas` CHES 2017 | 首个格密码单迹攻击；**掩码挡不住** |
| `bp_shuffle` TCHES 2023 | **洗牌可被反向破解** |
| `shuffle_hw` TCAS-II 2025 | 洗牌硬件只多 **260 Slices / ATP +8.7%** |
| `kamucheka` FPT 2022 | 纯硬件一阶掩码 Kyber-512 = **152,860 LUT** |
| `masked_kem_sca` ASHES 2023 | 突破口是**消息解码模块**，不是 NTT |
| `bitsliced` ePrint 2023/1042 | 高阶掩码也被攻破；**不用碰** |

## 3.3 开源 RTL 仓库（已下载到 `ref_rtl/`）

| 仓库 | ★ | 内容 | 价值 |
|---|---|---|---|
| **`acmert/kyber-polmul-hw`** | 53 | `pe1/` 完整多项式乘法：`KyberHPM1PE.v`、地址生成器、BRAM、蝶形，**含 4 个测试平台** | ⭐ **最成熟**；**NTT 已跑通并通过 FIPS 203 验证**（§3.4）|
| **`axytho/KyberButterflyCollection`** | 9 | `butterflies/` 下 **10 种蝶形变体**：`butterfly_Best.v`、`butterfly_best_KRED.v`、`butterfly_K_then_LUT.v` 等 | ⭐ Bertels 论文的配套代码，**可对照论文读** |
| `Intelectron6/KYBER-on-PYNQ` | 7 | PYNQ-Z2（**= Zynq-7020**）上的 Kyber 软硬协同，Vivado HLS | 同板实现参考 |
| `bsc-loca/PQC-Crystals-HLS-Accelerators` | 24 | HLS 版 PQC 加速器 | HLS 路线（若不想写 RTL） |
| `SARAVANAPERUMAL-2192/FPGA-based-Hardware-Accelerator` | 5 | 256 点 NTT 加速器，FSM 架构 | 新手友好的练手参考 |

> ✅ **iverilog 12.0 已装好**（`winget install --id Icarus.Verilog`，路径 `/c/iverilog/bin`，
> 但 Bash 里 PATH 不带它，每次要 `export PATH="/c/iverilog/bin:$PATH"`）。
> `pe1/` 已经跑起来了 —— 见 §3.5。

## 3.4 ★ 已有的 RTL 已经验证过了（2026-09-18）

`acmert/kyber-polmul-hw` 的 `pe1/` **NTT 已确认符合 FIPS 203**，不是"作者 testbench
打印 Correct 所以大概没大错"。验证链在 `../../refsim/`，一条命令可复跑：

```sh
cd ../../refsim && sh run_fntt_check.sh
```

```
FIPS 203 KAT 1000 条 → 锚定 C 参考实现为地面真值
参考实现复算作者的输入 → 与作者期望输出逐比特一致（512/512 个系数）
我方 16 组独立向量灌进 RTL → 全过（4096/4096 个系数）
∴ 这份 RTL 的 NTT 符合 FIPS 203
```

**为什么中间那环不能省**：作者 testbench 是「作者的期望值 vs 作者的 RTL」，
只能证自洽 —— 万一作者的 twiddle 表排错，它照样打印 `Correct!`。
先用 KAT 把参考实现锚成外部真值，链条才对外部标准闭合。

**"通过"要配"非退化"才作数**：4096 个输入系数里 2355 个不同值、覆盖 0..3327
全域。这种熵下全中不可能是巧合。验任何硬件都该先做这一步。

**还没验**：INTT 和 PWM2（点乘）—— 向量已备好但没灌进 RTL；INTT 方向更难
（Gentleman-Sande + 末级缩放），值得补。多 PE 配置、面积/时序/功耗也没验
（这是功能验证，不是实现质量评估）。

> 意义：这块 **可以直接拿来当基线对照**，不必从零写 NTT 再自己验自己。
> 详见 `refsim/README.md`。

## 3.5 标准文档与测试向量

| 材料 | 位置 | 说明 |
|---|---|---|
| pq-crystals/kyber 参考实现 | `../kyber_ref/` | **当前 ML-KEM 版**，`ref/ntt.c` 是权威 |
| 黄金模型 | `../ntt_golden.py` | 已证明与 C 参考**位精确一致** |
| twiddle 表 | `../rtl/zetas_tables_verified.v` | 128 项全对 |
| Kyber v3.0 官方规格 | `../_round3_extract/.../Supporting_Documentation/kyber.pdf` | ⚠️ **非 FIPS 203** |
| Round-3 KAT | `../_round3_extract/.../KAT/` | ⚠️ **不是 ML-KEM 的 KAT**，见第一部分 §1.3 |
| FIPS 203 正式标准 | **需自行下载** | NIST 官网 |

### ⚠️ 网络通路备忘（下次调研省时间）

本机实测：`github.com` **被墙（000）**、`raw.githubusercontent.com` **被墙**、`bytecode` 直连不通。

可用通路：
- `api.github.com` ✅ 200 —— 抓文件走 `-H "Accept: application/vnd.github.raw"`；抓整仓库走 `https://api.github.com/repos/OWNER/REPO/tarball`
- `codeload.github.com` ✅ 301
- `eprint.iacr.org` / `arxiv.org` ✅
- `ieeexplore.ieee.org` ❌ 418、`sciencedirect.com` ❌ 403（反爬）

---

# 第四部分 · 阅读路径

## 4.1 按角色分（零基础队伍 3 人）

**所有人先读**：本文档第一部分（算法本体）——不读懂 1.2 节就写不出 RTL。

| 角色 | 必读 | 选读 |
|---|---|---|
| **RTL 主写** | `elec`（骨架）→ `butterfly`（模乘）→ 第一部分 §1.2 | `j49`（调度）、`ni`（省 BRAM） |
| **验证/PS 侧** | 第一部分 §1.3（判据）→ `../ntt_golden.py` 源码 | `xl`（系统级） |
| **答辩/文档** | 第二部分全篇 → §2.6（侧信道） | `ravi_shuffle`、`shuffle_hw` |

## 4.2 按周排

| 周 | 读什么 | 目标 |
|---|---|---|
| **W1** | 第一部分 §1.1–1.2 | 讲清"为什么只有 7 层"和"为什么有 basemul" |
| **W1–W2** | `elec` 全文 + 它的架构图 | 画出自己的数据通路草图 |
| **W2** | `butterfly` 的模乘部分 + §2.3 | 定下约减方案（应该是 LUT+K-RED） |
| **W3** | 动手写 RTL | 别再看论文了 |
| **W5+** | §2.6 侧信道 + 第二部分 | 准备答辩问答 |

## 4.3 三条"别踩"警告

1. **别用 Montgomery** —— 会把每个模乘的 DSP 从 1 个变成 3 个（§2.3）
2. **别照抄 Longa 的 m=12** —— 那是给 q=12289 的，Kyber 的自然切点是 m=8
3. **别信"统一蝶形免 bit-reversal"** —— `butterfly` 论文明确纠正过这个说法

## 4.4 还没做的事

**已完成：**

- ✅ **FIPS 203 正式文本**已下载 → `standards/NIST.FIPS.203.pdf`（另附 204/205）
- ✅ **ML-KEM 版 KAT** 已获取（1000 条，12,012,890 字节），并建好本机校验环境
      → `mlkem_kat/`，**1000/1000 条逐比特通过**（四项独立复算，1.3 秒跑完）
      ⚠️ 出处是社区仓库 `post-quantum-cryptography/KAT`，**不是 NIST 官方发布**，
      措辞别说成"NIST 官方 KAT"；可信度来自我方独立复算本身
- ✅ **已有 RTL 的 NTT 已验证符合 FIPS 203** → 见 §3.4 与 `../../refsim/`
      NTT 黄金向量生成器是 `mlkem_kat/gen_ntt_vectors.c`
      （⚠️ 别和上一级的 `ntt_golden.py` 搞混：那是**独立写的**黄金模型，
       独立性正是它的价值；`gen_ntt_vectors.c` 是从 C 参考实现导向量）

**待办：**

- ☐ **`isec_p5.txt` 只有残片**（缺 pp.243–246，即两版模乘架构的电路图与算法本体）。该刊开放获取，值得补全文——它是"通用可参数化模乘"的直接竞品（87 LUT / 31 FF / 315 MHz）
- ☐ 22 篇里 `foldntt.pdf` 是针对 **N=1024 Falcon** 的，与 Kyber 的迁移性未验证
- ☐ `kyber_ref/randombytes.c` 没下下来（抓到的是 GitHub 限流页），目前用哨兵桩顶着。
      只走 `_derand` 接口的话不影响，但**若日后要用非 derand 入口，必须先补回真实现**

