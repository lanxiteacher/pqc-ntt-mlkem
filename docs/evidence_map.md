# evidence_map —— 评分项 → 证据地图

**主责：C（与 A 对齐）** ｜ 建立：**2026-10-18** ｜ 对应出彩组合第 6 件（10/21 截止）

> **用途**：答辩/评审时，从「一句话主张」一步跳到**可打开的文件**与**可复跑的命令**。
> 这张表**不是报告**，数字以报告正文与源文件为准；表里只放**结论和指针**。
> 判据：任何一行都能回答「文件在哪、怎么复跑、结果是什么、边界是什么」。

---

## 一、总表：五个评分项

| 评分项 | 分值 | 主证据 | 一句话结果 | 详见 |
|---|---:|---|---|---|
| **创新性** | **30** | `../docs/related-work.md`、`../report/design/01_background_and_related_work.md` §1.3–§1.5、`../report/design/02_design_and_innovation.md` | 一套参数化 RTL 出 1/4/16 三档；对外 12 位接口使引脚恒为 37（上游 16 蝶形要 397，本器件仅 125） | §二.1 |
| **性能与资源** | **20** | `../metrics/README.md`、`../rtl/vivado/reports/` | 核：LUT 727 / 2,000 / 8,922，周期 904 / 232 / 69；推算 Fmax 168 / 160 / 154 MHz；板级提频 80 / 75 / 62.5 MHz | §二.2 |
| **功能正确性** | **20** | `../refsim/`、`../rtl/probes/`、`../rtl/vivado/reports/board_*_txn.txt` | KAT 1000/1000；四条通路各 4096/4096；三档各六条命令 6/6 | §二.3 |
| **大模型协作与技能包** | **15** | `../report/ai-log/`、`../report/design/06_appendix.md`、`../skill/` | 逐日日志以 `git ls-files` 计数为准（10-19 时点 28 份）；附录摘 6 条自我纠错；技能包 4 条提示词 / 34 条坑 / 3 个校验脚本 / 3 个模板 | §二.4 |
| **文档与可复现** | **15** | `../README.md`、`../report/design/05_reproducibility.md`、`../skill/scripts/check_reproducible.sh` | 非作者（C）远端全新 clone 跑出「通过 4 / 跳过 0 / 失败 0」；B 另在干净 clone 跑 18/18 | §二.5 |

> 《选题指南》§3.3.5.3 七项正文的映射另见 `../report/design/00_front_matter.md` §三；
> 本文件按**评分表**组织，两者不是同一张表。

---

## 二、分项证据

### 2.1 创新性（30 分）

| 主张 | 证据文件 | 复跑 / 核对命令 | 结果 | 边界 |
|---|---|---|---|---|
| 22 篇公开工作 + 本队实测的对比表 | `../docs/related-work.md` | 人工读表；数字回原始 PDF | 主表 4a–4c 等 | 主表 4a–4c 器件型号、PQShield Table 3 等**未回原始 PDF**（缺口已标注） |
| 上游基线三档实测（同器件、同约束） | `../rtl/vivado/folding_comparison.md`、`../rtl/vivado/reports/pe*_utop_*.rpt` | `sh rtl/vivado/run_folding_sweep.sh` | 引脚 37 / 109 / **397**；上游 pe16 在 IO 阶段布线失败 | 上游 pe16 的 WNS 是**综合估值**，不可与布线后数字直接比 |
| 参数化改造：同一套 RTL、一个 parameter | `../rtl/folding_param_design.md`、`../report/design/02_design_and_innovation.md` | 看 `PE_NUMBER` 1 / 4 / 16 的同一份 `rtl/ntt_core/` | 三档都走完布线，IOB 恒为 37 | 「可配置折叠度」本身不是独有卖点（Information 2024 也用 `[c]×n`）；卖点是**固定宽度接口 + 同一器件三档实测** |
| 三档周期数随折叠度下降 | `../rtl/probes/README.md` §判据 2 | `sh rtl/probes/run_probes.sh` | 904 / 232 / 69（13.1×） | 周期数不含读出延迟；INTT 周期格只量周期、不当值判据 |
| 「Zynq-7020 上的 ML-KEM NTT」定位 | `../docs/related-work.md` §一 警告三 | 公开检索 | 公开检索未见 Zynq-7020 上的 ML-KEM NTT 实现 | **不写「首个」**；写「公开检索未见」 |

### 2.2 性能与资源（20 分）

