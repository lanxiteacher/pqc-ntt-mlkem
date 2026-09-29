// leaf_elab_tb.v —— ntt_ BRAM / BROM 两片叶子的 elaboration 与内容抽查
//
// 编译（三档各一次）：
//   iverilog -g2005 -DCFG_PE_NUM=1  -DCFG_TW=9 -o /tmp/leaf1.vvp  rtl/probes/leaf_elab_tb.v rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leaf1.vvp
//   iverilog -g2005 -DCFG_PE_NUM=4  -DCFG_TW=8 -o /tmp/leaf4.vvp  rtl/probes/leaf_elab_tb.v rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leaf4.vvp
//   iverilog -g2005 -DCFG_PE_NUM=16 -DCFG_TW=7 -o /tmp/leaf16.vvp rtl/probes/leaf_elab_tb.v rtl/ntt_core/BRAM.v rtl/ntt_core/BROM.v && vvp /tmp/leaf16.vvp
//
// 验四件事：
//   1. TW_ADDR_W 与 PE_NUMBER 的搭配正确（手工选的 9/8/7，推不出公式 —— 设计文档 §3.3）
//   2. BROM 的三张表**读出来的是上游那张表**（内容逐档不同，是第三处真结构分歧）
//   3. BRAM 读写往返正确，且地址之间不互相串
//   4. 非退化：抽查到的系数里有足够多个不同的值（约定 4）
//
// ⚠️ 期望值全部手工抄自上游 rtl/pe{1,4,16}/BROM.v，不是本文件算出来的。

