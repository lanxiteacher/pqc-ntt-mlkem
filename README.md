# 后量子密码FPGA加速平台

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
| **硬件加速核** | `refsim/pe1/` —— 在开源硬件基线 `kyber-polmul-hw/pe1` 上改造的工作副本；`rtl/` —— 交付给 Vivado 工程的产物（参数化核 `rtl/ntt_core/`、板级设计 `rtl/board/`、探针 `rtl/probes/`、综合脚本与报告 `rtl/vivado/`） |
| **验证台** | `refsim/` —— 用兼容考题锚定参考实现，再拿参考实现逐比特对拍 RTL |

验证台是本仓库的核心资产。它回答的问题不是"作者的 testbench 跑没跑通"，
而是"**这份 RTL 算得对不对**"——这两件事不一样，理由见 `refsim/README.md` 开头。

---

## 二、当前进度

> **2026-10-17 补充**：参数化 `rtl/ntt_core/` 三档 FULL/HALF 已新增独立回归 `python refsim/check_polmul_param.py --negative-controls`；各 16 组，多重集与协议顺序逐项比较均通过。下方旧表保留上游基线范围。全新克隆复跑入口 `python refsim/check_clean_clone.py --output logs/clean_clone.json`，需 git/sh/gcc/Python/iverilog/vvp；本机远端全新克隆通过，不等于第二台电脑或真板验收。当前 B 清单见 `team/plan_B_remaining.md`。

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

> 状态截至 **2026-10-05**。上表四项验的是**上游基线**（`research/ref_rtl/kyber-polmul-hw/pe1/`）；
> 本项目自己的参数化版本 `rtl/ntt_core/` 见下第三条。

- **ML-KEM 更外层的运算**：向量级点乘累加（`polyvec_basemul_acc_montgomery` 那一层）、
  base case 乘法、以及 `poly_tomont` / `poly_reduce` 归位。
  **已判定不做** —— 仓库里没有对应的 RTL，没有可验的对象。这条即本项目的验证边界。
- **多 PE 配置的功能正确性**：上表四通路只覆盖 **`PE_NUMBER=1`**（`refsim/` 那套链子）。
  `rtl/ntt_core/`（把上游三档手工副本合并成的参数化版本）自己的证据在 `rtl/probes/`
  （`sh rtl/probes/run_probes.sh` 可复跑），已有**「与上游逐拍等价 + 三档周期数逐个对齐
  + 三档功能对拍（3 运算 × 3 档 × 4096 系数全中，2026-09-29）」**。
  ⚠️ 该对拍判的是**多重集相等**（装载与读出顺序分开判）。**2026-10-05 订正**：原列的两项
  缺口（完整乘法 FNTT→PWM2→INTT 端到端、PWM2 两 bank 装不同数据）**都已验掉**（前者三档
  真板子 PASS，后者探针 `-DOP_PWM2AB` 三档 4096/4096）。⚠️ 验证在 `rtl/probes/`，不在 `refsim/` 链子里。
- **综合与资源**：上游基线三档已综合/实现（2026-09-22；⚠️ pe16 只到综合未布线）。资源与频率见
  `rtl/vivado/folding_comparison.md` 与 `rtl/vivado/reports/`。**参数化版本三档已综合并布线**（§九）；板级亦已到 bitstream。
- **功耗**：已完成 **vectorless 估算**（50 MHz 三档 **0.130 / 0.170 / 0.335 W**，提频 0.257 / 0.300 / 0.440 W；Confidence Medium、只算片内 PL，**非实测**）—— `rtl/vivado/power_estimate.md`，复跑 `sh rtl/vivado/run_board_power.sh`。
- **上板**：**NTT 核已上板（2026-10-04）** —— 板级 wrapper 见 `rtl/board/`（顶层 / 状态机 /
  行组装 / XDC），三档 pe1/pe4/pe16 各五条事务 256/256；PL 通路更早于 2026-09-29 用官方 `19_uart_loopback` 校验（16 字节原样返回）。
- **上位机与协议**：`host/proto.md` 已**冻结 v1.0（2026-09-29 生效）**，比原计划 W2 提前。
  PC 端上位机已成形（`host/src/` 14 个 `.py` / 4289 行，7 个自测全绿，含对真串口跑事务的
  `board_run.py`）；板子端实现即 `rtl/board/`。⚠️ 冻结说明 `host/proto.md` §九(d) 如实列了
  四个已知缺口，其中一条是**FNTT 的回传顺序随折叠度变**（pe1 交织 / pe4、pe16 自然序）。
