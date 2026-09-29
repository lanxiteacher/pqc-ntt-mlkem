// ===========================================================================
// KyberHPMNTT_top.v —— 固定 12 位接口的顶层（核外序列化）
//
// 干什么：把「一拍 PE_NUMBER 个系数」的宽接口核，包成**三档对外完全一样**的
//         12 位串行口。pe16 的 din/dout 本来是 192+192 位（396 个引脚），
//         包完之后三档都只有 12 位 —— 引脚预算只跟这一个口打交道。
//
// 层次（设计文档 §4.3）：
//     外部 din[11:0] / dout[11:0]
//       → 输入寄存级（与上游 _top 相同）
//       → 序列化器：攒够 PE_NUMBER 个系数，再让核吃一拍宽的
//       → 核 KyberHPMNTT（宽接口，**一行没改**）
//       → 反序列化器：核的一拍宽结果，拆成 PE_NUMBER 拍 12 位
//       → 输出寄存级（与上游 _top 相同）
//
// 为什么核一行不用改：核的「一拍」要占 PE_NUMBER 个系数，而外部一拍只给一个。
//   解法不是改 FSM，而是**把核的时钟按 1/PE 门控**（见下方 clk_core）——
//   对核来说只是「拍与拍之间隔了 PE 个外部周期」，每拍的行为完全不变。
//   ⚠️ 不能只门控 FSM 而让 butterfly/BRAM 继续跑：butterfly 是 6 级流水
//      （Ar0/Ar1 → w2r0/w3r0 → w2r1/w2r2 → Wr0 → w5r0 → w6r0），
//      流水被打散后 E/O 会整体错位。必须**整核一起冻结**。
//
// ---------------------------------------------------------------------------
// 节拍（下标 P = 主机改动 load_*/read_* 的那一拍，也就是信号被采到的前一拍）
//
// 相位机由**寄存后**的 load_R / read_R 触发，于是：
//   相位起点（sub=0）落在 posedge P+2 上，相位第 j 拍就是「sub=j」那一拍。
// 核的时钟使能取 **sub 模 PE_NUMBER 等于 PE_NUMBER-1** 那一拍，于是
//   装载：第 k 个宽拍（系数 k*PE .. k*PE+PE-1）在 posedge P+2+(k+1)*PE 被吃
//   读出：第 k 个宽结果在 posedge P+2+(k+1)*PE + 1 起挂在 dout_core 上
//
// ⚠️ 使能为什么不是 sub 模 PE == 0：FSM 在 posedge P+2 才进 OP_LOAD_DATA，
//    紧跟着的那拍核还没来得及收满一拍数据。整拍序列要往后挪 PE-1 拍。
//    挪完之后第 k 拍要的那 PE 个系数刚好全部到齐 —— 一个不多一个不少。
//
// 三条对外的时间（相对 P）：
//   done             start_* 之后 CC+3 拍（与折叠度**无关**，CC 见表）
//   第一条有效 dout   read_* 之后 2*PE_NUMBER+3 拍  ← **随折叠度变**
//   有效 dout 长度    连续 256 拍（第 257 拍是核越界回卷，丢掉）
//   相位长度          装载 256+PE 拍｜读出 256+3*PE 拍（都从 posedge P+2 起算）
//
// ★ PE_NUMBER == 1 时：使能恒 1、rsub 恒 0、序列化退化成 din 延迟一拍 ——
//   整个模块与上游 KyberHPM1PE_top **逐拍一致**（探针 ⑧ 实测 3358 拍全等）。
//
// ===========================================================================
// ⚠️ 已知未达标：**读出顺序三档并不统一**（拿到黄金锚之后才看见的）
//
// 「固定 12 位接口」这条判据，**端口/位宽/周期数都已成立**，但
// **值序列一致**只在一部分读数路上成立。探针 ⑨ 用 `refsim/batch/ntt_batch_exp.txt`
// 第 0 组（FIPS 203 KAT 校验过的参考实现算出来的 FNTT 结果）当外部锚，实测：
//
//   装载 A → FNTT A → 读 A          pe1 = 交织 0,2,1,3    pe4/pe16 = 自然序
//   装载 B → FNTT B → PWM2 A → 读 A  三档逐位相同（与探针 ⑧ 一致）
//
// 也就是说 ⑧ 那个「三档逐位相同」只覆盖了 PWM2 后的读数路，**不能外推**。
//
// 这不是本次参数化引入的 —— 「交织」是**上游 pe1 自己的约定**：
//   `refsim/pe1/fntt_batch_tb.v` 第 75 行按**自然序**灌数、第 113-117 行读回时
//   写成 `fout[4m+0], fout[4m+2], fout[4m+1], fout[4m+3]`，靠这步反交织才对得上
//   FIPS 203 黄金向量；`pwm2_batch_tb.v` / `intt_batch_tb.v` 的文件头也写明
//   FNTT/PWM2 进出都是交织、**INTT 输出是自然序**。
//   本模块的核与上游逐拍等价（探针 ⑦），所以这个约定被原样继承。
//
// ⚠️ 所以现在**不能**说「三档 dout 序列逐位相同」。要让这句话成立，
//    得在本模块里按操作 + 折叠度做一次反交织 —— 那是 Task 6 的事
//    （需要先把 PWM2 / INTT 两条路在三档上各自的读出约定都量出来）。
//    在此之前，host 侧按什么顺序收发，见 rtl/H1_port_spec.md §五。
// ===========================================================================
//
// ⚠️ 「接口一致」= 端口一致 + 值序列一致，**不包括延迟一致**。核自己的读出延迟固定，
//    但使能每 PE 拍才来一次，第一拍宽结果最早也要等 PE 拍才凑齐，此前没有数据可拆。
//    硬要三档都 read+5 吐第一个值，只能吐出假的。
//    ⚠️ rtl/folding_param_plan.md 的 Task 4 写「第一条有效 dout 在 read+5（三档都是）」，
//       这句**只对 pe1 成立**，别照抄。
//
// ⚠️ 慢跑相位里使能是间断的，落在使能之间的单拍脉冲会被丢掉。
//    协议是「连续灌满 256 拍之后，再脉冲 start_*」，那会儿慢跑已经结束、
//    使能恒 1，所以正常流程不受影响。host 要照 rtl/H1_port_spec.md §四 做。
// ===========================================================================

