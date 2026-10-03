# 基于 FPGA 的后量子密码硬件加速平台

> AMD 赛道 · 3.3 自主选题（初级组）
> 目标器件：正点原子领航者 ZYNQ-7020（XC7Z020）
> 许可证：[Apache License 2.0](LICENSE)

以 ML-KEM 的核心运算 **NTT（数论变换）** 为切入点，在 FPGA 上实现低延迟的
多项式乘法加速核，并配套一条以 FIPS 203 兼容考题为终点的**软硬协同验证链**。

---

## 一、这是什么

ML-KEM（FIPS 203，即 CRYSTALS-Kyber）是 NIST 后量子密码标准中的密钥封装算法。
其中计算量最大的一步是 **NTT** —— 在模 q = 3329 的有限域上，对 256 点多项式做变换。

本仓库包含两部分：

| 部分 | 内容 |
|---|---|
| **硬件加速核** | `refsim/pe1/` —— 在开源硬件基线 `kyber-polmul-hw/pe1` 上改造的工作副本；`rtl/` —— 交付给 Vivado 工程的产物（当前为 twiddle 表） |
| **验证台** | `refsim/` —— 用兼容考题锚定参考实现，再拿参考实现逐比特对拍 RTL |

验证台是本仓库的核心资产。它回答的问题不是"作者的 testbench 跑没跑通"，
而是"**这份 RTL 算得对不对**"——这两件事不一样，理由见 `refsim/README.md` 开头。

---

## 二、当前进度

### 已验证

| 项 | 结果 |
|---|---|
| FNTT（正向 NTT） | ✅ 16 组向量，4096/4096 系数逐比特一致 |
| INTT（逆向 NTT） | ✅ 16 组向量，4096/4096 |
| PWM2（点乘，NTT 域） | ✅ 16 组向量，4096/4096 |
| 完整多项式乘法 FULL（FNTT→FNTT→PWM2→INTT） | ✅ 16 组向量，4096/4096（端到端，无缩放因子） |
| 半程多项式乘法 HALF（FNTT→PWM2→INTT） | ✅ 16 组向量，4096/4096（端到端，无缩放因子） |
| 往返自检（RTL 的 FNTT 实际输出灌回 RTL 的 INTT） | ✅ 4096/4096 回到时域原值 |
| 阴性对照（人为改坏一个期望值） | ✅ 恰好报出 1 个系数不符，且位置正确 |
| 非退化性 | ✅ 每 4096 个系数中 2355～2374 个不同值，最常见值占比 < 0.25% |

"验证通过"必须配"非退化"才作数——向量全是常量时，全中也可能只是巧合。
上表最后一行是这个判据的实测值。

### 尚未验证

> 状态截至 **2026-09-29**。上表四项验的是**上游基线**（`research/ref_rtl/kyber-polmul-hw/pe1/`）；
> 本项目自己的参数化版本 `rtl/ntt_core/` 见下第三条。

- **ML-KEM 更外层的运算**：向量级点乘累加（`polyvec_basemul_acc_montgomery` 那一层）、
  base case 乘法、以及 `poly_tomont` / `poly_reduce` 归位。
  **已判定不做** —— 仓库里没有对应的 RTL，没有可验的对象。这条即本项目的验证边界。
- **多 PE 配置的功能正确性**：上表四通路只覆盖 **`PE_NUMBER=1`**（`refsim/` 那套链子）。
  `rtl/ntt_core/`（把上游三档手工副本合并成的参数化版本）自己的证据在 `rtl/probes/`
  （`sh rtl/probes/run_probes.sh` 可复跑），已有**「与上游逐拍等价 + 三档周期数逐个对齐
  + 三档功能对拍（3 运算 × 3 档 × 4096 系数全中，2026-09-29）」**。
  ⚠️ 该对拍判的是**多重集相等**（装载与读出顺序分开判），**仍未覆盖**：完整乘法
  FNTT→PWM2→INTT 端到端、PWM2 两 bank 装不同数据。⚠️ 这些验证在 `rtl/probes/`，
  **不在 `refsim/` 那套链子里** —— `refsim/` 跑的仍是上游基线。
- **综合与资源**：上游基线三档已综合/实现（2026-09-22），资源与频率见
  `rtl/vivado/folding_comparison.md` 与 `rtl/vivado/reports/`。**参数化版本尚未综合。**
- **功耗**：未测。
- **上板**：PL 通路已实测跑通（2026-09-29，官方 `19_uart_loopback` 串口回环，16 字节原样返回）。
  **NTT 核本身尚未上板** —— 还差一层板级 wrapper（时钟 / 复位 / UART）。
- **上位机与协议**：`host/proto.md` 已**冻结 v1.0（2026-09-29 生效）**，比原计划 W2 提前；
  PC 端上位机未开工，板子端也一行代码都没有（冻结的是**纸面协议**）。
  ⚠️ 冻结说明 `host/proto.md` §九(d) 如实列了四个已知缺口，其中一条是
  **FNTT 的回传顺序随折叠度变**（pe1 交织 / pe4、pe16 自然序）—— 协议正文尚未据此修订。

覆盖边界的完整说明在 `refsim/README.md` 第八节。

---

## 三、快速开始

需要 `git`、`gcc`、`python 3`、`iverilog`。详见第七节。

