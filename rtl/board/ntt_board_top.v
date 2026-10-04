// ===========================================================================
// ntt_board_top.v —— 板级顶层（引脚名字到此为止）
//
// 板子：正点原子领航者 ZYNQ（xc7z020clg400-2）。引脚见 ntt_board.xdc。
//
// 唯一一个和板子打交道的地方就是本模块：**引脚名在这里换成核的 clk/reset**。
// 再往下一律用 `clk` / `rst_n` / `reset`，跟板子无关。
//
// ---------------------------------------------------------------------------
// 数据流
//
//   uart_rxd ─→ uart_rx ─┬─→ uart_line_rx ─→ proto_fsm ─┬─→ poly_buf ─→ KyberHPMNTT_top
//                        │      (攒整行)       (协议主控) │              (NTT 核)
//                        └─→ (超时计时)                    └─→ uart_tx ─→ uart_txd
//
//   ※ poly_buf 是 A/B 两个 256×12 的组；装载时由 proto_fsm 一拍一个 burst 进核，
//     读出时又借它的 A 组当接收缓冲。理由写在 proto_fsm.v 头部。
//
// ---------------------------------------------------------------------------
// ★ 复位极性 —— 这条不写下来一定会有人接错
//
//     例程（uart_rx / uart_tx）：`rst_n`，**低**有效，异步
//     NTT 核（KyberHPMNTT_top）：`reset`，**高**有效，异步        ← 正好相反
//
//   引脚 N16 是**低有效**（按下＝低）。所以：
//     · 给 uart_rx / uart_tx / uart_line_rx / proto_fsm：直接用 rst_n
//     · 给核：`~rst_n`
//
// ★ 复位同步器（比例程多这一步，是刻意的）
//   机械按键松开时会有抖动/毛刺。例程 `19_uart_loopback` 只有两个模块、状态单调，
//   毛刺顶多丢一个字节；本设计有一个七态协议机，被毛刺打到会停在一个没人处理的状态。
//   所以这里做一个标准的「**异步置位、同步释放**」同步器：
//     按下（sys_rst_n 拉低）→ 立刻异步清零，不挑时钟；
//     松开 → 等两个时钟再放行，抖动被滤掉。
//   代价是两个触发器，比 JTAG 重烧一次便宜得多。
//
// ---------------------------------------------------------------------------
// Vivado 工程要加哪些文件（相对仓库根）
//
//   rtl/board/ntt_board_top.v      ← 本文件（顶层）
//   rtl/board/proto_fsm.v          ← 协议状态机
//   rtl/board/cmd_parse.v          ← 命令行解析（纯组合）
//   rtl/board/uart_line_rx.v       ← 字节流 → 整行
//   rtl/board/tx_line.v            ← 整行 → 字节流
//   rtl/board/hex3.v               ← 3 字符 ↔ 12 位 + hex_digit
//   rtl/board/poly_buf.v           ← 256×12 ×2 系数缓冲
//   rtl/uart_rx.v  rtl/uart_tx.v   ← 自写（端口名沿用正点原子例程，实现是重写的）
//                                    重写动因见 rtl/uart_rx.v 文件头：例程文件头是
//                                    「All rights reserved」，不是开源许可，而本仓库
//                                    要转公开。行为契约未变，见 rtl/uart_tx.v 文件头。
//   rtl/ntt_core/*.v               ← 核，整目录（KyberHPMNTT_top 及 ntt_* 库）
//   rtl/board/ntt_board.xdc        ← 引脚与时序约束
//
//   ⚠️ 核只加 `rtl/ntt_core/` **这一个**目录。`rtl/pe1/` 里有同名同类的一套
//      （上游原件），两个都加会撞模块名。
//   ⚠️ 仓库路径里有撇号（`l'x`），Vivado 的 ABC 引擎会被 shell 引号咬死 ——
//      **必须从仓库外的目录启动 Vivado**，GUI 建工程同样中招。
// ===========================================================================

