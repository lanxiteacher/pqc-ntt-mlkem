# B Phase 2：三档验证扩展（2026-10-21）

本轮按 `logs/letter_2026-10-21_A_to_B_phase2.txt` 执行。Phase 2 只需 Python、gcc、iverilog/vvp；完整 B 验收另需 pyserial 的 `loop://`。不需要 Vivado、板卡或 PYNQ。旧证据保留。

## 统一手动验收

在仓库根目录运行：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/accept_b_current.py --output ../B_current_manual_01
```

目录必须是新的；再次执行换成 `_02`。整套包含 Phase 2、8 个有符号输入检查、旧目录拒绝、11 个 Host 自测和四阶段送板兼容验收。51 个故障副本逐个编译和仿真，需要数分钟至数十分钟，以机器速度为准。Phase 2 的逐项进度写在输出目录 `phase2_run.txt`，主终端会在阶段完成后继续输出；每个外部工具调用有超时。不要在执行期间拉取或编辑源码，脚本末尾检查输入源码哈希是否变化。

完整 B 验收最终 `acceptance.json` 必须为 `status=pass`；其中 `phase2` 保存下面四阶段结果。自动执行可用 `--reuse-phase2 <已有输出>` 导入本轮已完成且源码哈希逐项一致的结果，明确记录 `phase2_reused=true`，不是重新跑了一次；用户按上面默认命令会重新执行全部测试。

单独运行 `python refsim/accept_phase2.py --output <新目录>` 时，其 `acceptance.json` 的 `status=complete` 表示四阶段执行完毕；故障未捕获项必须单独查看 `stages.mutations.survivors`，不能把 complete 翻译成“51 个全部捕获”。只需局部复查时可在该命令加 `--stage board_audit|ntt100|traces|mutations`；这不代表其他阶段也复跑了。

## 四阶段和边界

| 阶段 | 检查对象 | 判据与范围 |
|---|---|---|
| board_audit | A 已入库的三档串口记录 | 离线核对 trace 哈希、45 次调用及 11,520 个返回值；不新开串口。频率与烧录位流仍按操作者声明记录 |
| ntt100 | 原 16 组 + 新 84 组固定种子输入 | 每档 100 组、25,600 系数，三档共 76,800；改坏第 37 组第 100 项（从 0 编号），必须仅发现这一处差异 |
| traces | 社区兼容 KAT count=0/1/2 | 三个不同公钥与 trace 哈希；每份 keygen/encaps/decaps=6/3/6 次；三档共 135 次、34,560 系数 RTL 回放。count=0 与旧 trace 字节相同 |
| mutations | 同一批 17 个变异 × pe1/4/16 | 每组合 FULL、16 组；每档先跑未改基线。编译失败、超时不算捕获；数值不符或完整运行后出现 X/Z 分别记账 |

新 84 组的种子为 20261021，每组保留 250 个随机系数，并放入 0、3328、3329、-1、-3329、-3328 六个边界代表值。不是“100 组全新纯随机”。`ntt_signed_tool.c` 将有符号输入直接交给原版 `poly_ntt`；再与规范化输入的 C 结果对比。RTL 只接收取模后的 0..3328，不声称串口可以直接发负数或 q。

trace 仍仅覆盖正常 ML-KEM-768 流程中的正向 NTT；不是完整 KEM 硬件运行，不覆盖无效密文拒绝路径，也不是 NIST 官方 KAT。新 count=1/2 真板执行交 A。

pe1 的 `serializer_order` 把 `PE_NUMBER-1-rsub` 改为 `rsub`：只有一条 lane 时两式都为 0，属于该档等价变异，不能计成被捕获。其他存活项应逐项分析，不能更换判据凑满分。

## 输出与追溯

输出目录保留 `acceptance.json`、各阶段 `result.json`、输入、C 期望、编译与仿真 stdout/stderr、命令和源文件哈希。变异仅改输出目录中的副本，不改 `rtl/` 和 `research/`。

独立取指定 trace：

```powershell
python refsim/kem_trace.py --kat-count 1 --output ../B_kat1_new
```

完整交接与本次执行结果见 `team/handoff_2026-10-21_B_phase2.md`。串口发送修复的无板检查另见 `host/serial_write_safety.md`；此处的 RTL 测试不替代 USB/CH340 验证。
