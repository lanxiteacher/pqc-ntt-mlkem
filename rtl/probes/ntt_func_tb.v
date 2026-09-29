// ===========================================================================
// ntt_func_tb.v —— 三档功能对拍（判据 3）：`KyberHPMNTT_top` 对黄金向量跑满 16 组
//
// 判据是「**多重集相等**」（`rtl/H1_port_spec.md` §八 的手法）：
//   装载顺序与读出顺序分开判，不互相污染 —— 多重集对了说明**装载 + 变换**对了，
//   逐位对不对是**读出顺序**的事，单独量。
//
// 三种运算各一个 build（默认 FNTT）：
//   （无宏）      装载 A(_f, 自然序)      → FNTT A → 读 A
//   -DOP_INTT     装载 A(_i, 交织 0,2,1,3) → INTT A → 读 A
//   -DOP_PWM2     装载 A(_i) + B(_i) 各一份 → PWM2  → 读 A
//
// ⚠️ **协议按 (运算, 折叠度) 分档，没有一套通用的**。下面是实测表（本 TB 量出来的），
//    不是从某一份 bench 抄来的 —— 抄 pe1 那套去做 pe4/pe16 的 PWM2 会得到
//    22/4096（= 随机）的「假失败」，我们真踩了一次。
//
//      运算   路径    pe1 的顺序   pe4/pe16 的顺序   读出顺序
//      FNTT   _f      自然序       自然序             pe1 = σ｜pe4/pe16 = 自然序
//      INTT   _i      σ            σ                  三档都是 τ
//      PWM2   _i      σ            自然序             pe1 = σ｜pe4/pe16 = 自然序
//
//      σ(m) = 4*(m/4) + [0,2,1,3][m%4]      （组内 0,2,1,3）
//      τ(e) = e/2 + 128*(e%2)               （0,128,1,129,…）
//
//    「顺序」= 喂给本顶层串行口的那 256 拍，第 k 拍该取文件里的第几个下标。
//
//    上游只在 pe1 上按运算拆过 bench（`_FNTT` / `_INTT` / `_PWM2`），pe4/pe16 只有
//    `_ALL_FULL` / `_ALL_HALF` —— 所以上面 pe4/pe16 那两列**没有上游文档可抄**，
//    是扫出来的：`_i` 下把 σ / 自然序两个候选各跑一遍，只有自然序那一边
//    4096/4096，另一个 22/4096（= 随机命中）。扫描的开关留在 DEF_MODE 上面。
//
// ⚠️ 为什么读出顺序在 TB 里**不做假设**：pe4/pe16 的宽接口从来没有人驱动过，
//    它们的读出约定**没有文档**。所以本 TB 只把 256 个读出值原样打出来，
//    由段 ⑩ 的 python 去问「这一串是哪一种约定」。**约定是测量结果，不是输入参数。**
//    唯一的例外是**判「对拍通过」时按多重集**，那个不需要知道顺序。
//
// ⚠️ 记一条现象、不下结论：`_f` 装载 + `start_pwm2` 这条组合（两个 bank 都 `_f`，
//    或者 A`_f`B`_i` 混着）在本 TB 里读出**全是 X**（4096 槽）。两个 bank 必须
//    用**同一条**装载路径。这不是本轮的判据，只记下来省得下次重新踩。
//
// ⚠️ pe1 的校准作用：pe1 是唯一有作者版 bench 逐位对照过的档。
//    本 TB 在 PE_NUMBER=1、**默认协议**下的结论**必须**和 B 的 bench 一字不差
//    （FNTT = σ 读出、INTT = τ 读出、PWM2 = σ 读出，三者都 4096/4096）。
//    对不上说明是**本 TB 的脚手架**错了，不是 RTL 错了。
//    这是本 TB 唯一的自检锚 —— 没有它，"4096/4096" 可能只是自己跟自己对上了。
//
// 用法（从 rtl/probes/，向量已由 run_probes.sh 铺到 _work/）：
//   CORE="$(ls ../ntt_core/*.v | grep -v _top | tr '\n' ' ')"
//   iverilog -g2005 -DCFG_PE_NUM=1 -o _work/f1.vvp \
//       ntt_func_tb.v $CORE ../ntt_core/KyberHPMNTT_top.v && ( cd _work && vvp f1.vvp )
//   vvp 的工作目录决定 $readmemh 的相对路径，所以要在 _work 里跑。
// ===========================================================================

`timescale 1ns/1ps

`ifndef CFG_PE_NUM
    `define CFG_PE_NUM 1
    `define CFG_PE_MISSING
