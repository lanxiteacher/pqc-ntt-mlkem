// ===========================================================================
// KyberHPMNTT.v —— 参数化折叠度的 NTT 核（PE_NUMBER = 1 / 4 / 16）
//
// 来源：rtl/pe1/KyberHPM1PE.v + rtl/pe4/KyberHPM4PE.v + rtl/pe16/KyberHPM16PE.v
//       三份手工复制的代码合并成一份。逐拍等价的判据在
//       rtl/probes/core_equiv_tb.v（每个时钟沿比对全部输出，三档都必须 0 处不符）。
//
// 端口与 rtl/pe1/KyberHPM1PE.v **同名同序**（din/dout 之外的宽度全与配置无关）。
//
// ---------------------------------------------------------------------------
// 为什么里面还有 generate 分支
//
// 三档之间有一批**推不出统一式**的结构差异（设计文档 §3.2）。这些差异不是
// 「同一个公式代不同的 L」，而是三段各自成立的电路：
//
//   1. 数据通路那几个 case（OP_FNTT / OP_INTT 的级号分支、OP_PWM2 的排布）
//      —— 每档的级号集合、每级的拼接顺序都不同。是**抄写**，不是推导。
//   2. brams 的 dr1 源 —— pe1 用 AG 的 raddr_b，pe4/pe16 用 raddr0[L-1:0]。
//   3. NTT 单元里 OP_PWM2 那一张表 —— pe1 用 c_loop_pwm[0] 选择，pe4/pe16 用
//      stage_count_pwm 0..4 按 PE 下标切片。
//
// 所以分支里的内容是**逐行照抄**对应上游文件的，只把写死的常数换成参数。
// 这样做的代价是文件长；收益是「读一遍就能和上游对上」，且等价探针能逐拍判定。
// 想确认某个分支没抄错，直接 diff 探针的阴性对照，或对照 rtl/peN/。
//
// **不在此列的**（能统一就统一了，别再加分支）：
//   - di_cntr / do_cntr / op_cntr 的位宽与终值：都是 L 的函数
//   - BRAM / BROM / butterfly 的例化循环：PE_NUMBER=1 时自然退化成 pe1 那 4 个
//   - dout 的打包：{do0[0],...,do0[PE_NUMBER-1]} 用 generate 拼得出来
//   - W[ntt_loop] <= to[12*(PE_NUMBER-1-ntt_loop) +: 12]：PE=1 时就是 to 本身
//
// ---------------------------------------------------------------------------
// ⚠️ 宏名带配置前缀（`pe4_dic_0 / `pe16_dic_0）
// 因为上游 pe4/pe16 都用 `dic_0……` 这套裸名字。若本文件也用裸名字，和上游一起
// 编进同一个 iverilog 进程时**必然撞车**（iverilog 没有 namespace，宏是全局的）。
// 等价探针就是「两棵树同场编译」，所以这条不是洁癖，是硬约束。
// ===========================================================================

module KyberHPMNTT #(
    parameter PE_NUMBER = 1        // 折叠度：1 / 4 / 16，其余值非法（见下方守卫）
)(
    input                        clk, reset,
    input                        load_a_f, load_a_i,
    input                        load_b_f, load_b_i,
    input                        read_a, read_b,
    input                        start_ab,
    input                        start_fntt, start_pwm2, start_intt,
    input      [12*PE_NUMBER-1:0] din,
    output reg [12*PE_NUMBER-1:0] dout,
    output reg                    done
);

// ---------------------------------------------------------------- 派生参数
// L = log2(128/PE_NUMBER)：地址位宽 7 / 5 / 3，对应 §3.3a
localparam integer L = $clog2(128 / PE_NUMBER);

// ⚠️ TW_ADDR_W 是**手工选的** 9 / 8 / 7，没有公式（设计文档 §3.3a）。
//    别试图从 L 推 —— 推不出来，硬推会得到错的 BROM 深度。
localparam integer TW_ADDR_W = (PE_NUMBER == 1) ? 9 : (PE_NUMBER == 4) ? 8 : 7;

localparam integer DI_W = L + 1;                       // di_cntr 位宽 8 / 6 / 4
localparam integer DO_W = L + 2;                       // do_cntr 位宽 9 / 7 / 5
localparam integer OP_W = 10;                          // op_cntr 位宽，三档统一取够大的

