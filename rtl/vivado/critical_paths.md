# 关键路径（板级三档）—— 从 Vivado 报告机械抽取

> **本文件是派生物，不是手写的。** 由 `python gen_critical_paths.py` 从
> `reports/board_pe{1,4,16}_timing.rpt` 抽取生成 —— 报告重跑后重跑本脚本即可，
> 不要直接编辑本文。

对应 H4：C 要的「关键路径素材」。⚠️ **本文是数据，不是截图** ——
Vivado GUI 里那张 Schematic 图要人在机器前开 GUI 才截得到，本文替代不了它；
但报告里能引用的一切数字都在这里，且可复跑。

## 一、判据与口径

`report_timing_summary -max_paths 10` 的输出里路径分**两组**，先分清再读数：

| 组 | `Path Group` | 是什么 | 报告里的节 |
|---|---|---|---|
| 1 | `sys_clk` | 真正的时序关键路径；**`Design Timing Summary` 的 WNS 取自它** | `Max Delay Paths`（前） / `Min Delay Paths`（前） |
| 2 | `**async_default**` | 复位同步器到异步控制端的 recovery / removal | 后面那两组同名节 |

⚠️ **两组的 `Max Delay Paths` 都叫这个名字** —— 只按节名找会拿到第二组，
而第二组的 slack（pe1 是 8.338 ns）**不是 WNS**。
本文按 `Path Group` 字段筛，不按节名；筛完还会拿 `Design Timing Summary` 的
WNS 对一遍（见 §六），对不上直接报错、不出文档。

另一条同类的坑（`project_state.md` §二 已记）：**板级 WNS 不能反推 Fmax** ——
20 ns 目标是故意放松的，布线器没被逼；核的 Fmax 推算在 `folding_comparison.md` §9.1，
那是**另一个边界 + 另一个约束**，别把两个数放一格里比。

## 二、三档 WNS 与关键路径（`sys_clk` 组，Setup）

| 档 | WNS (ns) | 数据路径 (ns) | 其中逻辑 / 布线 | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|---|
| pe1 | **+6.538** | 13.153 | 2.562 (19.5%) / 10.591 (80.5%) | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]` |
| pe4 | **+6.840** | 12.905 | 2.692 (20.9%) / 10.213 (79.1%) | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[314]` |
| pe16 | **+6.241** | 13.472 | 2.562 (19.0%) / 10.910 (81.0%) | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[371]` |

⚠️ **三档的关键路径都不在蝶形里。** 起点都在 `u_line`（行组装）这一侧，
终点都在 `u_fsm` 的宽寄存器使能译码上 —— 也就是说，**卡时序的是协议状态机那一层，
不是 NTT 核**。这条对「折叠度是否值得做」是个旁证：收紧时钟时先动的是状态机，
不是蝶形阵列。

## 三、三档各自的前 10 条（`sys_clk` 组，Setup）

### pe1

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 6.538 | 13.153 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]` |
| 2 | 6.541 | 13.325 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[4]_rep__1` |
| 3 | 6.578 | 13.118 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[4]_rep__2` |
| 4 | 6.719 | 13.154 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]_rep__0` |
| 5 | 6.786 | 12.924 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[3]_rep__3` |
| 6 | 6.861 | 12.892 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[266]` |
| 7 | 6.864 | 12.887 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[330]` |
| 8 | 6.864 | 12.887 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[354]` |
| 9 | 6.864 | 12.887 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[362]` |
| 10 | 6.928 | 12.922 | 12 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[3]_rep__2` |

### pe4

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 6.840 | 12.905 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[314]` |
| 2 | 6.840 | 12.905 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[378]` |
| 3 | 6.840 | 12.905 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[442]` |
| 4 | 6.884 | 12.861 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[305]` |
| 5 | 6.884 | 12.861 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[465]` |
| 6 | 6.896 | 12.899 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[377]` |
| 7 | 6.896 | 12.899 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[393]` |
| 8 | 6.896 | 12.899 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[409]` |
| 9 | 6.896 | 12.899 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[417]` |
| 10 | 6.896 | 12.899 | 12 | `u_line/line_len_reg[2]` → `u_fsm/r_echo_reg[433]` |