`endif

module ntt_func_tb;

localparam integer PE_NUMBER = `CFG_PE_NUM;
localparam integer NG        = 16;        // 向量组数（16 组 × 256 = 4096 系数）
localparam integer FIRST_DOUT = 2*PE_NUMBER + 3;
localparam integer LOAD_WAIT  = 257 + PE_NUMBER + 8;
localparam integer CAP_N      = 320;
localparam integer WAIT_MAX   = 4000;     // done 的有界等待护栏（约束 3）

// 最长的那条路是 pe1 的 INTT（CC=904），留足余量
localparam integer OP_WAIT    =
    (PE_NUMBER==1) ? 960 : (PE_NUMBER==4) ? 300 : 120;

// ---- 装载协议（顺序 mode + 路径 _i/_f）------------------------------------
// 默认值 = **段 ⑩ 实测出来的那一套**，按 (运算, 折叠度) 选 —— 不是抄某一个档的 bench。
// 抄错了会得到「256 个系数全错」的假失败，本节底下那张表就是这么来的。
//
//   `-DA_NAT` / `-DA_SIG` / `-DB_NAT` / `-DB_SIG`  强制 A / B 的顺序（0 / 1）
//   `-DA_USE_F` / `-DB_USE_F`                       强制走 `_f` 装载路径
// 这些覆盖只是留着重跑当初那次扫描用的（见文件头「PWM2 的两套协议」）。
`ifdef OP_PWM2
    // PWM2：pe1 用 σ，pe4/pe16 用自然序 —— 两者都是 `_i`，差别只在顺序
    localparam integer DEF_MODE = (PE_NUMBER == 1) ? 1 : 0;
    localparam integer DEF_I    = 1;
`elsif OP_INTT
    localparam integer DEF_MODE = 1;      // 三档都是 σ
    localparam integer DEF_I    = 1;
`else
    localparam integer DEF_MODE = 0;      // FNTT 三档都是自然序
    localparam integer DEF_I    = 0;      // 走 `_f`
`endif

`ifdef A_NAT
localparam integer AMODE = 0;
`elsif A_SIG
localparam integer AMODE = 1;
`else
localparam integer AMODE = DEF_MODE;
`endif
`ifdef B_NAT
localparam integer BMODE = 0;
`elsif B_SIG
localparam integer BMODE = 1;
`else
localparam integer BMODE = DEF_MODE;
`endif
`ifdef A_USE_F
localparam integer A_I = 0;
`else
localparam integer A_I = DEF_I;
`endif
`ifdef B_USE_F
localparam integer B_I = 0;
`else
localparam integer B_I = DEF_I;
`endif

reg  clk, reset;
initial clk = 1'b0;
always #5 clk = ~clk;

reg  load_a_f, load_a_i, load_b_f, load_b_i, read_a;
reg  start_fntt, start_pwm2, start_intt;
reg  [11:0] din;
wire [11:0] dout;
wire        done;