`timescale 1ns/1ps

module ntt_board_top #(
    parameter integer PE_NUMBER = 1,        // 本轮只做 pe1
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer UART_BPS  = 115200,
    // ---- 下面四个只给测试台用；上板一律走默认值 ----
    // ★ 为什么把它们提到顶层：T_LINE 的真值是 1 秒 = 5000 万拍，
    //   在仿真里等一次就要跑 5000 万拍。提到顶层以后测试台可以改成几千拍，
    //   「超时后回 #ERR 05 且回到等命令行」这条逻辑才测得动。
    //   默认值就是协议里的真值，综合结果不受影响。
    parameter integer T_LINE_CC = 50_000_000,   // 1 s
    parameter integer T_CMD_CC  = 500_000_000,  // 10 s（字符间）
    parameter integer T_CORE_CC = 5_000_000,    // 100 ms
    parameter integer READ_LAT  = 5             // read_a 后第 5 拍出第一个有效 dout
)(
    input  sys_clk,         // U18，50 MHz
    input  sys_rst_n,       // N16，**低**有效（按下＝低）
    input  uart_rxd,        // T19
    output uart_txd         // J15
);

    // =====================================================================
    // 1. 复位同步器：异步置位、同步释放
    // =====================================================================
    reg [1:0] rst_sync;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) rst_sync <= 2'b00;                  // 按下 → 立刻清零
        else            rst_sync <= { rst_sync[0], 1'b1 };  // 松开 → 两拍后放行
    end

    wire rst_n      = rst_sync[1];          // 给 uart/协议那几级（低有效）
    wire core_reset = ~rst_n;               // 给核（**高**有效）

    // =====================================================================
    // 2. 串口收
    // =====================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_done;

    uart_rx #(
        .CLK_FREQ (CLK_FREQ),
        .UART_BPS (UART_BPS)
    ) u_rx (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .uart_rxd     (uart_rxd),
        .uart_rx_done (uart_rx_done),
        .uart_rx_data (uart_rx_data)
    );

    // =====================================================================
    // 3. 字节流 → 整行
    // =====================================================================
    wire [511:0] line;              // 64 字节，右对齐（末字符在 [7:0]）
    wire [6:0]   line_len;
    wire         line_valid;
    wire         line_over;
    wire         rx_clr;
    wire [7:0]   rx_max_bytes;

    uart_line_rx #(.MAXLEN(64)) u_line (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .clr       (rx_clr),
        .rx_data   (uart_rx_data),
        .rx_done   (uart_rx_done),
        .max_bytes (rx_max_bytes),
        .line      (line),
        .line_len  (line_len),
        .line_valid(line_valid),
        .line_over (line_over)
    );

    // =====================================================================
    // 4. 协议状态机
    // =====================================================================
    // 应答的收发口
    wire        tx_en;
    wire [7:0]  tx_data;
    wire        tx_busy;

    // 系数缓冲
    wire        pb_we, pb_sel_b;
    wire [7:0]  pb_waddr, pb_raddr;
    wire [11:0] pb_wdata, pb_a_rdata, pb_b_rdata;

    // 核的接口
    wire        core_load_a_f, core_load_a_i;
    wire        core_load_b_f, core_load_b_i;
    wire        core_read_a,   core_read_b;
    wire        core_start_ab;
    wire        core_start_fntt, core_start_pwm2, core_start_intt;
    wire [11:0] core_din, core_dout;
    wire        core_done;

    // ⚠️ 加 keep：综合会把没人用的信号优化掉，留一根线在这里，
    //    将来要挂 ILA 看状态机进度时不用改 RTL 重新综合一遍。
    (* keep = "true" *) wire [3:0] dbg_state;

    proto_fsm #(
        .T_LINE_CC (T_LINE_CC),
        .T_CMD_CC  (T_CMD_CC),
        .T_CORE_CC (T_CORE_CC),
        .READ_LAT  (READ_LAT)
    ) u_fsm (
        .clk            (sys_clk),
        .rst_n          (rst_n),

        .rx_byte        (uart_rx_done),
        .line           (line),
        .line_len       (line_len),
        .line_valid     (line_valid),
        .line_over      (line_over),
        .rx_clr          (rx_clr),
        .rx_max_bytes   (rx_max_bytes),

        .uart_tx_en     (tx_en),
        .uart_tx_data   (tx_data),
        .uart_tx_busy   (tx_busy),

        .pb_we          (pb_we),
        .pb_sel_b       (pb_sel_b),
        .pb_waddr       (pb_waddr),
        .pb_wdata       (pb_wdata),
        .pb_raddr       (pb_raddr),
        .pb_a_rdata     (pb_a_rdata),
        .pb_b_rdata     (pb_b_rdata),

        .core_load_a_f  (core_load_a_f),
        .core_load_a_i  (core_load_a_i),
        .core_load_b_f  (core_load_b_f),
        .core_load_b_i  (core_load_b_i),
        .core_read_a    (core_read_a),
        .core_read_b    (core_read_b),
        .core_start_ab  (core_start_ab),
        .core_start_fntt(core_start_fntt),
        .core_start_pwm2(core_start_pwm2),
        .core_start_intt(core_start_intt),
        .core_din       (core_din),
        .core_dout      (core_dout),
        .core_done      (core_done),

        .dbg_state      (dbg_state)
    );

    // =====================================================================
    // 5. 系数缓冲
    // =====================================================================
    poly_buf u_pb (
        .clk     (sys_clk),
        .we      (pb_we),
        .sel_b   (pb_sel_b),
        .waddr   (pb_waddr),
        .wdata   (pb_wdata),
        .raddr   (pb_raddr),
        .a_rdata (pb_a_rdata),
        .b_rdata (pb_b_rdata)
    );

    // =====================================================================
    // 6. NTT 核（pe1）
    // =====================================================================
    KyberHPMNTT_top #(
        .PE_NUMBER (PE_NUMBER)
    ) u_core (
        .clk        (sys_clk),
        .reset      (core_reset),       // ⚠️ 高有效，与 rst_n 相反
        .load_a_f   (core_load_a_f),
        .load_a_i   (core_load_a_i),
        .load_b_f   (core_load_b_f),
        .load_b_i   (core_load_b_i),
        .read_a     (core_read_a),
        .read_b     (core_read_b),
        .start_ab   (core_start_ab),
        .start_fntt (core_start_fntt),
        .start_pwm2 (core_start_pwm2),
        .start_intt (core_start_intt),
        .din        (core_din),
        .dout       (core_dout),
        .done       (core_done)
    );

    // =====================================================================
    // 7. 串口发
    // =====================================================================
    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .UART_BPS (UART_BPS)
    ) u_tx (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .uart_tx_en   (tx_en),
        .uart_tx_data (tx_data),
        .uart_txd     (uart_txd),
        .uart_tx_busy (tx_busy)
    );

endmodule