```sh
git clone <本仓库地址> FPGA
cd FPGA/refsim

sh run_fntt_check.sh          # NTT 全流程：KAT → 参考实现 → RTL
sh run_intt_pwm2_check.sh     # INTT + 点乘 + 往返自检
sh run_polmul_check.sh        # 完整多项式乘法（端到端）：FULL + HALF
sh run_ntt_layers.sh          # 导出并机器验证 twiddle 层序表
```

三条主脚本都是全自动的。`iverilog` 不在 PATH 里时脚本会自己加
`/c/iverilog/bin`。预期输出见 `refsim/README.md` 第三节。

---

## 四、目录结构

```
FPGA/
├── CLAUDE.md                  AI 协作约定与项目环境说明
├── logs/                      项目记录与进度排期
│   ├── project_state.md   当前状态与待办 —— 开工只读这一份
│   ├── project_state_background.md  硬约束/评分规则/风险 —— 做决策时读
│   ├── project_state_changelog.md  变更记录（只增）—— 追溯时读
│   ├── project_state_archive.md  更早的过程
│   └── schedule_plain.md  人话版，可直接转发队友
├── LICENSE                    Apache License 2.0
├── NOTICE                     Apache-2.0 要求的声明文件
├── THIRD_PARTY_LICENSES.md    第三方组件清单与许可证
│
├── refsim/                    RTL 软硬件一致性验证台
├── host/                      PC 上位机（串口喂数据 + 收回 + 自动比对）
├── rtl/                       改造后的 RTL、引脚约束、Vivado 工程
├── team/                      分工与个人计划
├── demo/  docs/  assets/      演示页 / 报告 / 截图录屏素材
│
├── research/                  参考资料（只读）
│   ├── ref_rtl/               开源 NTT 硬件基线
│   ├── kyber_ref/             ML-KEM C 参考实现（地面真值）
│   ├── mlkem_kat/             FIPS 203 兼容考题 1000 条
│   ├── standards/             NIST FIPS 203 / 204 / 205
│   └── pqc-ntt_ml-kem_compendium.md
│
├── selection/                 历史：选题过程
└── _refbuild/                 历史：参考实现早期 bench
```

目录名一律英文。`research/` 是只读的——对基线 RTL 的任何修改都在
`refsim/pe1/` 的副本上做。

---

## 五、验证链

```
   FIPS 203 兼容考题（1000 条，逐比特）
              │  kat_verify.c 四项独立复算，1000/1000 通过
              ▼
   C 参考实现（research/kyber_ref/）  ←── 从此它是"地面真值"
              │
              ▼
   黄金向量 ── 灌进 RTL ── 逐比特对拍
              ▼
   ∴ 这份 RTL 的 NTT / INTT / 点乘 / 完整多项式乘法符合 FIPS 203
```

**为什么不能只跑作者的 testbench**：作者的 testbench 是拿作者自己给的期望输出
去比作者自己的 RTL，只能证明自洽。万一期望值本身就错了（twiddle 表排错、
域约定选错），testbench 照样打印 `Correct!`。

**作者数据也被独立复算过**：`KYBER_DIN*_MFNTT.txt` 与参考实现逐比特一致
（512/512 个系数），这同时证明作者的数据没错、且我们对域约定与输出顺序的
理解与作者一致。

**单运算与端到端性质不同**：INTT / PWM2 的期望值需按常数因子换算
（R = 2¹⁶ mod q = 2285，R⁻¹ = 169），配有往返自检背书；FULL / HALF 端到端
没有任何缩放因子，逐比特直接比。

完整的验证设计、踩过的坑、覆盖边界见 **`refsim/README.md`**。

---

## 六、环境要求

| 需要 | 怎么来 | 备注 |
|---|---|---|
| `iverilog` 12.0 | `winget install --id Icarus.Verilog` | 装在 `C:\iverilog\bin`，**不在 PATH 里** |
| `gcc` | MinGW-w64 或任意带 gcc 的发行版 | 编译 C 参考实现外壳 |
| `python 3` | 任意 | 向量生成与比对 |
| `git` | 任意 | |

脚本是 `.sh`，在 Git Bash 里跑（命令前加 `sh`）。

⚠️ **行尾被 `.gitattributes` 锁死为 `* -text`，不做任何转换。**
不要改成 `text=auto` 或 `eol=lf`——那两种都会在 checkout 时改写字节，
会让对拍 `diff` 报出"256 行全不同"而数值一个不差。理由写在 `.gitattributes` 注释里。

---

## 七、第三方组件与许可证

本作品依据 **Apache License 2.0** 发布。所用第三方组件均为宽松许可
（CC0 / MIT / Apache-2.0），与本作品许可证兼容，详见
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)。

与本作品源代码直接相关的两处：

| 组件 | 出处 | 许可证 |
|---|---|---|
| 多项式乘法硬件基线 `research/ref_rtl/kyber-polmul-hw/` | Mert & Yaman | CC0 1.0 |
| ML-KEM C 参考实现 `research/kyber_ref/` | pq-crystals/kyber | CC0 1.0 或 Apache-2.0 |

`rtl/` 与 `refsim/pe1/` 下的 RTL 是在前者基础上改造得到的。

---

## 八、团队分工

| 角色 | 负责 |
|---|---|
| **A** | `rtl/` —— RTL 改造、引脚约束、Vivado 综合与上板 |
| **B** | `refsim/` `host/` —— 验证台、上位机、开源仓库 |
| **C** | `demo/` `docs/` `assets/` —— 演示页、设计报告、录屏素材 |

细节见 `team/` 目录。
