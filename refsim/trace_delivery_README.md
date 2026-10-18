# ML-KEM trace: RTL replay and board handoff

## B 的统一本机验收

从仓库根目录 PowerShell 执行：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/accept_trace_delivery.py --output ../B_trace_delivery_manual_01
```

需要 Python、gcc、iverilog/vvp，不需要 Vivado 或板子；本机预计几十秒到约两分钟，以实测为准。目录必须尚不存在，重跑换 `manual_02`，不要覆盖旧证据。入口依次完成：

1. 重新提取社区 FIPS 203 兼容 KAT count=0 的正常 ML-KEM-768 流程，检查 KAT、原版/插桩一致性、确定性、15 次调用的 C 复核和三档陪练。不是 NIST 官方向量，不是完整硬件 KEM。
2. 用本次编译的三档 `rtl/ntt_core` 实际计算这 15 次正向 NTT，共 45 次/11520 系数。按固定输出窗口和已有物理排列逐项核对，同时核对外层周期 907/235/72。每档再确认一个错误答案、未知输出、重复行和缺完成标志均被拒绝。
3. 三档 × 五命令 × 16 组分别走批量/逐行 Host 路径，共 480 次事务、122880 系数。发送字节流、结果、尝试次数和逐行审计记录一致；批量数据一次写出，逐行写出 256/512 次。另用记录字节对象执行正式 `SerialLink.write`，检查一次写入/一次 flush。这里是模拟传输对象，不验证 USB 或真实波特率。
4. 用替代串口对象及受控子进程测试送板工具：正确流程、错误档位、错误数值、打开失败、非零退出、超时、伪成功证据和旧目录保护。所有这些测试均无实体板卡。

最后显示 `PASS: offline trace delivery complete; actual RTL 45/45`，并明确 `board NOT tested`。总结果在新目录 `acceptance.json`，四阶段 stdout/stderr 和命令另存；`rtl/replay.json` 保留实际 RTL 结果，`board_kit/trace.json` 为本次可交接 trace。请截图最后结果完成用户人工验收。

## A 的真实送板操作

本轮已核验的固定 trace 随仓库提交在 `logs/verification_2026-10-18_B_kem_delivery_trace.json`，哈希见同批交接记录。A 可以直接使用，无须先在自己的机器生成 trace。

1. `git pull`。接好板卡，用现有烧录流程烧入已知档位、频率和波特率的有效位流。此工具只做串口回放，不执行综合或烧录。位流不在 Git 内，使用 A 本机真实 `.bit` 文件。
2. 关闭占用串口的其他程序，现查 CH340 串口号，核实实际位流信息。默认先用 115200；只有位流本身支持 921600 时才改参数。
3. 从仓库根目录运行下面命令，把尖括号占位符改为真实值。每个档位使用不同的新目录：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/run_kem_board.py --trace logs/verification_2026-10-18_B_kem_delivery_trace.json --output ../A_kem_serial_pe4_01 --port <实际串口号> --build 4 --bitstream <实际bit文件路径> --frequency-mhz <实际烧入版本的频率MHz> --baud 115200
```

以上带尖括号的行是模板，必须替换后执行；路径有空格时用双引号。`--build` 对应 1/4/16，每次换档应先换入正确位流。需要三档结果时逐档烧录、逐档运行，不要对同一档位流只更改 `--build` 冒充三档。

成功条件：每次 15 个调用全部通过、3840 个系数逐项一致，`session.json` 与 `serial/replay.json` 均为 `pass`。三档齐全是 45 次/11520 系数。收到 RDY 档位与声明不一致会拒绝；RDY 未收到时仍按现有协议允许使用人工核实的显式档位。

`--bitstream` 会记录指定文件 SHA-256；`--frequency-mhz` 记录人工声明频率。工具不能读取当前 FPGA 已加载位流，也不能测实际时钟，因此这两项不标为自动验证。A 应同时保留烧录/位流来源记录，不能只靠声明参数证明硬件身份。

## 成功和失败证据

每次新目录保存：

- `session.json`：状态、起止 UTC 时间、当前提交、串口/波特率/档位、位流和 trace 哈希、声明频率、实际执行命令。
- `stdout.txt`、`stderr.txt`：子进程完整输出；默认 180 秒超时，可用 `--timeout` 在 1..600 秒内调整。
- `serial/replay.json`：逐次检查点、RDY 信息、当前调用、已完成调用的原始行/事务日志/还原值及差异。可捕获的失败写 `fail`；打开串口就失败时也尽量留记录。总超时强制终止子进程时，此文件可能停在最后的 `running` 检查点，必须以外层 `session.json` 的 `timeout` 为准，不能当作通过。

原来的 SerialLink 写入/flush 没有显式超时，本入口使用独立子进程总时限，超时终止该次 Python 子进程并保留部分证据，退出码非零。后续如需重试，请排查串口和板子状态，使用新输出目录，不自动重复硬件事务。

A 跑完后将成功或失败的输出目录完整交回 B；B 再检查原始结果与 trace 哈希是否对应。不要只转发终端的一句 PASS。日志入库可以先放在 `logs/` 下，按日期、A、档位命名；无需改写 B 已记录的本机仿真结论。

## 当前完成边界

本机已具备真实 ML-KEM 调用的 C、Host 陪练和三档 RTL 三层证据。串口执行入口及失败留证逻辑在模拟条件下验证。实际 ML-KEM trace 送实体板卡仍待 A 执行，不能据这里的本机 PASS 将“全部 NTT 送板逐位比对”销项。也未完成第二台实体电脑验收。