`timescale 1ns/1ps

module leaf_elab_tb;

    localparam integer PE = `CFG_PE_NUM;      // 1 / 4 / 16
    localparam integer TW = `CFG_TW;          // 9 / 8 / 7
    localparam integer L  = $clog2(128/PE);   // 7 / 5 / 3

    // TW_ADDR_W 的期望值 —— ⚠️ 故意写成查表，**不是**公式（设计文档 §3.3）
    localparam integer TW_EXPECT = (PE==1) ? 9 : (PE==4) ? 8 : (PE==16) ? 7 : -1;

    reg clk = 0;
    always #5 clk = ~clk;

    integer errors  = 0;
    integer fatal   = 0;
    integer nseen   = 0;
    integer i, j;
    reg [11:0] seen [0:127];

    // ------------------------------------------------------------------ BROM
    reg  [TW-1:0]    tw_addr = 0;
    wire [12*PE-1:0] tw_dout;
    ntt_BROM #(.PE_NUMBER(PE), .TW_ADDR_W(TW)) u_brom (
        .clk(clk), .raddr(tw_addr), .dout(tw_dout));

    // ------------------------------------------------------------------ BRAM
    reg         b_wen   = 0;
    reg  [L:0]  b_waddr = 0, b_raddr = 0;
    reg  [11:0] b_din   = 0;
    wire [11:0] b_dout;
    ntt_BRAM #(.ADDR_W(L+1)) u_bram (
        .clk(clk), .wen(b_wen), .waddr(b_waddr), .din(b_din),
        .raddr(b_raddr), .dout(b_dout));

    // ------------------------------------------------------------------ 记录见过的值
    task note;
        input [11:0] w;
        integer k;
        reg     hit;
        begin
            hit = 1'b0;
            for (k = 0; k < nseen; k = k + 1)
                if (seen[k] === w) hit = 1'b1;
            if (!hit) begin
                if (nseen < 128) seen[nseen] = w;
                nseen = nseen + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------ BROM 抽查
    // exp 用 192 位接，比较时只取低 12*PE 位 —— 三档共用同一个 task
    task chk_tw;
        input [8:0]   a;
        input [191:0] exp;
        begin
            tw_addr = a[TW-1:0];
            @(posedge clk); #1;
            for (j = 0; j < PE; j = j + 1) note(exp[12*j +: 12]);
            if (tw_dout !== exp[12*PE-1:0]) begin
                $display("  x BROM  addr=%0d  期望=%h  实得=%h", a, exp[12*PE-1:0], tw_dout);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------ BRAM 往返
    task bram_wr;
        input [8:0]  a;
        input [11:0] v;
        begin
            b_wen = 1'b1; b_waddr = a[L:0]; b_din = v;
            @(posedge clk); #1;
            b_wen = 1'b0;
        end
    endtask

    task bram_rd;
        input [8:0]  a;
        input [11:0] v;
        begin
            b_raddr = a[L:0];
            @(posedge clk); #1;
            if (b_dout !== v) begin
                $display("  x BRAM  addr=%0d  写=%h  读回=%h", a, v, b_dout);
                errors = errors + 1;
            end
        end
    endtask

    // ================================================================== 主流程
    initial begin
        // ---- 0. 非法 PE 的守卫（BROM 的 generate 没有 default 分支）----
        if (TW_EXPECT < 0) begin
            $display("FATAL: CFG_PE_NUM=%0d 不是 1/4/16 —— BROM 的 generate 没有 default，dout 会悬空", PE);
            fatal = 1;
        end
        // ---- 1. F1：TW_ADDR_W 与 PE_NUMBER 搭配 ----
        if (!fatal && TW != TW_EXPECT) begin
            $display("FAIL: PE_NUMBER=%0d 时 TW_ADDR_W 应为 %0d，实为 %0d —— c_tw/raddr_tw/BROM 会读飞", PE, TW_EXPECT, TW);
            errors = errors + 1;
        end

        if (!fatal) begin
            repeat (4) @(posedge clk);

            // ---- 2. BROM 表内容抽查（值抄自上游 rtl/pe*/BROM.v）----
            case (PE)
            1: begin
                chk_tw(9'd0,   192'h6c1);                        // 首条
                chk_tw(9'd100, 192'h9f5);
                chk_tw(9'd200, 192'h703);
                chk_tw(9'd300, 192'ha7f);
                chk_tw(9'd381, 192'h497);                        // 末条
            end
            4: begin
                chk_tw(8'd0,   192'h6c1_6c1_6c1_6c1);            // 首条（四个全同）
                chk_tw(8'd100, 192'h49b_49b_88a_88a);            // 同条内两两相同
                chk_tw(8'd150, 192'ha77_a77_a77_a77);
                chk_tw(8'd200, 192'h737_5ca_3b8_949);            // 四个互不相同
                chk_tw(8'd221, 192'h375_98c_86a_497);            // 末条
            end
            16: begin
                chk_tw(7'd0,   {16{12'h6c1}});                   // 首条（16 个全同）
                chk_tw(7'd40,  192'h98b_98b_22a_22a_49b_49b_88a_88a_8ff_8ff_b6e_b6e_8bd_8bd_20d_20d);
                chk_tw(7'd60,  {{8{12'hcc9}}, {8{12'h11b}}});    // 前 8 同、后 8 同
                chk_tw(7'd80,  192'h6a7_65a_673_68e_ae5_21c_6fd_604_737_5ca_3b8_949_5b5_74c_a7f_282);
                chk_tw(7'd85,  192'h6ba_647_4bc_845_752_5af_405_8fc_83e_4c3_b77_18a_375_98c_86a_497); // 末条
            end
            endcase

            // ---- 3. BRAM 往返 + 地址间不串扰 ----
            bram_wr(9'd0,        12'h123);
            bram_wr(9'd1,        12'habc);
            bram_wr(9'd0 + (1<<L) - 1, 12'h7ff);          // 最后一个地址
            bram_rd(9'd0,        12'h123);
            bram_rd(9'd1,        12'habc);
            bram_rd(9'd0 + (1<<L) - 1, 12'h7ff);
            note(12'h123); note(12'habc); note(12'h7ff);

            // ---- 4. 非退化（约定 4）----
            $display("PE=%0d  L=%0d  TW_ADDR_W=%0d  BRAM 深度=%0d  BROM 表宽=%0d 位",
                     PE, L, TW, 1<<(L+1), 12*PE);
            $display("抽查到的不同 12 位系数值：%0d 个", nseen);
            if (nseen < 8) begin
                $display("  x 非退化不成立：抽查值太集中，「全中」可能只是巧合");
                errors = errors + 1;
            end
        end

        if (fatal)                       $display("FATAL");
        else if (errors == 0)            $display("PASS: PE=%0d 叶子 elaboration + 内容抽查全部通过", PE);
        else                             $display("FAIL: PE=%0d 共 %0d 处不一致", PE, errors);
        $finish;
    end

endmodule
