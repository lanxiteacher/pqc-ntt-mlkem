// ===========================================================================
// top_behavior_tb.v —— KyberHPMNTT_top 的对外行为探针（固定 12 位接口）
//
// 前面几条探针证明的是「新核 == 上游核」。这条证明的是**外面包的那层**：
// 序列化器把 12 位串行流攒成宽数据、反序列化器再拆回来，对外是不是对得上。
//
// 查四件事：
//   ① 装载：连着灌 din、相位过去之后再脉冲 start_*，能正常收到 done
//      —— 收不到就说明装载窗口不对（这条挂在有界等待的护栏上，不会挂死）
//   ② 读出起点：read 脉冲之后，第 2*PE_NUMBER+3 拍起才是有效 dout
//   ③ 读出长度：**连着 256 拍**，一拍不多一拍不少（第 257 拍是核越界回卷）
//   ④ done 拍数：start_* 脉冲之后第 CC+3 拍
//
// 然后打印 256 个 dout（**位置定位**，不是「找第一个非零」再对齐），
// 让 run_probes.sh 横向 diff：**三档喂同一串激励，这 256 个值必须逐位相同**
// —— 这就是「固定 12 位接口」的全部意义，也是 pe4/pe16 第一次被功能验证。
//
// ⚠️ ②的偏移**不是三档统一的**，是 2*PE_NUMBER+3（pe1 5 / pe4 11 / pe16 35）。
//    核自己的读出延迟固定，但 ce 每 PE 拍才来一次，第一拍宽结果最早也要等
//    第 3 个 ce（前两个 ce 上核在清 do_cntr），此前**没有数据可拆**。
//    硬要三档都在 read+5 吐第一个值，只能吐假的。
//    所以「接口一致」= 端口一致 + 值序列一致，**不含延迟一致**。
//    ⚠️ rtl/folding_param_plan.md 的 Task 4 写「第一条有效 dout 在 read+5（三档都是）」，
//       这句**只对 pe1 成立**，别照抄。
//
// ---------------------------------------------------------------------------
// 这条探针自己踩过的三个坑（都写在这儿，因为每一个都让探针**看起来在通过**）：
//
// 1. **LFSR 被 X 毒死**：`always @(negedge clk)` 在 t=0 会因 clk 的 X→0 触发一次，
//    那一刻 initial 还没播种，读到 X；全 X 的 LFSR 永远停在 X。整条 dout 全是 xxx，
//    而两棵树「一起 X」→ 逐拍对拍报 0 处不符。→ 必须 `if (!reset)`。
// 2. **空数组槽被当成非零**：`cap[]` 没被抓到的槽是 X，而 `X !== 0` 恒真，
//    「有效窗口之前必须为空」这条结构判据于是假 FAIL。→ 抓取使能要在脉冲**之前**开。
// 3. **bank B 的数据三档不同**：装载 A 在三档都发生在第 3 拍（数据天然一样），
//    但装载 B 分别在第 1188 / 519 / 368 拍，LFSR 一路自由跑，三档装进 bank B 的
//    系数**不是同一串**；PWM2 是 A、B 逐点乘，结果自然不同。
//    → 每次装载前重新播种（A / B 用不同种子），判据才立得住。
//    这条最像 RTL 的 bug 而其实不是 —— 先怀疑激励。
//
// 没覆盖到的：bank B 的读出（read_b）、INTT 方向。这条探针只走
// 「load A → FNTT A → load B → FNTT B → PWM2 A → read A」，够证明序列化器；
// 其余留给 Task 6。
//
// 用法（从 rtl/probes/）：
//   CORE="$(ls ../ntt_core/*.v | grep -v _top)"
//   iverilog -g2005 -DCFG_PE_NUM=1 -DREF_PE1 -o w1.vvp \
//       top_behavior_tb.v ../pe1/*.v $CORE ../ntt_core/KyberHPMNTT_top.v && vvp w1.vvp
//   -DREF_PE1 只在 pe1 加：那一档另外例化一份上游 KyberHPM1PE_top 逐拍对比。
//   pe4/pe16 没有可比的 _top —— 上游那两档的 _top 是宽接口，不是同一个东西。
//
//   -DDBG_WIDE 另开一段调试打印：逐拍打出核那一侧的**宽** din/dout 以及
//   sub/rsub/dsel/ce。核对「哪个 12 位切片被搬到了哪一拍」时用这个，
//   比对着 dout 猜快得多。默认不编进来。
// ===========================================================================

`timescale 1ns/1ps

`ifndef CFG_PE_NUM
    `define CFG_PE_NUM 1
    `define CFG_PE_MISSING