| 主张 | 证据文件 | 复跑 / 核对命令 | 结果 | 边界 |
|---|---|---|---|---|
| 核三档资源 / WNS / 周期 | `../rtl/vivado/reports/pe{1,4,16}_nc_{util,timing}.rpt` | `node metrics/gen_metrics.mjs` | LUT 727 / 2,000 / 8,922；DSP 1 / 4 / 16；WNS −0.936 / −1.260 / −1.507 ns；周期 904 / 232 / 69 | 顶层 `KyberHPMNTT_top`；post-route |
| 核的**推算** Fmax | 同上 + `../report/design/03_performance_and_resources.md` §3.3 / §3.6 | 手算 `1000 / (5 − WNS)`；生成器内嵌断言 | **168 / 160 / 154 MHz** | **不是板上实测**；5 ns 是故意收紧的约束 |
| 板级 50 MHz 基线 | `../rtl/vivado/reports/board_pe{1,4,16}_{util,timing,io}.rpt` | 看 `Intra Clock Table` 的 `sys_clk` 行 | WNS **+7.339 / +6.547 / +4.789 ns**；失败端点 0；LUT 5,074 / 6,529 / 12,894 | 20 ns 约束；**不能反推 Fmax**；别抄 `Design Timing Summary` 的 async 组 |
| 板级提频（MMCM） | `../rtl/vivado/reports/board_pe*_f*_{util,timing,io}.rpt`、`../rtl/vivado/board_freq_sweep.md` | `sh rtl/vivado/run_board_freq_sweep.sh` | **80 / 75 / 62.5 MHz**；新 WNS **+0.698 / +0.754 / +1.720 ns**；资源几乎不变 | 是「按该频率烧进去可用」，**不是芯片极限**；100 MHz pe1 WNS −0.066 未采用；hold 余量 0.05–0.06 ns 很紧 |
| 端到端瓶颈归因 | `../metrics/data/bottleneck.csv`、`../report/design/03_performance_and_resources.md` §3.10.3 | `python metrics/bottleneck.py` | 核 **18.08 µs**（904 拍 ÷ 50 MHz）；串口 **184.4 ms**；核占 0.0098% | 串口段是模型值（真实字节 × 10 bit ÷ 115200）；软件参考实现随机器变 |
| 指标汇总七列表 | `../metrics/data/metrics.csv`、`../metrics/README.md` | 同上两个生成器 | 资源 / 频率 / 周期 / 瓶颈归因 | 生成块不手改 |
| Pareto / ATP / roofline | `../metrics/data/pareto.csv`、`../report/figures/pareto_atp_roofline.svg` | `node metrics/gen_pareto.mjs`；`node report/figures/gen_figures.mjs` | **ATP 最低 pe4（0.706× pe1）**；三档均在 Pareto 前沿；核需 188.0 / 686.6 / 1,923.9 MB/s，115200 只给 0.0115 MB/s（差 16,316–167,006×） | `@核 Fmax` 是工具推算、`@板上提频` 是实测频率；**功耗为估算**；带宽按每趟 2124 B 复算 |

### 2.3 功能正确性（20 分）

| 主张 | 证据文件 | 复跑 / 核对命令 | 结果 | 边界 |
|---|---|---|---|---|
| KAT 1000 条 | `../research/mlkem_kat/`、`../refsim/README.md` §一 | `sh refsim/run_fntt_check.sh` | **1000 / 1000** | 是社区维护的 **FIPS 203 兼容**向量，**不是 NIST 官方** |
| 上游 pe1 四条通路 | `../refsim/README.md` §三 | `run_fntt_check.sh` / `run_intt_pwm2_check.sh` / `run_polmul_check.sh` / `run_ntt_layers.sh` | 每条 **4096 / 4096** | 边界止于**一次多项式乘法** |
| 非退化 | 同上 §三 表 | 统计不同值个数 | 每个 4096 系数文件约 2,300+ 个不同值；最常见值约 0.2% | 不是严格概率证明；配合阴性对照 |
| 参数化三档单运算 | `../rtl/probes/README.md` §判据 3 | `sh rtl/probes/run_probes.sh` | 3 运算 × 3 档，各 **4096 / 4096**（多重集） | 判据是多重集；读出顺序单独量，不并入 |
| 改造前后逐拍等价 | `../rtl/probes/README.md`（`ag_equiv_tb.v` / `core_equiv_tb.v`） | 同上 | 三档逐拍全等（端口 + 内部状态） | 「等价 + 老核已验」才继承结论 |
| 三档完整乘法（FULL/HALF） | `../refsim/check_polmul_param.py`、`../logs/verification_2026-10-17_B_clean_clone.json` | `sh refsim/run_polmul_param_check.sh`；`python refsim/check_polmul_param.py --negative-controls` | **24,576 个系数**（3 档 × 2 模式 × 16 组 × 256）；多重集与 τ 顺序全过 | 对象是 `rtl/ntt_core`；不能替代上板 |
| ML-KEM transcript replay（无板侧） | `../logs/verification_2026-10-18_B_kem_delivery*.json`、`../refsim/accept_trace_delivery.py` | `python refsim/accept_trace_delivery.py --output <目录>` | keygen / encaps / decaps = 6 / 3 / 6，共 **15 次**正向 NTT；三档实际 RTL 回放 **45 次 / 11,520 系数**逐项全对 | **无板**：不含板级 UART；真板 15 次/档待 A；trace 基于社区兼容 KAT，非官方认证 |
| 变异测试 + 固定周期 | `../refsim/accept_strengthening.py`、`../team/handoff_2026-10-18_B_strengthening.md` | `python refsim/accept_strengthening.py --output <目录>` | 17/17 变异体被捕获（16 数值 + 1 输出 X）；三档各 103 次输入（100 随机 + 3 边界）周期恒定，核 **904 / 232 / 69** 拍 | 变异只覆盖 **pe4 / FULL**，不称全档全运算覆盖率；固定延迟不是侧信道安全证明 |
| 阴性对照 | `../report/design/04_functional_correctness.md` §4.7 | 同上 + 探针负向控制 | 改坏一处必被抓（如 4095/4096、334/4096、FATAL） | 不同守卫的失败阶段不同（编译 / `vvp` 启动） |
| 真板子端到端 | `../rtl/vivado/reports/board_pe{1,4,16}_txn.txt`（提频版 `..._f{80,75,62.5}_txn.txt`） | `sh rtl/vivado/run_board_txn_report.sh` | 三档各 **6/6**（PING + 五条计算事务，各 256 系数零差异） | 10-15 的 5/6 是向量变长格式，旧报告留底；PING 不做系数比较 |
| 波形逐拍 | `../refsim/pe1/fntt_wave_tb.v`、`../report/figures/refsim_wave_fntt_compare.png` | `python refsim/run_wave_check.py --render-svg` | 上游 pe1 FNTT 第 0 组 **256/256** | **只代表这一组**，不代表三档 / INTT / 点乘 |

