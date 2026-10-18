# 板级提频实测（MMCM）—— 三档：80 / 75 / 62.5 MHz

> 2026-10-18 · A ｜ 对应报告《03 性能与资源》§3.10.1–§3.10.2
> 数据来源：`rtl/vivado/reports/board_pe{1,4,16}_f{80,75,62.5}_{util,timing,io}.rpt`
> 复跑：`sh rtl/vivado/run_board_freq_sweep.sh`（三档约 30 分钟，**不需要板子**）
>
> 本文件是**数据文档**，不是截图。Vivado GUI 里的关键路径图另存于 `assets/`。

## 一、结论

| 档 | 提频前（50 MHz）时钟级 WNS | 提频目标 | MMCM（MULT / DIV） | 提频后 WNS | 提频后 WHS | 失败端点 |
|---|---:|---:|---:|---:|---:|---:|
| pe1 | **+7.339 ns** | **80.0 MHz** | 24 / 15（VCO 1200） | **+0.698 ns** | +0.064 ns | 0 |
| pe4 | **+6.547 ns** | **75.0 MHz** | 24 / 16（VCO 1200） | **+0.754 ns** | +0.060 ns | 0 |
| pe16 | **+4.789 ns** | **62.5 MHz** | 20 / 16（VCO 1000） | **+1.720 ns** | +0.054 ns | 0 |

**三档提频位流 2026-10-18 已上板**（COM10，JTAG 直配）：每档跑
`#PING` + `#NTT 1` / `#INTT 1` / `#PMUL NTT 1` / `#PMUL TIME 1` / `#PMUL FULL 1`，
**各 6/6 PASS，每条 0/256 不同**。原始输出：

- pe1 @ 80 MHz → `reports/board_pe1_f80_txn.txt`
- pe4 @ 75 MHz → `reports/board_pe4_f75_txn.txt`
- pe16 @ 62.5 MHz → `reports/board_pe16_f62.5_txn.txt`

> 同一天也把 **50 MHz 基线**在当前驱动上重跑了三档：pe1 / pe4 / pe16 各 **6/6 PASS**
> （`reports/board_pe{1,4,16}_txn.txt`）。这同时收掉了 H6 最后一条 ——
> 10-15 卡住的 `#PMUL TIME 1` 在向量格式修好后三档全过。
> 10-15 的 5/6 旧报告留底为 `reports/board_pe1_txn_2026-10-15_5of6.txt`。

资源（提频只多一个 MMCM + 一个 BUFG，它们在报告里**不计入 LUT/FF**）：

| 档 | LUT（前 → 后） | FF（前 → 后） | BRAM Tile（前 → 后） | DSP（前 → 后） |
|---|---|---|---|---:|
| pe1 | 5074 → **5097** | 3496 → **3503** | 2.5 → 2.5 | 1 → 1 |
| pe4 | 6529 → **6543** | 3979 → **3983** | 9 → 9 | 4 → 4 |
| pe16 | 12894 → **12903** | 6042 → **6039** | 34.5 → 34.5 | 16 → 16 |

- 三档 **setup / hold / pulse width 全部 MET，失败端点 0**（每份报告 `Design Timing Summary`）。
- LUT 差 +9～+23、FF 差 ±7：来自时钟/复位网的重新映射与布局差异，**不是** MMCM 本身
  （MMCME2_ADV 与 BUFG 是专用时钟资源，不占 LUT/FF）。
- 频率比：pe1 **1.60×**、pe4 **1.50×**、pe16 **1.25×**（相对板上 50 MHz）。
- 核延迟按频率同比缩短。以 pe1 的 NTT 为例：904 拍 ÷ 50 MHz = 18.08 µs →
  **904 拍 ÷ 80 MHz = 11.30 µs**（周期数不变，只换了时钟）。

## 二、做法

### 2.1 只加一个 MMCM，不改协议

`rtl/board/ntt_board_top_mmcm.v` = `MMCME2_BASE` + `BUFG` + **原封不动**的 `ntt_board_top`。