`endif

module top_behavior_tb;

localparam integer PE_NUMBER = `CFG_PE_NUM;

// 核的周期数（H1_port_spec.md §二）。_top 在核的基础上多 3 拍：
//   输入寄存 1 拍 → 核自己 CC+1 → 输出寄存 1 拍
localparam integer CC_FNTT = (PE_NUMBER==1) ? 904 : (PE_NUMBER==4) ? 232 : 69;
localparam integer CC_PWM2 = (PE_NUMBER==1) ? 647 : (PE_NUMBER==4) ? 167 : 47;

localparam integer FIRST_DOUT = 2*PE_NUMBER + 3;   // 相对 read 脉冲那拍的偏移
localparam integer CAP_N      = 320;               // 抓多少拍（pe16 要 290）
// 装载相位长度 256+PE 拍，从 posedge P+2 起算 → 从 P 起 257+PE 拍才收尾。
// 早于收尾就脉冲 start_* 的话，核还在 OP_LOAD_DATA 里，那个脉冲会被丢掉。
localparam integer LOAD_WAIT  = 257 + PE_NUMBER + 8;

// --------------------------------------------------------------------- 时钟
reg clk, reset;
initial clk = 1'b0;
always #5 clk = ~clk;

// --------------------------------------------------------------------- 激励
reg  load_a_f, load_a_i, load_b_f, load_b_i;
reg  read_a, read_b, start_ab, start_fntt, start_pwm2, start_intt;
reg  [11:0] din;

wire [11:0] dout;
wire        done;

KyberHPMNTT_top #(.PE_NUMBER(PE_NUMBER)) dut (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(read_b),
    .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(dout), .done(done)
);

`ifdef REF_PE1
// 上游 _top：接口同名同位宽，直连对拍 —— pe1 的行为必须一拍都不许变。
wire [11:0] r_dout;
wire        r_done;

KyberHPM1PE_top u_ref (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(read_b),
    .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(r_dout), .done(r_done)
);
`endif

// --------------------------------------------------------------------- 记账
integer cyc;        // reset 释放之后过了几个时钟沿
integer mark;       // 刚发出的脉冲会被哪个时钟沿采到
integer done_cyc;   // done 第一次抬起的拍号（-1 = 还没见着）
integer nerr;

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
`ifdef REF_PE1
        if (dout !== r_dout) begin
            nerr = nerr + 1;
            if (nerr <= 10)
                $display("MISMATCH dout @cyc %0d  new=%h ref=%h", cyc, dout, r_dout);
        end
        if (done !== r_done) begin
            nerr = nerr + 1;
            if (nerr <= 10)
                $display("MISMATCH done @cyc %0d  new=%b ref=%b", cyc, done, r_done);
        end
`endif
    end
end

// din 每拍都变（LFSR）—— 别让「向量全是常量、全中只是巧合」（CLAUDE.md 约定 3）
// ⚠️ **必须挂 `if (!reset)`**：`always @(negedge clk)` 在 t=0 会因 clk 的 X→0
//    也触发一次，那一刻 initial 块还没跑 `lfsr = ...`，读到 X —— 而全 X 的 LFSR
//    永远停在 X，整条 dout 全是 xxx，探针却「全部相符」。这是本探针第一个踩到的坑。
//
// ★ 每次**装载**前重新播种 —— 这条是「三档 dout 序列逐位相同」能成立的前提。
//   装载 A 在三档都发生在第 3 拍，数据天然一样；但装载 B 分别发生在
//   第 1188 / 519 / 368 拍，LFSR 一路自由跑，**三档装进 bank B 的系数不是同一串**。
//   而 PWM2 是 A、B 逐点乘，于是三档结果自然不同 —— 这不是 RTL 的问题，是激励的问题。
//   播种点选在装载脉冲的第二个 negedge（见 pulse1 的说明），那一拍正是
//   核要吃的第一个系数 d[P+2]，所以从第一个系数起就是确定的。
//   A / B 用不同种子：两串数据不同，PWM2 才不是自乘的退化情形。
//
// ⚠️ `pending_reseed` 用**非阻塞**赋值置位，播种因此在**下一个** negedge 落地 ——
//    这样和同拍读它的本块没有竞争（本拍读到的是旧值 0）。
reg [31:0] lfsr;
reg [31:0] re_seed;
reg        pending_reseed;

always @(negedge clk) if (!reset) begin
    if (pending_reseed) begin
        lfsr           <= re_seed;
        din            <= re_seed[11:0] ^ 12'h9E3;
        pending_reseed <= 1'b0;
    end
    else begin
        lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        din  <= lfsr[11:0] ^ 12'h9E3;
    end
end

