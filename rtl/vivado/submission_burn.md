# 位流与烧录说明（提交包用，2026-10-29）

> 本文件随 `package_submission_bits.sh` 一起进入提交包，最终文件名是 `BURN.md`。
> 目标板：正点原子 **领航者 ZYNQ**，器件 **xc7z020clg400-2**。

## 一、六个位流

| 文件 | 档位（蝶形数） | 板上频率 | 说明 |
|---|---|---|---|
| `pqc_ntt_pe1_50mhz.bit` | pe1（1） | 50 MHz | 基线，10-07 重建（含 `#RDY`） |
| `pqc_ntt_pe4_50mhz.bit` | pe4（4） | 50 MHz | 基线 |
| `pqc_ntt_pe16_50mhz.bit` | pe16（16） | 50 MHz | 基线 |
| `pqc_ntt_pe1_80mhz.bit` | pe1（1） | 80 MHz | MMCM 提频版 |
| `pqc_ntt_pe4_75mhz.bit` | pe4（4） | 75 MHz | MMCM 提频版 |
| `pqc_ntt_pe16_62.5mhz.bit` | pe16（16） | 62.5 MHz | MMCM 提频版 |

- 位流**掉电即失**，每次上电都要重烧。
- 六个文件的 SHA-256 见同目录 `SHA256SUMS.txt`；烧之前可先核对。
- 基线与提频版的串口波特率默认都是 **115200 8N1**（另有 921600 位流，未放进本包）。

## 二、烧录前

1. **底板 P5 跳线在 PL 档**（3–5、4–6 短接）。
2. **启动拨码在 JTAG 档**（两位都 ON）。
3. 下载器插**底板右侧 14-Pin JTAG 座**（`USB_UART` / `USB_SLAVE` 都不能下载）。
4. 串口线接 `USB_UART` 口；Windows 设备名 `USB-SERIAL CH340`，**口号会变**：

   ```powershell
   [System.IO.Ports.SerialPort]::GetPortNames()
   ```

## 三、烧录

仓库内（或解压后的工程包）执行：

```bash
BIT=<位流文件绝对路径> sh rtl/vivado/run_board_prog.sh
```

- 需要 **Vivado 2020.2**（默认路径 `E:/xilinx/Vivado/2020.2/bin/vivado.bat`，可用 `VIVADO=` 覆盖）。
- 成功标志：`RESULT prog PROGRAMMED ...` 与 `End of startup status: HIGH`。

## 四、烧完验证（一条命令）

```bash
python host/src/board_run.py --build <1|4|16> --check "#NTT 1" --port COMx
```

- 期望：`#RDY 1 <build> 0*<校验>` 一行 + 256 个系数 `0/256 不同`。
- 更完整的一条（探活 + 五条计算事务，落报告）：

  ```bash
  PE=<1|4|16> TAG=_check PORT=COMx sh rtl/vivado/run_board_txn_report.sh
  ```

## 五、期望的 `#RDY`

| 位流 | 期望 `#RDY` |
|---|---|
| pe1 | `#RDY 1 1 0*7c` |
| pe4 | `#RDY 1 4 0*79` |
| pe16 | `#RDY 1 16 0*4a` |

`#RDY` 是**上电/复位释放后自发的一行**（协议 v1.0 §5.2，「尽力而为」）：如果串口是在
复位**之后**才打开的，就收不到这一行，**不是故障**；直接发 `#PING` 即可继续。

## 六、边界

- 50 / 80 / 75 / 62.5 MHz 是**人工声明**并写进位流文件名；工具不测板上实际时钟。
- 提频版是「按该频率约束、综合、布局布线并上板跑通 6/6」，**不是芯片频率极限**。
- 位流与报告里的频率一一对应：报告 §3.10.2 的三列即上表后三行。
