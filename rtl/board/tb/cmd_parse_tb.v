// ===========================================================================
// cmd_parse_tb.v —— cmd_parse 的**自检**测试台
//
// ⚠️ 本文件由 gen_cmd_parse_tb.py **机器生成**，不要手改 ——
//    改了下次重跑生成器就没了。要加用例请改生成器。
//
// 为什么非要这个测试台：
//    cmd_parse.v 里 20 多个十六进制常量全是手写的，一个 nibble 写错不会有任何
//    编译错误，只会在上板后表现成「某条命令莫名其妙不响应」。而这类错误用
//    仿真跑到完整协议 FSM 里再查，代价极高。
//    这里把常量单独拉出来验一遍：七条正常命令 + 十二种异常。
//
// 怎么跑：
//    export PATH="/c/iverilog/bin:$PATH"
//    cd rtl/board/tb
//    iverilog -g2005 -o chk.vvp ../cmd_parse.v cmd_parse_tb.v && vvp chk.vvp
//    末行出现 ALL PASS 即通过；有任何 FAIL 会逐条打印期望值与实际值。
//
// 覆盖了什么 / 没覆盖什么：
//    覆盖 —— 七条命令的识别、四种校验失败、未知命令、参数非法、
//            以及「校验和命令识别是两件独立的事」这一格。
//    没覆盖 —— 多位数的 n（见 cmd_parse.v 头部「已知简化」；§六第 2 条已把
//            n 冻结为 1，这条分支实际不可达）。真长度超过 64 字节的行也不归这里，
//            那是 uart_line_rx 的事。
// ===========================================================================