KyberHPMNTT_top #(.PE_NUMBER(PE_NUMBER)) dut (
    .clk(clk), .reset(reset),
    .load_a_f(load_a_f), .load_a_i(load_a_i),
    .load_b_f(load_b_f), .load_b_i(load_b_i),
    .read_a(read_a), .read_b(1'b0),
    .start_ab(1'b0),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .din(din), .dout(dout), .done(done)
);

integer cyc, cap_base, done_cyc, guard;
integer i, v, m, gi, nerr_all;
reg     cap_en;
reg [11:0] cap [0:CAP_N+8];

// ⚠️ 抓取必须和 `cyc` 自增在**同一个** always 块里。分成两块各带 `#1` 就是竞争，
//    `cap[]` 会出现没写过的 X 槽，表现为「多重集不等 / xxx 值」这种看着像 RTL 挂了的现象。
always @(posedge clk) begin
    #1;
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

task wait_done; begin
    guard = 0;
    while ((done !== 1'b1) && (guard < WAIT_MAX)) begin
        @(negedge clk);
        guard = guard + 1;
    end
    if (guard >= WAIT_MAX)
        $display("FATAL 第 %0d 组：done 在 %0d 拍内没来", v, WAIT_MAX);
end endtask

// 喂给串行口的第 k 拍，该取文件里的第几个下标。
// mode 0 = 自然序（FNTT 用）；mode 1 = σ 序（INTT / PWM2 用，照 B 的 bench）。
function integer ord; input integer k; input integer mode;
    integer q, r;
    begin
        q = k / 4;
        r = k - 4*q;
        if (mode == 0) ord = k;
        else           ord = 4*q + ((r==0) ? 0 : (r==1) ? 2 : (r==2) ? 1 : 3);
    end
endfunction

// 装载一组。src: 0 = 从 vin 取（A 或 INTT/PWM2 的 A），1 = 从 vb 取（PWM2 的 B）
task load_grp;
    input integer base;      // 组号
    input integer src;
    input integer mode;
    input integer is_b;      // 装到 bank B？
    input integer use_i;     // 走 _i 装载路径？
    begin
        @(negedge clk);
        if (use_i) begin
            if (is_b) load_b_i = 1'b1; else load_a_i = 1'b1;
        end else begin
            if (is_b) load_b_f = 1'b1; else load_a_f = 1'b1;
        end
        @(negedge clk);
        load_a_f = 0; load_a_i = 0; load_b_f = 0; load_b_i = 0;
        for (i = 0; i < 256; i = i + 1) begin
            gi = base*256 + ord(i, mode);
            din = (src == 1) ? vb[gi] : vin[gi];
            @(negedge clk);
        end
    end
endtask

// 收 256 个读出值，打成 `DOUT <组> <m> <值>`
task read_grp; input integer base; begin
    @(negedge clk);
    read_a = 1'b1;
    cap_base = cyc; cap_en = 1'b1;
    @(negedge clk);
    read_a = 1'b0;
    step(CAP_N + 4);
    cap_en = 1'b0;
    for (m = 0; m < 256; m = m + 1)
        $display("DOUT %0d %0d %03x", base, m, cap[FIRST_DOUT + m]);
end endtask

// 起一个运算并等 done，然后回读
task run_op; input integer which; input integer base; begin
    done_cyc = -1;
    @(negedge clk);
    case (which)
        1: start_fntt = 1'b1;
        2: start_pwm2 = 1'b1;
        3: start_intt = 1'b1;
    endcase
    @(negedge clk);
    start_fntt = 0; start_pwm2 = 0; start_intt = 0;
    wait_done;
    if (done_cyc < 0) begin
        nerr_all = nerr_all + 1;
        $display("FAIL 第 %0d 组：done 没抓到拍号", base);
    end
    read_grp(base);
    step(12);
end endtask

// ⚠️ 文件名带 `f_` 前缀（func），和段 ⑨ 用的 in.txt/exp.txt（只有 256 行）**分开** ——
//    这两条探针共用 _work/ 目录，同名会互相盖掉。
// ⚠️ 三个运算**各自一套文件名**，不要用同一个名字靠「跑之前重铺一遍」——
//    那样分析脚本一读就串味（我们真踩了一次：拿 pwm2 的期望去判 FNTT）。
`ifdef OP_PWM2
    `define F_IN  "f_pwm2_in.txt"
    `define F_EXP "f_pwm2_exp.txt"
    `define F_B   "f_pwm2_b.txt"
`elsif OP_INTT
    `define F_IN  "f_intt_in.txt"
    `define F_EXP "f_intt_exp.txt"
`else
    `define F_IN  "f_fntt_in.txt"
    `define F_EXP "f_fntt_exp.txt"
`endif

reg [11:0] vin  [0:NG*256-1];
reg [11:0] vexp [0:NG*256-1];
reg [11:0] vb   [0:NG*256-1];

initial begin
    $readmemh(`F_IN,  vin);
    $readmemh(`F_EXP, vexp);
`ifdef OP_PWM2
    $readmemh(`F_B, vb);
`endif

    cyc = 0; cap_en = 0; cap_base = 0; nerr_all = 0;
    reset = 1'b1;
    load_a_f = 0; load_a_i = 0; load_b_f = 0; load_b_i = 0;
    read_a = 0; din = 0;
    start_fntt = 0; start_pwm2 = 0; start_intt = 0;

`ifdef CFG_PE_MISSING
    $display("FATAL 没给 CFG_PE_NUM —— 用法：-DCFG_PE_NUM=1|4|16");
    $finish;
`endif

    repeat (4) step(1);
    reset = 1'b0;
    step(2);

    for (v = 0; v < NG; v = v + 1) begin
`ifdef OP_PWM2
        // PWM2：A 和 B 各装一份，再 start_pwm2。
        // 装法由 AMODE/BMODE/B_F 拨（见文件头「PWM2 的两套协议」）。
        load_grp(v, 0, AMODE, 0, A_I);
        step(LOAD_WAIT);
        load_grp(v, 1, BMODE, 1, B_I);
        step(LOAD_WAIT);
        run_op(2, v);
`elsif OP_INTT
        load_grp(v, 0, 1, 0, 1);
        step(LOAD_WAIT);
        run_op(3, v);
`else
        load_grp(v, 0, 0, 0, 0);
        step(LOAD_WAIT);
        run_op(1, v);
`endif
    end

    $display("SUMMARY groups %0d", NG);
    if (nerr_all == 0) $display("PASS 16 组 × 256 拍全部收齐");
    else               $display("FAIL %0d 处", nerr_all);
    $finish;
end

endmodule