- **整块板子仍然只有一个时钟域**：UART、协议机、系数缓冲、NTT 核全跑在 `clk_core` 上。
- 原顶层 `ntt_board_top.v` **一行没改**，仿真测试台（`rtl/board/tb/*.v`）照旧例化它；
  iverilog 里没有 MMCM 原语模型，把 MMCM 塞进原顶层会让仿真当场挂。
- 提频是**综合期参数**：`MMCM_MULT` / `MMCM_DIV` 由 `-generic` 传入，换频率 = 重综合，
  与折叠度 `PE_NUMBER` 是同一类参数。

### 2.2 三个跟频率走的常数必须一起换

`ntt_board_top` 里凡是「按拍数」写的常数，提频后都要按新频率重算，否则会出现
**频率对了、行为错了**，而且仿真发现不了（仿真仍是 50 MHz）：

| 参数 | 50 MHz 时的值 | 提频后 |
|---|---:|---|
| `CLK_FREQ`（UART 分频 = CLK_FREQ / 115200） | 50 000 000 | 新频率 |
| `T_LINE_CC`（行超时 1 s） | 50 000 000 | 新频率 |
| `T_CMD_CC`（字符间超时 10 s） | 500 000 000 | 10 × 新频率 |
| `T_CORE_CC`（核超时 100 ms） | 5 000 000 | 新频率 / 10 |

wrapper 里用 `localparam CLKOUT_HZ = 50_000_000 * MMCM_MULT / MMCM_DIV` 一次算好再传。
UART 分频取整误差：80 MHz → 694（115 273 bps，**+0.06%**）；75 MHz → 651（115 207 bps，+0.006%）；
62.5 MHz → 542（115 314 bps，+0.10%）。都在 UART 接收 16 倍过采样的容差内。

### 2.3 复位：等 MMCM 锁定

`locked` 拉高前 `clk_core` 不稳，wrapper 用 `sys_rst_n & locked` 把原顶层的
「异步置位、同步释放」同步器一直按住，锁定后再放行。

### 2.4 综合入口

```sh
# 三档一起跑（各自独立 _runs 目录与 scratch，互不覆盖）
sh rtl/vivado/run_board_freq_sweep.sh

# 只跑一档
PE=4 sh rtl/vivado/run_board_freq_sweep.sh
```

产物：

- 报告 `reports/board_pe<N>_f<MHz>_{util,timing,io}.rpt`（**带频率签名**，与 50 MHz 基线并存）
- 位流 `_runs/f<MHz>_pe<N>/ntt_board.bit`（+ `ntt_board.pe` 档位戳）

> ⚠️ 每档必须用**独立的 `VIVADO_RUNS` / `VIVADO_SCRATCH`**。2026-10-18 实测过并跑共用
> 目录的后果：第二轮 `rm -rf .Xil` 撞上第一轮正在写的文件（`Device or resource busy`），
> `set -e` 让整轮直接退出；两轮还会互相覆盖 `board_synth_try1.log`、`ntt_board.bit`。

## 三、为什么没有取 100 MHz

pe1 在 **100 MHz（10 ns）下不收敛**：

| 试验 | 约束 | 结果 |
|---|---|---:|
| pe1，**不含 MMCM**（只把 sys_clk 收紧到 10 ns） | 10.000 ns | WNS **+0.343 ns** |
| pe1，**含 MMCM**（MULT=20 / DIV=10） | 10.000 ns | WNS **−0.066 ns** ❌ |

- 两行的差别就是 MMCM 的时钟路径与布局差异：同一份 RTL、同一个约束，**MMCM 版贵约 0.4 ns**。
- 100 MHz 的位流已改名为 `_runs/f100_pe1/ntt_board_TIMING_VIOLATED.bit`，档位戳已删，
  **不要上板**；报告保留作证据（`reports/board_pe1_f100_timing.rpt`）。
- 取 80 MHz 的判据：**WNS ≥ +0.5 ns**。80 MHz 的 +0.698 ns 距门槛还有 0.2 ns 余量。

## 四、提频后卡住的仍然是协议层，不是蝶形

三档在**新频率**下的最坏路径（`sys_clk` 组 Setup）：

