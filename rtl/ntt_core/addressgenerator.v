/*
The designers:

Ahmet Can Mert <ahmetcanmert@sabanciuniv.edu>
Ferhat Yaman <ferhatyaman@sabanciuniv.edu>

To the extent possible under law, the implementer has waived all copyright
and related or neighboring rights to the source code in this file.
http://creativecommons.org/publicdomain/zero/1.0/
*/

// ===========================================================================
// ntt_addressgenerator —— 三档折叠度（PE_NUMBER = 1 / 4 / 16）合一的地址生成器
//
// 以 rtl/pe1/addressgenerator.v 为底：把写死的常数逐条换成 L 的表达式
// （设计文档 rtl/folding_param_design.md §3.1），只在**不是** L 的函数的地方
// 开 generate 分支（§3.2）。正确性判据不是「看起来对」，而是
// 「和上游逐拍一模一样」—— 由 rtl/probes/ag_equiv_tb.v 逐拍比对全部输出。
//
// L = log2(128 / PE_NUMBER)：pe1 → 7 ｜ pe4 → 5 ｜ pe16 → 3
//
// 需要 generate 分支的地方（**不要**「顺手统一」）：
//   ① FSM stall   §5.2 —— 三档停的位置与拍数各不相同，且 pe16 内部 FNTT/INTT 不对称
//   ② c_tw 计数器 —— 与 ① 同一张表，stall 期的冻结/推进三档不同
//   ③ PWM2 地址   §5.1 —— pe1 双读口 + c_pwm 调制；PE≥4 退化为恒等扫描
//
// ⚠️ 内部子模块一律用 ntt_ 前缀（约束 13）—— 否则与 rtl/pe{1,4,16}/ 里的同名模块
//    在等价探针里撞车（iverilog 没有 namespace，报 "module already declared"）。
//
// ⚠️ 分支判据一律用 `L`，**不是** `PE_NUMBER` —— 本模块只收 L。三档里
//    L==7 ⟺ PE_NUMBER==1、L==5 ⟺ 4、L==3 ⟺ 16。非法 L（如 6）会落进
//    最后一个 `else` 分支，得到一份**能编过但行为错**的电路 —— 由
//    rtl/probes/ag_equiv_tb.v 的非法 L 守卫 + rtl/probes/leaf_elab_tb.v 的
//    TW_ADDR_W 查表断言兜住，两处都会直接 FATAL。
// ===========================================================================

module ntt_addressgenerator #(
    parameter L         = 7,          // = $clog2(128/PE_NUMBER)：7 / 5 / 3
    parameter TW_ADDR_W = 9           // c_tw / raddr_tw / BROM 地址位宽：9 / 8 / 7
                                      // ⚠️ **推不出公式，手工选**（设计文档 §3.3a）
)(
    input  wire                  clk, reset,
    input  wire                  start_fntt, start_pwm2, start_intt,
    output reg                   ct,
    output reg                   pwm,
    output reg  [L:0]            raddr0, raddr1,
    output reg  [L:0]            waddr0, waddr1,
    output reg                   wen0  , wen1  ,
    output reg                   brsel0, brsel1,
    output reg                   brselen0, brselen1,
    output reg  [2:0]            stage_count,
    output reg  [2:0]            stage_count_pwm,
    output reg  [L-1:0]          c_loop_pwm,   // pe1 独有；其余档恒 0
    output wire [L-1:0]          raddr_b,      // pe1 独有；其余档恒 0
    output wire [TW_ADDR_W-1:0]  raddr_tw
);

// ---------------------------------------------------------------------------
// 常数门限
//
// ⚠️ 一律先夹到非负再比较：`c_stage < 6-L` 在 L=7 时是 `c_stage < -1`，
//    而 c_stage 无符号、`6-L` 有符号 —— 混比较会把 -1 当成 32'hFFFFFFFF，
//    于是「永不成立」变成「永远成立」。夹到 0 之后语义才对。
//    （L=7 时两个门限都在 0 或 0 以下，本来就没有那一支，夹到 0 不改变行为。）

localparam integer FNT_W_ID  = (L < 6) ? L : 6;           // FNTT 写口恒等门限 §3.1(b)
localparam integer INTT_R_ID = (7 - L > 0) ? (7 - L) : 0; // INTT 读口前置恒等
localparam integer INTT_W_ID = (6 - L > 0) ? (6 - L) : 0; // INTT 写口前置恒等