### 2.4 大模型协作与技能包（15 分）

| 主张 | 证据文件 | 复跑 / 核对命令 | 结果 | 边界 |
|---|---|---|---|---|
| 逐日 AI 协作日志 | `../report/ai-log/*.md` | `git ls-files 'report/ai-log/*.md'`（再数行数） | 以命令输出为准（2026-10-19 时点 **28**） | 每天在变；附录索引行数必须等于文件数 |
| 附录索引与自我纠错摘编 | `../report/design/06_appendix.md` §A.1 / §A.2 | 对文件计数、逐条回原日志 | 索引 28 行 = 28 个文件；摘 **6 条**轨迹 | B 的 09-29～10-05 **有意不补** |
| 技能包 | `../skill/README.md` | 看各子目录的四件套表 | `prompts/` 4 条、`checklists/` 5 份 34 条、`scripts/` 3 个（+ `refsim/` 四条入口）、`templates/` 3 个 | PYNQ 模板只过语法检查，**不宣称加分** |
| 非作者独立复现咬出缺陷（CRLF 回写） | `../skill/`、`../report/ai-log/` | 回原日志 | 见附录 §A.2 | 结论只到「发现并修复」，不外推 |

### 2.5 文档与可复现（15 分）

| 主张 | 证据文件 | 复跑 / 核对命令 | 结果 | 边界 |
|---|---|---|---|---|
| 一条命令跑通验证台 | `../README.md` §三、`../refsim/README.md` | `cd refsim && sh run_fntt_check.sh` 等四条 | 全绿 | 需要 `gcc` / `iverilog` / `python` |
| 一键复现检查 | `../skill/scripts/check_reproducible.sh` | `sh skill/scripts/check_reproducible.sh --from-remote` | **通过 4 / 跳过 0 / 失败 0**，退 0（2026-10-05） | 需要联网；**不是**第二台电脑验收 |
| 非作者全新 clone | `../report/design/05_reproducibility.md` §5.6 | 同上 | C（非代码作者）从远端 clone 独立跑通 | 同一人、另一台机器上的首次；H10 的「第二台电脑」另计 |
| 同一 PC 干净 clone 18 项 | `../logs/verification_2026-10-17_B_clean_clone.json` | 读 JSON `scope` | 18 项全过 | **不算 H10 换机** |
| 报告构建 | `../report/build_report.py` | `python report/build_report.py` | Markdown → HTML → PDF；产物在 `report/build/`（不入库） | 页码/页眉在 W5 加 |
| 现场演示 GUI + 一键脚本 | `../demo/gui.html`、`../demo/run_gui.cmd` | 双击 `run_gui.cmd`；或 `node demo/gen_gui_data.mjs` 重生成数据 | 四幕（输入 / 逐层 / 对拍 / 计时资源）；页面自检 32/32 组；对拍 256/256；阴性对照 255/256（1 个红格） | **无板回放**：板上数据来自已提交的 `board_*_txn.txt`，不是现场采集；自动演示约 3 分钟 |