| 档 | 起点 → 终点 | 数据路径 | 逻辑 / 布线 | 逻辑级数 |
|---|---|---|---:|---:|
| pe1 @80 | `u_line/line_len_reg[4]` → `u_fsm/r_echo_reg[329]/CE` | 11.430 ns | 1.767 / **9.663** | 11 |
| pe4 @75 | `u_line/line_len_reg[2]` → `u_fsm/tx_len_reg[3]_rep__1/CE` | 12.298 ns | 2.711 / **9.587** | 15 |
| pe16 @62.5 | `u_line/line_len_reg[3]` → `u_fsm/r_echo_reg[156]/CE` | 14.115 ns | 2.652 / **11.463** | 13 |

和 50 MHz 基线（`critical_paths.md` §二）**是同一类路径**：

- 起点都在 `u_line`（行组装），终点都在 `u_fsm` 的宽寄存器使能译码；
- 布线占 **78%–85%**，逻辑只占 15%–22% —— 瓶颈是**扇出与走线**，不是组合深度；
- 核自己的推算 Fmax 是 168 / 160 / 154 MHz（`folding_comparison.md` §9.1），
  离这些新频率还有一倍以上余量。

⇒ 结论：**再往上提频要先治协议层的扇出，而不是改蝶形**。这条与 §3.10.1 里
「理由 ③ 答错了问题」那段是同一个判断，现在有了提频实测作旁证。

## 五、边界（写清楚，别被追问倒）

1. **综合数字与上板证据都在。** 三档提频位流 2026-10-18 15:35–15:38 已上真板，
   各 **6/6 PASS**（`reports/board_pe<N>_f<MHz>_txn.txt`）。⚠️ 但这是
   **「按 80 / 75 / 62.5 MHz 烧进去、功能全对」**，不是用扫描仪测出来的芯片极限频率；
   报告里写「提频版已在板上跑通六条命令」，不写「已测出芯片最高频率」。
2. **hold 余量只有 0.05–0.06 ns。** 三档 WHS 分别是 +0.064 / +0.060 / +0.054 ns，
   都是 MET，但比 setup 余量更紧；这是本设计（50 MHz 基线 WHS +0.020）一贯的性质，
   不是提频引入的新问题。报告里要如实写「余量小」，不要写「余量充足」。
3. **MMCM 频率是编译期参数。** 板上换频率要重烧位流；不存在「运行时调频」。
4. **VCO 受速度等级限制。** -2 档允许 600–1440 MHz，本文件三组配置是 1000 / 1200 MHz。
5. **端到端不会变快多少。** 115200 bps 串口搬运 184.4 ms，核延迟 18.08 µs →
   提频到 11.30 µs，端到端仍被串口主导（§3.10.3）。**不要**把提频写成「端到端加速 1.6×」。

## 六、复跑

```sh
cd <仓库根>
sh rtl/vivado/run_board_freq_sweep.sh          # 三档，约 30 分钟
```

2026-10-18 复跑验证：pe1@80 用同一命令重跑一次，`WNS / WHS / 端点计数` 与首轮
**逐位相同**（+0.698 / +0.064 / 11295），三份报告被同值覆盖 —— 这套流程可复现。

判据（脚本与报告里都能查）：

- 每份 `reports/board_pe<N>_f<MHz>_timing.rpt` 的 `Design Timing Summary` 第一行
  `WNS ≥ 0`，且 `TNS Failing Endpoints = 0`；
- `_runs/f<MHz>_pe<N>/ntt_board.pe` 的档位戳与目录名一致；
- 报告名里的频率与 `MMCM_MULT/DIV` 对得上（`50 × MULT / DIV`）。

## 七、和报告/指标的关系

- 填 `report/design/03_performance_and_resources.md` **§3.10.2** 的三列「提频后」；
- `metrics/README.md`「还没测的」表里「上板实测最高频率」「提频后三档 WNS / 资源」两行
  可改为「已测（综合侧），上板待」；
- `report/design/00_front_matter.md` §四 第 ④ 项的状态可从句尾的「数未填」改为「已填」。

⚠️ **本文件只覆盖「综合侧」。** 上板那一步（烧位流 + 五条事务）没有做之前，
任何文档都不要出现「提频版已在板上验证通过」。
