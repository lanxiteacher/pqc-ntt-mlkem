// ===========================================================================
// ag_equiv_tb.v —— ntt_addressgenerator 与上游原版的**逐拍等价探针**
//
// 同一份激励同时喂给两个地址生成器，每个时钟沿比对**全部**输出。
// 判据：全 0 处不符，三档都 PASS。
//
// 用法（从仓库根目录）：
//   iverilog -g2005 -DCFG_L=7 -DHAS_PE1_PORTS -o w.vvp \
//       rtl/probes/ag_equiv_tb.v rtl/pe1/addressgenerator.v rtl/pe1/shiftreg.v \
//       rtl/ntt_core/addressgenerator.v rtl/ntt_core/shiftreg.v
//   vvp w.vvp
//   （pe4 用 -DCFG_L=5、pe16 用 -DCFG_L=3，**都不要** -DHAS_PE1_PORTS）
//
// 为什么两个 tree 能同时编进来：新树的模块叫 ntt_addressgenerator，叶子叫
// ntt_shiftreg，**不和上游同名** —— iverilog 没有 namespace，同名必撞。
// 这个探针本身就是「ntt_ 前缀」这条约束的活证明。
//
// 说明：
// - 上游 `ct`/`pwm` 是 output reg，**不是**输入。别把它们接常数。
// - pe1 的 AG 多两个输出 c_loop_pwm / raddr_b —— 旧那侧的例化要开
//   -DHAS_PE1_PORTS 才连得上；pe4/pe16 没这两个脚，带宏反而报错。
// - 激励在 negedge 变、比较在 posedge+1 采，避免竞争。
// ===========================================================================

`timescale 1ns/1ps

module ag_equiv_tb;

`ifndef CFG_L
    `define CFG_L 7
    `define CFG_L_MISSING
`endif

localparam integer L         = `CFG_L;
localparam integer TW_ADDR_W = (L == 7) ? 9 : (L == 5) ? 8 : (L == 3) ? 7 : 9;

// 每段给的宽裕拍数（远大于三档的实际周期数，见 rtl/probes/README.md）
localparam integer PAD_FNTT = 1400;
localparam integer PAD_PWM2 = 1000;
localparam integer PAD_INTT = 1400;

// --------------------------------------------------------------------- 激励
reg clk, reset;
reg start_fntt, start_pwm2, start_intt;

initial clk = 1'b0;
always #5 clk = ~clk;

// --------------------------------------------------------------------- 旧：上游原版
wire        o_ct, o_pwm;
wire [L:0]  o_raddr0, o_raddr1, o_waddr0, o_waddr1;
wire        o_wen0, o_wen1, o_brsel0, o_brsel1, o_brselen0, o_brselen1;
wire [2:0]  o_sc, o_scp;
wire [TW_ADDR_W-1:0] o_tw;
`ifdef HAS_PE1_PORTS
wire [L-1:0] o_clp, o_rb;
`endif

addressgenerator old (
    .clk(clk), .reset(reset),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .ct(o_ct), .pwm(o_pwm),
    .raddr0(o_raddr0), .raddr1(o_raddr1),
    .waddr0(o_waddr0), .waddr1(o_waddr1),
    .wen0(o_wen0),     .wen1(o_wen1),
    .brsel0(o_brsel0), .brsel1(o_brsel1),
    .brselen0(o_brselen0), .brselen1(o_brselen1),
    .stage_count(o_sc), .stage_count_pwm(o_scp),
`ifdef HAS_PE1_PORTS
    .c_loop_pwm(o_clp), .raddr_b(o_rb),
`endif
    .raddr_tw(o_tw)
);

// --------------------------------------------------------------------- 新：参数化版
wire        n_ct, n_pwm;
wire [L:0]  n_raddr0, n_raddr1, n_waddr0, n_waddr1;
wire        n_wen0, n_wen1, n_brsel0, n_brsel1, n_brselen0, n_brselen1;
wire [2:0]  n_sc, n_scp;
wire [TW_ADDR_W-1:0] n_tw;
wire [L-1:0] n_clp, n_rb;

ntt_addressgenerator #(.L(L), .TW_ADDR_W(TW_ADDR_W)) new (
    .clk(clk), .reset(reset),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .ct(n_ct), .pwm(n_pwm),
    .raddr0(n_raddr0), .raddr1(n_raddr1),
    .waddr0(n_waddr0), .waddr1(n_waddr1),
    .wen0(n_wen0),     .wen1(n_wen1),
    .brsel0(n_brsel0), .brsel1(n_brsel1),
    .brselen0(n_brselen0), .brselen1(n_brselen1),
    .stage_count(n_sc), .stage_count_pwm(n_scp),
    .c_loop_pwm(n_clp), .raddr_b(n_rb),
    .raddr_tw(n_tw)
);

// --------------------------------------------------------------------- 比对
integer ncyc, nerr, phase_busy, phase_n, total_busy;
reg     in_phase;