`timescale 1ns/1ps

module KyberHPMNTT_top #(
    parameter PE_NUMBER = 1        // 折叠度：1 / 4 / 16，其余值非法
)(
    input                      clk,
    input                      reset,        // 异步**高**有效（与上游一致）
    input                      load_a_f, load_a_i,
    input                      load_b_f, load_b_i,
    input                      read_a, read_b,
    input                      start_ab,
    input                      start_fntt, start_pwm2, start_intt,
    input      [11:0]          din,
    output reg [11:0]          dout,
    output reg                 done
);

localparam integer LOAD_EXT = 256 +     PE_NUMBER;    // 装载相位的外部拍数
localparam integer READ_EXT = 256 + 3 * PE_NUMBER;    // 读出相位的外部拍数

// 非法 PE_NUMBER 守卫。与核同规矩：只认 1 / 4 / 16。
// （不用「是 2 的幂」来判 —— PE=8 能过那个判据，然后静默落进 pe16 的分支。）
initial begin
    if ((PE_NUMBER != 1) && (PE_NUMBER != 4) && (PE_NUMBER != 16)) begin
        $display("FATAL: PE_NUMBER=%0d 非法 —— 只支持 1 / 4 / 16。", PE_NUMBER);
        $finish;
    end
end

// ===========================================================================
// 输入寄存级
//
// 控制信号与上游 _top 逐行相同。din 不进这一级 —— 序列化器 sr 就是它的寄存器
// （sr 每拍把**原始 din** 压进来，延迟正好一拍，与上游的 din_R 等价）。
// ===========================================================================

reg lf_R, li_R, bf_R, bi_R;
reg ra_R, rb_R, sab_R;
reg sf_R, sp_R, si_R;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        lf_R <= 0; li_R <= 0; bf_R <= 0; bi_R <= 0;
        ra_R <= 0; rb_R <= 0; sab_R <= 0;
        sf_R <= 0; sp_R <= 0; si_R <= 0;
        dout  <= 0;
        done  <= 0;
    end
    else begin
        lf_R <= load_a_f;   li_R <= load_a_i;
        bf_R <= load_b_f;   bi_R <= load_b_i;
        ra_R <= read_a;     rb_R <= read_b;
        sab_R <= start_ab;
        sf_R <= start_fntt; sp_R <= start_pwm2; si_R <= start_intt;
        dout  <= dout_sel;
        done  <= done_core;
    end
end

// ===========================================================================
// 慢跑相位机
// ===========================================================================

wire req_load = lf_R | li_R | bf_R | bi_R;    // 用**寄存后**的，见文件头
wire req_read = ra_R | rb_R;

reg        slow, slow_rd;
reg [9:0]  sub;      // 相位内的拍数，0..READ_EXT-1（pe16 最大 303）
reg [3:0]  rsub;     // sub 对 PE_NUMBER 取模，0..PE_NUMBER-1

wire phase_last = slow_rd ? (sub == READ_EXT-1) : (sub == LOAD_EXT-1);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        slow <= 1'b0; slow_rd <= 1'b0; sub <= 10'd0; rsub <= 4'd0;
    end
    else if (!slow) begin
        if (req_load) begin
            slow <= 1'b1; slow_rd <= 1'b0; sub <= 10'd0; rsub <= 4'd0;
        end
        else if (req_read) begin
            slow <= 1'b1; slow_rd <= 1'b1; sub <= 10'd0; rsub <= 4'd0;
        end
    end
    else begin
        sub  <= sub + 10'd1;
        rsub <= (rsub == PE_NUMBER-1) ? 4'd0 : (rsub + 4'd1);
        if (phase_last) slow <= 1'b0;
    end
end

// 核的时钟使能：慢跑期间落在 sub 模 PE_NUMBER == PE_NUMBER-1 那一拍；其余时间恒 1。
// PE_NUMBER == 1 时 rsub 恒 0，于是使能恒 1。
wire ce = slow ? (rsub == PE_NUMBER-1) : 1'b1;

// ===========================================================================
// 核的时钟门控
//
// ICG（集成时钟门控单元）的 RTL 写法：使能在 clk 低电平期间被锁存，
// 所以 clk_core 的上升沿只在使能已经稳定的那些拍出现，不会有毛刺。
// 直接写 clk & ce 会有问题：ce 由 clk 上升沿驱动的寄存器算出，同一时刻
// clk & ce 先因 clk 变高而抬起、再因 ce 落定而落下，仿真里会出现一个假的
// 窄脉冲，核会多跑一拍。
// ===========================================================================

reg ce_lat;
always @(*) if (!clk) ce_lat = ce;

wire clk_core = clk & ce_lat;

// ===========================================================================
// 序列化器：外部一拍一个系数 → 攒 PE_NUMBER 个 → 核一拍吃宽的
//
// sr 比一拍宽数据多留 12 位，好让「每拍压一位进最低切片」这一个写法对
// PE_NUMBER == 1 也成立（PE=1 时它就是 `sr <= din`，即 din 延迟一拍）。
//
// 切片方向由装载窗口倒推（H1_port_spec.md §五 实测同结论）：
//   核吃第 k 拍的那一刻，sr 的低 12*PE 位里正好是
//   d[P+2+k*PE] .. d[P+1+(k+1)*PE]（d[i] = 第 i 拍采到的 din）
//   其中 d[P+2+k*PE + j] 落在**从低位数第 PE_NUMBER-1-j 个**切片上
//   —— 即「最高切片 = 本拍最低下标」。
// ===========================================================================

reg [12*PE_NUMBER+11:0] sr;

always @(posedge clk or posedge reset) begin
    if (reset) sr <= {12*PE_NUMBER+12{1'b0}};
    else       sr <= {sr[12*PE_NUMBER-1:0], din};
end

wire [12*PE_NUMBER-1:0] din_core = sr[12*PE_NUMBER-1:0];

// ===========================================================================
// 反序列化器：核的一拍宽结果 → 外部一拍一个系数
//
// 第 k 个宽结果挂在 dout_core 上，每个宽结果在 dout_core 上停 PE 拍，
// 这 PE 拍里 rsub 依次取 0,1,...,PE-1。要在这 PE 拍里把组内 PE 个系数
// 按**下标从小到大**吐出去，而组内第 j 个系数在**从低位数第 PE-1-j 个**切片上
// （H1_port_spec.md §五 实测：最高切片 = 本拍最低下标）。于是
//   rsub=r 那一拍吐的是组内第 r 个 → 取从低位数第 PE-1-r 个切片
//
// ⚠️ 这条一开始写成了「rsub=0 取切片 0，否则取切片 PE_NUMBER-rsub」，
//    吐出来的组内顺序成了 0,3,2,1（pe4）—— 三档 dout 序列**逐位相同**这条
//    立刻不成立。因为最高切片才是最低下标，所以切片号要**倒着**走。
// ===========================================================================

wire [3:0]  dsel     = PE_NUMBER - 1 - rsub;
wire [11:0] dout_sel = dout_core[12*dsel +: 12];

// ===========================================================================
// 核
//
// 控制信号**原样直通**（就是上面那一级寄存器的输出），相位机只管使能。
// 不把控制信号按相位门控，有三个理由：
//   1. 上游 _top 就是直通的 —— pe1 要逐拍一致，结构就得一样；
//   2. 核的 OP_IDLE 只在**状态回到 IDLE 之后**才认 load/read，一拍宽的脉冲本来就够
//      （load_* 进 OP_LOAD_DATA 后一直待到装载完，不靠信号持续为高）；
//   3. 读 bank B 靠 read_b 在**核处于 OP_READ_DATA 期间**持续为高
//      （见 core_equiv_tb.v 里那条注记），按相位切成单拍反而把这条路切断。
//
// 代价（写进协议）：read_a/read_b 要按上游的握手法给，不能只给一拍 ——
//   折叠度越大，核待在 OP_READ_DATA 里的外部拍数越长，read_b 就得挂多久。
//   pe1 与上游完全同规矩；pe4/pe16 是折叠带来的必然结果。
//   ⚠️ 本探针（top_behavior_tb.v）只走 bank A，**没测** pe4/pe16 的 bank B 读出。
// ===========================================================================

wire [12*PE_NUMBER-1:0] dout_core;
wire                    done_core;

KyberHPMNTT #(.PE_NUMBER(PE_NUMBER)) u_core (
    .clk(clk_core), .reset(reset),
    .load_a_f(lf_R), .load_a_i(li_R),
    .load_b_f(bf_R), .load_b_i(bi_R),
    .read_a(ra_R),   .read_b(rb_R),
    .start_ab(sab_R),
    .start_fntt(sf_R),  .start_pwm2(sp_R), .start_intt(si_R),
    .din(din_core), .dout(dout_core), .done(done_core)
);

endmodule
