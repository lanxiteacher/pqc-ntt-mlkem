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
| 1 | `sys_clk` | 真正的时序关键路径；**「时钟级 WNS」指的就是这一组的**（取自 `Intra Clock Table` 里 `sys_clk` 那一行） | `Max Delay Paths`（前） / `Min Delay Paths`（前） |
| 2 | `**async_default**` | 复位同步器到异步控制端的 recovery / removal | 后面那两组同名节 |

⚠️ **两组的 `Max Delay Paths` 都叫这个名字** —— 只按节名找会拿到第二组，
而第二组的 slack（pe1 的 recovery 最坏一条是 2.490 ns）**不是时钟级 WNS**。
本文按 `Path Group` 字段筛，不按节名；筛完拿 `Intra Clock Table` 里 `sys_clk`
那一行对一遍（见 §六），对不上直接报错、不出文档。

⚠️⚠️ **`Design Timing Summary` 的 WNS 从 2026-10-07 起也不再等于时钟级 WNS 了。**
它给的是**全设计最坏**：板级三档时序全 MET 时，最坏那条可能落在
`**async_default**` 组（复位同步器的 recovery），而不是时钟组。
10-05 那版位流里 async 是 8.338、比时钟组 6.538 **好**，两个数**碰巧相等**，
所以拿它当锚一直没露馅；10-07 加了 `#RDY` 重建后反过来 —— pe1 那一行给 2.490，时钟组却是 7.339。
**同一个字段，含义变了，且不报错。**（`rtl/vivado/synth_board.tcl` 里同源的那条
2026-10-07 已拆成 `WNS_WORST_ANY_NS` / `WNS_CLOCK_NS` 两行；§六 的 1b 锚是它的机器版。）

⚠️ **而且这个坑是逐档的、不是「三档都错」** —— 同一批重建里：
pe1 全设计最坏 2.490 / 时钟级 7.339（不等）、pe4 1.879 / 6.547（不等）、
pe16 4.789 / 4.789（**相等**）。
pe16 恰好落在「相等」那一侧，所以只看 pe16 是看不出问题的 —— 这也是为什么
§六 的锚要在**三档上逐档跑**，不能挑一档抽样。

⚠️ 另有一处同源口径要记住：`**async_default**` **这一个组里混着两种检查** ——
`Recovery`（异步控制端的建立检查，进 **WNS**）与 `Removal`（进 **WHS**）。
pe1 组内：Recovery 最坏 2.490、Removal 最坏 1.700。
**取最坏时必须按族分开** —— 一锅端会把 Removal 的数当成 WNS 用。

另一条同类的坑（`project_state.md` §二 已记）：**板级 WNS 不能反推 Fmax** ——
20 ns 目标是故意放松的，布线器没被逼；核的 Fmax 推算在 `folding_comparison.md` §9.1，
那是**另一个边界 + 另一个约束**，别把两个数放一格里比。

## 二、三档 WNS 与关键路径（`sys_clk` 组，Setup）

| 档 | WNS (ns) | 数据路径 (ns) | 其中逻辑 / 布线 | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|---|
| pe1 | **+7.339** | 12.488 | 2.074 (16.6%) / 10.414 (83.4%) | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[361]` |
| pe4 | **+6.547** | 13.188 | 2.895 (22.0%) / 10.293 (78.0%) | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep__1` |
| pe16 | **+4.789** | 14.716 | 2.184 (14.8%) / 12.532 (85.2%) | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[256]` |

⚠️ **三档的关键路径都不在蝶形里。** 起点都在 `u_line`（行组装）这一侧，
终点都在 `u_fsm` 的宽寄存器使能译码上 —— 也就是说，**卡时序的是协议状态机那一层，
不是 NTT 核**。这条对「折叠度是否值得做」是个旁证：收紧时钟时先动的是状态机，
不是蝶形阵列。

## 三、三档各自的前 10 条（`sys_clk` 组，Setup）

### pe1

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 7.339 | 12.488 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[361]` |
| 2 | 7.373 | 12.371 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[290]` |
| 3 | 7.373 | 12.371 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[330]` |
| 4 | 7.373 | 12.371 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[394]` |
| 5 | 7.373 | 12.371 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[458]` |
| 6 | 7.383 | 12.362 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[265]` |
| 7 | 7.421 | 12.323 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[274]` |
| 8 | 7.421 | 12.323 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[402]` |
| 9 | 7.421 | 12.323 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[466]` |
| 10 | 7.424 | 12.320 | 11 | `u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[345]` |

