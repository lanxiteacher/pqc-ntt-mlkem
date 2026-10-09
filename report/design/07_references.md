# 参考文献

> **状态**：🔄 **草稿（2026-10-09）—— 这是首次把散在各处的引用收拢成一份列表，未经 A/B 核对。**
>
> **两件事要等 A 回话后才能定**（见 `../../logs/letter_2026-10-09_C_to_A.txt`）：
> ① 报告**到底要不要**单列参考文献、放在哪一段 —— 取决于《选题指南》§3.3.5.3「设计报告七项」的原文；
> ② 若单列，**用什么著录格式**（GB/T 7714 还是别的）同样以指南为准。
>
> **材料来源**：`../../docs/related-work.md` 主表与 §四 来源表、
> `../../research/pqc-ntt_ml-kem_compendium.md` §3.1–§3.5（后者信息密度最高，格式已接近文献条目）。
> **本文件与各章的「§x.7 / §x.10 数据溯源」是两件事**：那份是**内部文件指针**（「这个数出自哪个文件」），
> 这份是**外部文献**（「这项工作是谁在哪发表的」），互补、不重复。

---

## ⚠️ 先读：这份列表的完整度有限，缺口是**如实标出来的**

我们手上**没有**这些论文的完整书目信息，也**不能编**。具体缺什么，逐条标在下面：

| 缺什么 | 影响哪些条目 | 为什么缺 |
|---|---|---|
| **英文原标题** | `j49`、`xl`、`ma_tcas`、`kred24`、`ni`、`yaman`、`longa`、`nph23`、7 条侧信道工作 | 汇编里给的是**中文一句话描述**，不是原文标题 |
| **作者全名**（多数只有姓） | 除 PQShield 外几乎全部 | 汇编只记了姓 |
| **DOI / URL** | 除 PQShield（有 DOI）外几乎全部 | 未采集；`ieeexplore` / `sciencedirect` 在调研环境里反爬（见汇编 §3.5 网络备忘） |
| **venue 或年份** | `foldntt`、`ma_tcas`、`nph23`、`kred24`、Fritzmann RISQ-V | 汇编未记全 |
| **原始 PDF** | Information 2024、PQShield 等 | **PDF 本身不在仓库**（版权，见 `../../.gitignore`） |

⇒ **成文前需要 A 或 B 回原始 PDF 补齐**（`../../docs/related-work.md` §五 已把「未核」列成待办）。
标注规则：**`⚠️ 缺`** = 仓库里确实没有，**不是漏抄**；**`【未核】`** = 数值或出处尚未回原文核对。

---

## A. 标准与规范

| # | 条目 | 出处 |
|---|---|---|
| A1 | **NIST.** *Module-Lattice-Based Key-Encapsulation Mechanism Standard*（**FIPS 203**）. ⚠️ 出版年份未在仓库记录 | 本仓库副本 `../../research/standards/NIST.FIPS.203.pdf` |
| A2 | **CRYSTALS-Kyber 团队.** *Kyber v3.0 官方规格*（Round-3 支持文档）. ⚠️ **非 FIPS 203** | ⚠️ **该文件不在本仓库**（汇编 §3.5 记的路径是调研环境里的 `_round3_extract/…/kyber.pdf`）|
| A3 | **NIST.** FIPS 204（ML-DSA）／ FIPS 205（SLH-DSA）. ⚠️ **本作品未引用**，随 A1 一批下载 | `../../research/standards/NIST.FIPS.204.pdf`、`NIST.FIPS.205.pdf` |

## B. 参考实现与测试数据

