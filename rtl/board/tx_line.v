// ===========================================================================
// tx_line.v —— 把一整行字节串通过 uart_tx 发出去
//
// 只干一件事：**发 len 个字节，再补一个 LF**。校验值的 `*xx` 由调用方
// 放进 txbuf 里（因为校验是对**行内容**算的，在装缓冲那一步算最自然）。
//
// 依据：host/proto.md §5.1（行与行只靠 LF 分隔）+ rtl/uart_tx.v 的实际握手。
//
// ★ uart_tx 的握手（读它源码数出来的，不是猜的）：
//      uart_tx_en 是**1 拍脉冲**，它同时做三件事：
//        uart_tx_data → tx_data_t（锁存要发的字节）
//        uart_tx_busy <= 1
//        baud_cnt / tx_cnt 清零
//      所以**绝不能在 busy 为高时再拉 en** —— 那会把当前字节腰斩、从头重发。
//      本模块用一个三态子状态机保证：先等 busy 落 → 拉 en → 等 busy 起 →
//      等 busy 落 → 下一个字节。多一个「等 busy 起」看着冗余，但它让
//      「en 拉出去之后 busy 还没上来」这个窗口不会被误判成「发完了」。
//
// ⚠️ 字节在 txbuf 里是**右对齐**的（与 uart_line_rx / cmd_parse 同一套约定）：
//      第 i 个字节（i 从 0 起）在 txbuf[(len-1-i)*8 +: 8]，
//      也就是**最后一个字节永远在 [7:0]**。发的时候 idx 从 0 数到 len，
//      idx == len 那一拍发 LF，发完才算 done。
//
// 一处刻意的取舍：本模块**不判断**发完了要不要等一拍再收下一行 ——
// done 是 1 拍脉冲，调用方看到 done 后下一拍就可以再拉 start。
// ===========================================================================

// ⚠️ 端口名是 `txbuf` **不是** `buf` —— `buf` 是 Verilog 的保留字
//    （门级原语里的缓冲器），拿它当端口名 iverilog 直接报
//    「syntax error / Errors in port declarations」，而且报的行号是端口那一行，
//    一眼看不出是名字的问题。踩过一次，记这。

`timescale 1ns/1ps

module tx_line #(
    parameter integer MAXTX = 48        // 最长一行的字节数上限
)(
    input                     clk,
    input                     rst_n,

    input                     start,        // 1 拍脉冲：开始发 txbuf[0..len-1] + LF
    input      [MAXTX*8-1:0]  txbuf,        // 右对齐字节串（末字节在 [7:0]）
    input      [6:0]          len,          // 字节数（**不含**行尾 LF）

    output reg                tx_en,        // → uart_tx
    output reg [7:0]          tx_data,      // → uart_tx
    input                     busy,         // ← uart_tx_busy
    output reg                done          // 1 拍脉冲：整行（含 LF）发完
);

    localparam ST_IDLE = 2'd0,
               ST_LOW  = 2'd1,      // 等 busy 落，落了就拉 en
               ST_HIGH = 2'd2,      // 等 busy 起（确认 uart_tx 真的接手了）
               ST_FALL = 2'd3;      // 等 busy 落（本字节发完）

    reg [1:0]          st;
    reg [MAXTX*8-1:0]  b;           // 锁存的整行
    reg [6:0]          n;           // 锁存的长度
    reg [6:0]          idx;         // 0..n，idx==n 表示该发 LF 了

    // 当前该发的字节：idx < n 取 txbuf 里第 idx 个；idx == n 就是 LF
    wire [7:0] cur = (idx < n) ? b[(n-1-idx)*8 +: 8] : 8'h0A;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= ST_IDLE;
            b       <= {MAXTX*8{1'b0}};
            n       <= 7'd0;
            idx     <= 7'd0;
            tx_en   <= 1'b0;
            tx_data <= 8'h00;
            done    <= 1'b0;
        end
        else begin
            tx_en <= 1'b0;          // 脉冲输出默认拉低
            done  <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (start) begin
                        b   <= txbuf;
                        n   <= len;
                        idx <= 7'd0;
                        st  <= ST_LOW;
                    end
                end

                ST_LOW: begin
                    if (!busy) begin
                        tx_en   <= 1'b1;
                        tx_data <= cur;
                        st      <= ST_HIGH;
                    end
                end

                ST_HIGH: begin
                    if (busy) st <= ST_FALL;
                end

                ST_FALL: begin
                    if (!busy) begin
                        if (idx >= n) begin
                            // 刚发完的就是 LF（idx == n）→ 整行结束
                            st   <= ST_IDLE;
                            done <= 1'b1;
                        end
                        else begin
                            idx <= idx + 7'd1;
                            st  <= ST_LOW;
                        end
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
