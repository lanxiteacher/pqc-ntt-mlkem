# 参考文献

> **状态**：🔄 **草稿（2026-10-09 首次收拢；2026-10-10 补全书目信息）—— 未经 A/B 核对。**
>
> **一件事仍等 A 回话**（见 `../../logs/letter_2026-10-09_C_to_A.txt`）：
> 报告**到底要不要**单列参考文献、放在哪一段 —— 取决于《选题指南》§3.3.5.3「设计报告七项」的原文；
> 若单列，**用什么著录格式**（GB/T 7714 还是别的）同样以指南为准。
> ⚠️ **10-10 补的是「条目信息」，不是「格式」** —— 格式没定不影响把「谁在哪发表的」查清楚。
>
> **材料来源**：`../../docs/related-work.md` 主表与 §四 来源表、
> `../../research/pqc-ntt_ml-kem_compendium.md` §3.1–§3.5（后者信息密度最高，格式已接近文献条目）。
> **本文件与各章的「§x.7 / §x.10 数据溯源」是两件事**：那份是**内部文件指针**（「这个数出自哪个文件」），
> 这份是**外部文献**（「这项工作是谁在哪发表的」），互补、不重复。

---

## 条目说明

书目信息（标题 / 作者 / venue / 年 / 卷页 / DOI）按出版方公开页面核对补全。

**两条边界：**

1. **`网核` 标的是「来自公开网络检索」，不是回原始 PDF 逐字核的。**
   补的是**「谁在哪发表的」**（出版方自己发布，可靠性高）；
   **报告里引用的「数字」（器件型号 / LUT / 频率 / 周期）仍要回原始 PDF 核** ——
   那是另一回事，见 `../../docs/related-work.md` §五。**别把「引用信息已补齐」当成「数字已核实」。**
2. A2（Kyber v3.0 规格）与 B3（Round-3 KAT）来自 NIST 官方 Round-3 包
   （`Kyber-Round3.zip`，7 MB，2020-10-01），条目里已补官方 URL；
   归档 SHA-256 为 `A68B152C…`，**归档不进仓库**（见 `.gitignore`）。
   ⚠️ 链接与文件存在已核，**内容未逐字核**。

标注规则：

| 标注 | 意思 |
|---|---|
| **`网核`** | 公开检索补全（条目给了 DOI 或出版方页）。⚠️ **未回原始 PDF 逐字核** |
| **`未消`** | 仍缺，且**不是漏抄** —— 仓库里确实没有该原件 |
| **`未核`** | **数值或出处**尚未回原文核对（与上面两条不同：这是「数字」层面的欠账） |

---

## A. 标准与规范

| # | 条目 | 出处 |
|---|---|---|
| A1 | **NIST.** *Module-Lattice-Based Key-Encapsulation Mechanism Standard*（**FIPS 203**, **2024**）`网核` | 本仓库副本 `../../research/standards/NIST.FIPS.203.pdf` |
| A2 | **CRYSTALS-Kyber 团队.** *Kyber v3.0 官方规格*（Round-3 支持文档，2020-10-01）. ⚠️ **非 FIPS 203** `网核` | 官方包 `https://csrc.nist.gov/CSRC/media/Projects/post-quantum-cryptography/documents/round-3/submissions/Kyber-Round3.zip` → `Supporting_Documentation/kyber.pdf`；本机归档 `../../research/Kyber-Round3.zip`（**SHA-256 `A68B152C7CF70A32BAB1ABAF2AB5A21423F33B0AC11CA8DB9B9DD4864007319B`**，7,340,227 B，与官方 7 MB 包一致；**归档本身不进仓库**，见 `.gitignore`） |
| A3 | **NIST.** FIPS 204（ML-DSA）／ FIPS 205（SLH-DSA）. ⚠️ **本作品未引用**，随 A1 一批下载 | `../../research/standards/NIST.FIPS.204.pdf`、`NIST.FIPS.205.pdf` |

## B. 参考实现与测试数据

