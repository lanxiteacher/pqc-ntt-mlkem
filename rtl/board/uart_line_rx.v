// ===========================================================================
// uart_line_rx.v —— 字节流 → 整行
//
// 依据：host/proto.md §5.1（行的身份由第一个字符决定，行与行只靠 LF 分隔）
//       与 §5.5「边界情况怎么判」那张表。
//
// 干四件事：
//   1. 把 uart_rx 一个字节一个字节吐出来的东西，攒成一整行
//   2. LF = 行结束；空行（只有 LF）**忽略**（这样传送末尾多一个 LF 不会致命）
//   3. CR **丢弃且不计数** —— §5.5 写死：「长度怎么数，必须写死：`\r` 在计数之前
//      就被丢掉 —— 即 `044\r\n` 算 **3 字节**（合规），不是 4 字节（越界）」。
//      不定这条，串口助手不小心发了 CRLF 就会被误判成 #ERR 04。
//   4. 超长检测：命令行 64 字节、数据行 3 字节（由 max_bytes 输入切换）
//
// ★ 行的存放方式（本仓库统一，与 hex3.v 的约定一致）：
//      `line` 是 MAXLEN*8 位，**右对齐** —— 末字符永远在 line[7:0]。
//      所以「从行首数第 i 个字符」在 line[(line_len-1-i)*8 +: 8]。
//      右对齐的好处：行**尾**的位置是固定的，剥 `*xx` 只需 `line >> 24`（见 cmd_parse）。
//
// ⚠️ 为什么用 acc / line 两个寄存器（而不是一个）：
//      数据段一次来 256 行，每行只隔 347 µs ≈ 17,350 拍。fsm 收到 line_valid
//      后要把 line / line_len 采到自己的寄存器里再慢慢处理。如果 `line` 只有一份，
//      下一行的 LF 一到就把它覆盖了 —— 虽然实际上来得及，但这是在赌时序。
//      两份寄存器把「正在收的」和「已完成的」分开，fsm 读 line 期间 acc 照收不误。
//
// ⚠️ clr 的语义 = **丢弃当前半行，等下一个 LF 重新同步**（不是立即清空后马上
//    重新开始收）。协议 §5.5 关键规则一：超时后必须回到「找行首」状态。
//    如果只清缓冲而不等 LF，那半行的剩余字符会被当成新行的开头 —— 从此全线错位。
// ===========================================================================

`timescale 1ns/1ps

module uart_line_rx #(
    parameter integer MAXLEN = 64       // 行缓冲最大字节数 = 命令行的上限（§5.5）
)(
    input                     clk,
    input                     rst_n,        // 低有效（与 uart_rx 同规矩）
    input                     clr,          // 1 拍脉冲：丢弃当前半行，**下一个字节就重开一行**

    input      [7:0]          rx_data,      // 来自 uart_rx
    input                     rx_done,      // 1 拍脉冲：收到一个字节
    input      [7:0]          max_bytes,    // 本状态允许的最大字节数（命令行 64 / 数据段 3）

    output reg [MAXLEN*8-1:0] line,         // 已完成的整行，右对齐（末字符在 [7:0]）
    output reg [6:0]          line_len,     // 该行字节数（不含 LF / CR）
    output reg                line_valid,   // 1 拍脉冲：收到一整行（非空）
    output reg                line_over     // 1 拍脉冲：本行超长，已丢弃
);

    // 正在累积的那一行
    reg [MAXLEN*8-1:0] acc;
    reg [6:0]          acc_len;
    reg                drop;        // 本行已判超长，后续字节一律丢到 LF 为止

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= {MAXLEN*8{1'b0}};
            acc_len   <= 7'd0;
            drop      <= 1'b0;
            line      <= {MAXLEN*8{1'b0}};
            line_len  <= 7'd0;
            line_valid<= 1'b0;
            line_over <= 1'b0;
        end
        else begin
            // 脉冲输出默认拉低
            line_valid <= 1'b0;
            line_over  <= 1'b0;

            if (clr) begin
                // ---- 硬清：丢掉这半行，**下一拍就重新开始算一行** ----
                //
                // ⚠️ 这里**不能**写 `drop <= 1'b1`（丢到 LF 为止）。
                //    drop 只在 LF 分支清 0，而 clr 的触发场景恰恰是「本行的 LF 不会来了」：
                //    协议机的两个 clr 调用点**都是超时**（proto_fsm.v 里 S_IDLE 的 T_CMD
                //    超时、S_DATA 的 T_LINE 超时），超时意味着电脑那一侧也已经放弃了这一行，
                //    行尾的 LF 永远不会到。此时置 drop=1 等于挂起一个永远等不到的 LF，
                //    把**下一条完整命令行**整条吞掉 —— 板子完全不出声。
                //
                //    后果正好踩中 §5.5「关键规则一」：超时后必须回到「等命令行」。
                //    电脑按「关键规则二」超时后会先发 `#ABORT*69`，而这条 ABORT 会被吞，
                //    于是整轮测试卡死在原地。现象是「板子一开始还好好的，超时一次之后
                //    就再也不回话了」—— 第一反应会去怀疑电脑侧或串口线，实际在这儿。
                //    （2026-10-04 由 tb/uart_proto_tb.v 用例 T7 抓出。）
                //
                //    硬清之后最坏情况只是：万一残行的尾巴恰好在途，会被累积成一条乱码行，
                //    协议机按未知命令/校验和错驳回（`#ERR 01` / `#ERR 03`）——**有回话**；
                //    而 drop=1 是**没回话**。有回话的错态永远优于没回话的死态。
                acc     <= {MAXLEN*8{1'b0}};
                acc_len <= 7'd0;
                drop    <= 1'b0;
            end
            else if (rx_done) begin
                if (rx_data == 8'h0D) begin
                    // ---- CR：丢弃，**不计数**（§5.5）----
                end
                else if (rx_data == 8'h0A) begin
                    // ---- LF：行结束 ----
                    if (!drop && acc_len > 0) begin
                        line      <= acc;
                        line_len  <= acc_len;
                        line_valid<= 1'b1;
                    end
                    // 空行（acc_len == 0）**忽略**：不置 valid
                    // drop 行也不置 valid
                    acc     <= {MAXLEN*8{1'b0}};
                    acc_len <= 7'd0;
                    drop    <= 1'b0;
                end
                else if (drop) begin
                    // 已在丢弃中，继续丢
                end
                else if (acc_len >= max_bytes) begin
                    // ---- 超长：本行判废（§5.5 边界表）----
                    line_over <= 1'b1;
                    drop      <= 1'b1;
                    acc       <= {MAXLEN*8{1'b0}};
                    acc_len   <= 7'd0;
                end
                else begin
                    acc     <= { acc[MAXLEN*8-9:0], rx_data };
                    acc_len <= acc_len + 7'd1;
                end
            end
        end
    end

endmodule