`ifdef DBG_WIDE
// 临时调试用（-DDBG_WIDE）：把核那一侧的**宽** din/dout 逐拍打出来，
// 用来核对序列化/反序列化到底把哪些 12 位切片搬到了哪一拍。
// 每条打的是**该 posedge 之后**的值。默认不编进来。
// 相位自带边界，所以不用额外掐范围：装载相位只打 ce 那几拍，读出相位全打。
always @(posedge clk) begin
    #2;                                  // 落在记账块的 #1 之后，取到的是本拍最终值
    if (!reset) begin
        if (dut.slow && dut.ce)
            $display("LD cyc=%0d sub=%0d rsub=%0d din_core=%h",
                     cyc, dut.sub, dut.rsub, dut.u_core.din);
        if (dut.slow_rd)
            $display("RD cyc=%0d sub=%0d rsub=%0d ce=%b dsel=%0d dout_core=%h dout=%h",
                     cyc, dut.sub, dut.rsub, dut.ce, dut.dsel,
                     dut.u_core.dout, dout);
    end
end
`endif

// --------------------------------------------------------------------- 驱动
task step; input integer n; integer i; begin
    for (i = 0; i < n; i = i + 1) @(negedge clk);
end endtask

task clear_all; begin
    load_a_f = 0; load_a_i = 0; load_b_f = 0; load_b_i = 0;
    read_a = 0; read_b = 0; start_ab = 0;
    start_fntt = 0; start_pwm2 = 0; start_intt = 0;
end endtask

// 发一拍宽的单脉冲（negdege 拉，下一个 posedge 采到）
//   1=load_a_f  2=load_b_f  3=start_fntt(A)  4=start_fntt(B)  5=start_pwm2(A)  6=read_a
//
// ⚠️ `mark` 记的是**主机改动信号的那一拍**（也就是信号被采到的前一拍），
//    不是被采到的那一拍 —— 与 `pe1_timing_tb.v` 的 c_start / c_read 同一口径。
//    H1_port_spec.md 的「done 在 CC+3」「first dout 在 read+5」就是按这个口径量的，
//    所以这里必须同口径，否则整张表会整体差 1 拍。
// ⚠️ 装载（which=1/2）会顺带**重新播种 LFSR**（见上方 din 驱动块的说明）。
//    播种点定在装载脉冲的第二个 negedge，那一拍正是核要吃的第一个系数。
task pulse1; input integer which; begin
    @(negedge clk);
    case (which)
        1: begin load_a_f = 1'b1; re_seed <= 32'h1ACE_B00C; pending_reseed <= 1'b1; end
        2: begin load_b_f = 1'b1; re_seed <= 32'h5A5A_1234; pending_reseed <= 1'b1; end
        3: begin start_fntt = 1'b1; start_ab = 1'b0; end
        4: begin start_fntt = 1'b1; start_ab = 1'b1; end
        5: begin start_pwm2 = 1'b1; start_ab = 1'b0; end
        6: read_a     = 1'b1;
    endcase
    mark = cyc;                       // 本拍（下一个 posedge 才采到）
    @(negedge clk);
    clear_all;
end endtask

// --------------------------------------------------------------------- 主流程
integer i, j, k, nz_pre, nzero, ndistinct, op_exp;
reg [11:0] seen [0:255];

initial begin
    cyc = 0; mark = 0; done_cyc = -1; nerr = 0;
    cap_en = 0; cap_base = 0; lfsr = 32'h1ACE_B00C;
    re_seed = 32'h1ACE_B00C; pending_reseed = 1'b0;
    reset = 1'b1; clear_all(); din = 0;