### pe16

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 6.241 | 13.472 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[371]` |
| 2 | 6.241 | 13.472 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[379]` |
| 3 | 6.241 | 13.472 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[411]` |
| 4 | 6.241 | 13.472 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[443]` |
| 5 | 6.306 | 13.439 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[347]` |
| 6 | 6.310 | 13.401 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[309]` |
| 7 | 6.310 | 13.401 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[325]` |
| 8 | 6.310 | 13.401 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[477]` |
| 9 | 6.326 | 13.387 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[266]` |
| 10 | 6.326 | 13.387 | 12 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[282]` |

## 四、pe1 最坏那条的完整网表（12 级逻辑）

`u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]`，slack **+6.538 ns**，
数据路径 13.153 ns，逻辑级数 12（LUT3=1 LUT4=1 LUT5=5 LUT6=5）。

下表是报告里**数据路径那一段**逐行照抄 —— 源时钟路径、目的时钟路径两段已切掉
（它们不是数据路径）。走线单列成 `net` 行：布线在这张表里是**显式的**，
和逻辑各占一行，谁也不折进谁。

| # | 位置 | 类型 | 增量 (ns) | 累计 (ns) | 资源 |
|---|---|---|---|---|---|
| 1 | SLICE_X63Y33 | FDCE (Prop_fdce_C_Q) | 0.379 | 5.219 | `u_line/line_len_reg[2]/Q` |
| 2 | — | net (fo=65, routed) | 1.244 | 6.464 | `u_fsm/u_parse/Q[2]` |
| 3 | SLICE_X74Y43 | LUT3 (Prop_lut3_I0_O) | 0.115 | 6.579 | `u_fsm/u_parse/i_/r_echo_len[6]_i_5/O` |
| 4 | — | net (fo=16, routed) | 0.523 | 7.102 | `u_fsm/u_parse/line_len_reg[2]_6` |
| 5 | SLICE_X73Y43 | LUT5 (Prop_lut5_I2_O) | 0.288 | 7.390 | `u_fsm/u_parse/i_/r_echo_len[6]_i_4/O` |
| 6 | — | net (fo=20, routed) | 0.973 | 8.363 | `u_fsm/u_parse/line_len_reg[6]_0` |
| 7 | SLICE_X71Y37 | LUT6 (Prop_lut6_I1_O) | 0.275 | 8.638 | `u_fsm/u_parse/i_/e_pos_str[6]_i_66/O` |
| 8 | — | net (fo=10, routed) | 1.103 | 9.741 | `u_fsm/u_parse/i_/e_pos_str[6]_i_66_n_0` |
| 9 | SLICE_X81Y45 | LUT4 (Prop_lut4_I2_O) | 0.126 | 9.867 | `u_fsm/u_parse/i_/e_pos_str[14]_i_69/O` |
| 10 | — | net (fo=1, routed) | 0.549 | 10.416 | `u_fsm/u_parse/i_/e_pos_str[14]_i_69_n_0` |
| 11 | SLICE_X81Y45 | LUT5 (Prop_lut5_I1_O) | 0.289 | 10.705 | `u_fsm/u_parse/i_/e_pos_str[14]_i_16/O` |
| 12 | — | net (fo=1, routed) | 0.898 | 11.603 | `u_fsm/u_parse/i_/e_pos_str[14]_i_16_n_0` |
| 13 | SLICE_X79Y43 | LUT6 (Prop_lut6_I0_O) | 0.267 | 11.870 | `u_fsm/u_parse/i_/e_pos_str[14]_i_4/O` |
| 14 | — | net (fo=11, routed) | 0.962 | 12.832 | `u_fsm/u_parse/line_reg[494]` |
| 15 | SLICE_X66Y34 | LUT5 (Prop_lut5_I2_O) | 0.105 | 12.937 | `u_fsm/u_parse/i_/r_sfx_len[1]_i_48/O` |
| 16 | — | net (fo=2, routed) | 0.372 | 13.310 | `u_fsm/u_parse/i_/r_sfx_len[1]_i_48_n_0` |
| 17 | SLICE_X65Y34 | LUT6 (Prop_lut6_I5_O) | 0.105 | 13.415 | `u_fsm/u_parse/i_/r_sfx_len[1]_i_20/O` |
| 18 | — | net (fo=6, routed) | 0.795 | 14.209 | `u_fsm/u_parse/line_reg[4]` |
| 19 | SLICE_X64Y33 | LUT5 (Prop_lut5_I1_O) | 0.115 | 14.324 | `u_fsm/u_parse/i_/r_sfx_len[1]_i_6/O` |
| 20 | — | net (fo=7, routed) | 0.380 | 14.704 | `u_line/p_cksum_ok` |
| 21 | SLICE_X64Y32 | LUT6 (Prop_lut6_I5_O) | 0.267 | 14.971 | `u_line/after_state[3]_i_9/O` |
| 22 | — | net (fo=9, routed) | 0.503 | 15.474 | `u_line/line_len_reg[2]_0` |
| 23 | SLICE_X64Y30 | LUT6 (Prop_lut6_I1_O) | 0.105 | 15.579 | `u_line/after_state[3]_i_2/O` |
| 24 | — | net (fo=49, routed) | 1.804 | 17.383 | `u_fsm/after_state_reg[3]_0` |
| 25 | SLICE_X60Y2 | LUT5 (Prop_lut5_I0_O) | 0.126 | 17.509 | `u_fsm/tx_len[6]_i_2/O` |
| 26 | — | net (fo=1, routed) | 0.485 | 17.994 | `u_fsm/tx_len[6]_i_2_n_0` |