| # | 条目 | 出处 |
|---|---|---|
| B1 | **pq-crystals.** *kyber* —— CRYSTALS-Kyber / ML-KEM 参考实现（C）. `ref/ntt.c` 是 twiddle 表与 INTT 层序的权威来源。`网核` `https://github.com/pq-crystals/kyber` | `../../research/kyber_ref/` |
| B2 | **post-quantum-cryptography.** *KAT* —— FIPS 203 **兼容**考题（ML-KEM-768，1000 条）. `网核` `https://github.com/post-quantum-cryptography/KAT`。⚠️ **社区维护，不是 NIST 官方发布**（措辞红线，见 `../../research/mlkem_kat/README.md` 文首） | `../../research/mlkem_kat/` |
| B3 | **NIST / Kyber Round-3 提交包.** Kyber Round-3 KAT（`.req`/`.rsp`，2020-10-01）. ⚠️ **不是 ML-KEM 的 KAT** —— 种子派生是 `G(d)` 而非 `G(d‖K)`，**只作反面材料**（见 `../../research/verified_corrections_to_guide.md` 修正 4）`网核` | 同一个官方 zip → `Additional_Implementations/avx2/crypto_kem/kyber768/PQCkemKAT_2400.req` / `.rsp`（512/1024 同目录）；本机归档与哈希同 A2；结论记于 `../../research/verified_corrections_to_guide.md` |

## C. 公开工作（横向对比对象，对应 `../../docs/related-work.md` 主表）

> 主表行号见「出处」列。**所有条目 2026-10-10 经公开检索补全**（`网核`）。

| # | 条目 | 出处 / 备注 |
|---|---|---|
| C1 | **Omar S. Sonbul, Muhammad Rashid, Muhammad I. Masud, Mohammed Aman, Amar Y. Jaffar.** *Deeply Pipelined NTT Accelerator with Ping-Pong Memory and LUT-Only Barrett Reduction for Post-Quantum Cryptography*. *Electronics*（MDPI）**15**(3): 513, 2026. **DOI 10.3390/electronics15030513** `网核` | 主表第 1 行；**我们 pe1 的骨架来源** |
| C2 | **Mojtaba Bisheh-Niasar, Reza Azarderakhsh, Mehran Mozaffari-Kermani.** *Instruction-Set Accelerated Implementation of CRYSTALS-Kyber*. *IEEE TCAS-I* **68**(11): 4648–4659, 2021. **DOI 10.1109/TCSI.2021.3106639** `网核` | 主表第 2 / 2b 行（汇编记作 `j49`） |
| C3 | **Yufei Xing, Shuguo Li.** *A Compact Hardware Implementation of CCA-Secure Key Exchange Mechanism CRYSTALS-KYBER on FPGA*. *IACR TCHES* **2021**(2): 328–356. **DOI 10.46586/tches.v2021.i2.328-356** `网核` | 主表第 3 行（汇编记作 `xl`） |
| C4 | **Binh Kieu-Do-Nguyen, Nguyen The Binh, Cuong Pham-Quoc, Huynh Phuc Nghi, Ngoc-Thinh Tran, Trong-Thuc Hoang, Cong-Kha Pham.** *Compact and Low-Latency FPGA-Based Number Theoretic Transform Architecture for CRYSTALS Kyber Postquantum Cryptography Scheme*. *Information*（MDPI）**15**(7): 400, 2024. **DOI 10.3390/info15070400** `网核`。⚠️ 抽取文本里**没有具体器件型号**`未核`；PDF 不在仓库 | 主表第 4a–4c 行；`mdpi_v1.txt` / `mdpi_v2.txt` / `out_table.txt` |
| C5 | **Jonas Bertels, Ingrid Verbauwhede.** *A High Throughput Kyber NTT*. IACR Cryptology ePrint Archive, **Paper 2025/1763**, 2025. `网核` `https://eprint.iacr.org/2025/1763` | 主表第 5 行（汇编记作 `ht`） |
| C6 | **Masato Kamba.** *FoldNTT: A Multiplier- and Twiddle-Lean NTT Core with Formally Verified Arithmetic for Proth Primes*. **arXiv:2609.06412**, 2026. `网核`。⚠️ 该文**主对象是 Falcon / FN-DSA 的 q=12289（N=1024）**，Kyber（q=3329）只是「可推广性验证」一例 —— **与 Kyber 的迁移性未验证**`未核` | 主表第 6 行（汇编记作 `foldntt`） |
| C7 | **Yiqiang Zhao, Shijian Pan, Haocheng Ma, Ya Gao, Xintong Song, Jiaji He, Yier Jin.** *Side Channel Security Oriented Evaluation and Protection on Hardware Implementations of Kyber*. *IEEE TCAS-I* **70**(12): 5025–5035, 2023. **DOI 10.1109/TCSI.2023.3288600** `网核` | 主表第 7 行（汇编记作 `ma_tcas`）；**唯一给侧信道真板数据的** |
| C8 | **Jonas Bertels, Quinten Norga, Ingrid Verbauwhede.** *A Better Kyber Butterfly for FPGAs*. *FPL 2024*（34th Int'l Conf. on Field-Programmable Logic and Applications, Torino）, pp. 171–177. **DOI 10.1109/FPL64840.2024.00032**；ePrint 2024/1367 `网核` | 主表第 8 行；**我们的模乘单元直接抄它**，配套代码见 F2 |
| C9 | **Tim Fritzmann, Georg Sigl, Johanna Sepúlveda.** *RISQ-V: Tightly Coupled RISC-V Accelerators for Post-Quantum Cryptography*. *IACR TCHES* **2020**(4): 239–280. **DOI 10.13154/tches.v2020.i4.239-280** `网核` | `related-work.md` §三 警告三（唯一 Zynq-7000 上的 Kyber NTT 参照） |
| C10 | **Kamal Kundi, David Bermudo Mera, Sebastian Strub, Michael Hutter（PQShield）.** *High-Performance NTT Hardware Accelerator to Support ML-KEM and ML-DSA*. *ASHES '24*. **DOI 10.1145/3689939.3695785** `网核` | `related-work.md` §四③；⚠️ Table 3 抽取有缺行，本表暂未引用其数字 |
| C11 | **Tolun Tosun 等.** *Efficient Modular Multiplication Hardware for Number Theoretic Transform on FPGA*. IACR Cryptology ePrint Archive, **Paper 2024/1890**, 2024 `网核`。（同一工作的期刊版：*Optimized FPGA Architecture for Modular Reduction in NTT*, Springer LNCS, 2025）. ⚠️ 面向 **FHE 的 32/64 位素数**，与 Kyber 不可比大小 | 汇编 §2.3（记作 `kred24`）；**只读方法论，不引用数字** |

