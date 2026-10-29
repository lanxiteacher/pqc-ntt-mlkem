# 冻结日全量回归清单（W5 · 10/25–27）

> 目的：在**冻结提交**上把「仿真 / 上位机 / 真板 / 指标 / 报告」五条链各跑一遍，
> 留一份可直接放进提交材料的证据。**冻结之后只修不一致，不再加功能。**
> 本清单由 A 维护；B、C 各跑自己那几行。

## 0. 先钉住冻结版本（谁做都行，5 分钟）

```bash
git pull
git status --porcelain          # 必须为空（本机临时目录除外，见下）
git rev-parse HEAD              # 记下来，写进本清单末尾
git tag -a freeze-2026-10-27 -m "submission freeze"
git push origin main
git push origin freeze-2026-10-27
```

⚠️ `git status` 里允许出现的只有本机临时项：`_rebuild_logs/`、两个提交模板
（承诺书 PDF / 技术文档 DOCX）。**代码与文档不能有未提交改动。**

## 1. refsim 四条（A/B，约 2 分钟，不需要板子）

```bash
cd refsim
export PATH="/c/iverilog/bin:$PATH"
sh run_fntt_check.sh
sh run_intt_pwm2_check.sh
sh run_polmul_check.sh
sh run_ntt_layers.sh
```

**判据**：四条都 `rc=0`；前三条各 16/16 向量逐比特一致；`run_ntt_layers` 输出「逐层一致」。
证据：`logs/verification_<日期>_A_refsim.txt`（重定向保存）。

## 2. 上位机自测（B，约 1 分钟）

```bash
cd host/src
for t in test_*.py; do python "$t" || echo "FAIL $t"; done
```

**判据**：以 `ls host/src/test_*.py` 的实际个数为准（2026-10-22 为 **11 个**），全部退出 0；
`test_host.py`、`test_link.py`、`test_serial_write_safety.py` 无 FAIL。
⚠️ 不要在这里写死个数 —— 10-21 前写的是 9 个，B Phase 2 后已经过期。

## 2b. B Phase 2 总入口（B/C，不需要板子）

```bash
python refsim/accept_phase2.py --output logs/verification_<日期>_B_phase2
```

**判据**：`acceptance.json` 的 `status = complete`；100 组 NTT、3 份 trace、51 个变异体全部执行；
捕获/未捕获如实列出（10-21 为 50/51 捕获，pe1 `serializer_order` 为等价项）。
⚠️ 它会审计 A 已归档的真板回放，但**不接板、不产生新硬件证据**。

## 3. 指标生成器（C，约 2 分钟）

```bash
node metrics/gen_metrics.mjs
python metrics/bottleneck.py
node metrics/gen_pareto.mjs
git status --short metrics/     # 应只有预期内的重生成差异；有差异就提交
```

**判据**：`metrics/README.md`、`data/metrics.csv`、`data/bottleneck.csv`、`data/pareto.csv`
与报告引用的数一致；不一致就是有一处手抄过期，**改文件而不是改数**。

## 4. 真板：三档六条命令（A，约 15 分钟，要板子）

```bash
# 每档换位流；PORT 现查
BIT=rtl/vivado/_runs/pe1/ntt_board.bit  sh rtl/vivado/run_board_prog.sh
PE=1  TAG=_freeze PORT=COMx sh rtl/vivado/run_board_txn_report.sh
BIT=rtl/vivado/_runs/pe4/ntt_board.bit  sh rtl/vivado/run_board_prog.sh
PE=4  TAG=_freeze PORT=COMx sh rtl/vivado/run_board_txn_report.sh
BIT=rtl/vivado/_runs/pe16/ntt_board.bit sh rtl/vivado/run_board_prog.sh
PE=16 TAG=_freeze PORT=COMx sh rtl/vivado/run_board_txn_report.sh
```

**判据**：每档 6/6（`#PING` + 五条计算事务，各 0/256 不同）。
证据：`rtl/vivado/reports/board_pe<N>_freeze_txn.txt`。

> 可选（有时间再做）：提频版三档同样跑一遍（`_runs/f80_pe1` 等，`BAUD` 按位流），
> 以及 921600 版（`BAUD=921600` + 对应位流）。不做不影响交付，做了多一列证据。

## 5. 真板：ML-KEM trace 45 次（A，约 5 分钟，要板子）

```bash
PORT=COMx OUTTAG=_freeze sh rtl/vivado/run_kem_trace_boards.sh
```