`ifdef CFG_PE_MISSING
    $display("FATAL 没给 CFG_PE_NUM —— 用法：-DCFG_PE_NUM=1|4|16");
    $finish;
`endif
    if ((PE_NUMBER != 1) && (PE_NUMBER != 4) && (PE_NUMBER != 16)) begin
        $display("FATAL CFG_PE_NUM=%0d 非法 —— 只支持 1 / 4 / 16。", PE_NUMBER);
        $finish;
    end

    repeat (4) step(1);
    reset = 1'b0;
    step(2);

    // ---- ① 装载 A：灌 256 拍系数，相位收尾后再 start_fntt ----
    pulse1(1);
    $display("LOAD_A %0d  (din 从下一拍起被采)", mark);
    step(LOAD_WAIT);

    pulse1(3);                                   // start_fntt, bank A
    op_exp = mark + CC_FNTT + 3;
    $display("OP_FNTT_A start %0d expect_done %0d", mark, op_exp);
    step(CC_FNTT + 3 + 8);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(FNTT A)：实测 %0d，预期 %0d（差 %0d）",
                 done_cyc, op_exp, done_cyc - op_exp);
    end

    // ---- 装载 B + FNTT B ----
    // ⚠️ **不能省**：PWM2 是 A、B 两个 bank 的逐点乘，B 没装载/没变换的话
    //    BRAM 里是 X，乘出来把 bank A 也污染成 X，而两棵树会「一起 X」→ 全部相符。
    //    本探针第一个版本就是这么被骗过去的。
    done_cyc = -1;
    pulse1(2);
    $display("LOAD_B %0d", mark);
    step(LOAD_WAIT);

    pulse1(4);                                   // start_fntt, bank B
    op_exp = mark + CC_FNTT + 3;
    $display("OP_FNTT_B start %0d expect_done %0d", mark, op_exp);
    step(CC_FNTT + 3 + 8);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(FNTT B)：实测 %0d，预期 %0d（差 %0d）",
                 done_cyc, op_exp, done_cyc - op_exp);
    end

    // ---- PWM2 A：换一个操作，证明周期数表也是按 PE_NUMBER 取的 ----
    done_cyc = -1;
    pulse1(5);
    op_exp = mark + CC_PWM2 + 3;
    $display("OP_PWM2_A start %0d expect_done %0d", mark, op_exp);
    step(CC_PWM2 + 3 + 8);
    if (done_cyc != op_exp) begin
        nerr = nerr + 1;
        $display("FAIL ④ done 拍数(PWM2)：实测 %0d，预期 %0d（差 %0d）",
                 done_cyc, op_exp, done_cyc - op_exp);
    end

    // ---- ② ③ 读出 A ----
    // ⚠️ 这里**不能用 pulse1(6)**：pulse1 要吃掉两个 negedge 才返回，
    //    等它返回再开 cap_en，cap[1]（read 被采到的那一拍）根本没被抓到，
    //    数组槽留着 X —— 而 `X !== 0` 恒真，② 那条「有效窗口之前必须为空」
    //    就变成了假 FAIL（本探针第二个踩到的坑）。所以展开写，在置位那一拍
    //    和它被采到的那一拍之间把抓取打开。
    //    cap[0]（= 置位那一拍）按此写法抓不到，也没有判据用到它，见下方循环从 1 起。
    @(negedge clk);
    read_a   = 1'b1;
    mark     = cyc;
    cap_base = cyc; cap_en = 1'b1;
    @(negedge clk);
    read_a   = 1'b0;
    $display("READ_A %0d first_dout_expect %0d", mark, mark + FIRST_DOUT);
    step(CAP_N + 4);
    cap_en = 1'b0;

    // 有效窗口之前必须是空的（结构判据，不依赖读出值恰好非零）
    nz_pre = 0;
    for (i = 1; i < FIRST_DOUT; i = i + 1)
        if (cap[i] !== 12'd0) begin
            nz_pre = nz_pre + 1;
            $display("  PRE[%0d]=%03x （read 之后第 %0d 拍）", i, cap[i], i);
        end
    if (nz_pre != 0) begin
        nerr = nerr + 1;
        $display("FAIL ② 偏移 %0d 之前有 %0d 拍 dout 非零 —— 有效窗口起点不对",
                 FIRST_DOUT, nz_pre);
    end

    // 打印 256 个值。位置由架构定死（见文件头 ② 的推导），不靠猜。
    nzero = 0;
    for (i = 0; i < 256; i = i + 1) begin
        $display("DOUT %0d %03x", i, cap[FIRST_DOUT + i]);
        seen[i] = cap[FIRST_DOUT + i];
        if (cap[FIRST_DOUT + i] === 12'd0) nzero = nzero + 1;
    end
    ndistinct = 0;
    for (i = 0; i < 256; i = i + 1) begin
        k = 0;
        for (j = 0; j < i; j = j + 1)             // 只看前面有没有同值
            if (seen[j] === seen[i]) k = 1;
        if (k == 0) ndistinct = ndistinct + 1;
    end
    $display("READ_A nonzero_of_256 %0d distinct %0d", 256 - nzero, ndistinct);
    if (ndistinct < 200)
        $display("WARN 256 个读出值里只有 %0d 个不同 —— 探针可能退化了", ndistinct);

    $display("CYCLES %0d", cyc);
`ifdef REF_PE1
    if (nerr == 0)
        $display("PASS 与上游 KyberHPM1PE_top 逐拍一致：%0d 拍", cyc);
    else
        $display("FAIL 与上游 KyberHPM1PE_top 有 %0d 处不符", nerr);
`else
    $display("INFO 没有 -DREF_PE1 —— 只打印序列，横向对比交给 run_probes.sh diff");
`endif
    $finish;
end

endmodule