## D. 模乘与模约减

| # | 条目 | 出处 / 备注 |
|---|---|---|
| D1 | **Zyling Ni, Ayesha Khalid, Weiqiang Liu, Maire O'Neill.** *Towards a Lightweight CRYSTALS-Kyber in FPGAs: an Ultra-Lightweight BRAM-Free NTT Core*. *IEEE ISCAS*, 2023. `网核` | 汇编 §3.1（记作 `ni`）；**LUT+K-RED 约减与免 BRAM NTT** |
| D2 | **Ferhat Yaman, Ahmet Can Mert 等.** *A Hardware Accelerator for Polynomial Multiplication Operation of CRYSTALS-KYBER PQC Scheme*. *DATE 2021*, pp. 1020–1025. IACR ePrint 2021/485 `网核`（⚠️ 合著者全名未逐个核） | 汇编 §3.1（记作 `yaman`）；其开源 RTL 即 **F1**（`acmert/Kyber-polmul-hw`）。轻量/均衡/高性能三档 = 1/4/16 蝶形 —— **正是我们 pe1/pe4/pe16 的原始出处** |
| D3 | **Patrick Longa, Michael Naehrig.** *Speeding up the Number Theoretic Transform for Faster Ideal Lattice-Based Cryptography*. *CANS 2016*, LNCS 10052: 124–139. **DOI 10.1007/978-3-319-48965-0_8** `网核`。（预印本 ePrint 2016/504）. ⚠️ **针对 q=12289，不适用于 Kyber** | 汇编 §3.1；K-RED 的源头 |
| D4 | **Trong-Hung Nguyen, Cong-Kha Pham, Trong-Thuc Hoang.** *A High-Efficiency Modular Multiplication Digital Signal Processing for Lattice-Based Post-Quantum Cryptography*. *Cryptography*（MDPI）**7**(4): 46, 2023. **DOI 10.3390/cryptography7040046** `网核` | 汇编 §3.1（记作 `nph23`，K-DSP 免 DSP 模乘：**228 LUT / 174 FF / 0 DSP / 283 MHz**） |

## E. 侧信道相关工作（**仅存在性引用**——本作品不实现侧信道防护）

> **报告里只用于说明「有这类工作」**，防守口径见 `../../research/pqc-ntt_ml-kem_compendium.md` §2.6。
> 全部条目 2026-10-10 经公开检索补全（`网核`）。