**判据**：三档各 15/15、3840 系数，合计 45 次 / 11520 系数；`session.json` 的
`status=pass`、`transactions=15`。证据：`logs/verification_<日期>_A_kem_serial_pe{1,4,16}_freeze/`。

## 5.5 连续浸泡（A，约 40 分钟，要板子；可选）

```bash
python rtl/vivado/soak_board.py --port COMx --build 16 --minutes 40
```

**判据**：0 超时、0 数值不符、0 异常；日志 `logs/verification_<日期>_A_soak.txt`。
⚠️ 事务间隔默认 50 ms；无间隔时 CH340 可能在第 500 次左右阻塞（host 层，不是 RTL）。

## 6. 报告构建（C，约 10 分钟）

```bash
python report/build_report.py
```

**判据**：PDF 页数与 `report/README.md` 记录一致（±1 页可解释）；图表无破版；
**页码/页眉已加**（W5 项）；正文里的数与 `metrics/` 一致。
⚠️ 构建依赖 `markdown` + `pymdownx` + `pypdf` + 无头 Edge；本机（A）缺 `pymdownx`，在 C 机器上构建。
⚠️ 页码/页眉/书签由构建脚本自动叠加（`add_page_furniture`），**不要手改 PDF**；若 Edge 渲染页数变化，
脚本会拒绝合并并报出「叠层页数 ≠ 正文页数」。

## 7. 换目录复现（B/C，约 10 分钟，不需要板子）

```bash
python refsim/check_clean_clone.py --output logs/clean_clone_freeze.json
```

**判据**：能从远端 clone 并跑通；同机新目录只证明干净工作副本，**不证明换机兼容**（H10 仍缺第二台实体电脑）。

## 8. 证据归档与命名

- 真板事务：`rtl/vivado/reports/board_pe<N>_freeze_txn.txt`
- trace：`logs/verification_<日期>_A_kem_serial_pe<N>_freeze/`
- 仿真/回归：`logs/verification_<日期>_A_freeze_*.txt`
- 报告 PDF：提交件（不进 git），文件名按《指南》提交要求
- 所有日志提交到 `logs/`，并在 `logs/project_state_changelog.md` 加一条「冻结回归」

## 9. 时间预算

| 段 | 时长 | 谁 |
|---|---:|---|
| 0 冻结 + 1 refsim + 2 host | 15 min | A/B |
| 3 指标 + 6 报告 | 15 min | C |
| 4 真板三档 + 5 trace | 25 min | A |
| 7 clone | 10 min | B/C |
| 汇总 + 提交 | 15 min | 全员 |

## 10. 放行条件（全 ✅ 才能冻结）

- [x] `git status` 干净（允许本机临时项）（2026-10-29 夜；只剩 `_rebuild_logs/` 与两份空白模板）
- [x] refsim 四条 rc=0、各 16/16（2026-10-29 A；`logs/verification_2026-10-29_A_freeze_refsim.txt`）
- [x] host 全部自测 rc=0（11/11；`logs/verification_2026-10-29_A_freeze_host.txt`）
- [x] 指标生成器重跑后与报告一致（2026-10-29 C；`logs/verification_2026-10-29_C_freeze_metrics.txt`）
- [x] 真板三档各 6/6（含 `#PMUL TIME 1`）（2026-10-29 A；`rtl/vivado/reports/board_pe{1,4,16}_freeze_txn.txt`）
- [x] trace 三档各 15/15（45 次 / 11520 系数）（2026-10-29 A；`logs/verification_2026-10-29_A_kem_serial_pe{1,4,16}_freeze/`）
- [x] 报告 PDF 重建、页码已加、图表无破版（2026-10-29 C 两次：白天 63 页 / 8 书签；**晚间按 §4.11 真板 45→135 更正后再次重建，仍 63 页 / 8 书签**，SHA `29dd304b…e05e`；`logs/verification_2026-10-29_C_freeze_report.txt` §二）
- [x] `check_clean_clone.py` 通过（2026-10-29 C，21/21；`logs/clean_clone_freeze.json`）
- [ ] 冻结 tag 已推、GitHub 镜像推的是同一 commit（报告已按「真板 135 次」定稿并重建；只等用户签字材料与 A 打 tag）

---

