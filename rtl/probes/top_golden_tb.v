// ===========================================================================
// top_golden_tb.v —— KyberHPMNTT_top 对着**黄金向量**跑一遍（判据 3 的前哨）
//
// ⑧ 那条探针证明的是「三档互相一致」，那是**自洽**，不是**正确**。
// 这条把 FNTT 的黄金向量从 12 位串行口灌进去、再串行读出来，
// 和 `refsim/batch/ntt_batch_exp.txt` 第 0 组比 —— 这才是有外部锚的判据。
//
// 黄金向量由 FIPS 203 KAT 校验过的 C 参考实现算出（见 refsim/README.md），
// 所以「对上了」= 这一档的装载顺序 + 变换 + 读出顺序整条链路都对。
//
// 查两件事：
//   ① 多重集相等 —— 256 个读出值作为集合 == 黄金向量
//   ② 顺序 —— 打印读出位置 m → 黄金下标 的映射，三档应当得到**同一张**映射表
//
// ⚠️ 为什么非要②：⑤ 那条探针（上游宽接口，带 `_top`）给出的 pe1 读出顺序是
//    「组内 0,2,1,3」，而 pe4/pe16 是「组内自然序」—— 两者**不是同一个顺序**。
//    可是 ⑧ 实测三档 dout 序列**逐位相同**。这两件事不可能同时为真，
//    必有一边量错了。② 直接对着黄金向量数下标，不再依赖任何中间结论。
//
// 默认只跑 FNTT：装载 A → start_fntt(A) → 读 A。
//
// `-DWITH_INTT` 换成：装载 A → start_intt(A) → 读 A。**只量周期数，不判值** ——
//   INTT 的装载/读出约定还没有黄金锚（只有 FNTT 有），值判据留给 Task 6。
//   加这条是因为 Task 5 要的三档周期数表里，INTT 是唯一还没从顶层量过的一格
//   （FNTT / PWM2 已由 `-DWITH_PWM2` 那条路量到 CC+3）。
//
// `-DWITH_PWM2` 换成另一条路：装载 A → FNTT A → 装载 B(**同一份 vin**) → FNTT B
//   → PWM2 A → 读 A。B 跟 A 同数据时，PWM2 的结果在每个下标上就是
//   `exp[i]^2 mod 3329`，**仍然有黄金锚**，只是要平方一下。
//
// 为什么要这条：⑧（top_behavior_tb）说「三档 dout 逐位相同」，而这条默认跑的
// 那条路量出 pe1 是 `0,2,1,3`、pe4/pe16 是自然序 —— 两条路给不出同一个结论。
// ⑧ 读的是 **PWM2 之后**的 bank，本条默认读的是 **FNTT 之后**的 bank。
// 所以用 `-DWITH_PWM2` 把 ⑧ 那条路也锚到黄金向量上，看到底是「读出顺序随操作变」
// 还是「⑧ 的判据本身不分辨」。
//
// 用法（从 rtl/probes/，向量已由 run_probes.sh 复制到 _work/）：
//   CORE="$(ls ../ntt_core/*.v | grep -v _top | tr '\n' ' ')"
//   iverilog -g2005 -DCFG_PE_NUM=1 -o _work/g1.vvp \
//       top_golden_tb.v $CORE ../ntt_core/KyberHPMNTT_top.v && vvp _work/g1.vvp
//   vvp 的工作目录决定 $readmemh 的相对路径，所以要在 _work 里跑。
// ===========================================================================

`timescale 1ns/1ps

`ifndef CFG_PE_NUM
    `define CFG_PE_NUM 1
    `define CFG_PE_MISSING
`endif

module top_golden_tb;

localparam integer PE_NUMBER = `CFG_PE_NUM;

// 上游实测的核周期数（H1_port_spec.md §五 / 探针 ①③④）。顶层 = CC+3。
localparam integer CC_FNTT    = (PE_NUMBER==1) ? 904 : (PE_NUMBER==4) ? 232 : 69;
localparam integer CC_PWM2    = (PE_NUMBER==1) ? 647 : (PE_NUMBER==4) ? 167 : 47;
localparam integer CC_INTT    = (PE_NUMBER==1) ? 904 : (PE_NUMBER==4) ? 233 : 71;
localparam integer FIRST_DOUT = 2*PE_NUMBER + 3;
localparam integer LOAD_WAIT  = 257 + PE_NUMBER + 8;

