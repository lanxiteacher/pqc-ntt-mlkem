# 提频版上位机兼容性核查（2026-10-18，B）

核查基线：bbdb35f。结论：在 A 已提交的 MMCM wrapper 参数传递成立、实际位流与记录一致的前提下，没有发现上位机因提频必须修改的参数。维持 115200-8N1，维持原有等待时间，build 仍填 1/4/16。此为代码核查和离线检查结论，不是提频版上板通过证明。本轮未修改驱动、RTL、协议或超时标准。

## 核对结果

| 项目 | 代码依据 | 判断 |
|---|---|---|
| PC 波特率 | host/src/link.py DEFAULT_BAUD、SerialLink.__init__ | 默认 115200、8N1，不依赖 FPGA 时钟；不要把 --baud 改成 80000000 |
| 板端串口时钟 | rtl/board/ntt_board_top_mmcm.v CLKOUT_HZ、u_top 参数；rtl/uart_tx.v、uart_rx.v BAUD_MAX | wrapper 将新 CLK_FREQ 传入原顶层，UART_BPS 仍为 115200 |
| PC 等待 | host/src/host.py T_OK/T_BEGIN/T_RX/T_DONE | 分别 1/5/1/1 秒；以 time.monotonic 计真实时间，没有按 50 MHz 换算。T_RX 是每行超时，不是整个结果段 |
| 等待起点 | host/src/host.py _attempt | 发命令后等 OK；发完输入后等 BEGIN；逐行等结果；收齐结果后等 DONE。提频不要求缩短这些等待 |
| 板端超时 | wrapper u_top 参数 | T_LINE=CLKOUT_HZ、T_CMD=10×CLKOUT_HZ、T_CORE=CLKOUT_HZ/10，名义时间仍为 1 s/10 s/100 ms |
| 档位与排列 | board_run.py build 选择、unpack.py 的装载/读出表 | --build 表示 PE_NUMBER，不表示频率。显式 --build 优先于 RDY；缺 RDY 且未指定会默认 pe1，正式复核应明确指定实际档位 |
| 启动通知 | host.py handshake、board_run.py | 开串口后先尝试接收 RDY；没收到不等于板子故障。MMCM 锁定、复位和串口电气行为仍需上板确认 |

按 UART 的整数分频公式计算（仅计算，不是实测）：

| 板内时钟 | 分频整数 | 名义实际波特率 | 相对 115200 误差 |
|---|---:|---:|---:|
| 50 MHz 基线 | 434 | 115207.373 | +0.006400% |
| 80 MHz / pe1 | 694 | 115273.775 | +0.064041% |
| 75 MHz / pe4 | 651 | 115207.373 | +0.006400% |
| 62.5 MHz / pe16 | 542 | 115313.653 | +0.098657% |

误差计算本身不能证明 CH340、真实 UART 或板卡稳定性。不要把电脑端的波特率设置改成这些计算值；保持协议标称值 115200。

## 原有链路限制与上板操作条件

- SerialLink.read_line 有截止时间，底层按 POLL_SLICE 轮询；单次 read 可能略跨过截止点，不是硬实时保证。
- SerialLink.write 调用 pyserial.write 和 flush，目前没有显式 write_timeout。因此不能声称所有 I/O 都有严格有限超时，USB/驱动异常仍可能阻塞或抛异常。本轮记录这一原有问题，不把它误写成提频新增缺陷或已修复。发送超时与故障退出的完善需单独实现和验证。
- --build 显式值会覆盖 RDY，不能把 80、75、62.5 当 build；必须与实际位流的 1/4/16 一致。
- RDY 不含频率，无法从一次协议成功证明烧的是提频版。A 需保留位流路径/来源提交/频率与运行记录；TAG 只是文件标签，不能独自验证频率。
- 三个已通过时序的候选是 pe1/80、pe4/75、pe16/62.5 MHz。100 MHz 的失败候选不用于验收。
- 当前驱动原版五条事务与提频版五条事务仍需真板执行，尤其是 #PMUL TIME 1。串口号现查；保留旧报告，按 A 的 TAG 入口另存新报告。

## 本次实际检查

仅运行 test_host.py、test_link.py、test_board_pipeline.py，均退出 0。后者覆盖 240 次已知向量回放（61440 个系数）、15 次 CLI 及坏数据/遗漏装载排列/错档位控制。test_link 的 pyserial loop:// 收发路径实际运行；因本机已安装 pyserial，缺失依赖提示分支没有执行。没有重跑 RTL、综合、MMCM 功能仿真或整项目回归。

原始输出：../logs/verification_2026-10-18_B_host_mmcm.txt。

## B 的一次手动操作（已由本人截图确认）

在仓库根目录运行：

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/board_run.py --loopback --physical-order --fake-build 4 --check "#PMUL TIME 1"
```

检查输出是否从 RDY 识别 pe4，事务成功且 256 个值相同。这是在不手填 --build 时演练档位识别、半乘装载与检查流程；只是已知向量陪练，不测试 75 MHz、电气层或真实乘法。B 完成后提供实际观察再记为人工完成。

随后用户提供实际截图：RDY 自动识别 pe4，输入 512 行、收到 256 行，半乘一次成功，0 个系数不同。此人工步骤已完成。截图保存于 ../logs/verification_2026-10-18_B_manual_pe4.png。

后续状态更新：419cb37 已带入 A 的三档原频率和三档提频真板 6/6 日志。本文上面的“仍需真板执行”保留为核查时状态；最新证据由 board_report_check.md 所述工具审阅，不能把本次离线核查写成 B 上板。