---

## 三、口径红线（四处必须一致）

| # | 口径 | 正确说法 | 出处 |
|---|---|---|---|
| 1 | **频率三组数** | 核**推算 Fmax** 168 / 160 / 154 MHz（5 ns 收紧约束反推，非板上实测）；板级 50 MHz WNS +7.339 / +6.547 / +4.789 ns（**不能反推 Fmax**）；MMCM 提频版 **80 / 75 / 62.5 MHz**（各 6/6，**不是芯片极限**） | `03` §3.3 / §3.10.2 / §3.14 坑 4；`docs/defense_qa.md` §四 红线 3；`demo/video_script.md` 红线 3；`metrics/README.md` 口径 1 |
| 2 | **KAT 来源** | 「社区维护的 **FIPS 203 兼容**向量集，已由参考实现独立复算验证」 | `04` §4.4；`docs/defense_qa.md` 红线 1 |
| 3 | **端到端耗时** | 0.18–0.27 s 是 **115200 串口链路**墙钟值；核只占 **0.0098%**；不说成 FPGA 性能 | `03` §3.10.3 / §3.13.6；红线 2 |
| 4 | **板级 6/6 的含义** | PING 成功 + **五条计算事务各 256 系数零差异**；PING 不做系数比较 | `04` §4.8；`03` §3.10.2 |
| 5 | **估算 vs 实测** | 尚未做的功耗只能标「**估算**」；上板没跑就不写「已上板验证」 | `logs/letter_2026-10-18_A_to_BC_plan.txt` §四 |
| 6 | **PYNQ** | 候选骨架，**未执行、不宣称加分** | `skill/README.md`、`skill/templates/README.md` |

---

## 四、出彩组合七件（2026-10-18 A 定）

| # | 项 | 主责 | 判据 | 截止 | 当前 |
|---|---|---|---|---|---|
| 1 | 板级收口（当前驱动 + 提频版） | A | 三档各 6/6（含 `#PMUL TIME 1`） | — | ✅ 10-18 |
| 2 | 921600 演示模式 | A+B | 184 → 23 ms，0 误码 | 10/22 | ✅ 10-18（A）：线上 8.0×；墙钟 3.2×，差额是 CH340 的 31 ms 往返（`../rtl/vivado/high_baud_demo.md`、`reports/board_pe1_b921600_txn.txt`） |
| 3 | ML-KEM transcript replay | B | 全部 NTT 逐位一致 | 10/22 | 🔶 10-18 无板侧完成（B）：三档实际 RTL 各 15 次、共 45 次 / 11,520 系数全对；**真板 15 次/档待 A**（`../team/handoff_2026-10-18_B_trace_delivery.md`） |
| 4 | 变异测试 + 常数时间 | B | 变异体全捕获；周期恒 904/232/69 | 10/24 | ✅ 10-18（B）：17/17 被捕获；103 组输入三档周期恒定；边界只到 pe4/FULL（`../team/handoff_2026-10-18_B_strengthening.md`） |
| 5 | 现场演示 GUI + 一键脚本 | C | 双击可跑；无板回放；3 分钟 | 10/24 | ✅ 10-19（`demo/gui.html` + `run_gui.cmd`；无头 Edge 实测） |
| 6 | 证据地图 + 口径统一 | C+A | 报告/QA/metrics/视频四处一致 | 10/21 | ✅ 10-19（本文件）；报告草稿 10-19 重建 75 页、10-20 并入 §4.11 后 76 页（以构建输出为准） |
| 7 | Pareto / ATP / roofline + 功耗估算 | C+A | 一图一表；功耗标估算 | 10/24 | ✅ 10-19（C：`metrics/gen_pareto.mjs` + 三面板图；A：功耗 10-18） |

> 边界：完整 ML-KEM RTL、AXI/PS、radix-4、PYNQ、2/8 折叠档**都不做**，
> 理由见 `../logs/letter_2026-10-18_A_to_BC_plan.txt` §四。

---

## 五、维护规则

1. **数字变了，先改源文件/报告，再改本表**；本表不先于证据。
2. 每加一个新评分项证据，必须写全**文件 / 命令 / 结果 / 边界**四格；
   缺「边界」的那一行不算完成（评审追问时最容易被扣分的就是这里）。
3. 索引类数字（日志份数、表格行数）**用命令数，不手写**：
   `git ls-files 'report/ai-log/*.md'`，再数输出行数。
4. 本文件与 `../docs/defense_qa.md`、`../demo/video_script.md` 同一套口径；
   改一处必须同步另外两处与报告。
