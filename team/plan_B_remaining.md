# B 当前任务清单（2026-10-17）

这份清单按实物与测试输出更新。旧的 `guide_B.md`、`todo_AB.md` 保留原计划，不能据其旧日期判断今天的进度。

## 已完成，可以交接

| 工作 | 结果与入口 |
|---|---|
| 复核 A 的装载顺序修正 | 符合 `host/proto.md` §5.3.4；三档五命令各 16 组的协议链通过，见 `host/src/test_board_pipeline.py` |
| 有效向量补零 | 三个文件每行三位十六进制、LF；逐项数值未改，生成器同步修正；审计 `python refsim/normalize_host_vectors.py` |
| 上位机完整路径 | 八个自测通过；已知向量物理排列回放覆盖 240 次事务，另有 15 次 CLI 路径和负向控制。回放模型不计算 NTT |
| 三档完整乘法（10-15 新任务） | `python refsim/check_polmul_param.py --negative-controls`：参数化核 pe1/4/16 × FULL/HALF，每轮 4096 项，多重集与逐项排列均通过；原六个 shell 入口未改 |
| H5 波形交付 | PNG、SVG、TB 与生成器均入库；`python refsim/run_wave_check.py --render-svg` 可重建；仅上游 pe1 FNTT 第 0 组 |
| 协议文档收口 | 失效引用改文字/节号定位，补上行结果列，回填 H7、注错与向量状态；帧、接口、时序未改 |
| 本机远端全新克隆 | 提交 `206f957` 的 18 项检查通过，包含重新编译、社区兼容 KAT、原回归、新回归、波形与 UART RTL `+fast`；测试后跟踪文件无改动 |
| 当日 AI 日志与技术交接 | `report/ai-log/2026-10-17_B.md`、`logs/letter_2026-10-17_B_to_AC.txt` |

完整输出：`logs/verification_2026-10-17_B_clean_clone.json`。协议文档随后更新，另有 `logs/verification_2026-10-17_B_protocol_docs.txt` 记录八个自测复核。记录各自的被测版本，不把后续文档提交冒充先前全新克隆的版本。

## 仍需完成

1. **A 上板，B 配合核对结果**：先保留旧报告，再用当前驱动补跑 `#PMUL TIME 1`，最好三档都用入库脚本复核。文件格式阻塞已解除，但软件仿真通过不能代填真板结果。A 的 10-15 pe1 报告仍是 5/6。
2. **B 的 H10 第二台实体电脑验收**：用户确认目前没有第二台电脑，暂不完成这条。已有工具 `python refsim/check_clean_clone.py --output logs/clean_clone_second_pc.json` 可供届时复跑；需安装 git、sh、gcc、Python、iverilog/vvp。同机新目录只证明干净工作副本，不能证明换机兼容。
3. **W5 冻结后开源镜像**：B 负责打包与复现说明，A 配合账号/最终冻结提交。按既定决定一次性推冻结版，不做日常双向同步；尚未创建 GitHub 镜像或更改 Gitee 可见性。
4. **提交前检查与答辩练习**：跟进 A/C 采用本次证据、实际冻结版本复跑，并能解释下面四句话。不可补造过去日期的 AI 日志、真板日志或录屏。

## B 应能用自己的话解释

- FPGA 做 NTT、INTT 与 NTT 域乘法，PC 负责送数、收数和与参考结果比较；没有实现整套 ML-KEM，也没有 PS/AXI 软件系统。
- FULL 是两份时域输入各做 NTT，再点乘、INTT；HALF 的 B 输入已经在 NTT 域，所以少做一次 NTT。
- 三档表示核内并行度不同，输入和输出的物理排列也可能不同；上位机要按命令与 build 查表，数值相同但位置不同也会失败。
- C 参考实现重新计算标准答案；RTL 必须实际运行并逐项比较。故意打乱输入、改坏答案的测试必须失败，才能证明检查器会发现错误。

社区 FIPS 203 兼容 KAT 1000/1000 是对 C 参考实现的锚定，不是 NIST 官方向量，也不是 FPGA 完整密钥封装算法的认证。

UART `+fast` 边界：跳过 T5 完整串行 NTT 数据事务；通过的15个比对点不能表述成 T5 已复跑。
