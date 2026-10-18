# skill —— 技能包

**主责：C** ｜ 状态：✅ **四项齐了（2026-09-29）**：`checklists/` 34 条、`prompts/` 4 条、
`scripts/` 3 个零依赖校验脚本、`templates/` 4 个骨架
｜ ✅ **§3.3.5.2 四件套逐项补齐（2026-10-06）**：每类每一项写明「适用场景 / 使用方法 /
失效条件 / 已验证的效果」，**效果一列写实测**（见 §3.3.5.2 的四件套）
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
├── README.md            ← 本文：索引 + 「§3.3.5.2 四件套」的汇总入口
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
`../team/env_align_B.md` §四、
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
| [`templates/pynq_golden_compare.py`](templates/pynq_golden_compare.py) | PYNQ 输出 → 一维整数 JSON → 独立黄金参考比对（**骨架，未上过 PYNQ**） |

⚠️ 后三个是**骨架**，`TODO` 处要填。**2026-10-06 更新**：本机 10-05 已装 iverilog
（`C:\iverilog\bin`，**不在 PATH**，先 `export`），前两个骨架已做**编译 / 语法检查**
（结论见 `templates/README.md`），但**端到端仍需补 DUT 后自验**。
PYNQ 骨架 10-18 只过 `py_compile` 与 `--help`，**从未在 PYNQ 上运行**。

---

## §3.3.5.2 的四件套 —— 每一项都在

《选题指南》p24 §3.3.5.2（同 `../competition_guide_notes.md` §8.2）要求：
`skill/` 含 `README.md` 说明**每一项的适用范围、使用方法与失效条件**；
每一项须写明**适用场景、使用方法与已验证的效果**，并说明**是从哪些失败或观察中总结得出**。
评价标准是**可复用性**。

四类**每一项**的这四条，落在各子目录的 README 里（本节是汇总入口）：

| 类 | 项数 | 四件套在哪 |
|---|---|---|
| 提示词工作流 | 4 条 | [`prompts/README.md`](prompts/README.md) §每项的四件套 —— 每条提示词文件内另有 `适用范围` / `怎么用` / `失效条件` / `本项目的实例`（即「从哪总结」） |
| 踩坑清单 | 5 份 / 34 条 | [`checklists/README.md`](checklists/README.md) §每项的四件套 —— 每条坑按 `现象→原因→怎么修→怎么预防 + 怎么发现的 + 谁扛` 写 |
| 校验脚本 | 3 个（+ `refsim/` 四条入口） | [`scripts/README.md`](scripts/README.md) §每项的四件套 |
| 工程骨架模板 | 4 个 | [`templates/README.md`](templates/README.md) §每项的四件套 |

⚠️ 「**已验证的效果**」一列**写实测**（脚本跑出的数、本机编译结果），不写「设计如此」——
空口的效果不算证据（见 `checklists/verification.md` 第 6 条「一个永远通过的测试没有价值」）。

---

## 已验证的复用结果（《指南》§3.2.5.3）

《选题指南》§3.2.5.3（PDF 第 19 页 / 印刷第 16 页）在 §3.3.5.2 之外**多要一样东西**：

> 「……以及**已验证的复用结果**（干净环境部署，或跨设备、跨场景迁移）。」

我们有两份**独立于作者本机**的运行记录。它们证的是「脚本与流程能复跑」，
**不是**「板子电气层一定通」—— 边界逐条写在表后。

