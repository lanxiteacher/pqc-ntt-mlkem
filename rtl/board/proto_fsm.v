// ===========================================================================
// proto_fsm.v —— 协议状态机（板子那一端的主控）
//
// 依据：host/proto.md（已冻结 v1.0）
//       §5.1 帧格式与事务时序  §5.2 命令表 / 应答表 / 错误码表
//       §5.4 校验（含四条细则）§5.5 超时表 / 五条关键规则 / 边界表
//       时序与端口依据 rtl/H1_port_spec.md §二（实测值）
//
// ---------------------------------------------------------------------------
// 一条事务的完整路径（以 #NTT 1 为例）
//
//   PC:  #NTT 1*7c ⏎
//   ───────────────────────────────────────────────────────────────
//   板:  S_IDLE  认行、校验、认命令、判参数
//   板:  S_RESP  发 "#OK NTT 1*58" ⏎        ← 必须**立刻**发，不能等数据
//   板:  S_DATA  收 256 行，每行 3 字符 → 12 位 → 写 poly_buf 的 A
//   板:  S_LOAD  256 拍连续 burst 进核（load_a_f 脉冲 + 无间隔 din）
//   板:  S_START 发 start_fntt，等 done（T_CORE 看门狗）
//   板:  S_READ  发 read_a，隔 READ_LAT 拍，连采 256 拍存回 poly_buf 的 A
//   板:  S_RESP  发 "#BEGIN NTT 1 256*0a" ⏎
//   板:  S_OUT   逐行发 256 个结果（3 字符 + LF）
//   板:  S_RESP  发 "#DONE NTT 1 256*4d" ⏎
//   回到 S_IDLE。
//
// ★ 为什么 #BEGIN 排在算完之后 —— §5.1 原文：
//     「#OK 的到达时间 = 板子「有没有在听」；#BEGIN 的到达时间 = 板子「算了多久」」
//   所以计算必须夹在 #OK 和 #BEGIN 中间，不能边算边发。
//
// ★ 结果为什么拐回 poly_buf —— 核的读出是一串**连续 256 拍**的流
//   （第 257 拍是越界回卷，必须丢，H1 §二）。而 UART 发一行要 1736 拍，
//   比这慢 4000 倍，接不住。所以只能先把 256 拍全部接进寄存器阵列，再慢慢发。
//   poly_buf 的 A 组此时已经没用了（数据早进核了），正好拿来当读出缓冲 ——
//   省一块 256×12 的 RAM，也不占引脚预算。
//   ⚠️ 读出**按物理顺序原样回传**，不做任何地址映射（§5.3.4 定的甲）：
//      电脑端知道自己发的是哪条命令，能推出该用哪张表。
//
// ---------------------------------------------------------------------------
// 三个超时（§5.5 表格，数值可配，测试台会调小）
//
//   T_LINE  数据段等一行：**从本行第一个字节起算**，收到每个字节都重置。
//           到时 → 丢弃本行、回 #ERR 05、回「找行首」状态（关键规则一）。
//   T_CMD   命令行：**字符间**超时（每收一个字符重置）。
//           到时 → 丢弃这半行、**静默**、不回任何行。
//           理由（§5.5 原文）：电脑此刻正在发命令、没在等应答；板子这时主动
//           回一行，在电脑看来是「归属不明的行」→ 按关键规则四停止整轮测试。
//           一次手抖把整批打断，而超时本来只是小事。
//   T_CORE  给了 start_* 之后等核的 done。到时回 #ERR 06。
//
// ⚠️ 「等命令行时」**不设超时**（§5.5 表格专门列了这一行，为的是不让两端各自猜）。
//    所以本模块的 T_CMD 计数器只在**本行已经收到过字节**之后才走 —— 见 cmd_active。
//    不这么写的话，空闲 10 秒后计数器到点会发一次 rx_clr；万一那一拍正好撞上
//    新命令的第一个字节，uart_line_rx 里 clr 的优先级高于 rx_done，**首字符会被丢掉**。
//
// ---------------------------------------------------------------------------
// 应答帧长什么样（§5.2 应答表 + 错误码表）
//   #OK    <原命令>              —— 回显是同步的第一道保险
//   #BEGIN <原命令> <count>      count = 即将发出的数据行数（计算类是 256）
//   #DONE  <原命令> <count>      同上
//   #ERR   <code> <位置>         「位置」填什么由错误码表逐条定死：
//        01 未知命令 → 0          02 参数非法 → 出错字段的序号
//        03 校验错   → `got=<实际> exp=<应有>`（整段就是位置栏，§5.2 例子）
//        04 数据行格式 → 第一个非法字符的位置
//        05 行数不足/超时 → 已收到的行数   06 板内错误 → 0   07 忙 → 0
//   ⚠️ 应答表里 `#ERR` 还有个第三栏「详情」，但协议**没有定义过任何一个值**，
//      唯一的具体例子（`#ERR 03 got=3f exp=a2*52`）里也没有它。
//      所以本实现不发详情，行就是 `#ERR <code> <位置>` —— 与那个例子逐字节一致。
//      要用详情得先跟 B 把内容写进协议。
//
// ⚠️ 没有数据段的命令（`#PING` / `#ABORT`）只回 `#OK`，**不发** `#BEGIN`/`#DONE`。
//    依据 §5.2 对 #ABORT 的写法（§5.5 关键规则二：「板子收到 #ABORT 后按 §5.2 的
//    通用规则**回显** #OK ABORT*..」）—— 两者都是「后面要跟 0 行数据」的命令。
//    这是本实现的一处**判断**，已列入待 B 确认项。
//
// ---------------------------------------------------------------------------
// 字节摆放约定（沿用仓库统一的那套，与 uart_line_rx / cmd_parse / tx_line 一致）：
//   所有字节串**右对齐**，从串首数第 i 个字节在 [ (len-1-i)*8 +: 8 ]，
//   **最后一个字节永远在 [7:0]**。
//
// ⚠️ 组合块里凡是要用变量做字节下标的地方，一律先算进一个 `integer` 再取切片。
//    写成 `vec[(a - 1 - b)*8 +: 8]`（a、b 都是窄位宽 reg）时，Verilog 的
//    自决定位宽规则会先按窄位宽算完减法再扩展 —— 值一大就静默截断，且不报错。
// ===========================================================================

