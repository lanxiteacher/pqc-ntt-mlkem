# CLI 失败留证与连接关闭（2026-10-29）

正式入口 `host/src/board_run.py` 现在统一管理连接生命周期。握手、探活、向量准备、
计算事务、解包检查失败，以及 Ctrl+C 中断，都进入关闭连接的 finally 分支。
关闭本身抛错时保留原失败，同时另记关闭异常；不能声称操作系统一定成功释放设备。

## 使用

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/board_run.py --loopback --physical-order --check --result-json ../ntt_result.json "#NTT 1"
python host/src/test_board_run_failures.py
```

真板运行时将陪练参数换为实际 `--port`、`--build`、`--baud`；复位开机行是尽力发送，
未收到时仍须正确声明 build。记录文件父目录须存在，现有文件会更新为本次结果，
每次实验应使用新文件名以保留历史。记录写入失败也返回非零，错误摘要写到标准错误。

## 结果字段

- `status`、`exit_code`：成功或失败及程序退出状态。
- `stage`：open、handshake、probe、prepare、transaction、check 等调用阶段。
- `error_type`、`error`：原始异常类型与原因；关闭失败另记 `close_error_type/close_error`。
- `close_attempted`、`closed`：是否尝试关闭，以及 close 调用是否正常返回。
- `write_attempts`、`attempted_write_bytes`、`completed_write_bytes`：发送调用次数、
  最近一次尝试的字节数、正常返回的写调用累计字节数。它们不是线上实际送达字节数；
  失败的写操作可能已送出一个未知长度的前缀。
- `received_lines`、`io_operation`：已取得的完整行数与最近一次读/写操作。
- 正常返回事务时另存 `outcome`、`received_rows`、`transaction_log`。

失败时标准错误有 `BOARD_RUN_RESULT` JSON 摘要；不将异常吞成成功，不自动重发被中断的写操作。
协议状态机原有的明确重试规则仍保留；这次修改没有变动命令、串口帧、系数排列与 RTL。

## 验证边界

`test_board_run_failures.py` 对探活和计算命令分别注入短写、写超时、断连、读失败、
关闭失败，检查非零退出、证据、一次关闭和不重发；还检查三个真实 CLI 子进程的陪练成功、
帮助退出及打开失败，共 15 项。原有 SerialLink、Host、排列、批量和送板编排检查仍需全量运行。
这些是模拟驱动与陪练结果，不是拔线真板实验，也不是所有 USB/操作系统异常的无挂死保证。

A 的 10-29 真板回归对应 `145b689`，证明 10-21 正式发送修复在基线三档的正常路径；
本日后续 CLI 关闭与摘要修补不能借该记录声称已上板。最终运行版本若变化，按冻结清单安排冒烟。