读法：第 1 行是起点 FF 的 clk-to-Q，之后每「一跳 LUT + 一跳走线」成对出现，第 26 行（终点 FF 的 D 端之前那跳走线）收尾。

⚠️ 这条路的**布线占 80.5%**、逻辑只占 19.5%：
13 跳走线合计 10.591 ns，12 个 LUT 合计 2.183 ns，再加起点 FF 的 clk-to-Q 0.379 ns
—— 三项相加正是 `Data Path Delay` 的 13.153 ns（⚠️ Vivado 把**起点 FF 也算进「逻辑」**里，所以 12 个 LUT 的和比 `logic` 那栏小）。
平摊下来一个 LUT 0.182 ns、一跳走线 0.815 ns（**4.5 倍**）—— 所以优化该往「压扇出」走。

根因是控制信号的高扇出：起点 `u_line/line_len_reg[2]/Q` 一条网线扇出 65；
单跳最贵的是 `u_fsm/after_state_reg[3]_0`，扇出 49、一跳 1.804 ns —— 比任何一个 LUT 都慢一个量级。

## 五、`**async_default**` 组（复位的 recovery / removal）

| 档 | 组内最坏 Slack (ns) | 类型 | 起点 → 终点 |
|---|---|---|---|
| pe1 | 8.338 | Recovery | `rst_sync_reg[1]` → `u_core/u_core/ag/FSM_onehot_curr_state_reg[2]` |
| pe4 | 11.501 | Recovery | `rst_sync_reg[1]` → `u_fsm/resp_ph_reg[2]` |
| pe16 | 7.202 | Recovery | `rst_sync_reg[1]` → `u_line/acc_reg[164]` |

三档这一组的起点都是 `rst_sync_reg[1]/C` —— 就是 `ntt_board_top.v` 里那级
「异步置位、同步释放」复位同步器（比例程多这一步，拦按键毛刺）。

## 六、怎么复跑

```sh
cd rtl/vivado && python gen_critical_paths.py      # 只读 reports/*.rpt，不碰 Vivado
```

报告本身怎么来的：`sh rtl/vivado/run_board_synth.sh`（需 Vivado，**不需要板子**）。
⚠️ 从**仓库外目录**启动 Vivado —— 仓库路径含撇号会把综合引擎咬死。

脚本出文档前会自己锚三道，任一道对不上就报错退出、不生成文件：

1. 筛出来的那条路径的 slack，等于同份报告 `Design Timing Summary` 里的 WNS
   —— 防「按节名筛、筛到 `**async_default**` 那组」（§一 那个坑）。
2. 明细里数出的 LUT 条数，等于报告自报的 `Logic Levels` —— 防明细行没解析全。
3. 明细逐行延迟相加，等于报告自报的 `Data Path Delay` —— 防漏读或多读行。

这三道锚本身也有人验：**`python check_critical_paths_anchors.py`** 把每道锚本该
拦住的失败人造出来（按节名筛、丢一行 LUT、丢一行 net），看它响不响；
顺带拿报告自己的 `route` / `logic` 两栏当**独立旁证** —— 那两栏是 Vivado 算的，
与我们怎么切段无关，对得上才说明数据路径那一段既没切多也没切少。