| # | 条目 | 出处 |
|---|---|---|
| B1 | **pq-crystals.** *kyber* —— CRYSTALS-Kyber / ML-KEM 参考实现（C）. `ref/ntt.c` 是 twiddle 表与 INTT 层序的权威来源 | `../../research/kyber_ref/` |
| B2 | **post-quantum-cryptography.** *KAT* —— FIPS 203 **兼容**考题（ML-KEM-768，1000 条）. ⚠️ **社区维护，不是 NIST 官方发布**（措辞红线，见 `../../research/mlkem_kat/README.md` 文首） | `../../research/mlkem_kat/` |
| B3 | **NIST / Kyber Round-3 提交包.** Kyber Round-3 KAT（.req/.rsp）. ⚠️ **不是 ML-KEM 的 KAT** —— 种子派生是 `G(d)` 而非 `G(d‖K)`，**只作反面材料**（见 `../../research/verified_corrections_to_guide.md` 修正 4） | ⚠️ **不在本仓库**（同 A2）；结论记于 `../../research/verified_corrections_to_guide.md` |

## C. 公开工作（横向对比对象，对应 `../../docs/related-work.md` 主表）

| # | 条目 | 出处 / 备注 |
|---|---|---|
| C1 | **Sonbul**（⚠️ 名缺）. *Deeply Pipelined NTT Accelerator with Ping-Pong Memory and LUT-Only Barrett Reduction*. MDPI Electronics, 2026. ⚠️ 缺 DOI | 主表第 1 行；**我们 pe1 的骨架来源** |
| C2 | **Bisheh-Niasar**（⚠️ 名缺）. ⚠️ 英文原标题缺（汇编描述：「指令集式 Kyber NTT 核」）. IEEE TCAS-I **68(11)**, 2021 | 主表第 2 / 2b 行 |
| C3 | **Xing & Li**. ⚠️ 英文原标题缺（汇编描述：「最小 Artix-7 全 Kyber 硬件」）. IACR TCHES **2021(2)** | 主表第 3 行 |
| C4 | **Kieu-Do-Nguyen 等**. *Compact and Low-Latency FPGA-Based NTT Architecture for CRYSTALS Kyber*. Information, **15**, 400, 2024. ⚠️ 抽取文本里**没有具体器件型号**【未核】；PDF 不在仓库 | 主表第 4a–4c 行；`mdpi_v1.txt` / `mdpi_v2.txt` / `out_table.txt` |
| C5 | **Bertels**（⚠️ 名缺）. *A High Throughput Kyber NTT*. IACR ePrint **2025/1763** | 主表第 5 行 |
| C6 | ⚠️ **作者缺**. ⚠️ 标题缺（汇编记作 `foldntt`）. arXiv, 2026，⚠️ 编号缺【未核】. ⚠️ 该文针对 **N=1024 / Falcon**，与 Kyber 的迁移性未验证 | 主表第 6 行 |
| C7 | ⚠️ **作者缺**. ⚠️ 标题缺（汇编记作 `ma_tcas`，TCAS-I 2023）. ⚠️ 缺卷/页 | 主表第 7 行；**唯一给侧信道真板数据的** |
| C8 | **Bertels（COSIC）等**. *A Better Kyber Butterfly for FPGAs*. FPL, 2024 | 主表第 8 行；**我们的模乘单元直接抄它**，配套代码见 F2 |
| C9 | **Fritzmann 等**. *RISQ-V*（Zynq-7000 上的 Kyber NTT）. ⚠️ venue 与年份缺 | `related-work.md` §三 警告三 |
| C10 | **Kundi, Bermudo Mera, Strub, Hutter（PQShield）**. *High-Performance NTT Hardware Accelerator to Support ML-KEM and ML-DSA*. ASHES '24. **DOI 10.1145/3689939.3695785** ✅ **本列表唯一有 DOI 的一条** | `related-work.md` §四③；⚠️ Table 3 抽取有缺行，本表暂未引用其数字 |
| C11 | **Tosun**（⚠️ 名缺）. ⚠️ 标题缺（汇编记作 `kred24`，模约减横评）. ⚠️ venue 缺. ⚠️ 面向 **FHE 的 32/64 位素数**，与 Kyber 不可比大小 | 汇编 §2.3；**只读方法论，不引用数字** |

