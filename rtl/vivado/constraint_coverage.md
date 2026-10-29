# 板级时序约束覆盖说明（J06，2026-10-29）

> 起因：B 在 10-22 的评委视角审阅里指出（`team/review_2026-10-22_B_judge_audit.md` §J06）——
> 时序报告里 `no_input_delay (2)` / `no_output_delay (1)` 没有解释，而正文曾出现
> 「零告警、全部约束完善」这类无条件表述。本文回答三件事：
> **约束了什么、没约束什么、为什么没约束是可以接受的**。
>
> 证据：`rtl/board/ntt_board.xdc`、`rtl/vivado/reports/board_pe1_timing.rpt`（10-07 19:45，
> `ntt_board_top` 的 50 MHz 基线）、`rtl/vivado/reports/board_pe{4,16}_timing.rpt`。

## 一、约束清单（就这些，没有别的）

`rtl/board/ntt_board.xdc` 全文只有四类内容：

| 约束 | 对象 | 值 |
|---|---|---|
| `create_clock` | `sys_clk`（U18） | 20.000 ns（50 MHz） |
| `PACKAGE_PIN` / `IOSTANDARD` | `sys_clk` U18 / `sys_rst_n` N16 / `uart_rxd` T19 / `uart_txd` J15 | 均 LVCMOS33 |

**没有** `set_input_delay`、`set_output_delay`、`set_false_path`、`set_multicycle_path`、
`set_clock_groups`，也没有 `ASYNC_REG` 属性。这是有意的，下面逐条说。

## 二、两个「没约束的输入」是什么

`check_timing` 报的 `no_input_delay (2)` = **`uart_rxd` 与 `sys_rst_n`**；
`no_output_delay (1)` = **`uart_txd`**。

| 端口 | 性质 | 处理方式 | 为什么不需要 IO 延迟约束 |
|---|---|---|---|
| `uart_rxd` | 异步串行（CH340 → PL） | `rtl/uart_rx.v`：`rxd_s0` / `rxd_s1` 两级触发器；**起始沿判定用 `rxd_s1 & ~rxd_s0`（第一级直接进组合逻辑）**——B 2026-10-29 已指出这是 CDC 风险，**本轮按「接受已知限制」冻结，未改 RTL、未重出位流**；数据位**位中点单次采样**（系统时钟计数，**不是 16× 过采样**、无多数投票） | 接收端只认「起始沿 + 中点采样」，没有随路时钟；`set_input_delay` 需要一个参考时钟，这里不存在 |
| `uart_txd` | 异步串行（PL → CH340） | 由 `sys_clk` 直接驱动，速率 115200（一位 ≈ 8.68 µs ≈ 434 拍） | 对端按波特率自己采样，不按我们的时钟锁存；`set_output_delay` 同样没有参考对象 |
| `sys_rst_n` | 机械按键，异步 | 顶层 `rst_sync` 两级触发器：**异步置位、同步释放**（`ntt_board_top.v:96–104`） | 按键抖动是毫秒级；复位路径已在 `async_default` 组里分析（见 §三） |

## 三、时序结果怎么读（这里有个容易看错的点）

`board_pe1_timing.rpt` 里出现两个 WNS，不是矛盾：

| 表 | 组 | WNS | WHS | 端点 | 含义 |
|---|---|---:|---:|---:|---|
| Design Timing Summary | 总体（取最差） | **2.490** | 0.020 | 11,278 | 被 `async_default` 拉低 |
| Intra Clock Table | `sys_clk`（同步逻辑） | **7.339** | 0.020 | 7,807 | **我们自己的同步设计余量** |
| Other Path Groups | `async_default`（异步/复位类） | **2.490** | 1.700 | 3,471 | 异步置位/复位、异步控制路径 |

三档的 `sys_clk` WNS：**pe1 +7.339 / pe4 +6.547 / pe16 +4.789 ns**，失败端点 0，
`All user specified timing constraints are met.`（报告第 134 行）。

⚠️ **hold 余量只有 0.020 / 0.016 / 0.062 ns。** 这是 Vivado 全 PVT signoff 下的 MET，
**不说「余量充足」**；它是「在 signoff 角上刚好过」，换温度/电压角或改动逻辑都可能翻负。

## 四、CDC 与复位：做了什么、没做什么

**做了什么**

- 单时钟域设计（基线只有 `sys_clk` 一个时钟；提频版由 MMCM 产生，仍是一个同步域）。
- 异步输入只有两个：`uart_rxd`（两级触发器；起始沿判定用到第一级，见 §二 的已知限制）与 `sys_rst_n`（两级异步置位/同步释放）。
- 核的 `reset` 是高有效异步，由 `~rst_n` 驱动（`ntt_board_top.v:104`、244 行），
  与板级低有效复位在顶层转换，**不在核内部做极性假设**。

**没做什么（如实写）**

- 没有跑 CDC 形式化/静态检查工具，也没有算同步器的 MTBF —— 两级触发器是行业惯例，不是证明。
- **已知限制（2026-10-29，B 审阅 `team/review_2026-10-29_B_uart_cdc.md`）**：起始沿判定
  `rxd_s1 & ~rxd_s0` 直接使用第一级 `rxd_s0`，其潜在亚稳态可能进入接收状态机；
  数字仿真不建模模拟亚稳态，已有的真板 135 次与 9,233 次长跑不能证明该风险不存在。
  本轮**选择冻结、不修**：修法需要重出六只位流并做真板复验，超出收尾窗口；
  提交物按「已知限制」如实记录，不宣称「同步处理已完备」。
- 没有给同步器加 `ASYNC_REG` 属性（与上一条同因：本轮不改 RTL）。
- 没有为「异步路径」加 `set_false_path`：`async_default` 组照常分析，WNS 2.490 是**算出来的**，
  不是屏蔽出来的。

## 五、边界（别把这份说明读成更强的结论）

1. 「时序 MET」只代表**已约束、已分析**的路径满足要求；未约束的外部器件时序不在其中。
2. `sys_clk` 的 7.339 ns 余量**不能反推 Fmax**（那是核的 5 ns 收紧约束下的事，见 `report/design/03` §3.6）。
3. 如果以后加同步接口（SPI、摄像头、SDRAM 等），必须补 `set_input_delay` / `set_output_delay`
   与跨时钟域约束；本说明只覆盖当前四个引脚。
4. 提频版（`ntt_board_top_mmcm`）的时序见 `rtl/vivado/reports/board_pe*_f*_timing.rpt`，
   MMCM 输出时钟由 Vivado 自动派生；其 WNS 与 50 MHz 基线不是同一组数。

## 六、复现

```bash
# 约束文件
rtl/board/ntt_board.xdc

# 时序报告（check_timing 段 + 三张表）
rtl/vivado/reports/board_pe1_timing.rpt     # 38–53 行 check_timing；140–180 行三张表
rtl/vivado/reports/board_pe{4,16}_timing.rpt

# 重出报告
sh rtl/vivado/run_board_synth.sh            # 需要 Vivado 2020.2
```