// twiddle 前向初值 T(L)：§3.1(e)。校验 T(7)=127、T(5)=95、T(3)=39
function integer T;
    input integer LL;
    integer s;
    begin
        T = 0;
        for (s = 0; s <= 6; s = s + 1)
            T = T + ((s < LL) ? ((1 << s) - 1) : ((1 << LL) - 1));
        T = T + 7;
    end
endfunction

// 低 n 位为 1 的掩码；n <= 0 → 0（调用方据此得到「该级每拍都步进」）
function integer lowmask;
    input integer n;
    integer k;
    begin
        lowmask = 0;
        for (k = 0; k < 8; k = k + 1)
            if (k < n) lowmask[k] = 1'b1;
    end
endfunction

// FNTT：本级这一拍 c_tw 要不要 +1 —— §3.1(e) 上半
function fntt_step;
    input integer LL;
    input integer S;
    integer n;
    begin
        n = LL - S;
        if (S == 0)      fntt_step = 1'b0;      // 级 0 保持
        else if (n <= 0) fntt_step = 1'b1;      // L-S <= 0：每拍 +1
        else             fntt_step = ((c_loop & lowmask(n)) == lowmask(n));
    end
endfunction

// INTT：逆向回卷项 —— §3.1(e) 下半，N = S+L-5
// 返回 1 表示在「奇数 c_loop」那一拍要额外 +2（使净效果 = +1）
function intt_step;
    input integer LL;
    input integer S;
    integer n;
    begin
        n = S + LL - 5;
        if (n <= 0) intt_step = 1'b1;           // N<=0：两支同值，化简为裸 +1
        else        intt_step = ((c_loop & lowmask(n)) == lowmask(n));
    end
endfunction

// ---------------------------------------------------------------------------
// 控制信号

reg [2:0]           c_stage;
reg [L-1:0]         c_loop;
reg [2:0]           c_pwm;
reg [TW_ADDR_W-1:0] c_tw;

reg                 c_stl;   // pe16 的 stall 相位计数器；pe1/pe4 恒 0（不可达）

// PWM2 地址与 pe1 专有信号 —— 由下面的 generate 驱动
wire [L-1:0] pwm2_raddr_w;
wire [L-1:0] pwm2_waddr_w;
reg  [L-1:0] raddr_b_w;

// ---------------------------------------------------------------------------
// FSM
/*
FSM:

-- IDLE
-- NTT
-- PWM
-- INTT
-- STL0/STL1/STL2   （pe1 无 stall；三档共用一套编码，pe1 不会进入）

*/

parameter IDLE = 3'b000;
parameter FNTT = 3'b001;
parameter PWM2 = 3'b010;
parameter INTT = 3'b011;
parameter STL0 = 3'b100;
parameter STL1 = 3'b101;
parameter STL2 = 3'b110;

reg [2:0] curr_state, next_state;

always @(posedge clk or posedge reset) begin
    if(reset)
        curr_state <= 0;
    else
        curr_state <= next_state;
end

