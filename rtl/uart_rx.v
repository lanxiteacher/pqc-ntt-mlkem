// ===========================================================================
// uart_rx.v —— UART 接收（8N1：1 起始位 + 8 数据位 + 无校验 + 1 停止位）
//
// 本文件为**自主实现**，不是从任何例程复制的。
// 端口名与参数名与正点原子 `19_uart_loopback` 的 uart_rx 保持一致，这样
// 板级顶层 `rtl/board/ntt_board_top.v` 的具名端口连接与具名参数覆盖不用改；
// 内部结构、命名与注释均为重写。
//
// ★ 为什么要重写（别以后有人「为了省事」换回例程）
//
//   例程文件头写着 `Copyright(C) 正点原子 2023-2033 / All rights reserved`，
//   这不是开源许可。本仓库按竞赛要求最终要转公开，不能带一份没有拿到授权的
//   代码进去；例程的源码还是 GBK 编码，与本仓库其余文件的 UTF-8 也不一致。
//   代价只是几十行 —— UART 收发是成熟结构，没什么可「省」的。
//
// ---------------------------------------------------------------------------
// 时序约定
//
//   一位的时间 = CLK_FREQ / UART_BPS 个时钟（本设计 = 50e6/115200 = 434，
//   434 × 20 ns = 8680 ns，与 115200 bps 的名义位宽 8680.6 ns 差 0.6 ns；
//   十位累计也才 6 ns，远小于半个位时间，采样不会跑偏）。
//
//   采样点取**每一位的正中间**。这不是讲究，是必须：起始位的下降沿与本地
//   时钟没有任何相位关系，贴着边沿采样会被抖动直接打穿；采在中间，则前后
//   各留半个位时间的余量。
//
//   帧序：起始位（低）→ D0 … D7（LSB 先出）→ 停止位（高）
//
// ---------------------------------------------------------------------------
// 输出约定
//
//   uart_rx_done  收到一个完整字节时拉高**正好 1 拍**（拉高那一拍
//                 uart_rx_data 上已经是收到的字节）
//   uart_rx_data  收到的字节，1 拍脉冲期间有效
// ===========================================================================