## D. 模乘与模约减

| # | 条目 | 出处 / 备注 |
|---|---|---|
| D1 | **Ni**（⚠️ 名缺）. ⚠️ 英文原标题缺（汇编描述：「LUT+K-RED 约减与免 BRAM NTT」）. IEEE ISCAS, 2023 | 汇编 §3.1 |
| D2 | **Yaman**（⚠️ 名缺）. ⚠️ 英文原标题缺（汇编描述：「Kyber 多项式乘法硬件加速器」）. DATE, 2021 | 汇编 §3.1；其开源 RTL 即 **F1**（`acmert/kyber-polmul-hw`） |
| D3 | **Longa & Naehrig**. *Speeding up the NTT*（K-RED 的源头）. CANS, 2016. ⚠️ **针对 q=12289，不适用于 Kyber** | 汇编 §3.1 |
| D4 | ⚠️ **作者缺**. ⚠️ 标题 / venue 缺（汇编记作 `nph23`，「免 DSP 模乘」，228 LUT / 0 DSP / 283 MHz） | 汇编 §3.1 |

## E. 侧信道相关工作（**仅存在性引用**——本作品不实现侧信道防护）

> 全部 ⚠️ 缺作者与标题；汇编 §3.2 只记了 ID + venue + 结论。**报告里只用于说明「有这类工作」**，
> 防守口径见 `../../research/pqc-ntt_ml-kem_compendium.md` §2.6。

| # | ID | venue |
|---|---|---|
| E1 | `ravi_shuffle` | SPACE 2020 |
| E2 | `primas` | CHES 2017 |
| E3 | `bp_shuffle` | TCHES 2023 |
| E4 | `shuffle_hw` | TCAS-II 2025 |
| E5 | `kamucheka` | FPT 2022 |
| E6 | `masked_kem_sca` | ASHES 2023 |
| E7 | `bitsliced` | ePrint 2023/1042 |

## F. 开源 RTL 仓库与工具文档

| # | 条目 | 备注 |
|---|---|---|
| F1 | **acmert/kyber-polmul-hw** —— `pe1/` 完整多项式乘法 RTL，**含 4 个测试平台** | ⭐ 我们的**基线来源**（`../../research/ref_rtl/kyber-polmul-hw/pe1/`），已通过 FIPS 203 验证 |
| F2 | **axytho/KyberButterflyCollection** —— `butterflies/` 下 10 种蝶形变体（`butterfly_Best.v` 等） | C8 论文的配套代码 |
| F3 | **Intelectron6/KYBER-on-PYNQ** —— PYNQ-Z2（= Zynq-7020）上的 Kyber 软硬协同（HLS） | 同板实现参考（⚠️ 我们是纯 PL，不走 PYNQ） |
| F4 | **bsc-loca/PQC-Crystals-HLS-Accelerators** | HLS 路线参考 |
| F5 | **SARAVANAPERUMAL-2192/FPGA-based-Hardware-Accelerator** —— 256 点 NTT，FSM 架构 | 练手参考 |
| F6 | **AMD/Xilinx** Vivado 文档：**UG901**（综合）、**UG904**（实现）、**UG949**（UltraFast 方法学） | 工具链口径（我们实装 **2020.2**，见 `03` §3.15） |

---

## 溯源

| 内容 | 出处 |
|---|---|
| 主表 1–3、5–8 行与读表警告 | `../../docs/related-work.md` §一 / §三；`../../research/pqc-ntt_ml-kem_compendium.md` §2.2 / §2.5 / §3.1–3.4 |
| 各工作的资源/频率数字 | 同上；⚠️ 引用时**必须带测量条件**（`related-work.md` §三 四条警告） |
| Information 2024 / PQShield 的抽取文本 | `../../research/kyber_ref/papers/`（PDF 不在仓库） |
| 本作品的对照结论 | `../../report/design/01_background_and_related_work.md` §1.3–§1.5 |