// di_cntr 终值 = 2*(128/PE_NUMBER)-1 = 2^(L+1)-1 → 255 / 63 / 15
localparam [DI_W-1:0] DI_LAST = (1 << (L+1)) - 1;
// do_cntr 终值 = 2*(128/PE_NUMBER)+1 = 2^(L+1)+1 → 257 / 65 / 17
localparam [DO_W-1:0] DO_LAST = (1 << (L+1)) + 1;
localparam [DO_W-1:0] DO_ZERO = {DO_W{1'b0}};

// 三档的完整周期数。op_cntr 统一用 OP_W 位，所以比较也在 OP_W 位里做，
// 与上游各自的 10'd/8'd/7'd 语义相同（比较结果一样）。
function integer cc_of;
    input integer pe;
    input integer which;        // 0 = FNTT, 1 = PWM2, 2 = INTT
    begin
        case (pe)
        1:       cc_of = (which == 0) ? 904 : (which == 1) ? 647 : 904;
        4:       cc_of = (which == 0) ? 232 : (which == 1) ? 167 : 233;
        default: cc_of = (which == 0) ?  69 : (which == 1) ?  47 :  71;
        endcase
    end
endfunction

localparam [OP_W-1:0] FNTT_CC = cc_of(PE_NUMBER, 0);
localparam [OP_W-1:0] PWM2_CC = cc_of(PE_NUMBER, 1);
localparam [OP_W-1:0] INTT_CC = cc_of(PE_NUMBER, 2);

// ---------------------------------------------------------------- 非法参数守卫
// 数据通路是「每档一份」而不是公式，所以除 1/4/16 之外的 PE_NUMBER 会**静默**
// 落进 pe16 那一支 —— 编得过、跑得动、结果是错的。宁可在 time 0 就炸掉。
//
// ⚠️ 这条只管仿真。综合时 initial 被忽略，所以别指望它在 Vivado 里拦你。
//    Vivado 侧靠顶层只传 1/4/16 来保证；三档综合（Task 7）会各跑一遍。
initial begin
    if ((PE_NUMBER != 1) && (PE_NUMBER != 4) && (PE_NUMBER != 16)) begin
        $display("FATAL: PE_NUMBER=%0d 非法 —— 只支持 1 / 4 / 16。", PE_NUMBER);
        $display("       别的值没有对应的数据通路分支，会落进 pe16 那支得到错电路。");
        $finish;
    end
end

// ---------------------------------------------------------------- 状态编码
/*
We have 8 states:
-- 0 : OP_IDLE        --> Idle state, waiting for input
-- 1 : OP_LOAD_DATA   --> loading input polynomial A or B for (ntt or intt)
-- 2 : OP_FNTT        --> performing FNTT operation
-- 3 : OP_PWM2        --> performing PWM2 operation
-- 4 : OP_INTT        --> performing INTT operation
-- 5 : OP_NULL        --> no-operation-defined (can be added later)
-- 6 : OP_NULL        --> no-operation-defined (can be added later)
-- 7 : OP_READ_DATA   --> reading out output polynomial
*/

parameter OP_IDLE        = 3'd0;
parameter OP_LOAD_DATA   = 3'd1;
parameter OP_FNTT        = 3'd2;
parameter OP_PWM2        = 3'd3;
parameter OP_INTT        = 3'd4;
parameter OP_NULL1       = 3'd5; // no-operation-defined
parameter OP_NULL2       = 3'd6; // no-operation-defined
parameter OP_READ_DATA   = 3'd7;

reg [2:0]  curr_state,next_state;

reg [DI_W-1:0] di_cntr;  // counter for OP_LOAD_DATA/B state
reg [DO_W-1:0] do_cntr;  // counter for OP_READ_DATA/B state
reg [OP_W-1:0] op_cntr;  // counter for FNTT,INTT,PWM2 operations

reg        op_out_a; // where is output for A?
reg        op_out_b; // where is output for B?

reg        load_type;// 0 for FNTT, 1 for INTT

reg        load_ab;  // 0 for A, 1 for B
reg        read_ab;  // 0 for A, 1 for B
reg        exec_ab;  // 0 for A, 1 for B

// bram signals for input polynomial
reg [11:0]    di0 [2*PE_NUMBER-1:0];
wire[11:0]    do0 [2*PE_NUMBER-1:0];
reg [L:0]     dw0 [2*PE_NUMBER-1:0];
reg [L:0]     dr0 [2*PE_NUMBER-1:0];
reg           de0 [2*PE_NUMBER-1:0];

reg [11:0]    di1 [2*PE_NUMBER-1:0];
wire[11:0]    do1 [2*PE_NUMBER-1:0];
reg [L:0]     dw1 [2*PE_NUMBER-1:0];
reg [L:0]     dr1 [2*PE_NUMBER-1:0];
reg           de1 [2*PE_NUMBER-1:0];

// signals before going to brams
reg [11:0]    di2 [2*PE_NUMBER-1:0];
reg [L:0]     dw2 [2*PE_NUMBER-1:0];
reg [L:0]     dr2 [2*PE_NUMBER-1:0];
reg           de2 [2*PE_NUMBER-1:0];

// bram signals for twiddle factors
wire[12*PE_NUMBER-1:0] to;
reg [TW_ADDR_W-1:0]    tr;

// control unit signals (from control unit to top module)
wire                     c_ct;
wire                     c_pwm;
wire [L:0]               raddr0,raddr1;
wire [L:0]               waddr0,waddr1;
wire                     wen0  ,wen1  ;
wire                     brsel0,brsel1;
wire                     brselen0,brselen1;
wire [2:0]               stage_count;
wire [2:0]               stage_count_pwm;
wire [L-1:0]             c_loop_pwm;   // pe1 用；其余档 AG 输出恒 0
wire [L-1:0]             raddr_b;      // pe1 用；其余档 AG 输出恒 0
wire [TW_ADDR_W-1:0]     raddr_tw;

// signals for PU blocks（三档统一写成数组，PE_NUMBER=1 时就是 1 个元素）
reg        CT  [PE_NUMBER-1:0];
reg        PWM [PE_NUMBER-1:0];
reg [11:0] A   [PE_NUMBER-1:0];
reg [11:0] B   [PE_NUMBER-1:0];
reg [11:0] W   [PE_NUMBER-1:0];
wire[11:0] E   [PE_NUMBER-1:0];
wire[11:0] O   [PE_NUMBER-1:0];
wire[11:0] MUL [PE_NUMBER-1:0];
wire[11:0] ADD [PE_NUMBER-1:0];
wire[11:0] SUB [PE_NUMBER-1:0];

// ---------------------------------------------------------------- 两处「能统一就别分支」的换算
// OP_IDLE 的读触发：pe1 是 read_a || read_b，pe4/pe16 只认 read_a。上游真实差别。
// 这里是常数条件，综合会直接折成一条线。
wire sel_read = (PE_NUMBER == 1) ? (read_a || read_b) : read_a;

// brams 里 bank1 的读地址源：pe1 用 AG 的 raddr_b（PWM2 期间按 c_pwm 走），
// pe4/pe16 用 raddr0 的低 L 位。宽度都是 L。
wire [L-1:0] drb_src = (PE_NUMBER == 1) ? raddr_b : raddr0[L-1:0];

// ---------------------------------------------------------------- 宏（带配置前缀，见文件头说明）
// -- pe4：2*PE_NUMBER = 8 个 bank --------------------------------------------------
`define pe4_dic_0 {di2[0],di2[2],di2[4],di2[6]}
`define pe4_dwc_0 {dw2[0],dw2[2],dw2[4],dw2[6]}
`define pe4_drc_0 {dr2[0],dr2[2],dr2[4],dr2[6]}
`define pe4_dec_0 {de2[0],de2[2],de2[4],de2[6]}

`define pe4_dic_1 {di2[1],di2[3],di2[5],di2[7]}
`define pe4_dwc_1 {dw2[1],dw2[3],dw2[5],dw2[7]}
`define pe4_drc_1 {dr2[1],dr2[3],dr2[5],dr2[7]}
`define pe4_dec_1 {de2[1],de2[3],de2[5],de2[7]}

`define pe4_dic_2 {di2[0],di2[1],di2[2],di2[3],di2[4],di2[5],di2[6],di2[7]}
`define pe4_dwc_2 {dw2[0],dw2[1],dw2[2],dw2[3],dw2[4],dw2[5],dw2[6],dw2[7]}
`define pe4_drc_2 {dr2[0],dr2[1],dr2[2],dr2[3],dr2[4],dr2[5],dr2[6],dr2[7]}
`define pe4_dec_2 {de2[0],de2[1],de2[2],de2[3],de2[4],de2[5],de2[6],de2[7]}

// -- pe16：2*PE_NUMBER = 32 个 bank ------------------------------------------------
`define pe16_dic_0 {di2[0],di2[2],di2[4],di2[6],di2[8],di2[10],di2[12],di2[14],di2[16],di2[18],di2[20],di2[22],di2[24],di2[26],di2[28],di2[30]}
`define pe16_dwc_0 {dw2[0],dw2[2],dw2[4],dw2[6],dw2[8],dw2[10],dw2[12],dw2[14],dw2[16],dw2[18],dw2[20],dw2[22],dw2[24],dw2[26],dw2[28],dw2[30]}
`define pe16_drc_0 {dr2[0],dr2[2],dr2[4],dr2[6],dr2[8],dr2[10],dr2[12],dr2[14],dr2[16],dr2[18],dr2[20],dr2[22],dr2[24],dr2[26],dr2[28],dr2[30]}
`define pe16_dec_0 {de2[0],de2[2],de2[4],de2[6],de2[8],de2[10],de2[12],de2[14],de2[16],de2[18],de2[20],de2[22],de2[24],de2[26],de2[28],de2[30]}

`define pe16_dic_1 {di2[1],di2[3],di2[5],di2[7],di2[9],di2[11],di2[13],di2[15],di2[17],di2[19],di2[21],di2[23],di2[25],di2[27],di2[29],di2[31]}
`define pe16_dwc_1 {dw2[1],dw2[3],dw2[5],dw2[7],dw2[9],dw2[11],dw2[13],dw2[15],dw2[17],dw2[19],dw2[21],dw2[23],dw2[25],dw2[27],dw2[29],dw2[31]}
`define pe16_drc_1 {dr2[1],dr2[3],dr2[5],dr2[7],dr2[9],dr2[11],dr2[13],dr2[15],dr2[17],dr2[19],dr2[21],dr2[23],dr2[25],dr2[27],dr2[29],dr2[31]}
`define pe16_dec_1 {de2[1],de2[3],de2[5],de2[7],de2[9],de2[11],de2[13],de2[15],de2[17],de2[19],de2[21],de2[23],de2[25],de2[27],de2[29],de2[31]}

`define pe16_dic_2 {di2[0],di2[1],di2[2],di2[3],di2[4],di2[5],di2[6],di2[7],di2[8],di2[9],di2[10],di2[11],di2[12],di2[13],di2[14],di2[15],di2[16],di2[17],di2[18],di2[19],di2[20],di2[21],di2[22],di2[23],di2[24],di2[25],di2[26],di2[27],di2[28],di2[29],di2[30],di2[31]}
`define pe16_dwc_2 {dw2[0],dw2[1],dw2[2],dw2[3],dw2[4],dw2[5],dw2[6],dw2[7],dw2[8],dw2[9],dw2[10],dw2[11],dw2[12],dw2[13],dw2[14],dw2[15],dw2[16],dw2[17],dw2[18],dw2[19],dw2[20],dw2[21],dw2[22],dw2[23],dw2[24],dw2[25],dw2[26],dw2[27],dw2[28],dw2[29],dw2[30],dw2[31]}
`define pe16_drc_2 {dr2[0],dr2[1],dr2[2],dr2[3],dr2[4],dr2[5],dr2[6],dr2[7],dr2[8],dr2[9],dr2[10],dr2[11],dr2[12],dr2[13],dr2[14],dr2[15],dr2[16],dr2[17],dr2[18],dr2[19],dr2[20],dr2[21],dr2[22],dr2[23],dr2[24],dr2[25],dr2[26],dr2[27],dr2[28],dr2[29],dr2[30],dr2[31]}
`define pe16_dec_2 {de2[0],de2[1],de2[2],de2[3],de2[4],de2[5],de2[6],de2[7],de2[8],de2[9],de2[10],de2[11],de2[12],de2[13],de2[14],de2[15],de2[16],de2[17],de2[18],de2[19],de2[20],de2[21],de2[22],de2[23],de2[24],de2[25],de2[26],de2[27],de2[28],de2[29],de2[30],de2[31]}

// ---------------------------------------------------------------- load_type & op_out/load/read/exec

always @(posedge clk or posedge reset) begin
    if(reset)
        load_type <= 0;
    else begin
        if(load_a_i || load_b_i)
            load_type <= 1;
        else if(curr_state == OP_LOAD_DATA)
            load_type <= load_type;
        else
            load_type <= 0;
    end
end

always @(posedge clk or posedge reset) begin
    if(reset)
        op_out_a <= 0;
    else begin
        if(start_fntt && ~start_ab)
            op_out_a <= 1; // Doing FNTT (output will be at address 1)
        else if(start_pwm2 && ~start_ab)
            op_out_a <= 1; // Doing PWM2 (output will be at address 1)
        else if(start_intt && ~start_ab)
            op_out_a <= 0; // Doing INTT (output will be at address 0)
        else
            op_out_a <= op_out_a;
    end
end

always @(posedge clk or posedge reset) begin
    if(reset)
        op_out_b <= 0;
    else begin
        if(start_fntt && start_ab)
            op_out_b <= 1; // Doing FNTT (output will be at address 1)
        else if(start_pwm2 && start_ab)
            op_out_b <= 1; // Doing PWM2 (output will be at address 1)
        else if(start_intt && start_ab)
            op_out_b <= 0; // Doing INTT (output will be at address 0)
        else
            op_out_b <= op_out_b;
    end
end

always @(posedge clk or posedge reset) begin
    if(reset) begin
        load_ab <= 0;
        read_ab <= 0;
        exec_ab <= 0;
    end
    else begin
        // load
        if(load_a_f || load_a_i)
            load_ab <= 0;
        else if(load_b_f || load_b_i)
            load_ab <= 1;
        else if(curr_state == OP_IDLE)
            load_ab <= 0;
        else
            load_ab <= load_ab;
        // read
        if(read_a)
            read_ab <= 0;
        else if(read_b)
            read_ab <= 1;
        else if(curr_state == OP_IDLE)
            read_ab <= 0;
        else
            read_ab <= read_ab;
        // exec
        if(start_fntt || start_pwm2 || start_intt)
            exec_ab <= start_ab;
        else if(curr_state == OP_IDLE)
            exec_ab <= 0;
        else
            exec_ab <= exec_ab;
    end
end

// ---------------------------------------------------------------- FSM

always @(posedge clk or posedge reset) begin
    if(reset)
        curr_state <= 0;
    else
        curr_state <= next_state;
end

always @(*) begin
    case(curr_state)
    OP_IDLE: begin
        if(load_a_f || load_a_i || load_b_f || load_b_i)
            next_state = OP_LOAD_DATA;
        else if(start_fntt)
            next_state = OP_FNTT;
        else if(start_pwm2)
            next_state = OP_PWM2;
        else if(start_intt)
            next_state = OP_INTT;
        else if(sel_read)                  // pe1: read_a||read_b；pe4/pe16: read_a
            next_state = OP_READ_DATA;
        else
            next_state = OP_IDLE;
    end
    OP_LOAD_DATA: begin
        next_state = (di_cntr == DI_LAST) ? OP_IDLE : OP_LOAD_DATA;
    end
    OP_FNTT: begin
        next_state = (op_cntr == (FNTT_CC-1'b1)) ? OP_IDLE : OP_FNTT;
    end
    OP_PWM2: begin
        next_state = (op_cntr == (PWM2_CC-1'b1)) ? OP_IDLE : OP_PWM2;
    end
    OP_INTT: begin
        next_state = (op_cntr == (INTT_CC-1'b1)) ? OP_IDLE : OP_INTT;
    end
    OP_READ_DATA: begin
        next_state = (do_cntr == DO_LAST) ? OP_IDLE : OP_READ_DATA;
    end
    default: next_state = OP_IDLE;
    endcase
end

// ---------------------------------------------------------------- di_cntr,do_cntr,op_cntr

always @(posedge clk or posedge reset) begin
    if(reset) begin
        di_cntr <= 0;
        do_cntr <= 0;
        op_cntr <= 0;
    end
    else begin
        if (curr_state == OP_LOAD_DATA)
            di_cntr <= (di_cntr == DI_LAST) ? 0 : (di_cntr + 1'b1);

        if (curr_state == OP_READ_DATA)
            do_cntr <= (do_cntr == DO_LAST) ? 0 : (do_cntr + 1'b1);

        case(curr_state)
        OP_FNTT: op_cntr <= (op_cntr == (FNTT_CC-1'b1)) ? 0 : (op_cntr+1'b1);
        OP_PWM2: op_cntr <= (op_cntr == (PWM2_CC-1'b1)) ? 0 : (op_cntr+1'b1);
        OP_INTT: op_cntr <= (op_cntr == (INTT_CC-1'b1)) ? 0 : (op_cntr+1'b1);
        default: op_cntr <= op_cntr;
        endcase
    end
end

// ---------------------------------------------------------------- twiddle (read)

always @(posedge clk or posedge reset) begin
    if(reset)
        tr <= 0;
    else
        tr <= raddr_tw;
end

// ===========================================================================
// 数据通路：data (write & read)
//
// 三档各一支，内容逐行照抄 rtl/peN/。**不要**把这里「统一」掉 —— 见文件头。
// 唯一被参数化的地方：OP_LOAD_DATA 的 din 排布（load_f_pack，见下），因为
// 「每个系数复制两份、从高到低排」这条三档确实一致。
// ===========================================================================

// load_type==0 时的 din 排布：di2[2i] = di2[2i+1] = din[12*(PE_NUMBER-1-i) +: 12]
// 等价写法（和 rtl/peN/ 里那一长串 {2{din[x:y]}} 逐位相同）：
//   pe4  -> {{2{din[47:36]}},{2{din[35:24]}},{2{din[23:12]}},{2{din[11:0]}}}
//   pe16 -> 16 组同理
wire [24*PE_NUMBER-1:0] load_f_pack;

generate
    genvar lg;
    for (lg = 0; lg < 2*PE_NUMBER; lg = lg + 1) begin : G_LOAD_F_PACK
        assign load_f_pack[12*(2*PE_NUMBER-1-lg) +: 12] =
               din[12*(PE_NUMBER-1-(lg>>1)) +: 12];
    end
endgenerate

generate
if (PE_NUMBER == 1) begin : G_DP_PE1

    always @(*) begin
        case(curr_state)
        OP_LOAD_DATA: begin
            {di2[0],di2[1]} = load_f_pack;
            {dw2[0],dw2[1]} = (load_type == 1'd0) ? {2{1'b0,di_cntr[L-1:0]}} : {2{1'b1,di_cntr[L:1]}};
            {dr2[0],dr2[1]} = 0;
            {de2[0],de2[1]} = (load_type == 1'd0) ? {~di_cntr[L],di_cntr[L]} : {~di_cntr[0],di_cntr[0]};
        end
        OP_FNTT: begin
            // ------------------------------------------------------ READ
            {dr2[0],dr2[1]} = {raddr0,raddr1};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd0,3'd1,3'd2,3'd3,3'd4,3'd5: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        di2[0] = E[0];
                        dw2[0] = waddr0;
                        de2[0] = wen0;
                    end
                    else begin // brsel0 == 1
                        di2[0] = O[0];
                        dw2[0] = waddr1;
                        de2[0] = wen1;
                    end
                end
                else begin
                    di2[0] = 0;
                    dw2[0] = 0;
                    de2[0] = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        di2[1] = E[0];
                        dw2[1] = waddr0;
                        de2[1] = wen0;
                    end
                    else begin // brsel1 == 1
                        di2[1] = O[0];
                        dw2[1] = waddr1;
                        de2[1] = wen1;
                    end
                end
                else begin
                    di2[1] = 0;
                    dw2[1] = 0;
                    de2[1] = 0;
                end
            end
            3'd6: begin
                {di2[0],di2[1]} = {E[0],O[0]};
                {dw2[0],dw2[1]} = {waddr0,waddr1};
                {de2[0],de2[1]} = {wen0,wen1};
            end
            default: begin
                {di2[0],di2[1]} = 0;
                {dw2[0],dw2[1]} = 0;
                {de2[0],de2[1]} = 0;
            end
            endcase
        end
        OP_PWM2: begin
            if(c_loop_pwm[0] == 1'b1) begin
                // write to first BRAM
                {di2[0],di2[1]} = {E[0],E[0]};
                {dw2[0],dw2[1]} = {waddr1,waddr1};
                {dr2[0],dr2[1]} = {raddr1,raddr0};
                {de2[0],de2[1]} = {wen1|wen0,1'b0};
            end
            else begin
                // write to second BRAM
                {di2[0],di2[1]} = {E[0],E[0]};
                {dw2[0],dw2[1]} = {waddr1,waddr1};
                {dr2[0],dr2[1]} = {raddr1,raddr0};
                {de2[0],de2[1]} = {1'b0,wen1|wen0};
            end
        end
        OP_INTT: begin
            // ------------------------------------------------------ READ
            {dr2[0],dr2[1]} = {raddr0,raddr1};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd6: begin
                {di2[0],di2[1]} = {E[0],O[0]};
                {dw2[0],dw2[1]} = {waddr0,waddr1};
                {de2[0],de2[1]} = {wen0,wen1};
            end
            default: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        di2[0] = E[0];
                        dw2[0] = waddr0;
                        de2[0] = wen0;
                    end
                    else begin // brsel0 == 1
                        di2[0] = O[0];
                        dw2[0] = waddr1;
                        de2[0] = wen1;
                    end
                end
                else begin
                    di2[0] = 0;
                    dw2[0] = 0;
                    de2[0] = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        di2[1] = E[0];
                        dw2[1] = waddr0;
                        de2[1] = wen0;
                    end
                    else begin // brsel1 == 1
                        di2[1] = O[0];
                        dw2[1] = waddr1;
                        de2[1] = wen1;
                    end
                end
                else begin
                    di2[1] = 0;
                    dw2[1] = 0;
                    de2[1] = 0;
                end
            end
            endcase
        end
        OP_READ_DATA: begin
            {di2[0],di2[1]} = 0;
            {dw2[0],dw2[1]} = 0;
            {dr2[0],dr2[1]} = (read_ab == 1'b0) ? {2{op_out_a,do_cntr[L:1]}} : {2{op_out_b,do_cntr[L:1]}};
            {de2[0],de2[1]} = 0;
        end
        default: begin
            {di2[0],di2[1]} = 0;
            {dw2[0],dw2[1]} = 0;
            {dr2[0],dr2[1]} = 0;
            {de2[0],de2[1]} = 0;
        end
        endcase
    end

end
else if (PE_NUMBER == 4) begin : G_DP_PE4

    always @(*) begin
        case(curr_state)
        OP_LOAD_DATA: begin
            `pe4_dic_2 = (load_type == 1'd0) ? load_f_pack : {din,din};
            `pe4_dwc_2 = (load_type == 1'd0) ? {8{1'b0,di_cntr[L-1:0]}} : {8{1'b1,di_cntr[L:1]}};
            `pe4_drc_2 = 0;
            `pe4_dec_2 = (load_type == 1'd0) ? {4{~di_cntr[L],di_cntr[L]}} : {{4{~di_cntr[0]}},{4{di_cntr[0]}}};
        end
        OP_FNTT: begin
            // ------------------------------------------------------ READ
            `pe4_drc_2 = {4{raddr0,raddr1}};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd0,3'd1,3'd2,3'd3,3'd4: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        `pe4_dic_0 = {E[0],E[1],E[2],E[3]};
                        `pe4_dwc_0 = {4{waddr0}};
                        `pe4_dec_0 = {4{wen0}};
                    end
                    else begin // brsel0 == 1
                        `pe4_dic_0 = {O[0],O[1],O[2],O[3]};
                        `pe4_dwc_0 = {4{waddr1}};
                        `pe4_dec_0 = {4{wen1}};
                    end
                end
                else begin
                    `pe4_dic_0 = 0;
                    `pe4_dwc_0 = 0;
                    `pe4_dec_0 = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        `pe4_dic_1 = {E[0],E[1],E[2],E[3]};
                        `pe4_dwc_1 = {4{waddr0}};
                        `pe4_dec_1 = {4{wen0}};
                    end
                    else begin // brsel1 == 1
                        `pe4_dic_1 = {O[0],O[1],O[2],O[3]};
                        `pe4_dwc_1 = {4{waddr1}};
                        `pe4_dec_1 = {4{wen1}};
                    end
                end
                else begin
                    `pe4_dic_1 = 0;
                    `pe4_dwc_1 = 0;
                    `pe4_dec_1 = 0;
                end
            end
            3'd5: begin
                `pe4_dic_2 = {E[0],E[2],E[1],E[3],SUB[0],SUB[2],SUB[1],SUB[3]};
                `pe4_dwc_2 = {8{waddr0}};
                `pe4_dec_2 = {8{wen0}};
            end
            default: begin // 3'd6
                `pe4_dic_2 = {E[0],E[1],SUB[0],SUB[1],E[2],E[3],SUB[2],SUB[3]};
                `pe4_dwc_2 = {8{waddr0}};
                `pe4_dec_2 = {8{wen0}};
            end
            endcase
        end
        OP_PWM2: begin
            `pe4_drc_2 = {8{raddr0}};
            `pe4_dic_2 = {E[0],E[1],E[0],E[1],E[2],E[3],E[2],E[3]};
            `pe4_dwc_2 = {2{waddr1,waddr1,waddr0,waddr0}};
            `pe4_dec_2 = {2{wen1,wen1,wen0,wen0}};
        end
        OP_INTT: begin
            // ------------------------------------------------------ READ
            `pe4_drc_2 = {4{raddr0,raddr1}};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd0: begin
                `pe4_dic_2 = {E[0],E[2],E[1],E[3],O[0],O[2],O[1],O[3]};
                `pe4_dwc_2 = {{4{waddr0}},{4{waddr1}}};
                `pe4_dec_2 = {{4{wen0}},{4{wen1}}};
            end
            3'd6: begin
                `pe4_dic_2 = {E[0],O[0],E[1],O[1],E[2],O[2],E[3],O[3]};
                `pe4_dwc_2 = {4{waddr0,waddr1}};
                `pe4_dec_2 = {4{wen0,wen1}};
            end
            default: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        `pe4_dic_0 = {E[0],E[1],E[2],E[3]};
                        `pe4_dwc_0 = {4{waddr0}};
                        `pe4_dec_0 = {4{wen0}};
                    end
                    else begin // brsel0 == 1
                        `pe4_dic_0 = {O[0],O[1],O[2],O[3]};
                        `pe4_dwc_0 = {4{waddr1}};
                        `pe4_dec_0 = {4{wen1}};
                    end
                end
                else begin
                    `pe4_dic_0 = 0;
                    `pe4_dwc_0 = 0;
                    `pe4_dec_0 = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        `pe4_dic_1 = {E[0],E[1],E[2],E[3]};
                        `pe4_dwc_1 = {4{waddr0}};
                        `pe4_dec_1 = {4{wen0}};
                    end
                    else begin // brsel1 == 1
                        `pe4_dic_1 = {O[0],O[1],O[2],O[3]};
                        `pe4_dwc_1 = {4{waddr1}};
                        `pe4_dec_1 = {4{wen1}};
                    end
                end
                else begin
                    `pe4_dic_1 = 0;
                    `pe4_dwc_1 = 0;
                    `pe4_dec_1 = 0;
                end
            end
            endcase
        end
        OP_READ_DATA: begin
            `pe4_dic_2 = 0;
            `pe4_dwc_2 = 0;
            `pe4_drc_2 = (read_ab == 1'b0) ? {8{op_out_a,do_cntr[L:1]}} : {8{op_out_b,do_cntr[L:1]}};
            `pe4_dec_2 = 0;
        end
        default: begin
            `pe4_dic_2 = 0;
            `pe4_dwc_2 = 0;
            `pe4_drc_2 = 0;
            `pe4_dec_2 = 0;
        end
        endcase
    end

end
else begin : G_DP_PE16

    always @(*) begin
        case(curr_state)
        OP_LOAD_DATA: begin
            `pe16_dic_2 = (load_type == 1'd0) ? load_f_pack : {din,din};
            `pe16_dwc_2 = (load_type == 1'd0) ? {32{1'b0,di_cntr[L-1:0]}} : {32{1'b1,di_cntr[L:1]}};
            `pe16_drc_2 = 0;
            `pe16_dec_2 = (load_type == 1'd0) ? {16{~di_cntr[L],di_cntr[L]}} : {{16{~di_cntr[0]}},{16{di_cntr[0]}}};
        end
        OP_FNTT: begin
            // ------------------------------------------------------ READ
            `pe16_drc_2 = {16{raddr0,raddr1}};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd0,3'd1,3'd2: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        `pe16_dic_0 = {E[0],E[1],E[2],E[3],E[4],E[5],E[6],E[7],E[8],E[9],E[10],E[11],E[12],E[13],E[14],E[15]};
                        `pe16_dwc_0 = {16{waddr0}};
                        `pe16_dec_0 = {16{wen0}};
                    end
                    else begin // brsel0 == 1
                        `pe16_dic_0 = {O[0],O[1],O[2],O[3],O[4],O[5],O[6],O[7],O[8],O[9],O[10],O[11],O[12],O[13],O[14],O[15]};
                        `pe16_dwc_0 = {16{waddr1}};
                        `pe16_dec_0 = {16{wen1}};
                    end
                end
                else begin
                    `pe16_dic_0 = 0;
                    `pe16_dwc_0 = 0;
                    `pe16_dec_0 = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        `pe16_dic_1 = {E[0],E[1],E[2],E[3],E[4],E[5],E[6],E[7],E[8],E[9],E[10],E[11],E[12],E[13],E[14],E[15]};
                        `pe16_dwc_1 = {16{waddr0}};
                        `pe16_dec_1 = {16{wen0}};
                    end
                    else begin // brsel1 == 1
                        `pe16_dic_1 = {O[0],O[1],O[2],O[3],O[4],O[5],O[6],O[7],O[8],O[9],O[10],O[11],O[12],O[13],O[14],O[15]};
                        `pe16_dwc_1 = {16{waddr1}};
                        `pe16_dec_1 = {16{wen1}};
                    end
                end
                else begin
                    `pe16_dic_1 = 0;
                    `pe16_dwc_1 = 0;
                    `pe16_dec_1 = 0;
                end
            end
            3'd3: begin
                `pe16_dic_2 = {E[0],E[8],E[1],E[9],E[2],E[10],E[3],E[11],E[4],E[12],E[5],E[13],E[6],E[14],E[7],E[15],
                               SUB[0],SUB[8],SUB[1],SUB[9],SUB[2],SUB[10],SUB[3],SUB[11],SUB[4],SUB[12],SUB[5],SUB[13],SUB[6],SUB[14],SUB[7],SUB[15]};
                `pe16_dwc_2 = {32{waddr0}};
                `pe16_dec_2 = {32{wen0}};
            end
            3'd4: begin
                `pe16_dic_2 = {E[0],E[4],E[1],E[5],E[2],E[6],E[3],E[7],SUB[0],SUB[4],SUB[1],SUB[5],SUB[2],SUB[6],SUB[3],SUB[7],
                               E[8],E[12],E[9],E[13],E[10],E[14],E[11],E[15],SUB[8],SUB[12],SUB[9],SUB[13],SUB[10],SUB[14],SUB[11],SUB[15]};
                `pe16_dwc_2 = {32{waddr0}};
                `pe16_dec_2 = {32{wen0}};
            end
            3'd5: begin
                `pe16_dic_2 = {E[0],E[2],E[1],E[3],SUB[0],SUB[2],SUB[1],SUB[3],E[4],E[6],E[5],E[7],SUB[4],SUB[6],SUB[5],SUB[7],
                               E[8],E[10],E[9],E[11],SUB[8],SUB[10],SUB[9],SUB[11],E[12],E[14],E[13],E[15],SUB[12],SUB[14],SUB[13],SUB[15]};
                `pe16_dwc_2 = {32{waddr0}};
                `pe16_dec_2 = {32{wen0}};
            end
            default: begin // 3'd6
                `pe16_dic_2 = {E[0],E[1],SUB[0],SUB[1],E[2],E[3],SUB[2],SUB[3],E[4],E[5],SUB[4],SUB[5],E[6],E[7],SUB[6],SUB[7],
                               E[8],E[9],SUB[8],SUB[9],E[10],E[11],SUB[10],SUB[11],E[12],E[13],SUB[12],SUB[13],E[14],E[15],SUB[14],SUB[15]};
                `pe16_dwc_2 = {32{waddr0}};
                `pe16_dec_2 = {32{wen0}};
            end
            endcase
        end
        OP_PWM2: begin
            `pe16_drc_2 = {32{raddr0}};
            `pe16_dic_2 = {E[0],E[1],E[0],E[1],E[2],E[3],E[2],E[3],E[4],E[5],E[4],E[5],E[6],E[7],E[6],E[7],
                           E[8],E[9],E[8],E[9],E[10],E[11],E[10],E[11],E[12],E[13],E[12],E[13],E[14],E[15],E[14],E[15]};
            `pe16_dwc_2 = {8{waddr1,waddr1,waddr0,waddr0}};
            `pe16_dec_2 = {8{wen1,wen1,wen0,wen0}};
        end
        OP_INTT: begin
            // ------------------------------------------------------ READ
            `pe16_drc_2 = {16{raddr0,raddr1}};
            // ------------------------------------------------------ WRITE
            case(stage_count)
            3'd0: begin
                `pe16_dic_2 = {E[0],E[2],E[1],E[3],O[0],O[2],O[1],O[3],E[4],E[6],E[5],E[7],O[4],O[6],O[5],O[7],
                               E[8],E[10],E[9],E[11],O[8],O[10],O[9],O[11],E[12],E[14],E[13],E[15],O[12],O[14],O[13],O[15]};
                `pe16_dwc_2 = {4{{4{waddr0}},{4{waddr1}}}};
                `pe16_dec_2 = {4{{4{wen0}},{4{wen1}}}};
            end
            3'd1: begin
                `pe16_dic_2 = {E[0],E[4],E[1],E[5],E[2],E[6],E[3],E[7],O[0],O[4],O[1],O[5],O[2],O[6],O[3],O[7],
                               E[8],E[12],E[9],E[13],E[10],E[14],E[11],E[15],O[8],O[12],O[9],O[13],O[10],O[14],O[11],O[15]};
                `pe16_dwc_2 = {2{{8{waddr0}},{8{waddr1}}}};
                `pe16_dec_2 = {2{{8{wen0}},{8{wen1}}}};
            end
            3'd2: begin
                `pe16_dic_2 = {E[0],E[8],E[1],E[9],E[2],E[10],E[3],E[11],E[4],E[12],E[5],E[13],E[6],E[14],E[7],E[15],
                               O[0],O[8],O[1],O[9],O[2],O[10],O[3],O[11],O[4],O[12],O[5],O[13],O[6],O[14],O[7],O[15]};
                `pe16_dwc_2 = {{16{waddr0}},{16{waddr1}}};
                `pe16_dec_2 = {{16{wen0}},{16{wen1}}};
            end
            3'd6: begin
                `pe16_dic_2 = {E[0],O[0],E[1],O[1],E[2],O[2],E[3],O[3],E[4],O[4],E[5],O[5],E[6],O[6],E[7],O[7],
                               E[8],O[8],E[9],O[9],E[10],O[10],E[11],O[11],E[12],O[12],E[13],O[13],E[14],O[14],E[15],O[15]};
                `pe16_dwc_2 = {16{waddr0,waddr1}};
                `pe16_dec_2 = {16{wen0,wen1}};
            end
            default: begin
                if(brselen0) begin
                    if(brsel0 == 1'd0) begin
                        `pe16_dic_0 = {E[0],E[1],E[2],E[3],E[4],E[5],E[6],E[7],E[8],E[9],E[10],E[11],E[12],E[13],E[14],E[15]};
                        `pe16_dwc_0 = {16{waddr0}};
                        `pe16_dec_0 = {16{wen0}};
                    end
                    else begin // brsel0 == 1
                        `pe16_dic_0 = {O[0],O[1],O[2],O[3],O[4],O[5],O[6],O[7],O[8],O[9],O[10],O[11],O[12],O[13],O[14],O[15]};
                        `pe16_dwc_0 = {16{waddr1}};
                        `pe16_dec_0 = {16{wen1}};
                    end
                end
                else begin
                    `pe16_dic_0 = 0;
                    `pe16_dwc_0 = 0;
                    `pe16_dec_0 = 0;
                end

                if(brselen1) begin
                    if(brsel1 == 1'd0) begin
                        `pe16_dic_1 = {E[0],E[1],E[2],E[3],E[4],E[5],E[6],E[7],E[8],E[9],E[10],E[11],E[12],E[13],E[14],E[15]};
                        `pe16_dwc_1 = {16{waddr0}};
                        `pe16_dec_1 = {16{wen0}};
                    end
                    else begin // brsel1 == 1
                        `pe16_dic_1 = {O[0],O[1],O[2],O[3],O[4],O[5],O[6],O[7],O[8],O[9],O[10],O[11],O[12],O[13],O[14],O[15]};
                        `pe16_dwc_1 = {16{waddr1}};
                        `pe16_dec_1 = {16{wen1}};
                    end
                end
                else begin
                    `pe16_dic_1 = 0;
                    `pe16_dwc_1 = 0;
                    `pe16_dec_1 = 0;
                end
            end
            endcase
        end
        OP_READ_DATA: begin
            `pe16_dic_2 = 0;
            `pe16_dwc_2 = 0;
            `pe16_drc_2 = (read_ab == 1'b0) ? {32{op_out_a,do_cntr[L:1]}} : {32{op_out_b,do_cntr[L:1]}};
            `pe16_dec_2 = 0;
        end
        default: begin
            `pe16_dic_2 = 0;
            `pe16_dwc_2 = 0;
            `pe16_drc_2 = 0;
            `pe16_dec_2 = 0;
        end
        endcase
    end

end
endgenerate

// ===========================================================================
// brams：bank A / bank B 的连线
//
// 上游是 8 条（pe4/16）或 2 条（pe1）整段拼接。这里换成 generate 循环按 bank
// 逐根连 —— PE_NUMBER=1 时自然退化成 pe1 那两条。内容逐项相同。
// 唯一的差别是 dr1 的源（drb_src），已在上面按配置选好。
// ===========================================================================

generate
    genvar bg;
    for (bg = 0; bg < 2*PE_NUMBER; bg = bg + 1) begin : G_BRAM_WIRE
        always @(*) begin
            // bank A
            dr0[bg] = dr2[bg];
            dw0[bg] = dw2[bg];
            di0[bg] = di2[bg];
            de0[bg] = (load_ab || read_ab || exec_ab) ? 1'b0 : de2[bg];
            // bank B
            dr1[bg] = (curr_state == OP_PWM2) ? {1'b1, drb_src} : dr2[bg];
            dw1[bg] = dw2[bg];
            di1[bg] = di2[bg];
            de1[bg] = (load_ab || read_ab || exec_ab) ? de2[bg] : 1'b0;
        end
    end
endgenerate

// ===========================================================================
// ntt unit
//
// OP_FNTT/OP_INTT 那一段三档一致（W 的下标写成 PE_NUMBER-1-ntt_loop 即可，
// PE=1 时就是 to 本身），所以只有 OP_PWM2 那一张表要分支：
//   pe1     —— 用 c_loop_pwm[0] 在 do?[0] / do?[1] 之间选
//   pe4/16  —— 用 stage_count_pwm 0..4 按 PE 下标 2*i / 2*i+1 切片
// ===========================================================================

integer ntt_loop = 0;

generate
if (PE_NUMBER == 1) begin : G_NTT_PE1

    always @(posedge clk or posedge reset) begin
        for(ntt_loop = 0; ntt_loop<PE_NUMBER; ntt_loop=ntt_loop+1) begin
            if(reset) begin
                A[ntt_loop]   <= 0;
                B[ntt_loop]   <= 0;
                W[ntt_loop]   <= 0;
                CT[ntt_loop]  <= 0;
                PWM[ntt_loop] <= 0;
            end
            else begin
                case(curr_state)
                OP_FNTT,OP_INTT: begin
                    A[ntt_loop]   <= (exec_ab == 1'b0) ? do0[2*ntt_loop+0] : do1[2*ntt_loop+0];
                    B[ntt_loop]   <= (exec_ab == 1'b0) ? do0[2*ntt_loop+1] : do1[2*ntt_loop+1];
                    W[ntt_loop]   <= to[12*(PE_NUMBER-1-ntt_loop)+:12];
                    CT[ntt_loop]  <= c_ct;
                    PWM[ntt_loop] <= c_pwm;
                end
                OP_PWM2: begin
                    case(stage_count_pwm)
                    3'd0: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do0[0] : do0[1];
                        W[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do1[0] : do1[1];
                    end
                    3'd1: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do0[0] : do0[1];
                        W[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do1[0] : do1[1];
                    end
                    3'd2: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do0[0] : do0[1];
                        W[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do1[0] : do1[1];
                    end
                    3'd3: begin
                        A[ntt_loop] <= MUL[ntt_loop];
                        B[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do0[0] : do0[1];
                        W[ntt_loop] <= (c_loop_pwm[0]==1'b0) ? do1[0] : do1[1];
                    end
                    3'd4: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= MUL[ntt_loop];
                        W[ntt_loop] <= to[12*(PE_NUMBER-1-ntt_loop)+:12];
                    end
                    default: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= 0;
                        W[ntt_loop] <= 0;
                    end
                    endcase
                    CT[ntt_loop]  <= c_ct;
                    PWM[ntt_loop] <= c_pwm;
                end
                default: begin
                    A[ntt_loop]   <= A[ntt_loop];
                    B[ntt_loop]   <= B[ntt_loop];
                    W[ntt_loop]   <= W[ntt_loop];
                    CT[ntt_loop]  <= CT[ntt_loop];
                    PWM[ntt_loop] <= PWM[ntt_loop];
                end
                endcase
            end
        end
    end

end
else begin : G_NTT_WIDE

    always @(posedge clk or posedge reset) begin
        for(ntt_loop = 0; ntt_loop<PE_NUMBER; ntt_loop=ntt_loop+1) begin
            if(reset) begin
                A[ntt_loop]   <= 0;
                B[ntt_loop]   <= 0;
                W[ntt_loop]   <= 0;
                CT[ntt_loop]  <= 0;
                PWM[ntt_loop] <= 0;
            end
            else begin
                case(curr_state)
                OP_FNTT,OP_INTT: begin
                    A[ntt_loop]   <= (exec_ab == 1'b0) ? do0[2*ntt_loop+0] : do1[2*ntt_loop+0];
                    B[ntt_loop]   <= (exec_ab == 1'b0) ? do0[2*ntt_loop+1] : do1[2*ntt_loop+1];
                    W[ntt_loop]   <= to[12*(PE_NUMBER-1-ntt_loop)+:12];
                    CT[ntt_loop]  <= c_ct;
                    PWM[ntt_loop] <= c_pwm;
                end
                OP_PWM2: begin
                    case(stage_count_pwm)
                    3'd0: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= do0[2*ntt_loop+1];
                        W[ntt_loop] <= do1[2*ntt_loop+0];
                    end
                    3'd1: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= do0[2*ntt_loop+1];
                        W[ntt_loop] <= do1[2*ntt_loop+1];
                    end
                    3'd2: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= do0[2*ntt_loop+0];
                        W[ntt_loop] <= do1[2*ntt_loop+0];
                    end
                    3'd3: begin
                        A[ntt_loop] <= MUL[ntt_loop];
                        B[ntt_loop] <= do0[2*ntt_loop+0];
                        W[ntt_loop] <= do1[2*ntt_loop+1];
                    end
                    3'd4: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= MUL[ntt_loop];
                        W[ntt_loop] <= to[12*(PE_NUMBER-1-ntt_loop)+:12];
                    end
                    default: begin
                        A[ntt_loop] <= 0;
                        B[ntt_loop] <= 0;
                        W[ntt_loop] <= 0;
                    end
                    endcase
                    CT[ntt_loop]  <= c_ct;
                    PWM[ntt_loop] <= c_pwm;
                end
                default: begin
                    A[ntt_loop]   <= A[ntt_loop];
                    B[ntt_loop]   <= B[ntt_loop];
                    W[ntt_loop]   <= W[ntt_loop];
                    CT[ntt_loop]  <= CT[ntt_loop];
                    PWM[ntt_loop] <= PWM[ntt_loop];
                end
                endcase
            end
        end
    end

end
endgenerate

// ---------------------------------------------------------------- done

always @(posedge clk or posedge reset) begin
    if(reset)
        done <= 0;
    else begin
        case(curr_state)
        OP_FNTT: done <= (op_cntr == (FNTT_CC-1'b1)) ? 1'b1 : 1'b0;
        OP_INTT: done <= (op_cntr == (INTT_CC-1'b1)) ? 1'b1 : 1'b0;
        OP_PWM2: done <= (op_cntr == (PWM2_CC-1'b1)) ? 1'b1 : 1'b0;
        default: done <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------- dout
//
// 上游三档写的是三种不同长度的拼接：
//   pe1  {do0[0]} / {do0[1]}
//   pe4  {do0[0..3]} / {do0[4..7]}
//   pe16 {do0[0..15]} / {do0[16..31]}
// 其实同一条规则：do_cntr[0]==1 取 bank 的低半，否则取高半。用 generate 拼出
// 四个打包线，就三档通用了（PE=1 时退化成 {do0[0]} / {do0[1]}）。

wire [12*PE_NUMBER-1:0] do0_hi, do0_lo, do1_hi, do1_lo;

generate
    genvar dg;
    for (dg = 0; dg < PE_NUMBER; dg = dg + 1) begin : G_DOUT_PACK
        assign do0_hi[12*(PE_NUMBER-1-dg) +: 12] = do0[dg];
        assign do0_lo[12*(PE_NUMBER-1-dg) +: 12] = do0[PE_NUMBER+dg];
        assign do1_hi[12*(PE_NUMBER-1-dg) +: 12] = do1[dg];
        assign do1_lo[12*(PE_NUMBER-1-dg) +: 12] = do1[PE_NUMBER+dg];
    end
endgenerate

always @(posedge clk or posedge reset) begin
    if(reset) begin
        dout <= 0;
    end
    else begin
        if(curr_state == OP_READ_DATA) begin
            if(do_cntr > DO_ZERO)
                dout <= (do_cntr[0] == 1'd1) ? ((read_ab == 1'd0) ? do0_hi : do1_hi)
                                             : ((read_ab == 1'd0) ? do0_lo : do1_lo);
        end
        else begin
            dout <= 0;
        end
    end
end

// ---------------------------------------------------------------- CONTROL UNIT
//
// 改命名连接（上游三档都是位置连接，且 pe1 比另两档多两个输出）。
// 参数化后的 AG 三档端口一致，所以这里不用分支。

ntt_addressgenerator #(.L(L), .TW_ADDR_W(TW_ADDR_W)) ag (
    .clk(clk), .reset(reset),
    .start_fntt(start_fntt), .start_pwm2(start_pwm2), .start_intt(start_intt),
    .ct(c_ct), .pwm(c_pwm),
    .raddr0(raddr0), .raddr1(raddr1),
    .waddr0(waddr0), .waddr1(waddr1),
    .wen0(wen0),     .wen1(wen1),
    .brsel0(brsel0), .brsel1(brsel1),
    .brselen0(brselen0), .brselen1(brselen1),
    .stage_count(stage_count), .stage_count_pwm(stage_count_pwm),
    .c_loop_pwm(c_loop_pwm), .raddr_b(raddr_b),
    .raddr_tw(raddr_tw)
);

// ---------------------------------------------------------------- BRAMs
//
// PE_NUMBER=1 时这个循环正好退化成上游 pe1 显式写的那 4 个（bd00/bd01/bd10/bd11）。

generate
	genvar k;

    for(k=0; k<PE_NUMBER ;k=k+1) begin: BRAM1_GEN_BLOCK
        ntt_BRAM #(.ADDR_W(L+1)) bd00(clk,de0[2*k+0],dw0[2*k+0],di0[2*k+0],dr0[2*k+0],do0[2*k+0]);
        ntt_BRAM #(.ADDR_W(L+1)) bd01(clk,de0[2*k+1],dw0[2*k+1],di0[2*k+1],dr0[2*k+1],do0[2*k+1]);
    end
endgenerate

generate
	genvar j;

    for(j=0; j<PE_NUMBER ;j=j+1) begin: BRAM2_GEN_BLOCK
        ntt_BRAM #(.ADDR_W(L+1)) bd10(clk,de1[2*j+0],dw1[2*j+0],di1[2*j+0],dr1[2*j+0],do1[2*j+0]);
        ntt_BRAM #(.ADDR_W(L+1)) bd11(clk,de1[2*j+1],dw1[2*j+1],di1[2*j+1],dr1[2*j+1],do1[2*j+1]);
    end
endgenerate

// ---------------------------------------------------------------- BROMs

// ⚠️ 参数必须显式传：BROM 的 PE_NUMBER 决定表内容与 dout 宽度（三档的表**不同**，
//    不是同一张表的切片 —— 证据在 tools/check_brom.py 的 EVIDENCE 段）。
ntt_BROM #(.PE_NUMBER(PE_NUMBER), .TW_ADDR_W(TW_ADDR_W)) bt00(clk,tr,to);

// ---------------------------------------------------------------- BUTTERFLY UNIT

generate
	genvar m;

    for(m=0; m<PE_NUMBER ;m=m+1) begin: BTF_GEN_BLOCK
        ntt_butterfly btfu(clk,reset,
                           CT[m],
                           PWM[m],
		                   A[m],B[m],W[m],
			               E[m],O[m],
			               MUL[m],
			               ADD[m],SUB[m]);
    end
endgenerate

// ----------------------------------------------------------------

endmodule
