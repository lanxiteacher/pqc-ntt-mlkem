# B → A/C: ML-KEM trace RTL verification and board delivery

## 已完成

B 已按用户授权完成四项无板工作：前轮变异/周期用户手动验收归档、ML-KEM trace 三档实际 RTL 回放、Host 批量发送分支验证、真实送板入口和失败留证机制。

统一离线验收入口：`python refsim/accept_trace_delivery.py --output ../B_trace_delivery_manual_01`，需要 Python/gcc/iverilog/vvp，无需板卡或 Vivado。AI 完整运行通过，新入口的用户手动验收仍待本人执行。

| 项目 | 结果 | 边界 |
|---|---|---|
| ML-KEM trace | 正常 KEM-768，keygen/encaps/decaps=6/3/6，共15次正向 poly_ntt | 社区 FIPS 203 兼容 KAT count=0，不是官方认证 |
| 实际 RTL 回放 | pe1/4/16 各15次，合计45次、11520系数逐项全对 | 实际编译运行 `rtl/ntt_core`，不是陪练回答案；不含板级 UART |
| 外层周期 | pe1=907、pe4=235、pe16=72 | 按已有接口约定扣3拍后核904/232/69 |
| RTL 负向 | 各档一个坏期望、未知值、重复行、缺完成标志被拒 | 不排序掩盖次序差异 |
| Host 批量路径 | 240批量+240逐行，共480事务，122880系数；字节流与结果一致 | 三档、五命令、每命令16组；模拟传输 |
| 正式写适配器 | 256/512行块各一次 write/一次 flush | 记录字节对象，不是 USB 性能测试 |
| 送板入口 | 9项成功/失败场景测试通过 | 替代串口对象与受控子进程，不含真实板卡 |
| 原有回归 | host/src 下原有9个测试脚本通过 | 各自覆盖范围不变 |

## A 现在如何执行

拉取仓库后，固定 trace 已在 `logs/verification_2026-10-18_B_kem_delivery_trace.json`，不需要 A 再生成。完整步骤见 `refsim/trace_delivery_README.md`。

A 先用已有流程烧入正确的位流，再从仓库根目录执行（尖括号必须替换为现场值，路径有空格加双引号）：

```powershell
$env:PYTHONIOENCODING='utf-8'
python refsim/run_kem_board.py --trace logs/verification_2026-10-18_B_kem_delivery_trace.json --output ../A_kem_serial_pe4_01 --port <实际串口号> --build 4 --bitstream <实际bit文件路径> --frequency-mhz <实际版本频率MHz> --baud 115200
```

逐档烧录并分别改 `--build` 与输出目录。921600 仅用于对应波特率位流。每档成功是15次/3840系数，三档齐全是45次/11520系数。错误档位/结果会拒绝；默认180秒子进程总超时。请保留并交回每档完整输出目录，包含 session.json、stdout/stderr、serial/replay.json；失败目录也保留。

工具只对指定 `.bit` 文件计算哈希，频率是人工声明，不能证明 FPGA 此刻加载的位流或实测时钟。A 应一并保留实际烧录来源。没有板子结果前，出彩组合第3件仍未整体完成。

## C 可引用的资料

- `logs/verification_2026-10-18_B_kem_delivery.json`：整套本机验收摘要与源文件哈希。
- `logs/verification_2026-10-18_B_kem_delivery_rtl.json`：三档逐次 RTL 输出和周期。
- `logs/verification_2026-10-18_B_kem_delivery.md`：结果表、范围、trace 哈希。
- `logs/verification_2026-10-18_B_kem_delivery.zip`：完整本机执行日志、输入/负向记录、运行源码、固定 trace、Host 回归输出。
- `refsim/trace_delivery_README.md`：新入口与现场操作说明。

C 可据此补充报告验证章与证据地图，本轮 B 没有代改正文或生成 PDF。不要将“RTL 仿真回放45次通过”写成“真实板卡45次通过”，也不要写成整套 ML-KEM 已硬件实现。

## 仍未完成

实体板卡的 ML-KEM trace 回放待 A；第二台实体电脑 H10 待设备条件具备。打包/镜像/PYNQ扩展仍遵守现行项目优先级，本轮未启动。