`timescale 1ns/1ps

module cmd_parse_tb;

    reg  [511:0] line;
    reg  [6:0]   line_len;

    wire [2:0]   cmd;
    wire [1:0]   dom;
    wire [9:0]   exp_lines;
    wire         cksum_ok;
    wire         n_ok;
    wire [6:0]   payload_len;
    wire [7:0]   ck_got;
    wire [7:0]   ck_exp;

    cmd_parse #(.MAXLEN(64)) dut (
        .line        (line),
        .line_len    (line_len),
        .cmd         (cmd),
        .dom         (dom),
        .exp_lines   (exp_lines),
        .cksum_ok    (cksum_ok),
        .n_ok        (n_ok),
        .payload_len (payload_len),
        .ck_got      (ck_got),
        .ck_exp      (ck_exp)
    );

    localparam CMD_NONE  = 3'd0, CMD_PING = 3'd1, CMD_NTT = 3'd2,
               CMD_INTT  = 3'd3, CMD_PMUL = 3'd4, CMD_ABORT = 3'd5;
    localparam DOM_NONE  = 2'd0, DOM_NTT = 2'd1, DOM_TIME = 2'd2, DOM_FULL = 2'd3;

    integer fails = 0;
    integer cases = 0;

    // 一个用例：灌一行，比对六个输出
    task chk;
        input [511:0] l;
        input [6:0]   len;
        input [2:0]   ecmd;
        input [1:0]   edom;
        input [9:0]   eln;          // 期望的 exp_lines（输入数据行数）
        input         ecs;
        input         enok;
        input [7:0]   egot;         // 期望的 ck_got
        input [7:0]   eck;          // 期望的 ck_exp
        input [255:0] nm;
        begin
            line = l;
            line_len = len;
            #1;
            cases = cases + 1;
            if (cmd !== ecmd || dom !== edom || exp_lines !== eln ||
                cksum_ok !== ecs || n_ok !== enok ||
                ck_got !== egot || ck_exp !== eck ||
                payload_len !== (len >= 7'd3 ? len - 7'd3 : 7'd0)) begin
                fails = fails + 1;
                $display("FAIL  %0s", nm);
                $display("      cmd=%0d(exp %0d)  dom=%0d(exp %0d)  exp_lines=%0d(exp %0d)",
                         cmd, ecmd, dom, edom, exp_lines, eln);
                $display("      cksum_ok=%0d(exp %0d)  n_ok=%0d(exp %0d)  payload_len=%0d(exp %0d)",
                         cksum_ok, ecs, n_ok, enok, payload_len,
                         (len >= 7'd3 ? len - 7'd3 : 7'd0));
                $display("      ck_got=%02h(exp %02h)  ck_exp=%02h(exp %02h)",
                         ck_got, egot, ck_exp, eck);
            end
            else begin
                $display("ok    %0s", nm);
            end
        end
    endtask

    initial begin
        $display("=== cmd_parse 自检：%0d 个用例 ===", 20);
        // PING  无数据行
        chk(512'h2350494e472a3333, 7'd8, CMD_PING, DOM_NONE, 10'd0, 1'b1, 1'b1, 8'h33, 8'h33, "PING  ");

        // FNTT  256 行
        chk(512'h234e545420312a3763, 7'd9, CMD_NTT, DOM_NONE, 10'd256, 1'b1, 1'b1, 8'h7c, 8'h7c, "FNTT  256 ");

        // INTT  256 行
        chk(512'h23494e545420312a3335, 7'd10, CMD_INTT, DOM_NONE, 10'd256, 1'b1, 1'b1, 8'h35, 8'h35, "INTT  256 ");

        // 点乘 NTT  域 512 行
        chk(512'h23504d554c204e545420312a3538, 7'd14, CMD_PMUL, DOM_NTT, 10'd512, 1'b1, 1'b1, 8'h58, 8'h58, " NTT   512 ");

        // 点乘 TIME 域 512 行
        chk(512'h23504d554c2054494d4520312a3033, 7'd15, CMD_PMUL, DOM_TIME, 10'd512, 1'b1, 1'b1, 8'h03, 8'h03, " TIME  512 ");

        // 点乘 FULL 域（协议表缺这条，本脚本算出）
        chk(512'h23504d554c2046554c4c20312a3035, 7'd15, CMD_PMUL, DOM_FULL, 10'd512, 1'b1, 1'b1, 8'h05, 8'h05, " FULL ()");

        // ABORT 无数据行
        chk(512'h2341424f52542a3639, 7'd9, CMD_ABORT, DOM_NONE, 10'd0, 1'b1, 1'b1, 8'h69, 8'h69, "ABORT ");

        // 校验值错一位(*7c→*7d)
        chk(512'h234e545420312a3764, 7'd9, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h7d, 8'h7c, "(*7c->*7d)");

        // 校验值大写(*7C)——协议只认小写
        chk(512'h234e545420312a3743, 7'd9, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h7c, 8'h7c, "(*7C)");

        // 分隔符不是 *（写成 @）
        chk(512'h234e54542031403763, 7'd9, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h7c, 8'h7c, " *( @)");

        // 校验只有一位(*7)——长度对不上
        chk(512'h234e545420312a37, 7'd8, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h07, 8'h4d, "(*7)");

        // 未知命令，但校验是对的 → #ERR 01
        chk(512'h23464f4f20312a3734, 7'd9, CMD_NONE, DOM_NONE, 10'd0, 1'b1, 1'b0, 8'h74, 8'h74, " -> #ERR 01");

        // n=2   → 命令认得，参数非法
        chk(512'h234e545420322a3766, 7'd9, CMD_NTT, DOM_NONE, 10'd256, 1'b1, 1'b0, 8'h7f, 8'h7f, "n=2   -> ");

        // n=0   → 同上
        chk(512'h234e545420302a3764, 7'd9, CMD_NTT, DOM_NONE, 10'd256, 1'b1, 1'b0, 8'h7d, 8'h7d, "n=0   -> ");

        // INTT n=2
        chk(512'h23494e545420322a3336, 7'd10, CMD_INTT, DOM_NONE, 10'd256, 1'b1, 1'b0, 8'h36, 8'h36, "INTT n=2");

        // 点乘 NTT 域 n=2
        chk(512'h23504d554c204e545420322a3562, 7'd14, CMD_PMUL, DOM_NTT, 10'd512, 1'b1, 1'b0, 8'h5b, 8'h5b, " NTT  n=2");

        // 点乘 TIME 域 n=2
        chk(512'h23504d554c2054494d4520322a3030, 7'd15, CMD_PMUL, DOM_TIME, 10'd512, 1'b1, 1'b0, 8'h00, 8'h00, " TIME  n=2");

        // 域词 XXX 不认识 → #ERR 02（不是 01）
        chk(512'h23504d554c2058585820312a3465, 7'd14, CMD_PMUL, DOM_NONE, 10'd512, 1'b1, 1'b0, 8'h4e, 8'h4e, " XXX  -> #ERR 02( 01)");

        // 只有一个 #
        chk(512'h23, 7'd1, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h00, 8'h00, " #");

        // 空行
        chk(512'h0, 7'd0, CMD_NONE, DOM_NONE, 10'd0, 1'b0, 1'b0, 8'h00, 8'h00, "");


        $display("--------------------------------------------");
        if (fails == 0) $display("ALL PASS  (%0d/%0d)", cases, cases);
        else            $display("*** FAIL ***  %0d / %0d", fails, cases);
        $finish;
    end

endmodule
