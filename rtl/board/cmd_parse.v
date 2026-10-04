// ===========================================================================
// cmd_parse.v —— 命令行 → (命令码, 域词, 数据行数, 校验是否通过)  纯组合
//
// 依据：host/proto.md §5.2（命令字表）、§5.4（异或校验）、§六第 2 条（n 冻结为 1）。
//
// 命令行长这样（`*` 之前是命令本体，`*` 后正好 2 位小写十六进制校验值）：
//     #NTT 1*7c          #PMUL TIME 1*03          #PING*33
//
// ★ ASCII 一律写数值，不写转义字符串 —— 零基础读代码时 8'h23 比转义写法好认，
//   而且 Verilog 的双引号字符串是 8 位还是 32 位在不同工具里不一致（著名的坑）。
//   全协议用到的字符对照表：
//      '#'=23  sp=20  '0'=30  '1'=31  '*'=2A
//      'A'=41 'B'=42 'E'=45 'F'=46 'G'=47 'I'=49 'L'=4C 'M'=4D
//      'N'=4E 'O'=4F 'P'=50 'R'=52 'T'=54 'U'=55 'X'=58
//
// ★ 匹配为什么能写成固定切片：line 是**右对齐**的（见 uart_line_rx.v），
//   于是行**尾**的位置固定。`line >> 24` 扔掉行尾的 `*` + 2 位校验得到 payload，
//   payload 的末字符仍在 [7:0]。定长命令就成了定宽的常量比较，不需要动态索引。
//   移位量 24 是常量，综合时只是连线重排，不花逻辑。
//
// ---------------------------------------------------------------------------
// ★ ★ 字节位置怎么数 —— 这一步写错过一次，整段记在这，别再错第二遍
//
//   payload 有 N 个字节时，**从行首数第 i 个字节（i 从 0 起）在**
//         payload[(N-1-i)*8 +: 8]
//   反过来记更省事：**最后一个字节永远在 [7:0]**，倒数第二个在 [15:8]。
//
//   拿 "#NTT 1"（N=6）验一遍：
//         byte0 '#' → bit 40     byte3 'T' → bit 16
//         byte1 'N' → bit 32     byte4 ' ' → bit  8
//         byte2 'T' → bit 24     byte5 '1' → bit  0
//   于是前缀 "#NTT "（5 字节）= [47:8]，参数 n = **[7:0]**。
//
//   ⚠️ 我第一版把 n 写成 payload[15:8] —— 那是 byte4，也就是**那个空格**。
//      四种命令四处全错。测试台一跑就露馅（见 tb/cmd_parse_tb.v）。
//      凡是「最后一个字节」的场合，一律写 [7:0]，别看走眼。
//
// ---------------------------------------------------------------------------
// ★ ★ 命令字与参数**分开判**（返工过一次，记在这）：
//   协议 §5.2 把「未知命令」和「参数非法」分成两个错误码：
//       #ERR 01 —— `#` 开头但不是命令表里任何一个
//       #ERR 02 —— 命令认出来了，但 n 不在允许范围 / 域词不是 TIME|NTT|FULL
//   所以 `#NTT 2`、`#PMUL XXX 1` 都必须报 **02**，不是 01。
//   于是匹配分成两步：**前缀命中**（认命令字）→ **尾巴单独判**（n_ok）。
//   域词同理：`#PMUL ` 只当前缀，TIME/NTT/FULL 是尾巴的一部分，认不出就 dom=NONE。
//
//   n 的判定用 `payload[15:0] == 16'h20_31` 一次比两个字节 —— 空格 + '1'。
//   这样做顺带把「空格位置被别的字符占了」也一并挡掉（如 `#PMUL NTTA1`）。
//
// ⚠️ 已知简化：n 只按**一位十进制**解析。`#NTT 10` 会落进 default 报 01
//    （严格说该报 02）。因为 §六第 2 条已把 n 冻结为 1，电脑端不会发多位数，
//    这条分支实际不可达。写成一位是刻意的取舍，不是漏掉。
// ===========================================================================