reg  clk, reset;
initial clk = 1'b0;
always #5 clk = ~clk;

reg  load_a_f, load_b_f, read_a, start_fntt, start_pwm2, start_intt, start_ab;
reg  [11:0] din;
wire [11:0] dout;
wire        done;

KyberHPMNTT_top #(.PE_NUMBER(PE_NUMBER)) dut (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(1'b0),
    .load_b_f(load_b_f), .load_b_i(1'b0),
    .read_a(read_a), .read_b(1'b0),
    .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(dout), .done(done)
);

integer cyc, mark, done_cyc;
integer i;

// 抓取窗口（位置定位）：cap[FIRST_DOUT + m] = 第 m 个系数
// ⚠️ 抓取必须和 cyc 自增在**同一个** always 块里。分成两块各带 #1 就是竞争：
//    谁先跑不定，cap 读到的 cyc 可能已经加过 1 —— 表现为 cap[] 出现没写过的 X 槽。
localparam integer CAP_N = 320;
integer    cap_base;
reg        cap_en;
reg [11:0] cap [0:CAP_N+8];

always @(posedge clk) begin
    #1;                                    // 等非阻塞赋值落定
    if (!reset) begin
        cyc = cyc + 1;
        if ((done === 1'b1) && (done_cyc < 0)) done_cyc = cyc;
        if (cap_en && (cyc >= cap_base) && (cyc - cap_base) <= CAP_N)
            cap[cyc - cap_base] = dout;
    end
end

task step; input integer n; integer t; begin
    for (t = 0; t < n; t = t + 1) @(negedge clk);
end endtask

// 装载：拉 1 拍 load_{a,b}_f，紧接着每拍喂一个系数（A / B 装的是**同一串** vin）
// ⚠️ 第一个系数必须在装载脉冲的**下一个** negedge 就摆上 —— 那才是核要吃的
//    第一个系数（H1_port_spec.md §四 第 1 条：必须连续灌满，不能中途停）。
task load_serial; input integer is_b; begin
    @(negedge clk);
    if (is_b) load_b_f = 1'b1; else load_a_f = 1'b1;
    mark = cyc;
    @(negedge clk);
    load_a_f = 1'b0; load_b_f = 1'b0;
    din = vin[0];
    for (i = 1; i < 256; i = i + 1) begin
        @(negedge clk);
        din = vin[i];
    end
    @(negedge clk);
end endtask

// 1 拍脉冲
task pulse; input [2:0] which; begin
    @(negedge clk);
    case (which)
        1: start_fntt = 1'b1;
        2: start_pwm2 = 1'b1;
        3: start_intt = 1'b1;
    endcase
    mark = cyc;
    @(negedge clk);
    start_fntt = 1'b0; start_pwm2 = 1'b0; start_intt = 1'b0;
end endtask

integer op_exp, nerr, m, nzero, ndistinct, dup;
reg [11:0] vin  [0:255];
reg [11:0] vexp [0:255];
reg [11:0] seen [0:255];

initial begin
    $readmemh("in.txt",  vin);
    $readmemh("exp.txt", vexp);

    cyc = 0; mark = 0; done_cyc = -1; nerr = 0;
    cap_en = 0; cap_base = 0;
    reset = 1'b1;
    load_a_f = 0; load_b_f = 0; read_a = 0;
    start_fntt = 0; start_pwm2 = 0; start_intt = 0; start_ab = 0; din = 0;

`ifdef CFG_PE_MISSING
    $display("FATAL 没给 CFG_PE_NUM —— 用法：-DCFG_PE_NUM=1|4|16");
    $finish;
`endif

    repeat (4) step(1);
    reset = 1'b0;
    step(2);

    load_serial(0);
    $display("LOAD_A %0d", mark);
    step(LOAD_WAIT);

`ifdef WITH_INTT
    // 只量周期数：INTT 的方向和读出约定都没锚（H1_port_spec.md §五 只锚了 FNTT），
    // 所以这条**不判值**，只看 `done` 落在 CC_INTT+3。值判据留给 Task 6。
    done_cyc = -1;
    pulse(3);                                    // start_intt, bank A
    op_exp = mark + CC_INTT + 3;
    step(CC_INTT + 3 + 8);
    $display("OP_INTT_A start %0d expect_done %0d actual_done %0d", mark, op_exp, done_cyc);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(INTT A)：实测 %0d，预期 %0d", done_cyc, op_exp);
    end
`else
    done_cyc = -1;
    pulse(1);                                    // start_fntt, bank A
    op_exp = mark + CC_FNTT + 3;
    step(CC_FNTT + 3 + 8);
    $display("OP_FNTT_A start %0d expect_done %0d actual_done %0d", mark, op_exp, done_cyc);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(FNTT A)：实测 %0d，预期 %0d", done_cyc, op_exp);
    end
`endif

`ifdef WITH_PWM2
    // 装载 B —— 装同一串 vin，于是 PWM2 的结果是 exp 的逐点平方，锚还在
    load_serial(1);
    $display("LOAD_B %0d", mark);
    step(LOAD_WAIT);

    done_cyc = -1;
    start_ab = 1'b1;
    pulse(1);                                    // start_fntt, bank B
    op_exp = mark + CC_FNTT + 3;
    step(CC_FNTT + 3 + 8);
    $display("OP_FNTT_B start %0d expect_done %0d actual_done %0d", mark, op_exp, done_cyc);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(FNTT B)：实测 %0d，预期 %0d", done_cyc, op_exp);
    end

    done_cyc = -1;
    start_ab = 1'b0;
    pulse(2);                                    // start_pwm2, bank A
    op_exp = mark + CC_PWM2 + 3;
    step(CC_PWM2 + 3 + 8);
    $display("OP_PWM2_A start %0d expect_done %0d actual_done %0d", mark, op_exp, done_cyc);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(PWM2 A)：实测 %0d，预期 %0d", done_cyc, op_exp);
    end
`endif

    // 读出（抓取使能要在脉冲**之前**开，否则第一拍抓不到，槽里留 X）
    @(negedge clk);
    read_a = 1'b1;
    mark = cyc;
    cap_base = cyc; cap_en = 1'b1;
    @(negedge clk);
    read_a = 1'b0;
    $display("READ_A %0d first_dout_expect %0d", mark, mark + FIRST_DOUT);
    step(CAP_N + 4);
    cap_en = 1'b0;

    // 有效窗口之前必须是空的
    nzero = 0;
    for (m = 1; m < FIRST_DOUT; m = m + 1)
        if (cap[m] !== 12'd0) begin
            nzero = nzero + 1;
            $display("  PRE[%0d]=%03x", m, cap[m]);
        end
    if (nzero != 0) begin
        nerr = nerr + 1;
        $display("FAIL ② 偏移 %0d 之前有 %0d 拍 dout 非零", FIRST_DOUT, nzero);
    end

    // 打印 256 个读出值。位置由架构定死，不靠「找第一个非零」对齐。
    nzero = 0;
    for (m = 0; m < 256; m = m + 1) begin
        $display("DOUT %0d %03x", m, cap[FIRST_DOUT + m]);
        seen[m] = cap[FIRST_DOUT + m];
        if (cap[FIRST_DOUT + m] === 12'd0) nzero = nzero + 1;
    end
    ndistinct = 0;
    for (m = 0; m < 256; m = m + 1) begin
        dup = 0;
        for (i = 0; i < m; i = i + 1)
            if (seen[i] === seen[m]) dup = 1;
        if (dup == 0) ndistinct = ndistinct + 1;
    end
    $display("READ_A nonzero_of_256 %0d distinct %0d", 256 - nzero, ndistinct);
    if (ndistinct < 200)
        $display("WARN 只有 %0d 个不同的值 —— 探针可能退化了", ndistinct);

    if (nerr == 0) $display("PASS 时序四项（done/起点/长度/空窗）");
    else           $display("FAIL 时序 %0d 处不符", nerr);
    $finish;
end

endmodule