冻结 commit：A 侧真板与回归跑在 `d84f177`；C 的 §3/§6 跑在 `145b689` 与当时构建产物上。
`d84f177` 之后到 `b5d9731` 的改动只有三类：① 证据文件（`rtl/vivado/reports/*.txt`、`logs/`）；
② 文档与状态页；③ B 的 `b5d9731` 改了 `refsim/` 三个**发布验收脚本**（`accept_b_release.py` /
`check_independent_polmul.py` / `measure_board_service.py`，加超时与失败兜底）。
**§1 的四条入口脚本不引用这三个文件，报告与证据地图也不引用** —— 16/16 与 PDF 数字均不受影响；
C 已在 `b5d9731` 上重跑四条入口（`logs/verification_2026-10-29_C_refsim_after_b.txt`）。
`host/ metrics/ demo/` 未变。正式 tag 打在最终文档提交上。
冻结日期：`2026-10-29`（回归执行日；正式 `freeze-2026-11-04` tag 尚未打）

---

## 2026-10-29 · C 执行记录（缓冲周第 2 天）

10/25–27 的冻结窗口内没有发生任何提交；10-29 由 C 在**本机**补跑只有 C 能跑的三段。

| 段 | 结果 | 证据 |
|---|---|---|
| §3 指标链 | ✅ 三生成器 rc=0；与报告一致（4.80 µs / 0.706× / 904·232·69 / 资源三档） | `logs/verification_2026-10-29_C_freeze_metrics.txt` |
| §6 报告 | ✅ 63 页、8 书签、叠层页数 = 正文页数、HTML 无内部状态块 | `logs/verification_2026-10-29_C_freeze_report.txt`；产物 `report/build/report.pdf` |
| §7 clone | ✅ 远端 `145b689` 全新 clone，21/21 rc=0，跑完无改动 | `logs/clean_clone_freeze.json` |

**§3 的一处差异与处置**：`PC 侧软件开销` 重测 5.8 → 5.5 ms。该项文档自标「单次会话、
±10%、随机器变」，报告不引用，且 `demo/data/gui.js` 仍为 5.8。**还原 HEAD、不提交**，
理由写在证据文件里。

**仍未做（需要板子或全员）**：§0 冻结 tag、§1 refsim 四条、§2 host 自测、
§2b Phase 2 入口、§4 真板三档、§5 trace 45 次、§5.5 浸泡；
以及 §10 的 `git status` 干净、GitHub 镜像同 commit 两条。
⚠️ 本次只跑 §3/§6/§7 **不构成冻结** —— 清单 §10 仍是六个未勾项。

---

## 2026-10-29 夜 · A 执行记录

按 C 的 `logs/runbook_2026-10-29_freeze_board.md` 补跑 A 侧四段（提交 `d84f177`，串口 COM9，JTAG `xc7z020_1`）。

| 段 | 结果 | 证据 |
|---|---|---|
| §1 refsim 四条 | ✅ 四条 rc=0（前三条各 16/16；`run_ntt_layers` 逐层一致） | `logs/verification_2026-10-29_A_freeze_refsim.txt` |
| §2 host 自测 | ✅ **11/11** 退出 0 | `logs/verification_2026-10-29_A_freeze_host.txt` |
| §4 真板三档 | ✅ pe1 / pe4 / pe16 各 **6/6**（含 `#PMUL TIME 1`） | `rtl/vivado/reports/board_pe{1,4,16}_freeze_txn.txt` |
| §5 count=0 trace | ✅ 三档各 15/15、3,840 系数 = **45 次 / 11,520 系数** | `logs/verification_2026-10-29_A_kem_serial_pe{1,4,16}_freeze/` |

- 位流 SHA：pe1 `037f6edd…` / pe4 `f549882f…` / pe16 `c7c03e93…`（50 MHz 基线，10-07 版）。
- trace 哈希：`e107dc71…`（10-18 交付的 count=0 trace）。
- 与 10-29 日间 J07 的 count=1/2（90 次 / 23,040 系数）合起来，真板累计 **135 次 / 34,560 系数**。
- **未做（可选）**：§5.5 40 分钟浸泡（10-21 已有 9,233/9,233）、提频位流上的新驱动冒烟、§2b Phase 2 总入口（B 10-21 已跑，本清单不重复）。

> ⚠️ **仍未冻结**：§10 只剩「冻结 tag + GitHub 镜像同 commit」一条。
> 报告已在 10-29 晚间按「真板 135 次」更正并重建（63 页，SHA `29dd304b…e05e`），
> `logs/submission_checklist.md` 第 3 行与 `_submission/README.md` 已同步；
> 剩下的是用户签字材料 + A 打 tag、推 GitHub 同一 commit。