| # | 条目 | 汇编 ID | 用在报告的哪 |
|---|---|---|---|
| E1 | **Prasanna Ravi, Romain Poussier, Shivam Bhasin, Anupam Chattopadhyay.** *On Configurable SCA Countermeasures Against Single Trace Attacks for the NTT*（A Performance Evaluation Study over Kyber and Dilithium on the ARM Cortex-M4）. *SPACE 2020*, LNCS 12586: 123–146. **DOI 10.1007/978-3-030-66626-2_7**；ePrint 2020/1038 | `ravi_shuffle` | 掩码/洗牌代价基准（NTT Fine-Masked **+451.7%**） |
| E2 | **Robert Primas, Peter Pessl, Stefan Mangard.** *Single-Trace Side-Channel Attacks on Masked Lattice-Based Encryption*. *CHES 2017*, LNCS 10529: 513–533. **DOI 10.1007/978-3-319-66787-4_25** | `primas` | 首个格密码单迹攻击；**掩码挡不住** |
| E3 | **Julius Hermelink, Silvan Streit, Emanuele Strieder, Katharina Thieme.** *Adapting Belief Propagation to Counter Shuffling of NTTs*. *IACR TCHES* **2023**(1): 60–88. **DOI 10.46586/tches.v2023.i1.60-88** | `bp_shuffle` | **洗牌可被反向破解** |
| E4 | **Dejun Xu, Ke Wang 等.** *A Hardware-Friendly Shuffling Countermeasure Against Side-Channel Attacks for Kyber*. *IEEE TCAS-II* **72**(3): 504–508, 2025. **DOI 10.1109/TCSII.2025.3528751**；arXiv:2407.02452 | `shuffle_hw` | 洗牌硬件只多约 **260 Slices / ATP +8.7%** |
| E5 | **Tendayi Kamucheka, Alexander Nelson, David Andrews, Miaoqing Huang.** *A Masked Pure-Hardware Implementation of Kyber Cryptographic Algorithm*. *FPT 2022*（亦见 NIST 第 4 届 PQC 标准化会议, 2022）；ePrint 2022/1547 | `kamucheka` | 纯硬件一阶掩码 Kyber-512 = **152,860 LUT** |
| E6 | **Yanning Ji, Elena Dubrova.** *A Side-Channel Attack on a Masked Hardware Implementation of CRYSTALS-Kyber*. *ASHES '23*. **DOI 10.1145/3605769.3623992** | `masked_kem_sca` | 突破口是**消息解码模块**，不是 NTT |
| E7 | **Ruize Wang, Martin Brisfors, Elena Dubrova.** *A Side-Channel Attack on a Bitsliced Higher-Order Masked CRYSTALS-Kyber Implementation*. IACR Cryptology ePrint Archive, **Paper 2023/1042**, 2023 | `bitsliced` | 高阶掩码也被攻破；**不用碰** |

## F. 开源 RTL 仓库与工具文档

> ⚠️ **仓库地址来自汇编转抄；F1 / F2 两条 2026-10-10 经检索核过**，其余（F3–F5）**未逐个打开核对**。

| # | 条目 | 备注 |
|---|---|---|
| F1 | **acmert/Kyber-polmul-hw** —— `pe1/` 完整多项式乘法 RTL，**含 4 个测试平台**。`https://github.com/acmert/Kyber-polmul-hw` `网核` | ⭐ 我们的**基线来源**（`../../research/ref_rtl/kyber-polmul-hw/pe1/`），已通过 FIPS 203 验证 |
| F2 | **axytho/KyberButterflyCollection** —— `butterflies/` 下 10 种蝶形变体（`butterfly_Best.v` 等）。`https://github.com/axytho/KyberButterflyCollection` `网核` | C8 论文的配套代码 |
| F3 | **KYBER-on-PYNQ**（Intelectron6）—— PYNQ-Z2（= Zynq-7020）上的 Kyber 软硬协同（HLS） | 同板实现参考（⚠️ 我们是纯 PL，不走 PYNQ） |
| F4 | **PQC-Crystals-HLS-Accelerators**（bsc-loca） | HLS 路线参考 |
| F5 | **FPGA-based-Hardware-Accelerator**（SARAVANAPERUMAL-2192）—— 256 点 NTT，FSM 架构 | 练手参考 |
| F6 | **AMD/Xilinx** Vivado 文档：**UG901**（综合）、**UG904**（实现）、**UG949**（UltraFast 方法学） | 工具链口径（我们实装 **2020.2**，见 `03` §3.15） |

---

## 溯源

| 内容 | 出处 |
|---|---|
| 主表 1–3、5–8 行与读表警告 | `../../docs/related-work.md` §一 / §三；`../../research/pqc-ntt_ml-kem_compendium.md` §2.2 / §2.5 / §3.1–3.4 |
| 各工作的资源/频率数字 | 同上；⚠️ 引用时**必须带测量条件**（`related-work.md` §三 四条警告） |
| Information 2024 / PQShield 的抽取文本 | `../../research/kyber_ref/papers/`（PDF 不在仓库） |
| **2026-10-10 补全的条目信息（标题 / 作者 / venue / 卷页 / DOI）** | **公开网络检索（出版方页、DOI 注册记录、ePrint/arXiv 页）** —— ⚠️ **未回原始 PDF 逐字核**，见本文开头「先读」第 1 条 |
| 本作品的对照结论 | `../../report/design/01_background_and_related_work.md` §1.3–§1.5 |
