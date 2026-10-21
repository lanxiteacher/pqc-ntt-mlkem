# B → A/C：Phase 2 与正式串口发送修复（2026-10-21）

依据 A 的 `logs/letter_2026-10-21_A_to_B_phase2.txt`。本次没有访问实体串口，没有修改 `rtl/` 或 `research/` 原件。旧证据均保留。

## 证据入口

| 工作 | 独立证据 | 结果与边界 |
|---|---|---|
| A 真板 trace 离线复核 | `logs/verification_2026-10-21_B_phase2_board_audit.json` | 现有 count=0 三档 45 次、11,520 系数与原 trace 一致；频率/位流仍有操作者声明边界 |
| 100 组 NTT | `logs/verification_2026-10-21_B_phase2_ntt100.json` | 原 16 + 新 84，seed=20261021；每档 25,600、共 76,800 系数；各档单点改错恰好发现 1 处 |
| 三个 transcript | `logs/verification_2026-10-21_B_phase2_traces.json` | 不同 KAT count、公钥与 trace；实际 RTL 135 次、34,560 系数；新增真板尚未跑 |
| 三档变异 | `logs/verification_2026-10-21_B_phase2_mutations.json` | 三档变异共 50/51 捕获（pe1/pe4/pe16=16/17/17），另 1 项 pe1 serializer_order 等价，不计捕获。 逐项矩阵见同前缀 `_mutations.md`；FULL、每组合 16 组，不是全运算故障覆盖率 |
| 正式 Host 修复 | `logs/verification_2026-10-21_B_host_safety.json` | 11 个本机脚本通过；`host/serial_write_safety.md` 列改法及 A 复测步骤 |
| 统一自动验收 | `logs/verification_2026-10-21_B_current.json` | Phase 2 来源验证、8 项有符号输入检查、旧目录保护、Host 与送板兼容回归；人工验收尚未执行 |
| 原始输出与源快照 | `logs/verification_2026-10-21_B_phase2.zip` 与 `_manifest.json` | 不包含可执行文件；保留输入、命令、stdout/stderr、变异副本和源码快照，manifest 含逐文件 SHA-256 |

## A 可直接使用的新增 trace

- `logs/verification_2026-10-21_B_kem_trace_0.json`：与 10-18 旧 trace 逐字节一致，A 已有真板证据。
- `logs/verification_2026-10-21_B_kem_trace_1.json`：不同 KAT count=1、公钥。
- `logs/verification_2026-10-21_B_kem_trace_2.json`：不同 KAT count=2、公钥。

两份新增 trace 各有 15 次正向 `poly_ntt`（keygen/encaps/decaps=6/3/6）。**A 只需补 2 份 × 3 档，共 90 次真板调用**；与旧 45 次合计才是 135 次真板证据。不同档位必须先烧对应位流。

A 现有 `rtl/vivado/run_kem_trace_boards.sh` 把旧 TRACE 写死；只改 OUTTAG 会再次跑旧 count=0，不能据此验收两份新数据。请按原烧录步骤逐档烧录后，调用下列既有 Python 入口，替换真实串口、位流路径和频率；对 count=1/2、pe=1/4/16 共六个组合分别使用新目录：

```powershell
python refsim/run_kem_board.py --trace logs/verification_2026-10-21_B_kem_trace_1.json --output logs/verification_2026-10-21_A_kat1_pe4_01 --port <实际串口号> --build 4 --bitstream <实际bit文件> --frequency-mhz <该位流频率MHz> --baud 115200
```

尖括号是待替换项，不可原样执行。每次以 `session.json`、`serial/replay.json` 均 pass，15 次/3,840 系数且 trace 哈希正确为准。新正式 Host 已去掉无界 flush，但仍保留外层超时；不要自动重试失败事务。

另请 A 按 `host/serial_write_safety.md` 对正式驱动补真板冒烟/浸泡。已有 40 分钟 9233/9233 对应 A 旧脚本的 no-flush 替换路径，不能算成本次正式驱动的新测试。B 已做完这项的本机实现与验证。

## A/C 的报告使用口径

- NTT 是 **100 组总数=16 原有+84 随机并插入边界值**，不是 100 组全新纯随机。
- 负数和 q 先由 C 有符号输入验证，再取模给 RTL；不是“串口直接接受负数”。
- 三个 transcript 是社区 FIPS 203 兼容 KAT，不是 NIST 官方；覆盖正常 KEM 的正向 NTT，未实现整套 KEM 硬件。
- 135 次是本轮 RTL，已有真板仍为 count=0 的 45 次，直到 A 交回新增记录。
- pe1 `serializer_order` 为等价变异：`rsub` 复位为 0，PE=1 时递推仍为 0；原 `PE_NUMBER-1-rsub` 与变异后 `rsub` 都为 0。单通道没有可颠倒的 lane 顺序，不计捕获。
- 新证据不改变原 103 次固定周期/有效地址观察的范围，不把有限观察升级成侧信道证明。

报告 Markdown 的新增段落与证据地图以本轮已提交内容为准；C 后续需重建 PDF，不能把旧 PDF 页数或旧截图视为新段落已进入成品。

## B 的统一手动验收

仓库根目录运行（目录已存在则换 `_02`）：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/accept_b_current.py --output ../B_current_manual_01
```

末尾应为 `PASS: B local acceptance`；同时看故障捕获数和存活分类，不能只看 PASS。详细进度在输出目录 `phase2_run.txt`。预留数十分钟；运行期间不拉取或编辑源码。此次 B 人工执行结果待本人提交，不能用 AI 输出代填。

H10 仍需第二台实体电脑；冻结提交的复跑、打包和最终镜像要等冻结。PYNQ 新功能不在本轮项目范围；答辩工作按用户要求放在其他对话。
