// Parameterized FULL/HALF regression of the actual rtl/ntt_core top.
// Input/output timing follows rtl/H1_port_spec.md and ntt_func_tb.v.
// Python owns the independent C oracle and verdict; this bench only drives RTL.
`timescale 1ns/1ps
`ifndef CFG_PE_NUM
`define CFG_PE_NUM 1
`define MISSING_PE
`endif
`ifndef CFG_HALF
`define CFG_HALF 0
`endif

module polmul_param_tb;
localparam PE = `CFG_PE_NUM;
localparam HALF = `CFG_HALF;
localparam NV = 16;
localparam CAP_N = 320;
reg clk = 0;
always #5 clk = ~clk;
reg reset, load_a_f, load_a_i, load_b_f, load_b_i, read_a;
reg start_ab, start_fntt, start_pwm2, start_intt;
reg [11:0] din;
wire [11:0] dout;
wire done;
reg [11:0] va[0:4095], vb[0:4095];
reg [11:0] cap[0:CAP_N];
integer cyc, cap_base, i, v, m, idx, guard;
reg cap_en;

KyberHPMNTT_top #(.PE_NUMBER(PE)) dut (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(1'b0), .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(dout), .done(done)
);

always @(posedge clk) begin
    #1;
    if (!reset) begin
        cyc = cyc + 1;
        if (cap_en && cyc >= cap_base && cyc - cap_base <= CAP_N)
            cap[cyc - cap_base] = dout;
    end
end

task step;
    input integer n;
    integer t;
    begin for (t=0; t<n; t=t+1) @(negedge clk); end
endtask

task load_bank;
    input integer bank;
    integer interleave;
    begin
        // FULL A/B: natural via _f. HALF B: via _i, sigma only on pe1.
        interleave = bank && HALF && PE == 1;
`ifdef BAD_LOAD
        if (bank) interleave = !interleave;
`endif
        @(negedge clk);
        if (bank) begin
            if (HALF) load_b_i = 1; else load_b_f = 1;
        end else load_a_f = 1;
        @(negedge clk);
        load_a_f = 0; load_b_f = 0; load_b_i = 0;
        for (i=0; i<256; i=i+1) begin
            idx = i;
            if (interleave) begin
                case (i%4)
                    1: idx=i+1;
                    2: idx=i-1;
                endcase
            end
            din = bank ? vb[v*256+idx] : va[v*256+idx];
            @(negedge clk);
        end
        // Wait for the serialized load phase to finish on every build.
        step(257 + PE + 8);
    end
endtask

task run_op;
    input integer op;
    input integer bank;
    begin
        @(negedge clk);
        start_ab = bank;
        case (op)
            1: start_fntt = 1;
            2: start_pwm2 = 1;
            3: start_intt = 1;
        endcase
        @(negedge clk);
        start_ab=0; start_fntt=0; start_pwm2=0; start_intt=0;
        guard=0;
        while (done !== 1'b1 && guard < 4000) begin
            @(negedge clk);
            guard=guard+1;
        end
        if (guard >= 4000) $fatal(1, "done timeout group=%0d op=%0d", v, op);
        step(12);
    end
endtask

initial begin
`ifdef MISSING_PE
    $fatal(1, "CFG_PE_NUM is required (1, 4, 16)");
`endif
    if (PE != 1 && PE != 4 && PE != 16) $fatal(1, "invalid PE");
    $readmemh("in_a.txt", va);
    $readmemh("in_b.txt", vb);
    cyc=0; cap_en=0; cap_base=0;
    reset=1; load_a_f=0; load_a_i=0; load_b_f=0; load_b_i=0;
    read_a=0; din=0; start_ab=0; start_fntt=0; start_pwm2=0; start_intt=0;
    step(4); reset=0; step(2);
    for (v=0; v<NV; v=v+1) begin
        load_bank(0); load_bank(1);
        run_op(1, 0);
        if (!HALF) run_op(1, 1);
        run_op(2, 0); run_op(3, 0);
        @(negedge clk);
        read_a=1; cap_base=cyc; cap_en=1;
        @(negedge clk);
        read_a=0;
        step(CAP_N+4); cap_en=0;
        for (m=0; m<256; m=m+1)
            $display("DOUT %0d %0d %03x", v, m, cap[2*PE+3+m]);
        step(12);
    end
    $display("COMPLETE %0d %0d %0d", PE, HALF, NV);
    $finish;
end
endmodule
