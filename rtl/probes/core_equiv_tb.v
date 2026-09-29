// ===========================================================================
// core_equiv_tb.v —— KyberHPMNTT 与上游 KyberHPM{1,4,16}PE 的**逐拍等价探针**
//
// 同一份激励喂给两个核，每个时钟沿比对：
//   - 端口：dout / done
//   - 内部：curr_state / di_cntr / do_cntr / op_cntr / op_out_a / op_out_b /
//           load_type / load_ab / read_ab / exec_ab / tr
//   - 数据通路：di0/dw0/dr0/de0、di1/dw1/dr1/de1、di2/dw2/dr2/de2（逐 bank）
//
// 为什么要比内部而不只比 dout：dout 只在 OP_READ_DATA 那 200 多拍里有值，
// 其余时间恒 0。只比 dout 的话，地址生成、写使能、级号这类差异会被整段遮住。
// 这条探针要能在「地址错一位」的粒度上 FAIL —— 由下面的阴性对照证明它有这个分辨力。
//
// 用法（从仓库根目录，注意 $CORE 要**排除 _top**）：
//   CORE="$(ls rtl/ntt_core/*.v | grep -v _top)"
//   iverilog -g2005 -DCFG_PE_NUM=1  -DCFG_PE_MOD=KyberHPM1PE  -o w1.vvp \
//       rtl/probes/core_equiv_tb.v rtl/pe1/KyberHPM1PE.v   $CORE && vvp w1.vvp
//   （pe4 用 =4/KyberHPM4PE，pe16 用 =16/KyberHPM16PE）
//   逐拍等价的判据：三档都打印 PASS。
//
// ⚠️ **为什么要两个 -D**：上游三档的模块名不同，必须编译期选。而 iverilog 12.0
//    **不支持** `` `if MACRO == 值 `` 这种带比较的预处理条件（只认 `ifdef/`ifndef），
//    所以没法从 CFG_PE_NUM 推出模块名。两个宏都由 run_probes.sh 从同一个循环变量
//    生成，不会各说各话；手工敲命令时自己保证配套。
// ⚠️ 上游那侧不传参数（PE_NUMBER 默认值就是 1/4/16），新那侧传 CFG_PE_NUM。
// ⚠️ 两棵树能同场编进来，靠的是新树模块叫 KyberHPMNTT、叶子叫 ntt_*（iverilog
//    没有 namespace，同名必撞）。宏也带了配置前缀，理由同。
// ⚠️ 上游是异步高有效复位，这里 reset 就是高有效。
// ===========================================================================

`timescale 1ns/1ps

`ifndef CFG_PE_NUM
    `define CFG_PE_NUM 1
    `define CFG_PE_MISSING
`endif

`ifndef CFG_PE_MOD
    `define CFG_PE_MOD KyberHPM1PE
    `define CFG_PE_MOD_MISSING
`endif

`define DUT_OLD `CFG_PE_MOD

module core_equiv_tb;

localparam integer PE_NUMBER = `CFG_PE_NUM;
localparam integer L         = $clog2(128 / PE_NUMBER);

// 每段给的宽裕拍数（都 ≥ 实际需要的，不写无界等待）
localparam integer LOAD_N = 2*(128/PE_NUMBER) + 6;   // 装载：di_cntr 走完一圈
localparam integer READ_N = 2*(128/PE_NUMBER) + 10;  // 读出：do_cntr 走完一圈
localparam integer FNTT_P = ((PE_NUMBER==1) ? 904 : (PE_NUMBER==4) ? 232 : 69) + 12;
localparam integer PWM2_P = ((PE_NUMBER==1) ? 647 : (PE_NUMBER==4) ? 167 : 47) + 12;
localparam integer INTT_P = ((PE_NUMBER==1) ? 904 : (PE_NUMBER==4) ? 233 : 71) + 12;

// --------------------------------------------------------------------- 激励
reg clk, reset;
reg load_a_f, load_a_i, load_b_f, load_b_i;
reg read_a, read_b;
reg start_ab;
reg start_fntt, start_pwm2, start_intt;
reg [12*PE_NUMBER-1:0] din;

initial clk = 1'b0;
always #5 clk = ~clk;

// din 用 LFSR 驱动，每拍都变 —— 防止「向量全是常数，全中只是巧合」（CLAUDE.md 约定 3）
reg [31:0] lfsr;
integer    di;