`timescale 1ns/1ps

module cmd_parse #(
    parameter integer MAXLEN = 64
)(
    input      [MAXLEN*8-1:0] line,         // 整行（含 `*xx`），右对齐
    input      [6:0]          line_len,     // 整行字节数

    output reg [2:0]          cmd,          // 命令码，见下方 localparam
    output reg [1:0]          dom,          // 域词（只有 #PMUL 用得到）
    output reg [9:0]          exp_lines,    // 本命令后面应该跟几个数据行
    output reg                cksum_ok,     // 校验值对不对
    output reg                n_ok,         // 参数合法（本版只认 n = 1）
    output reg [6:0]          payload_len,  // `*` 之前的字节数
    output reg [7:0]          ck_got,       // 行里**实际写着**的校验值（给 #ERR 03 回显）
    output reg [7:0]          ck_exp        // 板子**算出来**的校验值（给 #ERR 03 回显）
);

    // ---- 命令码 ----
    localparam CMD_NONE  = 3'd0,
               CMD_PING  = 3'd1,
               CMD_NTT   = 3'd2,
               CMD_INTT  = 3'd3,
               CMD_PMUL  = 3'd4,
               CMD_ABORT = 3'd5;

    // ---- 域词（#PMUL 的第二个词）----
    localparam DOM_NONE = 2'd0,
               DOM_NTT  = 2'd1,
               DOM_TIME = 2'd2,
               DOM_FULL = 2'd3;

    // 扔掉行尾的 '*' + 2 位校验（3 字节 = 24 位）。常量移位 → 零代价。
    wire [MAXLEN*8-1:0] payload = line >> 24;

    // 一个字符是否等于 nibble n（**只认小写**，§5.4 细则 3：
    // 「全协议只用小写……减少一处两端不一致点」）
    function hexd_eq;
        input [7:0] c;
        input [3:0] n;
        reg   [7:0] want;
        begin
            want    = (n < 4'd10) ? (8'h30 + n)           // '0'..'9'
                                  : (8'h61 + n - 8'd10);  // 'a'..'f'
            hexd_eq = (c == want);
        end
    endfunction

    // 一个字符的**数值**（大小写都认），只给 #ERR 03 的 got= 回显用。
    // ⚠️ 这与 hexd_eq 不是一回事：hexd_eq 判「是不是那个小写字符」（严格），
    //    本函数判「这个字符代表哪个数」（宽容）。校验闸门用前者，回显用后者。
    function [3:0] hexval;
        input [7:0] c;
        begin
            if      (c >= 8'h30 && c <= 8'h39) hexval = c - 8'h30;            // 0-9
            else if (c >= 8'h61 && c <= 8'h66) hexval = c - 8'h61 + 4'd10;    // a-f
            else if (c >= 8'h41 && c <= 8'h46) hexval = c - 8'h41 + 4'd10;    // A-F
            else                               hexval = 4'h0;                 // 不是 hex 字符
        end
    endfunction

    integer   k;
    reg [7:0] xacc;

    always @(*) begin
        // ---------- 0. payload 长度 与 异或累加（后面步骤要用）----------
        // ⚠️ 顺序要紧：Verilog 的组合块**顺序执行**。累加原本写在末尾，
        //    结果 cksum_ok 读到的是上一轮的 xacc —— 返工过一次。
        payload_len = (line_len >= 7'd3) ? (line_len - 7'd3) : 7'd0;

        xacc = 8'h00;
        for (k = 0; k < MAXLEN; k = k + 1)
            if (k < payload_len)
                xacc = xacc ^ payload[k*8 +: 8];

        // ---------- 1. 默认值 ----------
        // ⚠️ n_ok 默认 **0**，不是 1。这样它有一个强不变量：
        //        n_ok == 1  ⟺  本行被完全接受（校验过 + 命令认得 + 参数合法）
        //    默认给 1 会让「将来加命令时忘了写参数判定」静默变成「任意参数都收」；
        //    默认给 0 则是静默变成「一律拒收」—— 后者在测试里一眼能看出来。
        //    代价是 #PING / #ABORT 这两个**无参数**命令要显式置 1（见下）。
        cmd       = CMD_NONE;
        dom       = DOM_NONE;
        exp_lines = 10'd0;
        n_ok      = 1'b0;

        // ---------- 2. 校验：行尾必须是 '*' + 2 位小写 hex，且等于 xacc ----------
        // 最短的合法命令行是 `#PING*33` = 8 字节，故加 line_len >= 8 的护栏
        // （既挡空行，也保证下面读 line[23:16] 落在有效范围内）。
        cksum_ok = (line_len >= 7'd8)
                 & (line[23:16] == 8'h2A)               // '*'
                 & hexd_eq(line[15:8], xacc[7:4])
                 & hexd_eq(line[ 7:0], xacc[3:0]);

        // 给 #ERR 03 回显的两个值：行里写的 vs 板子算的。
        // 协议 §5.4：「两个值都回，人一眼能看到差在哪，比只说『校验失败』有用得多」。
        ck_got = { hexval(line[15:8]), hexval(line[7:0]) };
        ck_exp = xacc;

        // ---------- 3. 命令匹配：前缀认字 + 尾巴判参 ----------
        if (cksum_ok) begin
            case (payload_len)
                // #PING            = 23 50 49 4E 47
                7'd5: begin
                    if (payload[39:0] == 40'h23_5049_4E47) begin
                        cmd  = CMD_PING;
                        n_ok = 1'b1;        // 无参数命令 → 认出来就是合法
                    end
                end

                // #NTT <d>         = 23 4E 54 54 20 | <d>
                // #ABORT           = 23 41 42 4F 52 54
                7'd6: begin
                    if (payload[47:8] == 40'h23_4E54_5420) begin
                        cmd       = CMD_NTT;
                        exp_lines = 10'd256;
                        n_ok      = (payload[7:0] == 8'h31);        // '1'，在 [7:0]！
                    end
                    else if (payload[47:0] == 48'h23_4142_4F52_54) begin
                        cmd  = CMD_ABORT;
                        n_ok = 1'b1;        // 无参数命令 → 认出来就是合法
                    end
                end

                // #INTT <d>        = 23 49 4E 54 54 20 | <d>
                7'd7: begin
                    if (payload[55:8] == 48'h23_494E_5454_20) begin
                        cmd       = CMD_INTT;
                        exp_lines = 10'd256;
                        n_ok      = (payload[7:0] == 8'h31);
                    end
                end

                // #PMUL NTT <d>    = 23 50 4D 55 4C 20 | 4E 54 54 | 20 <d>
                7'd11: begin
                    if (payload[87:40] == 48'h23_504D_554C_20) begin
                        cmd       = CMD_PMUL;
                        exp_lines = 10'd512;
                        if (payload[39:16] == 24'h4E_5454)         // "NTT"
                            dom = DOM_NTT;
                        n_ok = (payload[15:0] == 16'h20_31)        // " 1"
                             & (dom == DOM_NTT);
                    end
                end

                // #PMUL TIME <d>   = 23 50 4D 55 4C 20 | 54 49 4D 45 | 20 <d>
                // #PMUL FULL <d>   = 23 50 4D 55 4C 20 | 46 55 4C 4C | 20 <d>
                7'd12: begin
                    if (payload[95:48] == 48'h23_504D_554C_20) begin
                        cmd       = CMD_PMUL;
                        exp_lines = 10'd512;
                        if      (payload[47:16] == 32'h54_49_4D_45) // "TIME"
                            dom = DOM_TIME;
                        else if (payload[47:16] == 32'h46_55_4C_4C) // "FULL"
                            dom = DOM_FULL;
                        n_ok = (payload[15:0] == 16'h20_31)
                             & (dom != DOM_NONE);       // 域词认不出来也算参数非法
                    end
                end

                default: ;      // 长度对不上任何命令 → 保持 CMD_NONE（→ #ERR 01）
            endcase
        end
    end

endmodule