- **板级进阶（2026-10-18 / 10-21 补）**：基线三档各 **6/6**（5 条计算 + 1 条 `#PING` 探活），
  提频版 **80 / 75 / 62.5 MHz** 各 6/6；真实 ML-KEM trace **45 次 / 11,520 系数**逐位一致；
  40 分钟浸泡 **9,233 次 `#NTT` 0 错**（0 超时 / 0 数值不符 / 0 异常）。
  常用入口（板级脚本都在 `rtl/vivado/`，不需要 GUI）：

  ```sh
  BIT=<位流> sh rtl/vivado/run_board_prog.sh                        # 烧录
  PE=1 TAG=<标签> PORT=<COMx> sh rtl/vivado/run_board_txn_report.sh  # 探活 + 五条计算事务
  sh rtl/vivado/run_board_freq_sweep.sh                             # 提频综测（不需要板子，约 30 分钟）
  sh rtl/vivado/run_board_power.sh                                  # 功耗估算（不需要板子）
  PORT=<COMx> sh rtl/vivado/run_kem_trace_boards.sh                 # ML-KEM trace 三档送板
  python rtl/vivado/soak_board.py --port <COMx> --build 16 --minutes 40  # 连续浸泡（带看门狗）
  python host/src/board_run.py "#NTT 1" --check --build 1 --port <COMx> --baud 921600  # 921600 演示
  ```

覆盖边界的完整说明在 `refsim/README.md` 第八节。

---

## 三、快速开始

需要 `git`、`gcc`、`python 3`、`iverilog`。详见第七节。

```sh
git clone <本仓库地址> pqc-ntt-mlkem
cd pqc-ntt-mlkem/refsim

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
pqc-ntt-mlkem/
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
├── team/ demo/ docs/ assets/  分工 / 演示页 / 文档 / 素材
├── report/ skill/ metrics/ status/  设计报告 / 技能包 / 指标 / 进度页
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

### 目录对照说明（《选题指南》§3.3.5.4）

《选题指南》§3.3.5.4 给了一套**推荐**目录结构，并写明「采用其他组织方式的队伍
**须**在 README.md 中给出目录对照说明」。本仓库按自己的需要组织，故逐项对照如下。

| 指南推荐 | 本仓库对应 | 说明 |
|---|---|---|
| `README.md` | `README.md` | 直接对应（本文件） |
| `src/` | `rtl/` ＋ `host/src/` ＋ `refsim/pe1/` | 设计源码拆成三处：**RTL 交付产物**在 `rtl/`；**PC 上位机**在 `host/src/`；**开源基线的工作副本**在 `refsim/pe1/` |
| `sim/` | `refsim/`（＋ `rtl/probes/`、`rtl/board/tb/`） | `refsim/` 是 RTL 软硬件一致性验证台（本仓库核心资产）；参数化版仿真探针在 `rtl/probes/`，板级 testbench 在 `rtl/board/tb/` |
| `build/` | `rtl/vivado/` | Vivado 采用 non-project 模式，无独立 build 目录；综合/实现脚本与报告都在 `rtl/vivado/`（含 `reports/`） |
| `board/` | `rtl/board/`（＋ `rtl/vivado/board_prog.tcl`） | 上板顶层、协议状态机、引脚约束 XDC、板级运行脚本 |
| `data/` | `research/mlkem_kat/` ＋ `research/kyber_ref/` ＋ `refsim/batch/` ＋ `demo/data/` ＋ `metrics/data/` | 无单一 data 目录：FIPS 203 兼容考题、C 参考实现（地面真值）、黄金向量与 RTL 落盘输出、演示页数据、指标表各自就近存放 |
| `skill/` | `skill/` | 直接对应（含 `checklists/` `prompts/` `scripts/` `templates/`） |
| `report/` | `report/`（＋ `demo/` `docs/` `assets/`） | 设计报告正文与**大模型协作记录**在 `report/`；演示页在 `demo/`，支撑文档在 `docs/`，截图录屏素材在 `assets/` |

本仓库另有以下目录，不属上表八项：

| 目录 | 用途 |
|---|---|
| `host/` | PC 上位机：串口喂数据 + 收回 + 自动比对（含冻结的串口协议 `host/proto.md`） |
| `logs/` | 项目记录与进度排期（`project_state.md` 是开工唯一入口） |
| `team/` | 分工与个人计划（可直接转发队友） |
| `metrics/` | 指标汇总表（《选题指导》§8.3 要求每项写清测量条件与证据文件） |
| `status/` | 项目进度可视化页（`node status/gen_status.mjs` 生成） |
| `research/` | 只读参考资料（开源硬件基线、C 参考实现、NIST 标准） |
| `selection/`、`_refbuild/` | 历史归档：选题过程、参考实现早期 bench |

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