`timescale 1ns/1ps

module proto_fsm #(
    parameter integer MAXLEN = 64,
    parameter integer MAXTX  = 48,

    // 超时（拍数 @50 MHz；测试台调小，否则一次仿真要跑 5 亿拍）
    parameter integer T_LINE_CC = 50_000_000,     // 1 s
    parameter integer T_CMD_CC  = 500_000_000,    // 10 s
    parameter integer T_CORE_CC =   5_000_000,    // 100 ms

    // read_a 之后隔几拍照第一个有效 dout。**这个默认值只对 pe1 成立。**
    //   ⚠️ 真实口径是 `2*PE_NUMBER + 3`，**随折叠度变**（pe1=5 / pe4=11 / pe16=35）。
    //      正常路径上不由这里定 —— `ntt_board_top` 按它自己的 PE_NUMBER 算出值
    //      再传进来（见该文件 READ_LAT 那条注释）。
    //      本默认值只是给「单独例化本模块」的场合留的，那时假定 pe1。
    //   H1 §二 的 pe1 实测是 5 拍；留成参数是为了能用测试台**扫**出来，
    //   不要凭算式定死 —— 见 tb/ 里的说明。
    parameter integer READ_LAT  = 5,

    // 折叠度。**只用来算 A→B 的 bank 切换间隔**（见 S_LOAD 里那段 ⚠️）。
    //   ⚠️ 别拿它去推 READ_LAT —— 那个由 ntt_board_top 算好传进来；
    //      两处各算各的，早晚不一致。这里要的量是「核的装载相位有多长」，
    //      即 `256 + PE_NUMBER` 拍（KyberHPMNTT_top.v:98 的 LOAD_EXT）。
    parameter integer PE_NUMBER = 1
)(
    input                     clk,
    input                     rst_n,          // 低有效（与 uart_rx/uart_tx 同规矩）

    // ------------------------- 行接收 -------------------------
    input                     rx_byte,        // 1 拍脉冲：收到一个字节（喂超时计时）
    input      [MAXLEN*8-1:0] line,           // 来自 uart_line_rx，右对齐
    input      [6:0]          line_len,
    input                     line_valid,     // 1 拍脉冲：收到一整行（非空）
    input                     line_over,      // 1 拍脉冲：本行超长，已丢弃
    output reg                rx_clr,         // → uart_line_rx：丢弃当前半行
    output reg [7:0]          rx_max_bytes,   // → uart_line_rx：本状态单行上限

    // ------------------------- 行发送 -------------------------
    output                    uart_tx_en,
    output     [7:0]          uart_tx_data,
    input                     uart_tx_busy,

    // ------------------------- poly_buf -------------------------
    output reg                pb_we,
    output reg                pb_sel_b,
    output reg [7:0]          pb_waddr,
    output reg [11:0]         pb_wdata,
    output reg [7:0]          pb_raddr,
    input      [11:0]         pb_a_rdata,
    input      [11:0]         pb_b_rdata,

    // ------------------------- 算法核 -------------------------
    output reg                core_load_a_f, core_load_a_i,
    output reg                core_load_b_f, core_load_b_i,
    output reg                core_read_a,   core_read_b,
    output reg                core_start_ab,
    output reg                core_start_fntt, core_start_pwm2, core_start_intt,
    output reg [11:0]         core_din,
    input      [11:0]         core_dout,
    input                     core_done,

    output reg [3:0]          dbg_state
);

    // =====================================================================
    // 0. 常量
    // =====================================================================
    // ---- 命令码（必须与 cmd_parse.v 一致）----
    localparam CMD_NONE  = 3'd0, CMD_PING = 3'd1, CMD_NTT = 3'd2,
               CMD_INTT  = 3'd3, CMD_PMUL = 3'd4, CMD_ABORT = 3'd5;
    localparam DOM_NONE  = 2'd0, DOM_NTT = 2'd1, DOM_TIME = 2'd2, DOM_FULL = 2'd3;

    // ---- 主状态 ----
    localparam S_IDLE  = 4'd0,   // 等命令行（**无超时**）
               S_RESP  = 4'd1,   // 通用应答发送
               S_DATA  = 4'd2,   // 收数据行
               S_LOAD  = 4'd3,   // burst 进核
               S_START = 4'd4,   // 发 start_*，等 done
               S_READ  = 4'd5,   // 发 read_a，把 256 拍接回来
               S_OUT   = 4'd6;   // 逐行发结果

    // ---- 应答种类 ----
    localparam RK_OK = 2'd0, RK_BEGIN = 2'd1, RK_DONE = 2'd2, RK_ERR = 2'd3;

    // ---- 固定前缀（右对齐；ASCII 写数值不写转义字符串，理由见 cmd_parse.v 头部）----
    localparam [31:0] P_OK    = 32'h23_4F_4B_20;            // "#OK "
    localparam [55:0] P_BEGIN = 56'h23_42_45_47_49_4E_20;   // "#BEGIN "
    localparam [47:0] P_DONE  = 48'h23_44_4F_4E_45_20;      // "#DONE "
    localparam [39:0] P_ERR   = 40'h23_45_52_52_20;         // "#ERR "

    // ---- 计数后缀 ----
    localparam [31:0] SFX_256 = 32'h20_32_35_36;            // " 256"
    localparam [15:0] SFX_0   = 16'h20_30;                  // " 0"

    // ---- 错误码（2 位 ASCII，右对齐）----
    localparam [15:0] E_01 = 16'h30_31, E_02 = 16'h30_32, E_03 = 16'h30_33,
                      E_04 = 16'h30_34, E_05 = 16'h30_35, E_06 = 16'h30_36,
                      E_07 = 16'h30_37;

    localparam integer DATA_LINES = 256;    // 一组系数
    localparam integer OUT_LINES  = 256;    // 结果行数（永远 256，与输入行数无关）

    // ★ 数据段单行上限 = 9，**不是 3**。
    //   §5.2 要求数据段里必须认得出 `#ABORT`（§5.5 关键规则二要发它），
    //   而 `#ABORT*69` 整行 9 字节。设成 3 的话 uart_line_rx 会在第 4 个字符就
    //   判 line_over，`line_valid` 永远不会来 —— #ABORT 反而被当成 #ERR 04。
    //   设成 9 之后：坏数据行（如 `0444`）能完整收进来，由下面的
    //   `line_len != 3` 判成 #ERR 04，位置填 4 —— 与 §5.5 边界表的结论一致。
    localparam [7:0] MAX_DATA_LINE = 8'd9;

    // =====================================================================
    // 1. 子模块
    // =====================================================================
    wire [2:0]  p_cmd;
    wire [1:0]  p_dom;
    wire [9:0]  p_exp;
    wire        p_cksum_ok;
    wire        p_n_ok;
    wire [6:0]  p_paylen;
    wire [7:0]  p_ck_got, p_ck_exp;

    cmd_parse #(.MAXLEN(MAXLEN)) u_parse (
        .line        (line),
        .line_len    (line_len),
        .cmd         (p_cmd),
        .dom         (p_dom),
        .exp_lines   (p_exp),
        .cksum_ok    (p_cksum_ok),
        .n_ok        (p_n_ok),
        .payload_len (p_paylen),
        .ck_got      (p_ck_got),
        .ck_exp      (p_ck_exp)
    );

    // ---- 行发送器 ----
    reg               txl_start;
    reg [MAXTX*8-1:0] txl_buf;
    reg [6:0]         txl_len;
    wire              txl_done;

    tx_line #(.MAXTX(MAXTX)) u_txl (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (txl_start),
        .txbuf   (txl_buf),
        .len     (txl_len),
        .tx_en   (uart_tx_en),
        .tx_data (uart_tx_data),
        .busy    (uart_tx_busy),
        .done    (txl_done)
    );

    // ---- 结果行：12 位 → 3 个十六进制字符（**一律小写**，§5.4 细则 3）----
    wire [23:0] dat3;
    hex12_to3 u_h2c (.val (pb_a_rdata), .r (dat3));

    // ---- 数据行：3 个字符 → 12 位 + 合法性 + 第一个坏字符的位置 ----
    wire [3:0] hd_v1, hd_v2, hd_v3;
    wire       hd_o1, hd_o2, hd_o3;

    hex_digit hd1 (.c (line[23:16]), .v (hd_v1), .ok (hd_o1));
    hex_digit hd2 (.c (line[15: 8]), .v (hd_v2), .ok (hd_o2));
    hex_digit hd3 (.c (line[ 7: 0]), .v (hd_v3), .ok (hd_o3));

    // 先到的字符是最高 nibble（与 hex3.v 的约定一致）
    wire [11:0] h3_val = { hd_v1, hd_v2, hd_v3 };
    wire        h3_ok  = hd_o1 & hd_o2 & hd_o3;
    wire [1:0]  h3_bad = (!hd_o1) ? 2'd1 : ((!hd_o2) ? 2'd2 : 2'd3);

    // =====================================================================
    // 2. 命令上下文（在 S_IDLE 认下行的那一刻锁存）
    // =====================================================================
    reg [2:0]   r_cmd;
    reg [1:0]   r_dom;
    reg [9:0]   r_exp;          // 本命令后应跟的数据行数（256 / 512 / 0）
    reg         r_compute;      // 是不是计算类命令（PING / ABORT 不是）
    reg [6:0]   r_echo_len;     // 回显的 payload 字节数
    reg [MAXLEN*8-1:0] r_echo;  // 回显的 payload（= line >> 24，右对齐）

    // 装载：用哪个 load 口；启动：哪一步用哪个 start_*、哪一步 ab=1
    reg         r_lda_f, r_lda_i, r_ldb_f, r_ldb_i;
    reg [1:0]   r_nload;                        // 1（只 A）或 2（先 A 后 B）
    reg [3:0]   r_st_fntt, r_st_pwm2, r_st_intt, r_st_ab;   // 位掩码：第 i 位 = 第 i 步
    reg [2:0]   r_nstart;

    // =====================================================================
    // 3. 应答缓冲
    // =====================================================================
    reg  [1:0]         resp_kind;
    reg  [3:0]         after_state;
    reg  [3:0]         resp_ph;         // 0 装正文 / 1 追校验 / 2 起发 / 3 等发完
    reg  [6:0]         bi;
    reg  [MAXTX*8-1:0] tx_buf;          // **右对齐**
    reg  [6:0]         tx_len;
    reg  [31:0]        r_sfx;
    reg  [2:0]         r_sfx_len;

    // ---- #ERR 的 code 与「位置」----
    reg  [15:0]  e_code;
    reg          e_pos_is_str;          // 0 = 用下面的十进制数值；1 = 用整段字符串（只有 03）
    reg  [9:0]   e_pos_val;             // 十进制 0..999
    reg  [103:0] e_pos_str;             // 右对齐，最多 13 字节
    reg  [4:0]   e_pos_str_len;

    // =====================================================================
    // 4. 应答正文的逐字节组合生成
    // =====================================================================
    // 4 位 → ASCII 十六进制字符（**一律小写**，§5.4 细则 3）
    function [7:0] hx;
        input [3:0] n;
        begin
            hx = (n < 4'd10) ? (8'h30 + n) : (8'h61 + n - 4'd10);
        end
    endfunction

    // 4 位 → ASCII 十进制字符
    function [7:0] dg;
        input [3:0] n;
        begin
            dg = 8'h30 + n;
        end
    endfunction

    // 十进制渲染（0..999）→ 3 字节右对齐 + 有效位数（去前导零）
    wire [3:0]  p_100 = e_pos_val / 10'd100;
    wire [3:0]  p_10  = (e_pos_val / 10'd10) % 10'd10;
    wire [3:0]  p_1   = e_pos_val % 10'd10;
    wire [23:0] p_dec = { dg(p_100), dg(p_10), dg(p_1) };
    wire [1:0]  p_len = (e_pos_val >= 10'd100) ? 2'd3
                      : (e_pos_val >= 10'd10 ) ? 2'd2 : 2'd1;

    // 03 专用：「位置」栏就是 `got=XX exp=YY`（13 字节，§5.2）
    //   'g'=67 'o'=6F 't'=74 '='=3D ' '=20 'e'=65 'x'=78 'p'=70
    wire [103:0] det03 = { 32'h676F_743D,                    // "got="
                           hx(p_ck_got[7:4]), hx(p_ck_got[3:0]),
                           40'h20_6578_703D,                  // " exp="
                           hx(p_ck_exp[7:4]), hx(p_ck_exp[3:0]) };

    reg [7:0] rbyte;
    reg [6:0] rblen;

    // ⚠️ 变量字节下标一律先算进 integer（见文件头最后一段）
    integer ib, is;

    always @(*) begin
        rbyte = 8'h00;
        rblen = 7'd0;
        is    = 0;
        case (resp_kind)

            // ---- "#OK " + <原命令> ----
            RK_OK: begin
                rblen = 7'd4 + r_echo_len;
                if (bi < 7'd4) begin
                    is    = 4 - 1 - bi;
                    rbyte = P_OK[is*8 +: 8];
                end
                else begin
                    is    = r_echo_len - 7'd1 - (bi - 7'd4);
                    rbyte = r_echo[is*8 +: 8];
                end
            end

            // ---- "#BEGIN " + <原命令> + " <count>" ----
            RK_BEGIN: begin
                rblen = 7'd7 + r_echo_len + {4'b0, r_sfx_len};
                if (bi < 7'd7) begin
                    is    = 7 - 1 - bi;
                    rbyte = P_BEGIN[is*8 +: 8];
                end
                else if (bi < 7'd7 + r_echo_len) begin
                    is    = r_echo_len - 7'd1 - (bi - 7'd7);
                    rbyte = r_echo[is*8 +: 8];
                end
                else begin
                    is    = r_sfx_len - 1 - (bi - 7'd7 - r_echo_len);
                    rbyte = r_sfx[is*8 +: 8];
                end
            end

            // ---- "#DONE " + <原命令> + " <count>" ----
            RK_DONE: begin
                rblen = 7'd6 + r_echo_len + {4'b0, r_sfx_len};
                if (bi < 7'd6) begin
                    is    = 6 - 1 - bi;
                    rbyte = P_DONE[is*8 +: 8];
                end
                else if (bi < 7'd6 + r_echo_len) begin
                    is    = r_echo_len - 7'd1 - (bi - 7'd6);
                    rbyte = r_echo[is*8 +: 8];
                end
                else begin
                    is    = r_sfx_len - 1 - (bi - 7'd6 - r_echo_len);
                    rbyte = r_sfx[is*8 +: 8];
                end
            end

            // ---- "#ERR " + <code> + " " + <位置> ----
            //   5 + 2 + 1 + 位置长度
            RK_ERR: begin
                rblen = e_pos_is_str ? (7'd8 + {2'b0, e_pos_str_len})
                                     : (7'd8 + {5'b0, p_len});
                if (bi < 7'd5) begin
                    is    = 5 - 1 - bi;
                    rbyte = P_ERR[is*8 +: 8];
                end
                else if (bi < 7'd7) begin
                    is    = 2 - 1 - (bi - 7'd5);
                    rbyte = e_code[is*8 +: 8];
                end
                else if (bi == 7'd7) begin
                    rbyte = 8'h20;                              // 空格
                end
                else if (e_pos_is_str) begin
                    is    = e_pos_str_len - 1 - (bi - 7'd8);
                    rbyte = e_pos_str[is*8 +: 8];
                end
                else begin
                    is    = p_len - 1 - (bi - 7'd8);
                    rbyte = p_dec[is*8 +: 8];
                end
            end

            default: ;
        endcase
    end

    // =====================================================================
    // 5. 已装进 tx_buf 的正文的异或校验（组合）
    //    §5.4：从行首第一个字符（含 # 和空格）起，到 `*` 之前，逐字节异或。
    //    tx_buf 此时装的就是「行首到 `*` 之前」的全部字节。
    // =====================================================================
    reg [7:0] txc;
    integer   ti;
    always @(*) begin
        txc = 8'h00;
        for (ti = 0; ti < MAXTX; ti = ti + 1)
            if (ti < tx_len)
                txc = txc ^ tx_buf[(tx_len - 7'd1 - ti)*8 +: 8];
    end

    // ⚠️ Verilog **不允许**写成 `(rc - READ_LAT)[7:0]` —— 括号表达式后面不能直接跟
    //    位选，iverilog 报 "syntax error / malformed statement"。必须先用一根线接住。
    // ---- 读出采样点 --------------------------------------------------------
    //   READ_LAT 的口径（= 2*PE_NUMBER+3，pe1 就是 5）来自 rtl/probes/top_golden_tb.v
    //   的 FIRST_DOUT：它是**从「read 脉冲那一拍」起算**的，而且该台还断言
    //   脉冲后第 1..4 拍 dout 必须全 0，第一个有效值正好在第 5 拍。
    //
    //   ⚠️ 但本模块的 rc 是从「给 core_read_a **赋值**的那一拍」起数的，
    //      寄存器输出要下一拍才真的拉高 —— 所以 rc == 1 才是脉冲那一拍，
    //      第一个有效 dout 落在 **rc == READ_LAT + 1**。
    //      差这一拍的现象：整条结果流前移一位，第 0 行是采集前的残留（全 0），
    //      后面每一行都错位 —— 看起来像「读出顺序不对」，其实是采样点早了。
    localparam [9:0] RD_SAMP = READ_LAT + 1;
    wire      [9:0]  rc_off  = rc - RD_SAMP;    // rc = RD_SAMP .. RD_SAMP+255 → 0..255
                                                // （RD_SAMP 随折叠度变：pe1 6｜pe4 12｜pe16 36）
    wire      [7:0]  rd_addr = rc_off[7:0];

    // =====================================================================
    // 6. 主状态机
    // =====================================================================
    reg [3:0]  state;
    reg [9:0]  lc;              // S_LOAD 的拍计数 0..258+PE_NUMBER（pe1 258｜pe4 261｜pe16 273）
    reg        ld_ph;           // S_LOAD：0 装 A，1 装 B
    reg [9:0]  rc;              // S_READ 的拍计数
    reg [9:0]  oc;              // S_OUT 的已发行数
    reg [2:0]  sph;             // S_START 子相位：0 发脉冲 / 1 等 done
    reg [2:0]  sc;              // S_START 第几步
    reg [9:0]  r_rcvd;          // S_DATA 已收到的数据行数
    reg [1:0]  oph;             // S_OUT 子相位：0 取地址 / 1 装行 / 2 起发 / 3 等发完
    reg        cmd_active;      // 命令行已收到过至少一个字节（T_CMD 只在此时才走）

    reg [31:0] t_line_c;
    reg [31:0] t_cmd_c;
    reg [31:0] t_core_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            after_state    <= S_IDLE;
            resp_kind      <= RK_OK;
            resp_ph        <= 4'd0;
            bi             <= 7'd0;
            tx_buf         <= {MAXTX*8{1'b0}};
            tx_len         <= 7'd0;
            txl_start      <= 1'b0;
            txl_buf        <= {MAXTX*8{1'b0}};
            txl_len        <= 7'd0;
            rx_clr         <= 1'b0;
            rx_max_bytes   <= 8'd64;
            pb_we          <= 1'b0;
            pb_sel_b       <= 1'b0;
            pb_waddr       <= 8'd0;
            pb_wdata       <= 12'd0;
            pb_raddr       <= 8'd0;
            core_load_a_f  <= 1'b0;  core_load_a_i <= 1'b0;
            core_load_b_f  <= 1'b0;  core_load_b_i <= 1'b0;
            core_read_a    <= 1'b0;  core_read_b   <= 1'b0;
            core_start_ab  <= 1'b0;
            core_start_fntt<= 1'b0;  core_start_pwm2 <= 1'b0;  core_start_intt <= 1'b0;
            core_din       <= 12'd0;
            lc <= 10'd0; rc <= 10'd0; oc <= 10'd0; sc <= 3'd0;
            sph <= 3'd0; ld_ph <= 1'b0; oph <= 2'd0; r_rcvd <= 10'd0;
            cmd_active <= 1'b0;
            t_line_c <= 32'd0; t_cmd_c <= 32'd0; t_core_c <= 32'd0;
            r_cmd <= CMD_NONE; r_dom <= DOM_NONE; r_exp <= 10'd0;
            r_compute <= 1'b0; r_echo <= {MAXLEN*8{1'b0}}; r_echo_len <= 7'd0;
            r_lda_f <= 1'b0; r_lda_i <= 1'b0; r_ldb_f <= 1'b0; r_ldb_i <= 1'b0;
            r_nload <= 2'd1;
            r_st_fntt <= 4'd0; r_st_pwm2 <= 4'd0; r_st_intt <= 4'd0; r_st_ab <= 4'd0;
            r_nstart <= 3'd1;
            r_sfx <= SFX_0; r_sfx_len <= 3'd2;
            e_code <= E_01; e_pos_is_str <= 1'b0; e_pos_val <= 10'd0;
            e_pos_str <= 104'd0; e_pos_str_len <= 5'd1;
            dbg_state <= S_IDLE;
        end
        else begin
            // ---- 脉冲输出默认拉低 ----
            txl_start     <= 1'b0;
            rx_clr        <= 1'b0;
            pb_we         <= 1'b0;
            core_load_a_f <= 1'b0; core_load_a_i <= 1'b0;
            core_load_b_f <= 1'b0; core_load_b_i <= 1'b0;
            core_read_a   <= 1'b0; core_read_b   <= 1'b0;
            core_start_fntt <= 1'b0; core_start_pwm2 <= 1'b0; core_start_intt <= 1'b0;
            dbg_state     <= state;

            // ---- 单行上限默认是命令行那一档，只有 S_DATA 例外 ----
            rx_max_bytes <= 8'd64;

            case (state)

            // =============================================================
            // S_IDLE —— 等命令行
            //   ⚠️ 本状态**不设整行超时**（§5.5）。只走字符间计时，而且只在
            //      本行已经收到过字节之后才走（cmd_active）。
            // =============================================================
            S_IDLE: begin

                // ---- 命令行超长（>64 字节还没等到 LF）→ #ERR 04 ----
                if (line_over) begin
                    resp_kind      <= RK_ERR;
                    e_code         <= E_04;
                    e_pos_is_str   <= 1'b0;
                    e_pos_val      <= 10'd65;       // 第 65 个字节越界（§5.5 边界表）
                    after_state    <= S_IDLE;
                    resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                    cmd_active     <= 1'b0;
                    t_cmd_c        <= 32'd0;
                    state          <= S_RESP;
                end

                // ---- 整行到了 ----
                else if (line_valid) begin
                    cmd_active <= 1'b0;
                    t_cmd_c    <= 32'd0;

                    if (!p_cksum_ok) begin
                        // 校验错 → #ERR 03，位置栏原样回 got=/exp=（§5.2 定死）
                        resp_kind     <= RK_ERR;
                        e_code        <= E_03;
                        e_pos_is_str  <= 1'b1;
                        e_pos_str     <= det03;
                        e_pos_str_len <= 5'd13;
                        after_state   <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state         <= S_RESP;
                    end
                    else if (p_cmd == CMD_NONE) begin
                        // 校验对、命令不认识 → #ERR 01，位置 0
                        resp_kind    <= RK_ERR;
                        e_code       <= E_01;
                        e_pos_is_str <= 1'b0;
                        e_pos_val    <= 10'd0;
                        after_state  <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state        <= S_RESP;
                    end
                    else if (!p_n_ok) begin
                        // 命令认得、参数非法 → #ERR 02，位置 = 出错字段的序号
                        //   #NTT/#INTT：只有两个词，错的一定是 n → 2
                        //   #PMUL ...：域词错 → 2；域词对而 n 错 → 3
                        resp_kind    <= RK_ERR;
                        e_code       <= E_02;
                        e_pos_is_str <= 1'b0;
                        e_pos_val    <= (p_dom == DOM_NONE) ? 10'd2 : 10'd3;
                        after_state  <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state        <= S_RESP;
                    end
                    else begin
                        // ---------- 合法命令：锁存上下文 ----------
                        // ⚠️ 下面一律用 p_* 直接算，**不要**借用 r_* ——
                        //    非阻塞赋值的值下一拍才可见，本拍读到的还是上一轮命令的。
                        r_cmd      <= p_cmd;
                        r_dom      <= p_dom;
                        r_exp      <= p_exp;
                        // ⚠️ 回显要**连行首的 `#` 一起去掉**，不是只去 `*xx`。
                        //   proto.md:211/221 逐字写着：电脑发 `#PMUL TIME 1`，
                        //   板子回 `#OK PMUL TIME 1*27`。多一个 `#` 就是回显对不上，
                        //   而回显对不上按关键规则四 = **停整轮测试**，代价最大的一种错。
                        //
                        //   ⚠️ 这里**不能**靠多移一位去掉 `#`：右移只能从低位丢字节，
                        //   而行首的 `#` 在右对齐值的**最高**字节上，移多少都丢不掉。
                        //   （改 >>32 试过：`#PING*33` 会变成 `#PIN`，把 `G` 也丢了。）
                        //
                        //   正解：字节位**原样不动**，只把声明的长度减 1。
                        //   >>24 丢掉行尾 `*xx` 三字节 → 载荷 `#PING` 右对齐、末字节在 [7:0]。
                        //   载荷的第 j 个字符在 [(L-1-j)*8 +: 8]；现在按长度 L-1 重新解释，
                        //   取值口径 is = (L-1)-1-(bi-4) 正好读到第 j+1 个字符 = 跳过 `#`。
                        //   —— 位不动，只改解释，这一点是这段唯一容易写错的地方。
                        r_echo     <= line >> 24;       // 载荷全域（含行首 `#`），右对齐
                        r_echo_len <= p_paylen - 7'd1;  // 声明长度减 1 = 跳过第 1 个字符

                        // ---- 有没有数据段：PING / ABORT 没有 ----
                        r_compute  <= (p_cmd != CMD_PING) & (p_cmd != CMD_ABORT);
                        r_sfx      <= ((p_cmd != CMD_PING) & (p_cmd != CMD_ABORT))
                                      ? SFX_256 : {16'd0, SFX_0};
                        r_sfx_len  <= ((p_cmd != CMD_PING) & (p_cmd != CMD_ABORT))
                                      ? 3'd4 : 3'd2;

                        // ---- 装载口（§5.2 表最后一列）----
                        //   _f 灌 BRAM 低半区（时域），_i 灌高半区（NTT 域）。
                        //   灌错不会报错，只是 256 个系数全错 —— 见 §5.2 的警告。
                        r_lda_f <= (p_cmd == CMD_NTT) |
                                   ((p_cmd == CMD_PMUL) &
                                    ((p_dom == DOM_TIME) | (p_dom == DOM_FULL)));
                        r_lda_i <= (p_cmd == CMD_INTT) |
                                   ((p_cmd == CMD_PMUL) & (p_dom == DOM_NTT));
                        r_ldb_f <= (p_cmd == CMD_PMUL) & (p_dom == DOM_FULL);
                        r_ldb_i <= (p_cmd == CMD_PMUL) &
                                   ((p_dom == DOM_NTT) | (p_dom == DOM_TIME));
                        r_nload <= (p_cmd == CMD_PMUL) ? 2'd2 : 2'd1;

                        // ---- 启动序列位掩码：第 i 位 = 第 i 步该不该发这个信号 ----
                        //   NTT       : fntt
                        //   INTT      : intt
                        //   PMUL NTT  : pwm2
                        //   PMUL TIME : fntt → pwm2 → intt
                        //   PMUL FULL : fntt(A) → fntt(B) → pwm2 → intt
                        //               （两个 fntt 靠 start_ab 选 A/B，见 §5.2）
                        r_st_fntt <= (p_cmd == CMD_NTT)                          ? 4'b0001 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_TIME)) ? 4'b0001 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_FULL)) ? 4'b0011 : 4'b0000;
                        r_st_pwm2 <= ((p_cmd == CMD_PMUL) & (p_dom == DOM_NTT))  ? 4'b0001 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_TIME)) ? 4'b0010 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_FULL)) ? 4'b0100 : 4'b0000;
                        r_st_intt <= (p_cmd == CMD_INTT)                         ? 4'b0001 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_TIME)) ? 4'b0100 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_FULL)) ? 4'b1000 : 4'b0000;
                        r_st_ab   <= ((p_cmd == CMD_PMUL) & (p_dom == DOM_FULL)) ? 4'b0010 : 4'b0000;
                        r_nstart  <= (p_cmd == CMD_NTT)  ? 3'd1 :
                                     (p_cmd == CMD_INTT) ? 3'd1 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_NTT))  ? 3'd1 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_TIME)) ? 3'd3 :
                                     ((p_cmd == CMD_PMUL) & (p_dom == DOM_FULL)) ? 3'd4 : 3'd1;

                        // ---- 回 #OK，**立刻**（不等数据；等就死锁，见 §5.1）----
                        resp_kind   <= RK_OK;
                        after_state <= ((p_cmd != CMD_PING) & (p_cmd != CMD_ABORT))
                                       ? S_DATA : S_IDLE;
                        resp_ph     <= 4'd0;
                        bi          <= 7'd0;
                        tx_len      <= 7'd0;
                        r_rcvd      <= 10'd0;
                        state       <= S_RESP;
                    end
                end

                // ---- 字符间超时：只在「本行已收到过字节」时才走 ----
                //   到时**静默**丢弃这半行、回「等命令行」，不发任何行（§5.5）
                else if (rx_byte) begin
                    cmd_active <= 1'b1;
                    t_cmd_c    <= 32'd0;
                end
                else if (cmd_active) begin
                    if (t_cmd_c < T_CMD_CC) begin
                        t_cmd_c <= t_cmd_c + 32'd1;
                    end
                    else begin
                        t_cmd_c    <= 32'd0;
                        cmd_active <= 1'b0;
                        // 丢掉这半行，立刻回到「等命令行」（§5.5 关键规则一），**不出声**。
                        // ⚠️ uart_line_rx.v 里 clr 是**硬清**（下一个字节就重开一行），
                        //    不是「丢到 LF 为止」—— 本行行尾那个 LF 永远不会来了。
                        //    语义写错会把超时后的 `#ABORT*69` 整条吞掉，卡死整轮测试。
                        rx_clr     <= 1'b1;
                    end
                end
            end

            // =============================================================
            // S_RESP —— 发一行应答（#OK / #BEGIN / #DONE / #ERR 共用）
            //   相位 0：逐字节装正文   1：追加 `*` + 2 位小写校验
            //   相位 2：起发           3：等发完 → 去 after_state
            // =============================================================
            S_RESP: begin
                case (resp_ph)
                    4'd0: begin
                        tx_buf <= { tx_buf[MAXTX*8-9:0], rbyte };
                        tx_len <= tx_len + 7'd1;
                        if (bi == rblen - 7'd1) begin
                            bi      <= 7'd0;
                            resp_ph <= 4'd1;
                        end
                        else begin
                            bi <= bi + 7'd1;
                        end
                    end

                    4'd1: begin
                        // 正文已稳（tx_buf/tx_len 上一拍定格），追加 `*` + 校验
                        tx_buf  <= { tx_buf[MAXTX*8-25:0], 8'h2A, hx(txc[7:4]), hx(txc[3:0]) };
                        tx_len  <= tx_len + 7'd3;
                        resp_ph <= 4'd2;
                    end

                    4'd2: begin
                        // ⚠️ 这里**不再**加 3 —— 相位 1 已经把校验的 3 字节计进 tx_len 了。
                        //   之前写成 `tx_len + 7'd3`，等于把校验算两遍：多发 3 个字节，
                        //   而那 3 个字节取自 tx_buf 正文**上方**的残留（首次应答时是全 0），
                        //   现象就是回帧前面挂一串 0x00。改回 `tx_len` 即可。
                        txl_buf   <= tx_buf;            // 打完校验后的完整行
                        txl_len   <= tx_len;            // 正文 + `*xx`，相位 1 已计完
                        txl_start <= 1'b1;
                        resp_ph   <= 4'd3;
                    end

                    4'd3: begin
                        if (txl_done) begin
                            resp_ph <= 4'd0;
                            state   <= after_state;
                        end
                    end

                    default: resp_ph <= 4'd0;
                endcase
            end

            // =============================================================
            // S_DATA —— 收数据行
            //   §5.5 边界表：空行忽略、CR 忽略且不计数（这两条在 uart_line_rx 里做掉）
            // =============================================================
            S_DATA: begin
                rx_max_bytes <= MAX_DATA_LINE;

                // ---- 行超时（T_LINE，按字节重置）→ #ERR 05 ----
                if (t_line_c >= T_LINE_CC) begin
                    t_line_c      <= 32'd0;
                    resp_kind     <= RK_ERR;
                    e_code        <= E_05;
                    e_pos_is_str  <= 1'b0;
                    e_pos_val     <= r_rcvd;        // 「位置」= 已收到的行数（§5.2 错误码表）
                    after_state   <= S_IDLE;        // 关键规则一：必须回「等命令行」
                    resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                    // 同 S_IDLE 的 T_CMD 超时：clr 是**硬清**（见 uart_line_rx.v），
                    // 本行行尾的 LF 不会来了，下一个字节就重开一行。
                    rx_clr        <= 1'b1;
                    state         <= S_RESP;
                end

                // ---- 本行超长（>9 字符还没等到 LF）→ #ERR 04 ----
                else if (line_over) begin
                    t_line_c      <= 32'd0;
                    resp_kind     <= RK_ERR;
                    e_code        <= E_04;
                    e_pos_is_str  <= 1'b0;
                    e_pos_val     <= 10'd10;        // 第 10 个字节越界
                    after_state   <= S_IDLE;
                    resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                    state         <= S_RESP;
                end

                else if (line_valid) begin
                    t_line_c <= 32'd0;

                    // ---- 数据段里插进来的 #ABORT 是**合法**的 ----
                    //   §5.5 关键规则二：电脑超时后先发一次 #ABORT 再重传。
                    //   §5.2 也写明「数据段内不允许有命令，`#ABORT` 除外」。
                    if ((p_cmd == CMD_ABORT) & p_cksum_ok & (line_len == 7'd9)) begin
                        r_echo      <= line >> 24;      // 同 S_IDLE：位不动，只把长度减 1
                        r_echo_len  <= p_paylen - 7'd1;
                        resp_kind   <= RK_OK;
                        after_state <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state       <= S_RESP;
                    end
                    // ---- 长度不是 3 → #ERR 04（位置 = 第一个越界的字符位）----
                    else if (line_len != 7'd3) begin
                        resp_kind    <= RK_ERR;
                        e_code       <= E_04;
                        e_pos_is_str <= 1'b0;
                        e_pos_val    <= {3'b0, line_len};
                        after_state  <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state        <= S_RESP;
                    end
                    // ---- 三个字符里有非十六进制 → #ERR 04（位置 = 第一个坏字符）----
                    else if (!h3_ok) begin
                        resp_kind    <= RK_ERR;
                        e_code       <= E_04;
                        e_pos_is_str <= 1'b0;
                        e_pos_val    <= {8'd0, h3_bad};
                        after_state  <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state        <= S_RESP;
                    end
                    // ---- 合法数据行：写进 poly_buf ----
                    else begin
                        pb_we    <= 1'b1;
                        pb_sel_b <= (r_rcvd >= DATA_LINES);     // 前 256 行给 A，其余给 B
                        pb_waddr <= r_rcvd[7:0];                // 512 → 低 8 位自然回绕到 0..255
                        pb_wdata <= h3_val;
                        r_rcvd   <= r_rcvd + 10'd1;

                        if (r_rcvd + 10'd1 >= r_exp) begin
                            // 数据收齐 → 去 burst 进核
                            pb_raddr <= 8'd0;           // S_LOAD 第一拍就要用地址 0
                            lc       <= 10'd0;
                            ld_ph    <= 1'b0;
                            state    <= S_LOAD;
                        end
                    end
                end

                // ---- 按字节重置行超时（§5.5：从本行第一个字节起算）----
                else if (rx_byte) begin
                    t_line_c <= 32'd0;
                end
                else if (t_line_c < T_LINE_CC) begin
                    t_line_c <= t_line_c + 32'd1;
                end
            end

            // =============================================================
            // S_LOAD —— 把 poly_buf burst 进核
            //
            //   ⚠️ 核的 load_* 口**没有数据有效选通**（H1 §四）：一旦进了装载，
            //      每拍硬写一次 BRAM，靠内部计数器数满 256 才退出。所以
            //      din 必须**连续 256 拍不断**，且这 256 拍之间不能有空拍。
            //
            //   拍序（lc = 0 … 258+PE_NUMBER；PE 见下面那段 ⚠️）：
            //     lc = 0        拉 load 脉冲（1 拍）。**这一拍 din 不动**
            //     lc = 1..256   din ← 第 lc-1 个系数   ← 连续 256 拍，一个空拍都没有
            //     lc = 257..258+PE  间隔 —— **长度随折叠度变**，理由见下
            //     lc = 259+PE   装 B（如果这条命令要两个）或去 S_START
            //                   pe1=259 ｜ pe4=262 ｜ pe16=274
            //
            //   ★ 为什么 din 比脉冲晚一拍 —— 这条写错过一次，代价是整条结果流全错
            //
            //   判据在 rtl/probes/top_golden_tb.v 的 `load_serial`（那是 KyberHPMNTT_top
            //   已验证 4096/4096 的驱动方式，逐字抄在下面）：
            //
            //       load_a_f = 1;   // ← 脉冲落在这一拍
            //       #FP;            //   下一拍脉冲拉低，din 才摆上第一个系数
            //       load_a_f = 0;
            //       din = vin[0];
            //       for (i = 1; i < 256; i = i + 1) begin #FP; din = vin[i]; end
            //
            //   也就是「第 k 个系数要挂在**脉冲那一拍之后**的第 k+1 拍上」。
            //   对照本模块：脉冲和 din 都是寄存器输出，`<=` 要下一拍才生效。
            //   之前把脉冲和 din[0] 写在**同一拍**，于是 din 整体比脉冲早一拍 ——
            //   核吃到的第一个系数是 1 而不是 0，装载结果整条错位，
            //   NTT 输出与黄金向量毫无关系（现象是「值都不在黄金向量里」，
            //   很容易误判成读出顺序问题）。
            //
            //   din 为什么能当拍取到：poly_buf 是**组合读**，pb_raddr 提前一拍设好。
            //   本段的写法是「lc 这一拍把 pb_raddr 设成 lc」，于是下一拍
            //   pb_a_rdata 就是第 lc 个系数，正好给下一拍的 core_din 用。
            //   ⚠️ 是 `lc[7:0]`，**没有 +1** —— 加 1 会让最后一个系数取到回绕的 0。
            // =============================================================
            S_LOAD: begin
                if (lc == 10'd0) begin
                    if (!ld_ph) begin
                        core_load_a_f <= r_lda_f;
                        core_load_a_i <= r_lda_i;
                    end
                    else begin
                        core_load_b_f <= r_ldb_f;
                        core_load_b_i <= r_ldb_i;
                    end
                    pb_raddr <= 8'd0;               // 下一拍 pb_a_rdata = 系数 0
                    lc       <= 10'd1;              // ⚠️ 本拍不碰 core_din
                end
                else if (lc <= DATA_LINES) begin                   // 1..256
                    core_din <= ld_ph ? pb_b_rdata : pb_a_rdata;   // = 系数 lc-1
                    pb_raddr <= lc[7:0];                           // 下一拍 = 系数 lc
                    lc       <= lc + 10'd1;
                end
                // ---- 257 .. 258+PE 间隔 ----------------------------------
                //   ★ 间隔长度**随折叠度变**，不是常数。2026-10-04 修过一次：
                //     原来写死 `DATA_LINES + 3`（257,258 两拍），只对 pe1 成立。
                //
                //   为什么：这一段后面的每一个动作，都假定**核的装载相位已经走完**。
                //     核的装载相位长 `256 + PE_NUMBER` 拍（KyberHPMNTT_top.v:98 的
                //     LOAD_EXT），比 256 多出 PE_NUMBER 拍是序列化器的排空。
                //     写死 2 拍间隔 ⇒ 相位对 pe4/pe16 还没结束，于是**两个**出口都错：
                //
                //     (a) 走 B 的那一支 —— 相位机（KyberHPMNTT_top.v:157 的
                //         `else if (!slow)`）不为新 load 起相位。但核**自己**已经从
                //         OP_IDLE 进了 OP_LOAD_DATA（它的 di_cntr 数 256/PE 个 ce
                //         脉冲，早在 lc=258 就数满了）—— 于是核确实在装 B，
                //         只是 `ce` 恒 1、没被按 1/PE 门控，按 PE 倍速把序列化器
                //         抽干，装进去的值整体错位。
                //         ⚠️ 关键在 `bf_R` **只高 1 拍**（load_b_f 是 1 拍脉冲）：
                //            相位机此刻 `slow=1`，`else if (!slow)` 判假 ⇒ 这一拍
                //            被丢掉；等 `slow` 落回 0 时 `bf_R` 早已归零 ⇒ 相位
                //            永远起不来。**请求丢了，但核收到了** —— 这就是「两个
                //            出口都错」里最难看出的一处。
                //         ⚠️ pe4 与 pe16 是**同一个**失效模式，不是两种 —— 两档下
                //            核都在 lc=258 把 di_cntr 数满（与折叠度无关），
                //            lc=261 时处于 OP_IDLE，lc=262 进 OP_LOAD_DATA。
                //         现象值得记：**结果每个值都像模像样，不是全 0** ——
                //         所以既不像「没装上」也不像「顺序错」，肉眼分不开。
                //         2026-10-04 pe4 上三条 #PMUL 全挂就是这么来的。
                //
                //     (b) 走 S_START 的那一支 —— `core_start_*` 是**一拍宽**的脉冲
                //         （本文件 :508 默认清零），而核把它在**自由跑**的时钟上
                //         寄存成 sf_R（KyberHPMNTT_top.v:134），所以 sf_R 高那一拍
                //         必须正好赶上 `ce` 被门控打开的那一拍，否则**整个 start 丢掉**。
                //         相位没结束时 ce 是按 PE 分频的，脉冲宽度 1 拍根本撞不上。
                //         ⇒ 核永远收不到 start ⇒ 不跑 ⇒ 不回 done ⇒ 100 ms 后
                //           `#ERR 06`。**这正是 pe16 冒烟台 `#NTT` 挂掉的原因**
                //           （pe4 侥幸没中：它的 ce 分频比 4 恰好让那一拍对上）。
                //
                //   间隔取 `2 + PE_NUMBER` 拍 ⇒
                //     pe1 : 到 lc=258，else 在 259 —— **与原常数逐拍相同**，零回归
                //     pe4 : 到 lc=261，else 在 262
                //     pe16: 到 lc=273，else 在 274
                //   三档都把相位甩在身后（相位机可受理的那拍 260/263/275，
                //   而 B 的 req_load 落在 262/265/277），余量均 2 拍 ——
                //   与 pe1 在真板上已跑通的那 2 拍余量同源。
                else if (lc < DATA_LINES + 2 + PE_NUMBER) begin     // 257 .. 258+PE
                    lc <= lc + 10'd1;
                end
                else begin                                          // 259 / 262 / 274
                    if (!ld_ph && (r_nload == 2'd2)) begin
                        ld_ph    <= 1'b1;
                        lc       <= 10'd0;
                        pb_raddr <= 8'd0;
                    end
                    else begin
                        sc    <= 3'd0;
                        sph   <= 3'd0;
                        state <= S_START;
                    end
                end
            end

            // =============================================================
            // S_START —— 按位掩码逐条发 start_*，每条等 done
            //   核的 done 是「本次运算完成」的应答；T_CORE 是它的看门狗。
            // =============================================================
            S_START: begin
                if (sph == 3'd0) begin
                    core_start_fntt <= r_st_fntt[sc];
                    core_start_pwm2 <= r_st_pwm2[sc];
                    core_start_intt <= r_st_intt[sc];
                    core_start_ab   <= r_st_ab[sc];
                    t_core_c        <= 32'd0;
                    sph             <= 3'd1;
                end
                else begin
                    if (core_done) begin
                        if (sc + 3'd1 >= r_nstart) begin
                            rc    <= 10'd0;
                            state <= S_READ;
                        end
                        else begin
                            sc  <= sc + 3'd1;
                            sph <= 3'd0;
                        end
                    end
                    else if (t_core_c >= T_CORE_CC) begin
                        // ---- 核没在预期时间内回 done → #ERR 06 ----
                        t_core_c      <= 32'd0;
                        resp_kind     <= RK_ERR;
                        e_code        <= E_06;
                        e_pos_is_str  <= 1'b0;
                        e_pos_val     <= 10'd0;
                        after_state   <= S_IDLE;
                        resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                        state         <= S_RESP;
                    end
                    else begin
                        t_core_c <= t_core_c + 32'd1;
                    end
                end
            end

            // =============================================================
            // S_READ —— 发 read_a，隔 RD_SAMP(=READ_LAT+1) 拍，连采 256 拍存回 poly_buf 的 A
            //   ⚠️ 只取 256 拍。第 257 拍是越界回卷，必须丢（H1 §二）。
            //   采样点为什么是 RD_SAMP 而不是 READ_LAT，见上面 RD_SAMP 那段的注释。
            // =============================================================
            S_READ: begin
                if (rc == 10'd0) begin
                    core_read_a <= 1'b1;
                    rc          <= rc + 10'd1;
                end
                else if (rc < RD_SAMP) begin
                    rc <= rc + 10'd1;
                end
                else if (rc < RD_SAMP + OUT_LINES) begin
                    pb_we    <= 1'b1;
                    pb_sel_b <= 1'b0;
                    pb_waddr <= rd_addr;
                    pb_wdata <= core_dout;
                    rc       <= rc + 10'd1;
                end
                else begin
                    // 结果收齐 → 发 #BEGIN（此刻才算「算完了」，见 §5.1）
                    resp_kind   <= RK_BEGIN;
                    after_state <= S_OUT;
                    resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                    oc      <= 10'd0;
                    oph     <= 2'd0;
                    state   <= S_RESP;
                end
            end

            // =============================================================
            // S_OUT —— 逐行发 256 个结果（每行 3 个十六进制字符 + LF）
            //   一行 = 3 字符 + LF = 4 字节 = 347 µs，256 行约 89 ms
            // =============================================================
            S_OUT: begin
                case (oph)
                    2'd0: begin
                        pb_raddr <= oc[7:0];
                        oph      <= 2'd1;
                    end
                    2'd1: begin
                        // pb_a_rdata 是组合读，pb_raddr 上一拍已设好，这拍稳
                        txl_buf <= {{(MAXTX-3)*8{1'b0}}, dat3};
                        txl_len <= 7'd3;
                        oph     <= 2'd2;
                    end
                    2'd2: begin
                        txl_start <= 1'b1;
                        oph       <= 2'd3;
                    end
                    2'd3: begin
                        if (txl_done) begin
                            oph <= 2'd0;
                            if (oc + 10'd1 >= OUT_LINES) begin
                                // 全部发完 → 发 #DONE
                                resp_kind   <= RK_DONE;
                                after_state <= S_IDLE;
                                resp_ph <= 4'd0; bi <= 7'd0; tx_len <= 7'd0;
                                state   <= S_RESP;
                            end
                            else begin
                                oc <= oc + 10'd1;
                            end
                        end
                    end
                    default: oph <= 2'd0;
                endcase
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
