# skill —— 技能包

**主责：C** ｜ 状态：✅ **四项齐了（2026-09-29）**：`checklists/` 34 条、`prompts/` 4 条、
`scripts/` 3 个零依赖校验脚本、`templates/` 3 个骨架
｜ 对应评分项：**大模型协作与技能包（15 分）**

> 位置与内容要求见 `../competition_guide_notes.md` §8.2。
> AI 协作**记录**（逐日日志）不在这里，在 `../report/`。

---

## 这是什么

把这次用过的**提示词、脚本、流程、踩坑**整理成**别人拿去就能用**的东西。
评价标准就一条：**可复用性**。

⚠️ **这一项的分不是靠"我们用了 AI"，是靠"我们总结出了别人能复用的方法"。**

---

## 目录约定

```
skill/
├── README.md            ← 本文：索引 + 每项的适用范围/使用方法/失效条件
├── prompts/             提示词工作流
├── checklists/          踩坑清单
├── scripts/             校验脚本
└── templates/           工程骨架模板
```

新建子目录时**先在群里说一声**（目录名一律英文，见 `../CLAUDE.md`）。

---

## 四项必交内容

### 1. `prompts/` —— 提示词工作流 ✅（2026-09-29）

四条，其中前两条是选题指导 §8.2 点名要求的：

| 提示词模板 | 用途 | 状态 |
|---|---|---|
| [`prompts/01_hardware_software_partition.md`](prompts/01_hardware_software_partition.md) | 从算法描述推导软硬划分 | ✅ |
| [`prompts/02_bottleneck_from_reports.md`](prompts/02_bottleneck_from_reports.md) | 根据综合报告定位瓶颈 | ✅ |
| [`prompts/03_explain_your_own_code.md`](prompts/03_explain_your_own_code.md) | 让 AI 讲懂它自己写的代码（答辩要能复述原理） | ✅ |
| [`prompts/04_every_number_has_a_source.md`](prompts/04_every_number_has_a_source.md) | 每个数都要有出处（防「顺手补全」） | ✅ |

每条写清五件事：**适用范围 / 不能用 / 使用方法（可直接复制的原文）/ 期望得到什么 /
失效条件**，外加一段 `本项目的实例`（问出了什么、从哪个失败里总结的）。

> `04` 是原计划里没有的，是**本项目踩了两次之后补的**：
> 一次是往对比表里补了源表里根本没有的 FF 一列，
> 一次是把 `fqmul(zeta, b)` 写成 `zeta × b`（格式都对、事实都错）。

### 2. `checklists/` —— 踩坑清单 ✅（2026-09-29）

按主题分成五份，共 **34 条**，每条写清 **现象 → 原因 → 怎么修 → 怎么预防**，
外加 **怎么发现的**（决定下次能不能更快发现）与 **谁扛**：

| 文件 | 主题 | 条数 |
|---|---|---|
| [`checklists/data-format.md`](checklists/data-format.md) | 数据文件的编码与行尾 | 6 |
| [`checklists/verification.md`](checklists/verification.md) | 验证方法学：怎么才算「验过了」 | 9 |
| [`checklists/rtl-and-timing.md`](checklists/rtl-and-timing.md) | RTL、时序、资源报告 | 6 |
| [`checklists/toolchain-and-board.md`](checklists/toolchain-and-board.md) | 工具链与上板 | 8 |
| [`checklists/ai-collaboration.md`](checklists/ai-collaboration.md) | 与 AI 协作时特有的坑 | 5 |

原料汇总自五处（都是本项目一手记录，不是通用建议）：
`../CLAUDE.md` 的「约定」6 条、`../refsim/README.md` §七/§八、
`../team/FPGA竞赛_B_Claude环境对齐指南.md` §四、
`../competition_guide_notes.md` §7、
`../logs/project_state_changelog.md`。

### 3. `scripts/` —— 校验脚本 ✅（2026-09-29）

选题指导点名的三类：

| 类别 | 在哪 | 说明 |
|---|---|---|
| ① 自动比对黄金模型 | **`../refsim/` 四条入口**（不复制） | 本仓库最成熟的资产，各自自包含；复制会分叉 |
| ② 检查资源与时序 | `../metrics/gen_metrics.mjs` | 从报告**解析**出数字生成表，不手抄 |
| ③ 验证工程可复现性 | [`scripts/check_reproducible.sh`](scripts/check_reproducible.sh) | 干净目录 + 全新 clone + 从零跑 |

另外新写了两个通用校验（本项目的格式坑全是「数值全对、比对全错」，
肉眼看不出来）：
[`scripts/check_data_format.sh`](scripts/check_data_format.sh)（每行 3 位小写十六进制 + LF）、
[`scripts/check_nondegenerate.sh`](scripts/check_nondegenerate.sh)（不同值占比 + 最常见值占比）。

**三个脚本只用 `sh` + `awk`，零依赖** —— 别人拿去不用先装东西。
各脚本的关键坑、资源报告的四个必查项，都写在 [`scripts/README.md`](scripts/README.md)。

### 4. `templates/` —— 工程骨架模板 ✅（2026-09-29）

| 模板 | 用途 |
|---|---|
| [`templates/vivado_nonproject.tcl`](templates/vivado_nonproject.tcl) | 非工程模式「量数字」脚本（含两个环境雷区） |
| [`templates/batch_testbench.v`](templates/batch_testbench.v) | 批量对拍 testbench 骨架（有界等待 / 好定位的报错 / 顺序注释） |
| [`templates/run_checks.sh`](templates/run_checks.sh) | 一键验证脚本骨架（相对路径 / 工具预检 / 逐项报） |

⚠️ 后两个是**骨架**，`TODO` 处要填；`batch_testbench.v` 本机没有 iverilog，
**没有编译验证过**，套用时先跑最小例。

---

## 写法要求

- **面向"下一个做类似题目的人"写**，不是面向评委写。他不需要知道我们是谁，
  他需要知道**怎么做**。
- 每条都写清「**从哪些失败或观察中总结**」「**为什么有效**」「**边界如何确定**」
  —— 这三句是选题指导 §8.2 原话。
- 不写评价性、安慰性语言（`../CLAUDE.md` 约定 6）。自查：这句话删掉之后信息有没有损失？

---

## 相关

- AI 协作**日志**：`../report/`
- 分工与逐周计划：`../team/FPGA竞赛_C_引导与计划.md`
- 项目记录：`../logs/project_state.md`