`define CHK(nm, a, b)                                                      \
    if ((a) !== (b)) begin                                                 \
        nerr = nerr + 1;                                                   \
        if (nerr <= 15)                                                    \
            $display("MISMATCH @cyc %0d phase %0d  %s  old=%h new=%h",     \
                     ncyc, phase_n, nm, a, b);                             \
    end

always @(posedge clk) begin
    #1;                                  // 等非阻塞赋值落定
    if (!reset) begin
        ncyc = ncyc + 1;
        if (in_phase) begin
            // ⚠️ 「在干活」**不能**用 ct 判：上游 IDLE 那一支是 `b_ct <= b_ct;`
            //    （保持），所以 ct 一旦被 FNTT 拉高就再也不下来，整段 pad 全是高。
            //    用 wen/brselen/pwm —— 这三路在 IDLE 都会被清 0。
            if (n_pwm | n_wen0 | n_wen1 | n_brselen0 | n_brselen1) begin
                phase_busy = phase_busy + 1;
                total_busy = total_busy + 1;
            end
        end

        `CHK("ct",            o_ct   , n_ct   )
        `CHK("pwm",           o_pwm  , n_pwm  )
        `CHK("raddr0",        o_raddr0, n_raddr0)
        `CHK("raddr1",        o_raddr1, n_raddr1)
        `CHK("waddr0",        o_waddr0, n_waddr0)
        `CHK("waddr1",        o_waddr1, n_waddr1)
        `CHK("wen0",          o_wen0 , n_wen0 )
        `CHK("wen1",          o_wen1 , n_wen1 )
        `CHK("brsel0",        o_brsel0, n_brsel0)
        `CHK("brsel1",        o_brsel1, n_brsel1)
        `CHK("brselen0",      o_brselen0, n_brselen0)
        `CHK("brselen1",      o_brselen1, n_brselen1)
        `CHK("stage_count",   o_sc   , n_sc   )
        `CHK("stage_count_pwm", o_scp , n_scp  )
        `CHK("raddr_tw",      o_tw   , n_tw   )
`ifdef HAS_PE1_PORTS
        `CHK("c_loop_pwm",    o_clp  , n_clp  )
        `CHK("raddr_b",       o_rb   , n_rb   )
`endif
    end
end

// --------------------------------------------------------------------- 跑法
task run_phase;
    input integer which;    // 0=FNTT 1=PWM2 2=INTT
    input integer pad;
    integer i;
    begin
        phase_n    = which;
        phase_busy = 0;
        in_phase   = 1'b1;

        @(negedge clk);
        if (which == 0) start_fntt = 1'b1;
        if (which == 1) start_pwm2 = 1'b1;
        if (which == 2) start_intt = 1'b1;
        @(negedge clk);
        start_fntt = 1'b0; start_pwm2 = 1'b0; start_intt = 1'b0;

        for (i = 0; i < pad; i = i + 1) @(negedge clk);

        in_phase = 1'b0;
        if (phase_busy >= pad)
            $display("PHASE %0d busy=%0d (== pad，拍数被截断，请调大 PAD)", which, phase_busy);
        else
            $display("PHASE %0d busy=%0d", which, phase_busy);
    end
endtask

integer i;

initial begin
    ncyc = 0; nerr = 0; phase_busy = 0; phase_n = -1; total_busy = 0; in_phase = 0;
    reset = 1'b1; start_fntt = 0; start_pwm2 = 0; start_intt = 0;

`ifdef CFG_L_MISSING
    $display("FATAL 没给 CFG_L —— 用法：-DCFG_L=7|5|3");
    $finish;
`endif
    if ((L != 7) && (L != 5) && (L != 3)) begin
        $display("FATAL L=%0d 非法 —— 只支持 7(pe1) / 5(pe4) / 3(pe16)。", L);
        $display("      非法 L 会落进 pe16 那个 else 分支，得到一份能编过但行为错的电路。");
        $finish;
    end
`ifdef HAS_PE1_PORTS
    // 一般到不了这里：pe4/pe16 带了这个宏时，iverilog 会在 elaborate 阶段先报
    // 「port ``c_loop_pwm'' is not a port of old」，比这条更直白。留着是给
    // 将来换仿真器时兜底。
    if (L != 7) begin
        $display("FATAL 带了 -DHAS_PE1_PORTS 但 L=%0d —— 只有 pe1(L=7) 有 c_loop_pwm/raddr_b 两个脚。", L);
        $finish;
    end
`else
    if (L == 7) begin
        $display("FATAL L=7 必须带 -DHAS_PE1_PORTS —— pe1 的 AG 多两个输出，旧侧例化会缺端口。");
        $finish;
    end
`endif

    $display("CFG L=%0d TW_ADDR_W=%0d", L, TW_ADDR_W);

    repeat (4) @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);

    run_phase(0, PAD_FNTT);
    run_phase(1, PAD_PWM2);
    run_phase(2, PAD_INTT);

    $display("CYCLES %0d  busy_total=%0d", ncyc, total_busy);
    if (nerr == 0)
        $display("PASS 逐拍等价：%0d 拍、18 路输出全部一致", ncyc);
    else
        $display("FAIL 逐拍等价：%0d 拍里有 %0d 处不符", ncyc, nerr);
    $finish;
end

endmodule