### pe4

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 6.547 | 13.188 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep__1` |
| 2 | 6.547 | 13.188 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep__3` |
| 3 | 6.673 | 13.091 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[1]` |
| 4 | 6.673 | 13.091 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[1]_rep__0` |
| 5 | 6.691 | 13.044 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep` |
| 6 | 6.691 | 13.044 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]_rep` |
| 7 | 6.691 | 13.044 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]_rep__0` |
| 8 | 6.691 | 13.044 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[6]_rep__1` |
| 9 | 6.796 | 12.930 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep__0` |
| 10 | 6.796 | 12.930 | 15 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[0]_rep__4` |

### pe16

| # | Slack (ns) | 数据路径 (ns) | 逻辑级数 | 起点 → 终点 |
|---|---|---|---|---|
| 1 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[256]` |
| 2 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[320]` |
| 3 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[328]` |
| 4 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[344]` |
| 5 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[360]` |
| 6 | 4.789 | 14.716 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[448]` |
| 7 | 4.838 | 14.669 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[280]` |
| 8 | 4.838 | 14.669 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[312]` |
| 9 | 4.838 | 14.669 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[376]` |
| 10 | 4.870 | 14.669 | 12 | `u_line/line_len_reg[6]` → `u_fsm/r_echo_reg[440]` |

## 四、pe1 最坏那条的完整网表（11 级逻辑）

`u_line/line_len_reg[0]` → `u_fsm/r_echo_reg[361]`，slack **+7.339 ns**，
数据路径 12.488 ns，逻辑级数 11（LUT3=2 LUT4=1 LUT5=4 LUT6=4）。

下表是报告里**数据路径那一段**逐行照抄 —— 源时钟路径、目的时钟路径两段已切掉
（它们不是数据路径）。走线单列成 `net` 行：布线在这张表里是**显式的**，
和逻辑各占一行，谁也不折进谁。

| # | 位置 | 类型 | 增量 (ns) | 累计 (ns) | 资源 |
|---|---|---|---|---|---|
| 1 | SLICE_X64Y8 | FDCE (Prop_fdce_C_Q) | 0.379 | 5.227 | `u_line/line_len_reg[0]/Q` |
| 2 | — | net (fo=44, routed) | 1.161 | 6.389 | `u_fsm/u_parse/Q[0]` |
| 3 | SLICE_X74Y10 | LUT3 (Prop_lut3_I2_O) | 0.119 | 6.508 | `u_fsm/u_parse/i_/r_echo_len[6]_i_5/O` |
| 4 | — | net (fo=16, routed) | 0.841 | 7.349 | `u_fsm/u_parse/line_len_reg[2]_0` |
| 5 | SLICE_X76Y8 | LUT5 (Prop_lut5_I2_O) | 0.286 | 7.635 | `u_fsm/u_parse/i_/r_echo_len[6]_i_4/O` |
| 6 | — | net (fo=20, routed) | 1.036 | 8.670 | `u_fsm/u_parse/line_len_reg[6]_1` |
| 7 | SLICE_X74Y10 | LUT6 (Prop_lut6_I1_O) | 0.267 | 8.937 | `u_fsm/u_parse/i_/e_pos_str[6]_i_66/O` |
| 8 | — | net (fo=10, routed) | 1.343 | 10.280 | `u_fsm/u_parse/i_/e_pos_str[6]_i_66_n_0` |
| 9 | SLICE_X90Y4 | LUT5 (Prop_lut5_I2_O) | 0.105 | 10.385 | `u_fsm/u_parse/i_/e_pos_str[6]_i_45/O` |
| 10 | — | net (fo=1, routed) | 0.125 | 10.510 | `u_fsm/u_parse/i_/e_pos_str[6]_i_45_n_0` |
| 11 | SLICE_X90Y4 | LUT6 (Prop_lut6_I0_O) | 0.105 | 10.615 | `u_fsm/u_parse/i_/e_pos_str[6]_i_13/O` |
| 12 | — | net (fo=1, routed) | 1.293 | 11.909 | `u_fsm/u_parse/i_/e_pos_str[6]_i_13_n_0` |
| 13 | SLICE_X70Y5 | LUT6 (Prop_lut6_I2_O) | 0.105 | 12.014 | `u_fsm/u_parse/i_/e_pos_str[6]_i_3/O` |
| 14 | — | net (fo=9, routed) | 0.677 | 12.691 | `u_fsm/u_parse/line_reg[57]` |
| 15 | SLICE_X68Y10 | LUT3 (Prop_lut3_I1_O) | 0.105 | 12.796 | `u_fsm/u_parse/i_/e_pos_str[6]_i_1/O` |
| 16 | — | net (fo=9, routed) | 0.512 | 13.308 | `u_fsm/u_parse/i_/e_pos_str[6]_i_4_0[0]` |
| 17 | SLICE_X67Y10 | LUT5 (Prop_lut5_I3_O) | 0.126 | 13.434 | `u_fsm/u_parse/i_/after_state[1]_i_5/O` |
| 18 | — | net (fo=8, routed) | 0.574 | 14.008 | `u_line/r_ldb_i_reg_3` |
| 19 | SLICE_X66Y11 | LUT5 (Prop_lut5_I2_O) | 0.267 | 14.275 | `u_line/resp_kind[1]_i_4/O` |
| 20 | — | net (fo=1, routed) | 0.732 | 15.007 | `u_line/resp_kind[1]_i_4_n_0` |
| 21 | SLICE_X66Y11 | LUT6 (Prop_lut6_I1_O) | 0.105 | 15.112 | `u_line/resp_kind[1]_i_2/O` |
| 22 | — | net (fo=5, routed) | 0.616 | 15.728 | `u_line/line_len_reg[1]_0` |
| 23 | SLICE_X64Y13 | LUT4 (Prop_lut4_I3_O) | 0.105 | 15.833 | `u_line/r_echo_len[6]_i_1/O` |
| 24 | — | net (fo=495, routed) | 1.503 | 17.336 | `u_fsm/r_echo_len_reg[0]_0[0]` |

读法：第 1 行是起点 FF 的 clk-to-Q，之后每「一跳 LUT + 一跳走线」成对出现，第 24 行（终点 FF 的 D 端之前那跳走线）收尾。

⚠️ 这条路的**布线占 83.4%**、逻辑只占 16.6%：
12 跳走线合计 10.413 ns，11 个 LUT 合计 1.695 ns，再加起点 FF 的 clk-to-Q 0.379 ns
—— 三项相加正是 `Data Path Delay` 的 12.488 ns（⚠️ Vivado 把**起点 FF 也算进「逻辑」**里，所以 12 个 LUT 的和比 `logic` 那栏小）。
平摊下来一个 LUT 0.154 ns、一跳走线 0.868 ns（**5.6 倍**）—— 所以优化该往「压扇出」走。

根因是控制信号的高扇出：起点 `u_line/line_len_reg[0]/Q` 一条网线扇出 44；
单跳最贵的是 `u_fsm/r_echo_len_reg[0]_0[0]`，扇出 495、一跳 1.503 ns —— 比任何一个 LUT 都慢一个量级。

## 五、`**async_default**` 组（复位的 recovery / removal）

⚠️ **这一个组里混着两种检查，必须分开看** —— `Recovery` 属 Setup 族、进 **WNS**；
`Removal` 属 Hold 族、进 **WHS**。下面的表按族分两列，别把两列放一起比大小。

| 档 | Recovery 最坏 (ns) → 进 WNS | Removal 最坏 (ns) → 进 WHS | 起点 → 终点 |
|---|---|---|---|
| pe1 | 2.490 | 1.700 | `rst_sync_reg[1]` → `u_core/u_core/BTF_GEN_BLOCK[0].btfu/w5r0_reg[10]` |
| pe4 | 1.879 | 1.574 | `rst_sync_reg[1]` → `u_core/u_core/BTF_GEN_BLOCK[0].btfu/w5r0_reg[0]` |
| pe16 | 9.400 | 0.575 | `rst_sync_reg[1]` → `u_fsm/r_echo_reg[362]` |

三档这一组的起点都是 `rst_sync_reg[1]/C` —— 就是 `ntt_board_top.v` 里那级
「异步置位、同步释放」复位同步器（比例程多这一步，拦按键毛刺）。终点分两类：
pe1 / pe4 落在 **NTT 核内部**（`u_core/.../btfu/w5r0_reg`），pe16 落在 `u_fsm`。
原因直白 —— 复位网的扇出：核内 `w5r0` 那一排寄存器离 `rst_sync_reg[1]` 的布线更远。
⚠️ **这仍然不是「核有时序问题」**：recovery 量的是「异步复位释放沿离时钟沿够不够远」，
与核的组合逻辑深度无关 —— 别把它读成 §二 那条「卡时序的不是蝶形」的反例。

⚠️ **2026-10-07 起，Recovery 那一列就是「全设计最坏」的所在地**（见 §一 那段）。
注意它的性质：这条路径**不 gate 时钟** —— recovery 检查的是「异步控制端别在
时钟沿附近动」，它 slack 小**不等于** 50 MHz 跑不动。`Design Timing Summary`
的 WNS 现在被它占着，所以**别拿那一格反推板级余量**，要用 §二 的时钟级数。

## 六、怎么复跑

```sh
cd rtl/vivado && python gen_critical_paths.py      # 只读 reports/*.rpt，不碰 Vivado
```

报告本身怎么来的：`sh rtl/vivado/run_board_synth.sh`（需 Vivado，**不需要板子**）。
⚠️ 从**仓库外目录**启动 Vivado —— 仓库路径含撇号会把综合引擎咬死。

脚本出文档前会自己锚四道，任一道对不上就报错退出、不生成文件：

1. 筛出来的那条路径的 slack，等于同份报告 `Intra Clock Table` 里 `sys_clk`
   那一行的 WNS（**时钟级**）—— 防「按节名筛、筛到 `**async_default**` 那组」
   （§一 那个坑）。
1b. `Design Timing Summary` 的 **WNS** ＝ `sys_clk` 组与 `**async_default**` 组里的
   **Recovery** 里更差的那个；**WHS** 同理，对 `**async_default**` 组的
   **Removal** —— 防报告里出现本脚本没认出来的第三组路径 / 第三种检查。
   ⚠️ **这条 2026-10-07 才加**：它反过来暴露了旧的
   第 1 道锚本身在用错数（拿全设计最坏当时钟级 WNS 使，RTL 一改就误判）。
2. 明细里数出的**逻辑级**条数，等于报告自报的 `Logic Levels` —— 防明细行没解析全。
   ⚠️ 口径是「非走线、且非时序单元（`FD*`/`LD*`/`RAMB*`/`SRL*`）」，**不是只数**
   `LUT*`**：pe4 那条路径中间有一级 `MUXF7`（专用多路器），它算一级逻辑但不叫 LUT。
3. 明细逐行延迟相加，等于报告自报的 `Data Path Delay` —— 防漏读或多读行。

这四道锚本身也有人验：**`python check_critical_paths_anchors.py`** 把每道锚本该
拦住的失败人造出来（按节名筛、把 async 两族混着取最坏、只数 LUT、丢一行 net），
看它响不响；
顺带拿报告自己的 `route` / `logic` 两栏当**独立旁证** —— 那两栏是 Vivado 算的，
与我们怎么切段无关，对得上才说明数据路径那一段既没切多也没切少。

⚠️ **锚 1b 和锚 2 的第一版都是错的，是这套阴性对照当场抓出来的**（2026-10-07）：
1b 把 async 组 20 条一锅端取 min，拿 Removal 的 1.700 去比 WNS 2.490；
2 只数 LUT，在 pe4 上得 14 而报告写 15。两道都**报假错**（把对的数判成错的）——
跟它们本来要防的「报假对」是一对。**没有阴性对照，这两条会一直错下去**，
因为三档里 pe1/pe16 恰好都能蒙对。
