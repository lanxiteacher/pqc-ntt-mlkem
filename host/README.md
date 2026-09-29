# host —— PC 上位机

**主责：B** ｜ 状态：⬜ 未开工

通过串口把数据喂给板子、收回结果、自动和标准答案比对。

## 目录约定

```
host/
├── README.md          ← 本文
├── proto.md           ← 串口协议定义（H3，W2 前必须冻结）
└── src/               ← 上位机源码
```

## 硬约束

- **先对仿真跑通协议，再上板。** UART 收发灌进 testbench（`refsim/`），
  在真板子之前把协议跑通。上板时变量只剩"硬件对不对"一个。
- **协议两侧各实现一端。** 板子侧是 A 写的。协议不冻结，两边一定对不上（见 H3）。
- 板载 CH340C → 设备名 `USB-SERIAL CH340`，115200-8N1，与官方 `19_uart_loopback` 例程一致。
  ⚠️ **COM 口号会变**（Windows 按「插在哪个 USB 口」现分配，见过 COM10、COM9）——
  **不要写死数字**，运行时用 `serial.tools.list_ports` 按设备名 `USB-SERIAL CH340` 找当前是哪个。

## 相关

- 分工与交接点：`../team/FPGA竞赛_B_引导与计划.md`
- 验证台：`../refsim/README.md`