`timescale 1ns/1ps

module uart_rx #(
    parameter CLK_FREQ = 50000000,   // 系统时钟频率（Hz）
    parameter UART_BPS = 115200      // 串口波特率
)(
    input  wire       clk,
    input  wire       rst_n,         // 低有效，异步
    input  wire       uart_rxd,      // 串口接收引脚（空闲为高）
    output reg        uart_rx_done,  // 收完一个字节，1 拍脉冲
    output reg  [7:0] uart_rx_data   // 收到的字节
);

    // ---- 一位占多少个时钟 -------------------------------------------------
    //   注意是**整数除法**，余数丢掉（434.03 → 434）。见文件头的误差估算。
    localparam integer BAUD_MAX = CLK_FREQ / UART_BPS;
    localparam integer BAUD_MID = BAUD_MAX / 2;        // 位中点
    localparam integer CNT_W    = $clog2(BAUD_MAX);    // 波特计数器的位宽

    // ---- 位序编号 ---------------------------------------------------------
    //   bitn 数的是「当前正处于哪一位」，起始位算 0 号：
    //       0        起始位
    //       1 … 8    D0 … D7
    //       9        停止位
    //   所以采样数据位时下标要减 1。
    localparam [3:0] N_START = 4'd0;
    localparam [3:0] N_STOP  = 4'd9;

    localparam S_IDLE = 1'b0,
               S_RECV = 1'b1;

    reg              state;
    reg [CNT_W-1:0]  bcnt;      // 波特计数器，数一位之内的时钟
    reg [3:0]        bitn;      // 当前位号
    reg [7:0]        shreg;     // 移位/装配寄存器

    // ---- 输入同步：两级同步 + 一拍延迟的边沿检测 --------------------------
    //   ⚠️ 2026-10-29 B 审阅（team/review_2026-10-29_B_uart_cdc.md）：
    //   起始沿判定**不能**直接使用第一级 rxd_s0 —— 第一级仍可能处于亚稳态，
    //   拿它驱动组合逻辑，等于把风险带进接收状态机。
    //   现在 s0/s1 只做同步（s0 加 ASYNC_REG），s2 是 s1 的延迟副本；
    //   起始沿用 s2（旧）与 s1（新）相比，二者都是同步后的寄存器输出。
    //   代价：检测比原来晚 1 拍（一位 434 拍、中点余量 217 拍，可忽略）。
    //   复位置 1（空闲电平），避免复位后第一个时钟造出假沿。
    (* ASYNC_REG = "TRUE" *) reg rxd_s0;
    (* ASYNC_REG = "TRUE" *) reg rxd_s1;
    reg rxd_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_s0 <= 1'b1;
            rxd_s1 <= 1'b1;
            rxd_s2 <= 1'b1;
        end else begin
            rxd_s0 <= uart_rxd;
            rxd_s1 <= rxd_s0;
            rxd_s2 <= rxd_s1;
        end
    end

    // ---- 起始沿判定 -------------------------------------------------------
    //   rxd_s2 是**旧**值、rxd_s1 是**新**值（s1 比 s2 晚一拍）。
    //   所以「旧值 1、新值 0」= 下降沿 = 起始位。
    //   只在空闲态认沿：接收过程中的低电平是数据位，不是新的起始位。
    wire start_seen = rxd_s2 & ~rxd_s1 & (state == S_IDLE);

    // ---- 主状态机 ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            bcnt         <= {CNT_W{1'b0}};
            bitn         <= N_START;
            shreg        <= 8'd0;
            uart_rx_done <= 1'b0;
            uart_rx_data <= 8'd0;
        end else begin
            // done 是 1 拍脉冲：默认拉低，只有收完那一拍才拉高
            uart_rx_done <= 1'b0;

            case (state)
            // ---------------------------------------------------------------
            S_IDLE: begin
                if (start_seen) begin
                    state <= S_RECV;
                    bcnt  <= {CNT_W{1'b0}};   // 从检测到沿的这一拍重新数
                    bitn  <= N_START;         // 当前是起始位
                    shreg <= 8'd0;
                end
            end
            // ---------------------------------------------------------------
            S_RECV: begin
                // 位中点采样。只采数据位（1…8），起始位和停止位不采。
                if ((bcnt == BAUD_MID - 1) && (bitn >= 4'd1) && (bitn <= 4'd8))
                    shreg[bitn - 4'd1] <= rxd_s1;

                if (bitn == N_STOP) begin
                    // 停止位：走到**中点**就收工，不等它走完。
                    //
                    // ⚠️ 这条是本模块最容易写错的地方。看似「等停止位结束再回
                    //    空闲」更自然，实际会丢字节：本模块的采样栅格是从
                    //    **检测到起始沿**那一刻起算的，而起始沿经过两级同步
                    //    再延迟一拍进来，比真实沿晚约 3 拍 —— 栅格也就晚 3 拍。
                    //    连着的下一个字节的起始沿会**早于**停止位结束 3 拍到达，
                    //    而那一刻 state 还是 S_RECV，start_seen 被
                    //    `(state == S_IDLE)` 挡住，那个字节被整个丢掉。
                    //    现象是「PC 连着发 256 行，板子只认出零星几个字节」。
                    //
                    //   取得中点则留出半个位时间（217 拍）的余量，而栅格偏差
                    //    只有 3 拍 —— 差两个数量级，够了。
                    //
                    //    ⚠️ 这里取 shreg 是安全的：最高位 D7 在 bitn==8 的中点
                    //       就写完了，现在是下一个位时间的中点，早已稳定。
                    if (bcnt == BAUD_MID - 1) begin
                        state        <= S_IDLE;
                        uart_rx_done <= 1'b1;
                        uart_rx_data <= shreg;
                    end else begin
                        bcnt <= bcnt + 1'b1;
                    end
                end
                else if (bcnt == BAUD_MAX - 1) begin
                    // 数据位走完（起始位与数据位都走这条），进下一位
                    bcnt <= {CNT_W{1'b0}};
                    bitn <= bitn + 4'd1;
                end
                else begin
                    bcnt <= bcnt + 1'b1;
                end
            end
            // ---------------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