// ---- next_state：§5.2 三档 stall 结构不同，逐档照抄上游 ----------------------
generate
if (L == 7) begin : G_FSM_PE1
    // rtl/pe1/addressgenerator.v:62-101 —— 4 态、**一处都不停**
    always @(*) begin
        case(curr_state)
        IDLE: begin
            if(start_fntt)      next_state = FNTT;
            else if(start_pwm2) next_state = PWM2;
            else if(start_intt) next_state = INTT;
            else                next_state = IDLE;
        end
        FNTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else
                next_state = FNTT;
        end
        PWM2: begin
            if((c_pwm == 3'd4) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else
                next_state = PWM2;
        end
        INTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else
                next_state = INTT;
        end
        default: next_state = IDLE;
        endcase
    end
end
else if (L == 5) begin : G_FSM_PE4
    // rtl/pe4/addressgenerator.v:62-111 —— STL0(→FNTT)、STL1(→INTT)，各 1 拍
    always @(*) begin
        case(curr_state)
        IDLE: begin
            if(start_fntt)      next_state = FNTT;
            else if(start_pwm2) next_state = PWM2;
            else if(start_intt) next_state = INTT;
            else                next_state = IDLE;
        end
        FNTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else if((c_stage == L-1) && (c_loop == {L{1'b1}}))
                next_state = STL0;
            else
                next_state = FNTT;
        end
        PWM2: begin
            if((c_pwm == 3'd4) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else
                next_state = PWM2;
        end
        INTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else if((c_stage == 3'd0) && (c_loop == {L{1'b1}}))
                next_state = STL1;
            else
                next_state = INTT;
        end
        STL0: next_state = FNTT;
        STL1: next_state = INTT;
        default: next_state = IDLE;
        endcase
    end
end
else begin : G_FSM_PE16
    // rtl/pe16/addressgenerator.v:65-120 —— STL0 / STL2 各 2 拍（靠 c_stl），STL1 1 拍
    // ⚠️ 非法 L 会落到这一支
    always @(*) begin
        case(curr_state)
        IDLE: begin
            if(start_fntt)      next_state = FNTT;
            else if(start_pwm2) next_state = PWM2;
            else if(start_intt) next_state = INTT;
            else                next_state = IDLE;
        end
        FNTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else if((c_stage <= L-1) && (c_loop == {L{1'b1}}))
                next_state = STL0;
            else
                next_state = FNTT;
        end
        PWM2: begin
            if((c_pwm == 3'd4) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else
                next_state = PWM2;
        end
        INTT: begin
            if((c_stage == 3'd6) && (c_loop == {L{1'b1}}))
                next_state = IDLE;
            else if((c_stage <= L-1) && (c_loop == {L{1'b1}}))
                next_state = STL1;
            else if(((c_stage == 3'd4) || (c_stage == 3'd5)) && (c_loop == {L{1'b1}}))
                next_state = STL2;
            else
                next_state = INTT;
        end
        STL0: next_state = (c_stl == 1'd1) ? FNTT : STL0;
        STL1: next_state = INTT;
        STL2: next_state = (c_stl == 1'd1) ? INTT : STL2;
        default: next_state = IDLE;
        endcase
    end
end
endgenerate

// ---------------------------------------------------------------------------
// c_stl（pe16 专用相位计数器）
//
// 不做 generate：STL0/STL2 在 pe1/pe4 不可达，所以同一条规则对三档都对。

always @(posedge clk or posedge reset) begin
    if(reset) begin
        c_stl <= 0;
    end
    else begin
        if((curr_state == STL0) || (curr_state == STL2))
            c_stl <= (c_stl == 1'd1) ? 0 : (c_stl + 1'd1);
        else
            c_stl <= 0;
    end
end

// ---------------------------------------------------------------------------
// Control operations
//
// 结构说明：上游这里是一个 `always @(posedge)` 直接写寄存器。为了把「三档不同」
// 的部分收进 generate，改写成「组合算出 nx_* + 一个共用的寄存器块」。
// 上游全部用非阻塞赋值、且只读当前值，所以改写成组合逻辑**语义不变**。

reg [2:0]           nx_c_stage;
reg [L-1:0]         nx_c_loop;
reg [2:0]           nx_c_pwm;
reg [TW_ADDR_W-1:0] nx_c_tw;

generate
if (L == 7) begin : G_CNT_PE1
    // rtl/pe1/addressgenerator.v:107-188 —— FNTT/INTT 均无 stall
    always @(*) begin
        if(start_fntt || start_pwm2 || start_intt) begin
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = (start_intt) ? T(L) : ((start_pwm2) ? 2*T(L) : 0);
        end
        else if(curr_state == FNTT) begin
            nx_c_stage = (c_loop == {L{1'b1}})
                       ? ((c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1)) : c_stage;
            nx_c_loop  = (c_loop == {L{1'b1}}) ? {L{1'b0}} : (c_loop + 1'b1);
            nx_c_pwm   = c_pwm;
            if(c_loop == {L{1'b1}})        nx_c_tw = c_tw + 1'b1;
            else if(fntt_step(L, c_stage)) nx_c_tw = c_tw + 1'b1;
            else                           nx_c_tw = c_tw;
        end
        else if(curr_state == PWM2) begin
            nx_c_stage = 0;
            nx_c_loop  = (c_pwm == 3'd4) ? (c_loop + 1'b1) : c_loop;
            nx_c_pwm   = (c_pwm == 3'd4) ? 3'd0 : (c_pwm + 3'd1);
            nx_c_tw    = (c_pwm == 3'd4) ? (c_tw + 1'b1) : c_tw;
        end
        else if(curr_state == INTT) begin
            nx_c_stage = (c_loop == {L{1'b1}})
                       ? ((c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1)) : c_stage;
            nx_c_loop  = (c_loop == {L{1'b1}}) ? {L{1'b0}} : (c_loop + 1'b1);
            nx_c_pwm   = c_pwm;
            if(c_loop == {L{1'b1}})            nx_c_tw = c_tw + 1'b1;
            else if(c_stage == 3'd6)           nx_c_tw = c_tw;
            else if(c_loop[0] == 1'b0)         nx_c_tw = c_tw + 1'b1;
            else                               nx_c_tw = c_tw - 1'b1
                                                        + (intt_step(L, c_stage) ? 2'd2 : 2'd0);
        end
        else begin // IDLE（pe1 不进 STL*）
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = 0;
        end
    end
end
else if (L == 5) begin : G_CNT_PE4
    // rtl/pe4/addressgenerator.v:117-214
    // FNTT 在 S==L-1 处只冻结 c_stage（c_loop 照回卷、c_tw 照 +1）；INTT 在 S==0 处冻结 c_stage
    always @(*) begin
        if(start_fntt || start_pwm2 || start_intt) begin
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = (start_intt) ? T(L) : ((start_pwm2) ? 2*T(L) : 0);
        end
        else if(curr_state == FNTT) begin
            if((c_loop == {L{1'b1}}) && (c_stage == L-1))
                nx_c_stage = c_stage;
            else if(c_loop == {L{1'b1}})
                nx_c_stage = (c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1);
            else
                nx_c_stage = c_stage;
            nx_c_loop  = (c_loop == {L{1'b1}}) ? {L{1'b0}} : (c_loop + 1'b1);
            nx_c_pwm   = c_pwm;
            if(c_loop == {L{1'b1}})        nx_c_tw = c_tw + 1'b1;
            else if(fntt_step(L, c_stage)) nx_c_tw = c_tw + 1'b1;
            else                           nx_c_tw = c_tw;
        end
        else if(curr_state == PWM2) begin
            nx_c_stage = 0;
            nx_c_loop  = (c_pwm == 3'd4) ? (c_loop + 1'b1) : c_loop;
            nx_c_pwm   = (c_pwm == 3'd4) ? 3'd0 : (c_pwm + 3'd1);
            nx_c_tw    = (c_pwm == 3'd4) ? (c_tw + 1'b1) : c_tw;
        end
        else if(curr_state == INTT) begin
            if((c_loop == {L{1'b1}}) && (c_stage == 3'd0))
                nx_c_stage = c_stage;
            else if(c_loop == {L{1'b1}})
                nx_c_stage = (c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1);
            else
                nx_c_stage = c_stage;
            nx_c_loop  = (c_loop == {L{1'b1}}) ? {L{1'b0}} : (c_loop + 1'b1);
            nx_c_pwm   = c_pwm;
            if(c_loop == {L{1'b1}})            nx_c_tw = c_tw + 1'b1;
            else if(c_stage == 3'd6)           nx_c_tw = c_tw;
            else if(c_loop[0] == 1'b0)         nx_c_tw = c_tw + 1'b1;
            else                               nx_c_tw = c_tw - 1'b1
                                                        + (intt_step(L, c_stage) ? 2'd2 : 2'd0);
        end
        else if(curr_state == STL0) begin
            nx_c_stage = c_stage + 3'd1;
            nx_c_loop  = c_loop;
            nx_c_pwm   = c_pwm;
            nx_c_tw    = c_tw;
        end
        else if(curr_state == STL1) begin
            nx_c_stage = c_stage + 3'd1;
            nx_c_loop  = c_loop;
            nx_c_pwm   = c_pwm;
            nx_c_tw    = c_tw;
        end
        else begin // IDLE
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = 0;
        end
    end
end
else begin : G_CNT_PE16
    // rtl/pe16/addressgenerator.v:140-253
    // ⚠️ pe16 的 FNTT 与 INTT **不对称**（设计文档 §5.2）：
    //    FNTT 在 S<=L-1 时把 c_stage / c_loop / c_tw 三者**一起**冻结；
    //    INTT 在同一位置**只冻结 c_stage**，c_loop 照回卷、c_tw 照 +1。
    //    这是真的，**不要统一掉**。
    // ⚠️ 非法 L 会落到这一支
    always @(*) begin
        if(start_fntt || start_pwm2 || start_intt) begin
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = (start_intt) ? T(L) : ((start_pwm2) ? 2*T(L) : 0);
        end
        else if(curr_state == FNTT) begin
            if((c_loop == {L{1'b1}}) && (c_stage <= L-1))   nx_c_stage = c_stage;
            else if(c_loop == {L{1'b1}})                    nx_c_stage = (c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1);
            else                                            nx_c_stage = c_stage;

            if((c_loop == {L{1'b1}}) && (c_stage <= L-1))   nx_c_loop = c_loop;
            else if(c_loop == {L{1'b1}})                    nx_c_loop = {L{1'b0}};
            else                                            nx_c_loop = c_loop + 1'b1;

            nx_c_pwm = c_pwm;
            if((c_loop == {L{1'b1}}) && (c_stage <= L-1))   nx_c_tw = c_tw;
            else if(c_loop == {L{1'b1}})                    nx_c_tw = c_tw + 1'b1;
            else if(fntt_step(L, c_stage))                  nx_c_tw = c_tw + 1'b1;
            else                                            nx_c_tw = c_tw;
        end
        else if(curr_state == PWM2) begin
            nx_c_stage = 0;
            nx_c_loop  = (c_pwm == 3'd4) ? (c_loop + 1'b1) : c_loop;
            nx_c_pwm   = (c_pwm == 3'd4) ? 3'd0 : (c_pwm + 3'd1);
            nx_c_tw    = (c_pwm == 3'd4) ? (c_tw + 1'b1) : c_tw;
        end
        else if(curr_state == INTT) begin
            if((c_loop == {L{1'b1}}) && (c_stage <= L-1))                          nx_c_stage = c_stage;
            else if((c_loop == {L{1'b1}}) && ((c_stage == 3'd4) || (c_stage == 3'd5))) nx_c_stage = c_stage;
            else if(c_loop == {L{1'b1}})                                           nx_c_stage = (c_stage == 3'd6) ? 3'd6 : (c_stage + 3'd1);
            else                                                                   nx_c_stage = c_stage;

            if((c_loop == {L{1'b1}}) && ((c_stage == 3'd4) || (c_stage == 3'd5)))  nx_c_loop = c_loop;
            else if(c_loop == {L{1'b1}})                                           nx_c_loop = {L{1'b0}};
            else                                                                   nx_c_loop = c_loop + 1'b1;

            nx_c_pwm = c_pwm;
            if((c_loop == {L{1'b1}}) && ((c_stage == 3'd4) || (c_stage == 3'd5)))  nx_c_tw = c_tw;
            else if(c_loop == {L{1'b1}})                                           nx_c_tw = c_tw + 1'b1;
            else if(c_stage == 3'd6)                                               nx_c_tw = c_tw;
            else if(c_loop[0] == 1'b0)                                             nx_c_tw = c_tw + 1'b1;
            else                                                                   nx_c_tw = c_tw - 1'b1
                                                                                          + (intt_step(L, c_stage) ? 2'd2 : 2'd0);
        end
        else if(curr_state == STL0) begin
            nx_c_stage = (c_stl == 1'd0) ? c_stage : c_stage + 3'd1;
            nx_c_loop  = (c_stl == 1'd0) ? c_loop  : {L{1'b0}};
            nx_c_pwm   = c_pwm;
            nx_c_tw    = (c_stl == 1'd0) ? c_tw    : c_tw + 1'b1;
        end
        else if(curr_state == STL1) begin
            nx_c_stage = c_stage + 3'd1;
            nx_c_loop  = c_loop;
            nx_c_pwm   = c_pwm;
            nx_c_tw    = c_tw;
        end
        else if(curr_state == STL2) begin
            nx_c_stage = (c_stl == 1'd0) ? c_stage : c_stage + 3'd1;
            nx_c_loop  = (c_stl == 1'd0) ? c_loop  : {L{1'b0}};
            nx_c_pwm   = c_pwm;
            nx_c_tw    = (c_stl == 1'd0) ? c_tw    : c_tw + 1'b1;
        end
        else begin // IDLE
            nx_c_stage = 0;
            nx_c_loop  = 0;
            nx_c_pwm   = 0;
            nx_c_tw    = 0;
        end
    end
end
endgenerate

always @(posedge clk or posedge reset) begin
    if(reset) begin
        c_stage <= 0;
        c_loop  <= 0;
        c_pwm   <= 0;
        c_tw    <= 0;
    end
    else begin
        c_stage <= nx_c_stage;
        c_loop  <= nx_c_loop;
        c_pwm   <= nx_c_pwm;
        c_tw    <= nx_c_tw;
    end
end

// --------------------------------------------------------------------------- signals

reg [L:0] raddr;
reg [L:0] waddre,waddro;
reg       wen;
reg       brsel;
reg       brselen;

// --------------------------------------------------------------------------- raddr (c_loop)

always @(posedge clk or posedge reset) begin
    if(reset) begin
        raddr[L] <= 0; // alternating addressing between stages
    end
    else begin
        if(start_fntt || start_pwm2 || start_intt) begin
            raddr[L] <= (start_fntt) ? 0 : 1;
        end
        else if((raddr[L-1:0] == {L{1'b1}}) && ((curr_state == FNTT) || (curr_state == INTT))) begin
            // negate for next stage
            raddr[L] <= ~raddr[L];
        end
        else begin
            // otherwise, keep it
            raddr[L] <= raddr[L];
        end
    end
end

always @(posedge clk or posedge reset) begin
    if(reset) begin
        raddr[L-1:0] <= 0;
    end
    else begin
        if(start_fntt || start_pwm2 || start_intt) begin
            raddr[L-1:0] <= 0;
        end
        else if(curr_state == FNTT) begin
            // 读口恒等门限 = L-1（§3.1(b)：与写口**不是**同一条线）
            if(c_stage >= L-1)
                raddr[L-1:0] <= c_loop;
            else begin
                raddr[L-1:0] <= ((c_loop>>1) & ((1<<(L-1-c_stage))-1))
                              + (c_loop[0] << (L-1-c_stage))
                              + ((c_loop>>(L-c_stage)) << (L-c_stage));
            end
        end
        else if(curr_state == PWM2) begin
            raddr[L-1:0] <= pwm2_raddr_w;
        end
        else if(curr_state == INTT) begin
            // 前置恒等门限 = 7-L（§3.1(b)）；末级恒等三档都是 S==6
            if(c_stage < INTT_R_ID)
                raddr[L-1:0] <= c_loop;
            else if(c_stage == 3'd6)
                raddr[L-1:0] <= c_loop;
            else begin
                raddr[L-1:0] <= ((c_loop>>1) & ((1<<(c_stage+L-6))-1))
                              + (c_loop[0] << (c_stage+L-6))
                              + ((c_loop>>(c_stage+L-5)) << (c_stage+L-5));
            end
        end
        else if(curr_state == STL0) begin
            raddr[L-1:0] <= raddr[L-1:0];
        end
        else if(curr_state == STL1) begin
            raddr[L-1:0] <= raddr[L-1:0];
        end
        else if(curr_state == STL2) begin
            raddr[L-1:0] <= raddr[L-1:0];
        end
        else begin
            raddr[L-1:0] <= 0;
        end
    end
end

// --------------------------------------------------------------------------- waddr,wen,brsel (c_loop)

always @(posedge clk or posedge reset) begin
    if(reset) begin
        waddre[L] <= 0;
        waddro[L] <= 0;
    end
    else begin
        if(start_fntt || start_pwm2 || start_intt) begin
            waddre[L] <= (start_fntt || start_pwm2) ? 1 : 0;
            waddro[L] <= (start_fntt || start_pwm2) ? 1 : 0;
        end
        else if((waddro[L-1:0] == {L{1'b1}}) && (c_loop == 0) && ((curr_state == FNTT) || (curr_state == INTT))) begin
            // negate for next stage
            waddre[L] <= ~waddre[L];
            waddro[L] <= ~waddro[L];
        end
        else begin
            // otherwise, keep it
            waddre[L] <= waddre[L];
            waddro[L] <= waddro[L];
        end
    end
end

always @(posedge clk or posedge reset) begin
    if(reset) begin
        waddre[L-1:0] <= 0;
        waddro[L-1:0] <= 0;
        wen           <= 0;
        brsel         <= 0;
        brselen       <= 0;
    end
    else begin
        if(start_fntt || start_pwm2 || start_intt) begin
            waddre[L-1:0] <= 0;
            waddro[L-1:0] <= 0;
            wen           <= 0;
            brsel         <= 0;
            brselen       <= 0;
        end
        else if (curr_state == FNTT)begin
            // 写口恒等门限 = min(L,6)（§3.1(b)：pe1 的 S 在 6 饱和，pe4 的 L-1=4 必须落在同一条线上）
            if(c_stage >= FNT_W_ID) begin
                waddre[L-1:0] <= c_loop;
                waddro[L-1:0] <= c_loop;
            end
            else begin
                waddre[L-1:0] <= (c_loop>>1) + ((c_loop>>(L-c_stage)) << (L-1-c_stage));
                waddro[L-1:0] <= (c_loop>>1) + ((c_loop>>(L-c_stage)) << (L-1-c_stage)) + (1 << (L-1-c_stage));
            end
            wen       <= 1;
            brsel     <= c_loop[0];
            brselen   <= 1;
        end
        else if (curr_state == PWM2) begin
            waddre[L-1:0] <= pwm2_waddr_w;
            waddro[L-1:0] <= pwm2_waddr_w;
            wen           <= (c_pwm == 3'd3) ? 1 : 0;
            brsel         <= 0;
            brselen       <= 0;
        end
        else if (curr_state == INTT) begin
            // 前置恒等门限 = 6-L（比读口**少一级**，§3.1(b)：上游真实行为，不是笔误）
            if(c_stage < INTT_W_ID) begin
                waddre[L-1:0] <= c_loop;
                waddro[L-1:0] <= c_loop;
            end
            else if(c_stage == 3'd6) begin
                waddre[L-1:0] <= c_loop;
                waddro[L-1:0] <= c_loop;
            end
            else begin
                waddre[L-1:0] <= (c_loop>>1) + ((c_loop>>(c_stage+L-5)) << (c_stage+L-6));
                waddro[L-1:0] <= (c_loop>>1) + ((c_loop>>(c_stage+L-5)) << (c_stage+L-6)) + (1 << (c_stage+L-6));
            end
            wen       <= 1;
            brsel     <= c_loop[0];
            brselen   <= 1;
        end
        else if(curr_state == STL0) begin
            waddre[L-1:0] <= waddre[L-1:0];
            waddro[L-1:0] <= waddro[L-1:0];
            wen           <= 0;
            brsel         <= 0;
            brselen       <= 0;
        end
        else if(curr_state == STL1) begin
            waddre[L-1:0] <= waddre[L-1:0];
            waddro[L-1:0] <= waddro[L-1:0];
            wen           <= 0;
            brsel         <= 0;
            brselen       <= 0;
        end
        else if(curr_state == STL2) begin
            waddre[L-1:0] <= waddre[L-1:0];
            waddro[L-1:0] <= waddro[L-1:0];
            wen           <= 0;
            brsel         <= 0;
            brselen       <= 0;
        end
        else begin
            waddre[L-1:0] <= 0;
            waddro[L-1:0] <= 0;
            wen           <= 0;
            brsel         <= 0;
            brselen       <= 0;
        end
    end
end

reg b_ct;
reg b_pwm;

// --------------------------------------------------------------------------- ct, pwm
always @(posedge clk or posedge reset) begin
    if(reset) begin
        b_ct  <= 0;
        b_pwm <= 0;
    end
    else begin
        if((curr_state == FNTT) || (curr_state == PWM2))
            b_ct <= 1;
        else if(curr_state == INTT)
            b_ct <= 0;
        else
            b_ct <= b_ct;

        if(curr_state == PWM2)
            b_pwm <= (c_pwm == 3'd4) ? 1 : 0;
        else
            b_pwm <= 0;
    end
end

// --------------------------------------------------------------------------- PWM2 地址（§5.1）

generate
if (L == 7) begin : G_PWM2_PE1
    // rtl/pe1/addressgenerator.v:236-238（读）、:326-327（写）
    assign pwm2_raddr_w = (c_pwm < 2) + ((c_loop>>1) << 1);
    assign pwm2_waddr_w = ((0 < c_pwm) && (c_pwm < 3)) + ((c_loop>>1) << 1);
end
else begin : G_PWM2_WIDE
    // rtl/pe4/…:262-263, 342-344 ｜ rtl/pe16/…:301-302, 385-387
    // PE>=4：数据布局天然对齐，退化为恒等扫描
    assign pwm2_raddr_w = c_loop;
    assign pwm2_waddr_w = c_loop;
end
endgenerate

// --------------------------------------------------------------------------- raddr_b / c_loop_pwm（pe1 独有）

generate
if (L == 7) begin : G_RB_PE1
    // rtl/pe1/addressgenerator.v:254-269（raddr_b_w）、:409-410（两级 shiftreg）
    wire [L-1:0] raddr_b_wd0;
    wire [L-1:0] c_loop_pwmd0;

    always @(posedge clk or posedge reset) begin
        if(reset) begin
            raddr_b_w <= 0;
        end
        else begin
            if(curr_state == PWM2)
                raddr_b_w <= c_pwm[0] + ((c_loop>>1)<<1);
            else
                raddr_b_w <= 0;
        end
    end

    ntt_shiftreg #(.SHIFT(2),.DATA(L)) sre12(clk,reset,c_loop    ,c_loop_pwmd0);
    ntt_shiftreg #(.SHIFT(1),.DATA(L)) sre13(clk,reset,raddr_b_w ,raddr_b_wd0);

    always @(posedge clk or posedge reset) begin
        if(reset) c_loop_pwm <= 0;
        else      c_loop_pwm <= c_loop_pwmd0;
    end

    assign raddr_b = raddr_b_wd0;
end
else begin : G_RB_WIDE
    // PE>=4 不产生这两个信号，顶层也不连 —— 恒 0 即可（设计文档 §5.1）。
    // raddr_b_w 在这一支没有驱动也没有读者，综合时会整个消失。
    always @(posedge clk or posedge reset) begin
        if(reset) c_loop_pwm <= 0;
        else      c_loop_pwm <= 0;
    end

    assign raddr_b = {L{1'b0}};
end
endgenerate

// --------------------------------------------------------------------------- delays

wire       ctd0;
wire       pwmd0;
wire [L:0] waddrd0;
wire [L:0] waddrd1;
wire       wend0;
wire       wend1;
wire       brseld0;
wire       brseld1;
wire       brselend0;
wire       brselend1;
wire [2:0] stage_countd0;
wire [2:0] stage_count_pwmd0;
wire [TW_ADDR_W-1:0] raddr_twd0;

ntt_shiftreg #(.SHIFT(1),.DATA(1))         sre00(clk,reset,b_ct   ,ctd0);
ntt_shiftreg #(.SHIFT(1),.DATA(1))         sre01(clk,reset,b_pwm  ,pwmd0);
ntt_shiftreg #(.SHIFT(5),.DATA(L+1))       sre02(clk,reset,waddre ,waddrd0);
ntt_shiftreg #(.SHIFT(6),.DATA(L+1))       sre03(clk,reset,waddro ,waddrd1);
ntt_shiftreg #(.SHIFT(5),.DATA(1))         sre04(clk,reset,wen    ,wend0);
ntt_shiftreg #(.SHIFT(6),.DATA(1))         sre05(clk,reset,wen    ,wend1);
ntt_shiftreg #(.SHIFT(5),.DATA(1))         sre06(clk,reset,brsel  ,brseld0);
ntt_shiftreg #(.SHIFT(6),.DATA(1))         sre07(clk,reset,brsel  ,brseld1);
ntt_shiftreg #(.SHIFT(5),.DATA(1))         sre08(clk,reset,brselen,brselend0);
ntt_shiftreg #(.SHIFT(6),.DATA(1))         sre09(clk,reset,brselen,brselend1);
ntt_shiftreg #(.SHIFT(6),.DATA(3))         sre10(clk,reset,c_stage,stage_countd0);
ntt_shiftreg #(.SHIFT(2),.DATA(3))         sre11(clk,reset,c_pwm  ,stage_count_pwmd0);
ntt_shiftreg #(.SHIFT(1),.DATA(TW_ADDR_W)) sre14(clk,reset,c_tw   ,raddr_twd0);

// --------------------------------------------------------------------------- outputs

always @(posedge clk or posedge reset) begin
    if(reset) begin
        ct              <= 0;
        pwm             <= 0;
        raddr0          <= 0;
        raddr1          <= 0;
        waddr0          <= 0;
        waddr1          <= 0;
        wen0            <= 0;
        wen1            <= 0;
        brsel0          <= 0;
        brsel1          <= 0;
        brselen0        <= 0;
        brselen1        <= 0;
        stage_count     <= 0;
        stage_count_pwm <= 0;
    end
    else begin
        ct              <= ctd0;
        pwm             <= pwmd0;
        raddr0          <= raddr;
        raddr1          <= raddr;
        waddr0          <= waddrd0;
        waddr1          <= waddrd1;
        wen0            <= wend0;
        wen1            <= wend1;
        brsel0          <= brseld0;
        brsel1          <= brseld1;
        brselen0        <= brselend0;
        brselen1        <= brselend1;
        stage_count     <= stage_countd0;
        stage_count_pwm <= stage_count_pwmd0;
    end
end

assign raddr_tw = raddr_twd0;

endmodule