| 证据 | 谁 / 何时 | 怎么做 | 结果 | 原始输出 |
|---|---|---|---|---|
| **干净环境部署** | C / 2026-10-05 | 当天用 winget 装齐 `gcc` / `python` / `iverilog`（此前本机三者都没有），按 `../README.md` 从零跑 | `refsim/` 四条入口全过（16 组 × 256/256）；`check_reproducible.sh --from-remote` **通过 4 / 跳过 0 / 失败 0、退 0**；改名后又复验一遍 | `../report/ai-log/2026-10-05_C.md` 第三段；`../report/design/05_reproducibility.md` §5.6 |
| **远端全新 clone** | B / 2026-10-17 | 从 Gitee 远端 clone 指定提交到临时目录，按 README 跑 | **18 项全过**：社区 FIPS 203 兼容 KAT 1000/1000、原四条验证入口、陪练注错、8 个 host 自测、参数化三档完整乘法回归、波形重建、UART RTL（`+fast`）；测试后跟踪文件无改动 | `../logs/verification_2026-10-17_B_clean_clone.json` |

**跨场景迁移的旁证**（三个人的机器条件不同，同一套脚本仍可用）：

- A 的机器有 Vivado 与板子；B 的机器**没有 Vivado、也没有板子**；C 的机器有
  `iverilog` / `gcc` / `python`、**没有 Vivado**。`refsim/` 与 `skill/scripts/` 在三边都能跑，
  不依赖 Vivado —— 这正是它们用相对路径、零依赖（`sh` + `awk`）的原因。
- 上位机的协议链在**陪练**（`host/src/fake_board.py`）上跑完了 691 + 97 项命令行/数据段检查、
  36 项链路检查与 160 项解包检查 —— **没有板子也能验协议衔接**。

**边界（不放大）**：

- 「全新 clone 能跑」只证明**文件与脚本齐全、可复现**，**不证明**电气层（波特率/时序、
  USB 丢字节、CH340 流控）或板子接没接 —— 那些必须上真板子（见 `../host/KNOWN_ISSUES.md`）。
- B 的 2026-10-17 记录是**同一台实体电脑**上的全新 clone，**不是第二台电脑**；
  H10 要求的「换一台电脑」仍待条件，**没有冒充完成**。
- 上位机自测的项数是**环境相关**的（装没装 `pyserial` 会改变个别分支），不要当固定值引。

---

## 通用 PYNQ Skill（候选，2026-10-18；**未取得加分**）

《选题指南》§3.3.5.2 末段与 §3.3.2 各写了一次「**通用 PYNQ Skill 单独加分**」：
Skill 须**面向 PYNQ 框架**且**不与本队题目绑定**（换题目、换板卡仍可用）。

**现状与本项目的取舍**：主实现是**纯 PL + UART**，没有 PS、没有 Overlay、没有 PYNQ 镜像
（理由见 `../report/design/01_background_and_related_work.md` §1.6）。因此我们不把
「做到 PYNQ 加分」当成既成事实。已经落地的只有两块**与题目/板卡解绑**的候选材料：

| 材料 | 是什么 | 边界 |
|---|---|---|
| [`templates/pynq_golden_compare.py`](templates/pynq_golden_compare.py) | PYNQ Overlay → 一维整数 JSON 的适配骨架 | **从未在 PYNQ 上执行**；`py_compile` 与 `--help` 通过 |
| [`../refsim/compare_integer_results.py`](../refsim/compare_integer_results.py)（B 维护，**不复制**） | 按位置精确比较的独立黄金参考比对器 + JSON 报告 | 不调硬件、不做归一化；5 个合成用例 + 6 项单元 + 2 项集成测试通过（C 10-18 本机复跑 6 项单元全过） |

两条合起来，正好对应 §3.3.2 举的第三个例子「**黄金参考比对……的工具**」。
**但它现在还缺 PYNQ 侧的真实运行证据**，所以：

- 报告与答辩里**只能写「候选材料」**，不能写「已获得 PYNQ 单独加分」；
- 要改这个结论，最低证据是：在 PYNQ 镜像上跑通**一次正确样例 + 一次故意改错的样例**，
  原始输出入库，并记录镜像版本与 bit/hwh 来源；
- 在此之前，这两块材料的价值计入「**大模型协作与技能包 15 分**」的可复用性，
  **不计入** PYNQ 单独加分。

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
- 分工与逐周计划：`../team/guide_C.md`
- 项目记录：`../logs/project_state.md`
