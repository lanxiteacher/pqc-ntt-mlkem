// ===========================================================================
// ntt_board_top_mmcm.v —— 带 MMCM 的板级顶层（提频版，2026-10-18）
//
// 板子：正点原子领航者 ZYNQ（xc7z020clg400-2）。引脚与 ntt_board.xdc 一致。
//
// ---------------------------------------------------------------------------
// 为什么要单独一个顶层，而不是把 MMCM 塞进 ntt_board_top.v
//
//   ① ntt_board_top.v 是**仿真与上板共用**的顶层，测试台（rtl/board/tb/*.v）
//      直接例化它，iverilog 里没有 MMCME2_BASE 的原语模型 —— 塞进去，仿真当场挂。
//   ② 基线（50 MHz）的 bitstream 与三份已提交报告必须**能原样复现**。
//      提频版是**另一条**综合入口，不能把基线那条路改掉。
//   ③ 所以：本文件 = 「MMCM + 原顶层」，原顶层一行没动。
//      综合脚本用 TOP=... 选择走哪条路（见 rtl/vivado/run_board_synth.sh）。
//
// ---------------------------------------------------------------------------
// 时钟结构
//
//   sys_clk (U18, 50 MHz) ─→ MMCME2_BASE ─→ BUFG ─→ clk_core ─→ ntt_board_top
//                                                            └─ 里面 UART / 协议机 / NTT 核
//                                                               **全部**跑在 clk_core 上
//
//   ⚠️ 整块板子只有一个时钟域。**不要**把 UART 留在 50 MHz、只给核提频 ——
//      那样协议机与核之间要多两级异步 FIFO，协议时序（READ_LAT / 装载间隔）
//      全部要重算，等于把冻结的 v1.0 协议推倒重来。提频的代价必须只落在
//      「一个参数 + 一个 MMCM」上。
//
// ---------------------------------------------------------------------------
// 频率怎么定（MMCM_MULT / MMCM_DIV）
//
//   VCO = 50 MHz × MMCM_MULT       （7 系列 -2 速度等级要求 600–1440 MHz）
//   clk_core = VCO / MMCM_DIV
//
//   已验证可用的组合（2026-10-18 综合实测，见 rtl/vivado/board_freq_sweep.md）：
//     62.5 MHz : MULT=20 DIV=16   VCO=1000
//     75   MHz : MULT=24 DIV=16   VCO=1200
//     80   MHz : MULT=24 DIV=15   VCO=1200
//     100  MHz : MULT=20 DIV=10   VCO=1000
//
//   ⚠️ MMCM_MULT/DIV 是**综合时**由 -generic 传进来的整数，不是运行时寄存器。
//      换频率 = 重新综合、重新出 bitstream，与折叠度是同一类参数。
//
// ---------------------------------------------------------------------------
// 参数传递（三个跟频率走的常数，最容易漏）
//
//   ntt_board_top 里凡是「按拍数」写死的常数，在提频后都必须按新频率重算，
//   否则**频率提上去了、行为却错了**，而且仿真发现不了（仿真还是 50 MHz）：
//
//     CLK_FREQ     : UART 分频 = CLK_FREQ / UART_BPS（整数除法）
//     T_LINE_CC    : 行超时 1 s      → CLK_FREQ
//     T_CMD_CC     : 字符间超时 10 s → 10 × CLK_FREQ
//     T_CORE_CC    : 核超时 100 ms   → CLK_FREQ / 10
//
//   本文件在 localparam 里算好再传下去。⚠️ T_CMD_CC 在 100 MHz 时是 10^9，
//   仍在 32 位有符号范围内（协议机里 t_cmd_c 是 32 位）。
//
//   复位：MMCM 锁之前 clk_core 是不稳的，所以 rst_n_int = sys_rst_n & locked，
//   把原顶层的「异步置位」一直按住，等 LOCKED 起来再放行。原顶层内部还有一级
//   「异步置位、同步释放」同步器，两级不冲突。
// ===========================================================================

