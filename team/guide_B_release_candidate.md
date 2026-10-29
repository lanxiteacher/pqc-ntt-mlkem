# B 源码候选验收与交付说明

本入口验证指定源码候选，不能替代团队最终冻结、真实板卡测试、本人手动验收或正式提交。
要求 Python、pyserial、git、sh、gcc、iverilog/vvp；不需要 Vivado 或板子。

## 最短检查

仓库根目录运行：

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/test_board_run_failures.py
```

它仅检查 CLI 生命周期与失败留证。完整结果还要看下面的验收记录，不能以这一条代替全量验证。

## 完整候选验收

先提交并推送代码，使本机与远端对应同一提交；输出目录必须在仓库外且尚不存在。
运行期间不修改源码、不拉取其他版本；工具链速度随机器而变，需预留数十分钟。

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/accept_b_release.py --output ../B_release_candidate_01
```

执行顺序：完整 B Phase 2 与 Host 回归、独立卷积、板级服务时间、远端干净 clone、
源码包导出及逐文件解压哈希检查，最后运行解压包内 CLI 检查。每阶段日志和总 `acceptance.json`
都在输出目录；中途失败不生成通过结论，旧目录不覆盖。

远端在运行中若发生提交，干净 clone 可能对应新版本，工具会拒绝把它写成旧候选通过。
此时对齐版本后重新核对，不得手改 commit 字段掩盖差异。

## 两个新增科学检查的范围

- `check_independent_polmul.py`：以朴素模 x^256+1 卷积独立验证三档 FULL，
  包含 16 组输入、单项式绕回与固定种子随机值；不使用 C NTT 或 basemul 作答案。
- `measure_board_service.py`：临时插入观察代码，不修改 RTL；用真实板级 wrapper、FSM、核，
  保留输出逐项检查。UART 仅在仿真中设为 5 Mbaud，板级时钟仍为 50 MHz。
  分别测进入 S_LOAD 到 S_START、S_READ、后续 S_RESP 的周期差。
  连续两次 NTT 的装载入口间隔含测试台和模拟 UART，不能当最大启动速率或真板吞吐。

## 源码包与最终包

```powershell
python refsim/build_source_candidate.py --ref HEAD --output ../B_source_candidate_01
```

`source.zip` 只含该提交已跟踪的字节；`manifest.json` 记录提交号、归档哈希和逐文件哈希，
`extracted/` 是实际解压核验副本。生成工具不发布仓库，不推镜像，不替团队打冻结标签。

最终提交还须单独加入：实际位流和身份表、最终 PDF、最终视频、签署材料，并核对同一版本。
位流身份表至少含 PE、频率声明、波特率、SHA-256、生成提交、烧录命令和对应测试记录。
最终压缩包解压后再检查，不能只验证开发目录。

## 仍需外部条件

1. A 提供位流、约束覆盖说明，并确认最终运行版本的真板验收范围。
2. 第二台电脑可用时完成 H10；多次同机 clone 不等于第二台实体电脑。
3. A/C 提供最终报告、视频和提交材料，团队确定冻结提交后推最终镜像、公开和提交。
4. B 本人手动运行的验收保留单独记录；AI 自动执行不能替本人签收。

## 已有完整核心结果时的复用

`--reuse-b-current ../B_release_2026-10-29_01/b_current` 可引用既有完整验收目录；工具逐项验证源文件哈希，拒绝不相符结果。四个独立发布工具须在本轮另行执行。这不等于所有检查在新提交重跑。本轮最终结果与版本见 `handoff_2026-10-29_B_closeout.md`。

10-29 现状订正：A 已交位流包和约束覆盖说明，视频已完成；外部待办是最终集成、UART 风险处理、技术文档、报名表及冻结/公开。不得把上面的包范围清单读成全队尚未制作。
