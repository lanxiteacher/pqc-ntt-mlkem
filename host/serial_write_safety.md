# 串口发送的有限等待（B，2026-10-21）

A 在持续 CH340 通信中观察到 `SerialLink.write().flush()` 卡住；板卡仍可在重开串口后响应。A 的 `rtl/vivado/soak_board.py --no-flush` 已在 pe16、115200、声明 50 MHz 下完成 40 分钟 9233/9233。原始摘要见 `logs/verification_2026-10-21_A_soak.txt`。该结果对应 A 当时的浸泡脚本，不是 B 此次正式驱动修复后的真板复测。

## 本次正式驱动修改

- 构造真实串口时设置 `write_timeout=5.0` 秒，保留原有读超时。
- 写入不再调用无超时的 `flush()`。写成功仅表示驱动接受字节；协议层仍等待 ACK/BEGIN/DONE，不能据此声称数据已抵达 FPGA。
- 写入返回字节数不足时立即抛错；超时、断连异常向调用者传播，不重发可能已经发出一部分的帧。
- 命令、字节排列、LF、批量发送和协议超时不变。5 秒是 pyserial 写操作的配置上限，不是对所有 USB/操作系统异常的绝对无挂死保证；A 的外部看门狗仍有价值。

## 无板验收

```powershell
$env:PYTHONIOENCODING='utf-8'
python host/src/test_serial_write_safety.py
python host/src/test_link.py
python host/src/test_bulk_pipeline.py
```

新检查以模拟驱动验证构造参数、完整写入、无 flush、短写、超时、断连及不自动重试；既有 `loop://` 检查运行实际 pyserial 行缓冲；批量检查覆盖三档五命令各 16 组的两种发送方式，共 480 事务。它们不模拟 CH340 电气行为，不测 USB 吞吐。

## A 下一次有板时

拉取本次提交，按原三档计算事务冒烟；随后对新正式 `SerialLink` 运行浸泡。可沿用 `soak_board.py`，**不加 `--no-flush`**，使其直接调用正式驱动而非替换 `write`。该脚本仍会把底层写超时调为 1 秒，保留看门狗。日志中旧 `flush=yes` 标签仅表示没有启用脚本替换，与新驱动是否真的调用 flush 已不等价；记录时应明确新驱动版本与该区别，由 A 更新脚本标签。

B 没有修改 A 的 `rtl/`；本轮只完成正式驱动代码和本机检查。A 旧 40 分钟测试继续作为原脚本证据，不追认成新代码测试。
