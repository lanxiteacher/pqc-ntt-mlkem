// ===========================================================================
// uart_tx.v —— UART 发送（8N1：1 起始位 + 8 数据位 + 无校验 + 1 停止位）
//
// 本文件为**自主实现**，不是从任何例程复制的。
// 端口名与参数名与正点原子 `19_uart_loopback` 的 uart_tx 保持一致，这样
// 板级顶层 `rtl/board/ntt_board_top.v` 的具名端口连接与具名参数覆盖不用改；
// 内部结构、命名与注释均为重写。
// 重写的动因（例程的许可与编码问题）写在 `rtl/uart_rx.v` 的文件头。
//
// ---------------------------------------------------------------------------
// ★ 握手契约 —— 上游 `rtl/board/tx_line.v` 是按这份契约写的，改之前先看它
//
//   `uart_tx_en` 是**1 拍脉冲**，它同时做三件事：
//       uart_tx_data → latch      （锁存要发的那个字节）
//       uart_tx_busy <= 1         （下一拍起 busy 为高）
//       bcnt / bitn 清零          （从起始位开始重新数）
//
//   `uart_tx_busy` 从拉高的那一拍起保持高，直到**停止位也发完**才落下。
//   空闲时 busy 为低、`uart_txd` 保持高（串口空闲电平）。
//
//   ⚠️ **busy 为高时绝不能再拉 en。** 本模块在 busy 期间直接忽略 en ——
//      这个字节会被丢掉。上游 tx_line.v 用三态子状态机（等 busy 落 → 拉 en
//      → 等 busy 起 → 等 busy 落）保证了「拉 en 时 busy 一定是低的」。
//      （例程的写法是 busy 期间也接受 en，会把当前字节腰斩、从头重发；
//        本模块选择忽略而非腰斩 —— 腰斩会发出一帧非法数据，丢字节则能被
//        上层当成一次明确的失败看见。两者都违背契约，忽略至少是可诊断的。）
//
// ---------------------------------------------------------------------------
// 时序约定
//
//   一位的时间 = CLK_FREQ / UART_BPS 个时钟（本设计 = 434 个 = 8680 ns）。
//   位序：起始位（低）→ D0 … D7（LSB 先出）→ 停止位（高）
//
//   起始位在拉 en 的**下一拍**就压下去，中间不留空拍（空闲电平多待一拍虽然
//   对端也认不出来 —— 20 ns 对 8680 ns 微不足道 —— 但会让「一位 = BAUD_MAX
//   拍」这个口径在第一位上不成立，时序表就得多写一条例外）。
// ===========================================================================

`timescale 1ns/1ps

module uart_tx #(
    parameter CLK_FREQ = 50000000,   // 系统时钟频率（Hz）
    parameter UART_BPS = 115200      // 串口波特率
)(
    input  wire       clk,
    input  wire       rst_n,         // 低有效，异步
    input  wire       uart_tx_en,    // 发送使能，1 拍脉冲
    input  wire [7:0] uart_tx_data,  // 要发送的字节
    output reg        uart_txd,      // 串口发送引脚（空闲为高）
    output reg        uart_tx_busy   // 发送忙
);

    // ---- 一位占多少个时钟（整数除法，余数丢掉）----------------------------
    localparam integer BAUD_MAX = CLK_FREQ / UART_BPS;
    localparam integer CNT_W    = $clog2(BAUD_MAX);

    // ---- 位序编号：起始位算 0 号，与 uart_rx.v 同一套口径 ------------------
    localparam [3:0] N_START = 4'd0;
    localparam [3:0] N_STOP  = 4'd9;

    reg [CNT_W-1:0] bcnt;    // 波特计数器，数一位之内的时钟
    reg [3:0]       bitn;    // 当前正在发第几位
    reg [7:0]       latch;   // 本字节的数据（锁存后不再看 uart_tx_data）

    // ---- 下一位该输出什么电平（组合）--------------------------------------
    //   bitn == 0 → 起始位（低）；bitn == 9 → 停止位（高）；其余是数据位，
    //   下标要减 1（bitn=1 → latch[0] = D0）。
    //
    //   ⚠️ 这里算的是**下一位**（bitn_next），不是当前位 —— 这是刻意的。
    //      位边界那一拍要把 uart_txd 更新成新一位的电平，而那一拍 bitn 还是
    //      旧值。若用旧 bitn 算，新电平要再等一拍才出现，起始位就比别的位
    //      宽一拍，「一位 = BAUD_MAX 拍」这个口径会多出一条例外。
    //      对端其实认不出来（20 ns 对 8680 ns 微不足道），但口径干净值得。
    wire [3:0] bitn_next = (bitn == N_STOP) ? N_START : bitn + 4'd1;
    wire tx_bit_next = (bitn_next == N_START) ? 1'b0
                     : (bitn_next == N_STOP ) ? 1'b1
                     :                          latch[bitn_next - 4'd1];

    // ---- 主状态机 ---------------------------------------------------------
    //   busy 与 txd 写在同一个 always 块里：uart_txd 只有一个驱动源，
    //   拉 en 那一拍要立刻把起始位压下去，和 busy 的翻转必须是同一拍的事。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx_busy <= 1'b0;
            uart_txd     <= 1'b1;              // 空闲电平为高
            bcnt         <= {CNT_W{1'b0}};
            bitn         <= N_START;
            latch        <= 8'd0;
        end
        // -------------------------------------------------------------------
        else if (!uart_tx_busy) begin
            uart_txd <= 1'b1;                  // 空闲：保持高
            if (uart_tx_en) begin
                latch        <= uart_tx_data;  // 锁存
                uart_tx_busy <= 1'b1;          // 下一拍起忙
                bcnt         <= {CNT_W{1'b0}};
                bitn         <= N_START;
                uart_txd     <= 1'b0;          // 起始位当拍压下，不留空拍
            end
        end
        // -------------------------------------------------------------------
        else begin
            // 发送中。uart_txd 只在**位边界**和拉 en 那一拍赋值，
            // 位中间不赋值 —— 不赋值即保持（时钟块的固有行为），少写一句
            // 就少一处口是心非的可能。
            if (bcnt == BAUD_MAX - 1) begin
                // 一位走完
                bcnt <= {CNT_W{1'b0}};
                if (bitn == N_STOP) begin
                    uart_tx_busy <= 1'b0;      // 停止位发完，收工
                    uart_txd     <= 1'b1;      // 立刻回到空闲电平
                end else begin
                    bitn     <= bitn + 4'd1;
                    uart_txd <= tx_bit_next;   // 直接拍上「下一位」的电平
                end
            end else begin
                bcnt <= bcnt + 1'b1;
            end
        end
    end

endmodule