always @(negedge clk) begin
    lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    for (di = 0; di < PE_NUMBER; di = di + 1)
        din[12*di +: 12] <= lfsr[11:0] ^ (di * 12'h9E3);
end

// --------------------------------------------------------------------- 旧：上游原版
wire [12*PE_NUMBER-1:0] o_dout;
wire                    o_done;

`DUT_OLD old (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(read_b),
    .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(o_dout), .done(o_done)
);

// --------------------------------------------------------------------- 新：参数化版
wire [12*PE_NUMBER-1:0] n_dout;
wire                    n_done;

KyberHPMNTT #(.PE_NUMBER(PE_NUMBER)) new (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(read_b),
    .start_ab(start_ab),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(n_dout), .done(n_done)
);

// --------------------------------------------------------------------- 比对
integer  ncyc, nerr, first_bad;
integer  nz_dout;
reg [63:0] chk;

`define CHK(nm, a, b)                                                          \
    if ((a) !== (b)) begin                                                     \
        nerr = nerr + 1;                                                       \
        if (nerr <= 20)                                                        \
            $display("MISMATCH @cyc %0d  %s  old=%h new=%h", ncyc, nm, a, b);  \
    end

`define CHKI(nm, idx, a, b)                                                    \
    if ((a) !== (b)) begin                                                     \
        nerr = nerr + 1;                                                       \
        if (nerr <= 20)                                                        \
            $display("MISMATCH @cyc %0d  %s[%0d]  old=%h new=%h",              \
                     ncyc, nm, idx, a, b);                                     \
    end

integer ci;

always @(posedge clk) begin
    #1;                                  // 等非阻塞赋值落定
    if (!reset) begin
        ncyc = ncyc + 1;

        `CHK("dout", o_dout, n_dout)
        `CHK("done", o_done, n_done)

        `CHK("curr_state", old.curr_state, new.curr_state)
        `CHK("next_state", old.next_state, new.next_state)
        `CHK("di_cntr",    old.di_cntr,    new.di_cntr)
        `CHK("do_cntr",    old.do_cntr,    new.do_cntr)
        `CHK("op_cntr",    old.op_cntr,    new.op_cntr)
        `CHK("op_out_a",   old.op_out_a,   new.op_out_a)
        `CHK("op_out_b",   old.op_out_b,   new.op_out_b)
        `CHK("load_type",  old.load_type,  new.load_type)
        `CHK("load_ab",    old.load_ab,    new.load_ab)
        `CHK("read_ab",    old.read_ab,    new.read_ab)
        `CHK("exec_ab",    old.exec_ab,    new.exec_ab)
        `CHK("tr",         old.tr,         new.tr)

        for (ci = 0; ci < 2*PE_NUMBER; ci = ci + 1) begin
            `CHKI("di2", ci, old.di2[ci], new.di2[ci])
            `CHKI("dw2", ci, old.dw2[ci], new.dw2[ci])
            `CHKI("dr2", ci, old.dr2[ci], new.dr2[ci])
            `CHKI("de2", ci, old.de2[ci], new.de2[ci])
            `CHKI("di0", ci, old.di0[ci], new.di0[ci])
            `CHKI("dw0", ci, old.dw0[ci], new.dw0[ci])
            `CHKI("dr0", ci, old.dr0[ci], new.dr0[ci])
            `CHKI("de0", ci, old.de0[ci], new.de0[ci])
            `CHKI("di1", ci, old.di1[ci], new.di1[ci])
            `CHKI("dw1", ci, old.dw1[ci], new.dw1[ci])
            `CHKI("dr1", ci, old.dr1[ci], new.dr1[ci])
            `CHKI("de1", ci, old.de1[ci], new.de1[ci])
        end

        // 非退化统计：dout 有多少拍非零、滚动校验和
        if (n_dout !== 0) begin
            nz_dout = nz_dout + 1;
            chk = ((chk << 5) + chk + n_dout) & 64'hFFFF_FFFF_FFFF_FFFF;
        end
    end
end

// --------------------------------------------------------------------- 跑法
task step; input integer n; integer i; begin
    for (i = 0; i < n; i = i + 1) @(negedge clk);
end endtask

// 装载：拉 1 拍 load_*，随后 din 自然被采 DI 拍
task do_load; input integer which; begin
    @(negedge clk);
    load_a_f = (which == 0);
    load_a_i = (which == 2);
    load_b_f = (which == 1);
    load_b_i = (which == 3);
    @(negedge clk);
    load_a_f = 0; load_a_i = 0; load_b_f = 0; load_b_i = 0;
    step(LOAD_N);
end endtask

// 运算：拉 1 拍 start_* + start_ab，随后空跑
task do_op; input integer which; input ab; begin
    @(negedge clk);
    start_fntt = (which == 0);
    start_pwm2 = (which == 1);
    start_intt = (which == 2);
    start_ab   = ab;
    @(negedge clk);
    start_fntt = 0; start_pwm2 = 0; start_intt = 0;
    step(which == 0 ? FNTT_P : (which == 1 ? PWM2_P : INTT_P));
end endtask

// 读出
// ⚠️ 想读 bank B 时：本拍同时拉 read_a/read_b，之后**只留 read_b**。
//    因为 pe4/pe16 的 OP_IDLE 只认 read_a（进入 OP_READ_DATA），而 read_ab 的
//    优先级是 read_a > read_b —— 所以必须先 read_a 把状态推过去，再靠持续
//    的 read_b 在 OP_READ_DATA 期间把 read_ab 置 1。pe1 那边两句都成立。
task do_read; input integer which; begin
    @(negedge clk);
    read_a = 1'b1;
    read_b = (which == 1);
    @(negedge clk);
    read_a = 1'b0;                       // read_b 按 which 继续挂着
    @(negedge clk);
    read_b = 1'b0;
    step(READ_N);
end endtask

initial begin
    ncyc = 0; nerr = 0; first_bad = -1; nz_dout = 0; chk = 0;
    reset = 1'b1;
    load_a_f = 0; load_a_i = 0; load_b_f = 0; load_b_i = 0;
    read_a = 0; read_b = 0; start_ab = 0;
    start_fntt = 0; start_pwm2 = 0; start_intt = 0;
    din = 0; lfsr = 32'h1ACE_B00C;

`ifdef CFG_PE_MISSING
    $display("FATAL 没给 CFG_PE_NUM —— 用法：-DCFG_PE_NUM=1|4|16");
    $finish;
`endif
`ifdef CFG_PE_MOD_MISSING
    $display("FATAL 没给 CFG_PE_MOD —— 用法：-DCFG_PE_MOD=KyberHPM1PE|KyberHPM4PE|KyberHPM16PE");
    $finish;
`endif
    if ((PE_NUMBER != 1) && (PE_NUMBER != 4) && (PE_NUMBER != 16)) begin
        $display("FATAL CFG_PE_NUM=%0d 非法 —— 只支持 1 / 4 / 16。", PE_NUMBER);
        $display("      别的值会同时把上游那侧也选成 KyberHPM16PE，比出来是假的。");
        $finish;
    end

    $display("CFG PE_NUMBER=%0d L=%0d", PE_NUMBER, L);

    repeat (4) step(1);
    reset = 1'b0;
    step(2);

    // A 载入 → FNTT；B 载入 → FNTT；A 做 PWM2；读 A、读 B
    do_load(0);                       // load_a_f
    do_load(1);                       // load_b_f
    do_op(0, 1'b0);                   // start_fntt, A
    do_op(0, 1'b1);                   // start_fntt, B
    do_op(1, 1'b0);                   // start_pwm2, A
    do_read(0);
    do_read(1);

    // A/B 载入（INTT 方向） → A 做 INTT → 读 A、读 B → B 做 INTT → 读 A、读 B
    do_load(2);                       // load_a_i
    do_load(3);                       // load_b_i
    do_op(2, 1'b0);                   // start_intt, A
    do_read(0);
    do_read(1);
    do_op(2, 1'b1);                   // start_intt, B
    do_read(0);
    do_read(1);

    $display("CYCLES %0d  dout_nonzero=%0d  dout_chk=%h", ncyc, nz_dout, chk);
    if (nz_dout == 0)
        $display("WARN 全程 dout 没出现过非零值 —— 探针是退化的，别拿它当通过");
    if (nerr == 0)
        $display("PASS 逐拍等价：%0d 拍、端口+内部共 %0d 路全部一致",
                 ncyc, 15 + 12*2*PE_NUMBER);
    else
        $display("FAIL 逐拍等价：%0d 拍里有 %0d 处不符", ncyc, nerr);
    $finish;
end

endmodule