`timescale 1ns/1ps

module ntt_board_top_mmcm #(
    // 折叠度：1 / 4 / 16（与基线顶层同名同义，由综合脚本的 PE=<n> 传进来）
    parameter integer PE_NUMBER = 1,
    // MMCM 倍频/分频整数。默认 62.5 MHz（= 1000 / 16）。
    parameter integer MMCM_MULT = 20,
    parameter integer MMCM_DIV  = 16,
    parameter integer UART_BPS  = 115200
)(
    input  sys_clk,         // U18，50 MHz
    input  sys_rst_n,       // N16，**低**有效（按下＝低）
    input  uart_rxd,        // T19
    output uart_txd         // J15
);

    // =====================================================================
    // 0. 频率常量 —— 全部从 MMCM_MULT/DIV 推出，不另写死一个数
    // =====================================================================
    localparam integer CLKOUT_HZ = 50_000_000 * MMCM_MULT / MMCM_DIV;

    // MMCM 的 *_F 参数要 real。整数 → real 的转换在 elaboration 时完成。
    localparam real MMCM_MULT_F = MMCM_MULT;
    localparam real MMCM_DIV_F  = MMCM_DIV;

    // 输入时钟周期（ns）：50 MHz = 20 ns。MMCM 用它算 VCO。
    localparam real CLKIN_PERIOD_NS = 20.0;

    // =====================================================================
    // 1. MMCM + BUFG
    // =====================================================================
    wire clk_mmcm;
    wire clk_core;
    wire locked;
    wire clkfb;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (MMCM_MULT_F),
        .CLKIN1_PERIOD      (CLKIN_PERIOD_NS),
        .CLKOUT0_DIVIDE_F   (MMCM_DIV_F),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKOUT0   (clk_mmcm),
        .CLKOUT0B  (),
        .CLKOUT1   (),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .CLKFBOUT  (clkfb),
        .CLKFBOUTB (),
        .LOCKED    (locked),
        .CLKIN1    (sys_clk),
        .PWRDWN    (1'b0),
        .RST       (1'b0),
        .CLKFBIN   (clkfb)
    );

    // ⚠️ 显式例化 BUFG，不靠综合器自己插：
    //    MMCM 的 CLKOUT 必须经 BUFG 才能驱动全芯片的时钟网；让工具推断时，
    //    它有时会把 BUFG 放到核内部、时钟树被切成两段，报告里的时钟延迟就
    //    对不上实际布线（这一步在 2026-10-07 的板级时序核对里踩过一次，
    //    见 rtl/vivado/critical_paths.md §一 关于时钟组的说明）。
    BUFG u_bufg (
        .I (clk_mmcm),
        .O (clk_core)
    );

    // =====================================================================
    // 2. 复位：MMCM 锁定前一直按住
    // =====================================================================
    // ⚠️ 这里只在 **clk_core 域**做组合与；sys_rst_n 是异步输入，
    //    原顶层内部第一级就是「异步置位」的同步器，极性/时序都对得上。
    wire rst_n_int = sys_rst_n & locked;

    // =====================================================================
    // 3. 原顶层，一行没改 —— 只是把时钟与按拍数定的常数换掉
    // =====================================================================
    ntt_board_top #(
        .PE_NUMBER (PE_NUMBER),
        .CLK_FREQ  (CLKOUT_HZ),
        .UART_BPS  (UART_BPS),
        .T_LINE_CC (CLKOUT_HZ),          // 1 s
        .T_CMD_CC  (CLKOUT_HZ * 10),     // 10 s
        .T_CORE_CC (CLKOUT_HZ / 10)      // 100 ms
    ) u_top (
        .sys_clk   (clk_core),
        .sys_rst_n (rst_n_int),
        .uart_rxd  (uart_rxd),
        .uart_txd  (uart_txd)
    );

endmodule
