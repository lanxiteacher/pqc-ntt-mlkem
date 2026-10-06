// ===========================================================================
// uart_proto_tb.v —— 串口协议验收台（**B 的资产，A 只是起草**）
//
// ⚠️⚠️ 归属先看这一段，它决定这个文件该怎么维护 ⚠️⚠️
//
//   这份**不是 A 的**。`host/proto.md` §六第 12 条第 3 问逐字写着：
//
//     「§5.5 末尾的三种注入错误是否都跑过、两个环节都不卡死？
//       → ⬜ 尚未跑（**属 B 的 W2 活**）……**B 须在 W2 内跑完并回报**。」
//
//   同一条里 B 提的落点就是 `refsim/pe1/uart_proto_tb.v` + `refsim/run_uart_check.sh`
//   （A 已于 2026-09-29 回「认」）。所以：
//
//     · 最终位置 = `refsim/pe1/uart_proto_tb.v`，运行脚本 = `refsim/run_uart_check.sh`
//     · 现在是 A 起草的一版，临时放在 A 的目录里**等 B 取走**
//     · B 取走后**这个文件归 B**，B 可以任意改写、拆分、推倒重来
//
//   A 为什么会先写：写板级 FSM 时需要一个能自己跑的东西，写完才发现规模
//   已经超出「冒烟」、等于把 B 的活做了一遍。A 那边只留 `tb/smoke_tb.v`。
//   本文件移交时**已经能跑**，且抓到过 `proto_fsm.v` / `uart_line_rx.v` 三个真
//   bug（见文件末「移交说明」）。
//
// ---------------------------------------------------------------------------
// 这不是「把字节塞进 proto_fsm」的单元测试，是**位级**的：测试台自己按
// 115200-8N1 在 `uart_rxd` 上翻电平、在 `uart_txd` 上按中点采样。
// 换句话说，**真的 uart_rx / uart_tx / 行组装 / 协议机 / 核 / 缓冲全在环路里**
// —— 上板之前能验的东西，这里一次性全验掉，只差一个 CH340。
//
// ---------------------------------------------------------------------------
// 测试台是「电脑」的替身：它必须遵守协议里电脑那侧的每一条义务
// （发命令 → 等 `#OK` → 才发数据 → 说完全部数据行等 `#BEGIN` → 收 256 行 → 等 `#DONE`）。
// 不遵守的话测出来的是测试台的错，不是板子的错。
//
// ---------------------------------------------------------------------------
// 用例清单
//
//   T0  ★ 测试台自检：用**协议文档里逐字给出的 7 个校验和**验测试台自己的
//         异或实现。这一条不过，下面全都不用看 —— 判据本身先得是对的。
//   T1  #PING                       → #OK PING*..
//   T2  #ABORT                      → #OK ABORT*..
//   T3  #FOO 1（未知命令）           → #ERR 01 0*..
//   T4  #PING 但校验和故意写错        → #ERR 03 got=00 exp=33*..
//   T5  #NTT 1 端到端                → #OK → #BEGIN NTT 1 256 → 256 行结果 → #DONE
//                                     结果逐行对拍 refsim/batch/ntt_batch_exp.txt 第 0 组
//                                     （按 FNTT pe1 的交织读出顺序 0,2,1,3 还原系数下标）
//   T6  #NTT 1 + 数据行 `0z4`        → #ERR 04 2*..   （§5.5 注入错误 ②）
//   T7  #NTT 1 + 收 1 行后停住        → #ERR 05 1*..   （§5.5 注入错误 ①）
//   T8  板子在等数据段时必须**一个字都不发**（§5.5「一个字节都不许主动发」）
//
//   §5.5 注入错误 ③（电脑侧 T_OK 超时后发 #ABORT → 重发 → 干净退出）是**电脑侧**的
//   行为，在 `host/` 里，不在这里。这里只验板子侧：T8 证明它不抢话，
//   T7 里紧跟的 #ABORT 证明它超时后确实回到了「等命令行」。
//
// ⚠️ 没测到的（不要当成测过了）：#ERR 02（参数非法）、#ERR 06（板内核超时）、
//    #ERR 07（忙）。06 需要让核不回 done，07 需要违反一问一答 —— 本测试台都在
//    协议内动作，造不出来。三条都是靠读代码确认的，不是靠这一轮跑出来的。
//
// ---------------------------------------------------------------------------
// 跑法：`sh refsim/run_uart_check.sh`（脚本自己 cd 到 refsim/）
//       —— 2026-10-06 本文件已从 A 的 `rtl/board/tb/` 搬到 `refsim/pe1/`，
//          $readmemh 随之由 `../../../refsim/batch/...` 改为 `batch/...`
//          （与同目录兄弟 tb 一致）。加 `+fast` 跳过 T5（占九成以上仿真时间）
// ===========================================================================

`timescale 1ns/1ps

module board_tb;

    // =====================================================================
    // 0. 常量
    // =====================================================================
    localparam integer CLK_FREQ = 50_000_000;
    localparam integer UART_BPS = 115200;

    localparam real CLK_HALF_NS = 10.0;             // 20 ns 周期 → 50 MHz
    localparam integer BIT_NS      = 8680;          // 1 位 = 434 拍 × 20 ns
    localparam integer HALF_BIT_NS = 4340;          // 半位 → 采样落在位的正中

    // ★ 缩短的超时（真值是 1 s / 10 s / 100 ms @50 MHz）
    //
    //   为什么 T_LINE 不能取更小：板子一进数据段，T_LINE 就开始计时，
    //   而这时电脑还在**收 `#OK`**（11 字节 ≈ 47740 拍）——协议规定电脑
    //   必须等 `#OK` 到了才发数据。所以 T_LINE 必须明显大于 47740 拍，
    //   留 4 倍余量 → 200000 拍（4 ms）。
    //   真值 1 s 对应约 21000 倍余量，怎么都不会误判；这里只是把余量压到
    //   够用，省仿真时间。
    localparam integer T_LINE_CC = 300_000;
    //   T_CMD / T_CORE 用真值：**只有真的触发才会花时间**，平时不占预算。
    localparam integer T_CMD_CC  = 500_000_000;
    localparam integer T_CORE_CC =   5_000_000;
    localparam integer READ_LAT  = 5;               // H1 §二：走 _top 时 read_* 后第 5 拍

    localparam integer GUARD_CC  = 800_000;         // 收一个字节的护栏（16 ms）
    localparam real    MAX_NS    = 900_000_000.0;   // 全局护栏（0.9 s）

    // =====================================================================
    // 1. DUT
    // =====================================================================
    reg  sys_clk = 1'b0;
    reg  sys_rst_n = 1'b0;
    reg  uart_rxd  = 1'b1;
    wire uart_txd;

    always #(CLK_HALF_NS) sys_clk = ~sys_clk;

    ntt_board_top #(
        .PE_NUMBER  (1),
        .CLK_FREQ   (CLK_FREQ),
        .UART_BPS   (UART_BPS),
        .T_LINE_CC  (T_LINE_CC),
        .T_CMD_CC   (T_CMD_CC),
        .T_CORE_CC  (T_CORE_CC),
        .READ_LAT   (READ_LAT)
    ) dut (
        .sys_clk   (sys_clk),
        .sys_rst_n (sys_rst_n),
        .uart_rxd  (uart_rxd),
        .uart_txd  (uart_txd)
    );

    // =====================================================================
    // 2. 全局护栏 —— 任何没有上限的等待都不许存在（CLAUDE.md 约定 2）
    // =====================================================================
    initial begin
        #(MAX_NS);
        $display("");
        $display("FAIL_WATCHDOG: 仿真跑到 %0.0f ns 还没结束 —— 有等待没有上限。", MAX_NS);
        $finish;
    end

    // =====================================================================
    // 3. 工具函数
    // =====================================================================
    integer nfail = 0;
    integer nchk  = 0;

    reg [8*128-1:0] dbg_rs;     // 只为了把函数结果先落进变量再进 $display

    // ---- 半字节 → 小写 ASCII ----
    function [7:0] hexchar(input [3:0] n);
        begin
            hexchar = (n < 4'd10) ? (8'h30 + {4'b0, n})
                                  : (8'h61 + {4'b0, n} - 8'd10);
        end
    endfunction

    // ---- ASCII → 半字节（只吃小写；测试台只发小写）----
    function [3:0] hexnib(input [7:0] ch);
        begin
            hexnib = (ch >= 8'h30 && ch <= 8'h39) ? (ch - 8'h30)
                                                  : (ch - 8'h61 + 4'd10);
        end
    endfunction

    // ---- 3 字符 → 12 位 ----
    function [11:0] hex3val(input [7:0] a, input [7:0] b, input [7:0] c);
        begin
            hex3val = { hexnib(a), hexnib(b), hexnib(c) };
        end
    endfunction

    // ---- 异或校验：从行首第一个字符起算，不含 `*`、不含 LF、不含被忽略的 CR ----
    //      ⚠️ 这是测试台自己的一份独立实现（不信 RTL 那一份）。T0 验它。
    function [7:0] xorsum(input [8*32-1:0] s, input integer n);
        integer i, ib;
        begin
            xorsum = 8'h00;
            for (i = 0; i < n; i = i + 1) begin
                ib = (n - 1 - i) * 8;               // ⚠️ 先算进 integer，别直接 bit-select 表达式
                xorsum = xorsum ^ s[ib +: 8];
            end
        end
    endfunction

    // ---- 取出字符串 s 的第 i 个字符（0 基，右对齐）----
    function [7:0] schar(input [8*32-1:0] s, input integer n, input integer i);
        integer ib;
        begin
            ib = (n - 1 - i) * 8;
            schar = s[ib +: 8];
        end
    endfunction

    // =====================================================================
    // 4. 假的串口发送侧（测试台 = 电脑）
    // =====================================================================
    task send_byte(input [7:0] b);
        integer i;
        begin
            uart_rxd = 1'b0;  #(BIT_NS);                    // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                uart_rxd = b[i];  #(BIT_NS);                // LSB 先发
            end
            uart_rxd = 1'b1;  #(BIT_NS);                    // 停止位
        end
    endtask

    // 正文 n 字符 + `*` + 两位**指定**校验 + LF
    task send_ps(input [8*32-1:0] s, input integer n, input [7:0] k);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) send_byte(schar(s, n, i));
            send_byte(8'h2A);                               // '*'
            send_byte(hexchar(k[7:4]));
            send_byte(hexchar(k[3:0]));
            send_byte(8'h0A);                               // LF
        end
    endtask

    // 正文 n 字符 + 自算校验 + LF（正常命令走这条）
    task send_cmd(input [8*32-1:0] s, input integer n);
        begin
            send_ps(s, n, xorsum(s, n));
        end
    endtask

    // 一条数据行：3 位小写十六进制 + LF
    task send_data(input [11:0] v);
        begin
            send_byte(hexchar(v[11:8]));
            send_byte(hexchar(v[7:4]));
            send_byte(hexchar(v[3:0]));
            send_byte(8'h0A);
        end
    endtask

    // =====================================================================
    // 5. 假的串口接收侧（板子 → 测试台）
    // =====================================================================
    reg [7:0] rbuf [0:1023];
    integer   rlen;

    // 假定起始位**已经**被看到（调用方轮询到 uart_txd==0），此刻约在起始位开头。
    task recv_byte_raw(output [7:0] b);
        integer i;
        begin
            // ⚠️⚠️ 必须等 **1.5 位**，不是 0.5 位。
            //   等 0.5 位落点是**起始位正中**，接着采到的第一个值就是起始位 0 ——
            //   整字节左移一位（0x23 收成 0x46）。错位是静默的，现象是
            //   「板子没回话」，而板子其实回得好好的。A 在这里踩过一次。
            //   1.5 位才是 bit0 正中；循环结束时落在停止位正中。
            #(BIT_NS + HALF_BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_txd;                            // 每一位的正中采样
                #(BIT_NS);
            end
        end
    endtask

    // 等起始位（带上限），然后收 8 位
    task recv_byte(output [7:0] b);
        integer w;
        begin
            w = 0;
            while ((uart_txd !== 1'b0) && (w < GUARD_CC)) begin
                @(posedge sys_clk);  w = w + 1;
            end
            if (w >= GUARD_CC) begin
                $display("");
                $display("FAIL_TIMEOUT: 等串口起始位超过 %0d 拍（%.2f ms）—— 板子没回话。",
                         GUARD_CC, GUARD_CC * 20.0 / 1000000.0);
                $finish;
            end
            recv_byte_raw(b);
        end
    endtask

    // 收一整行（到 LF 为止，LF 不计入）
    task recv_line;
        integer i; reg stop; reg [7:0] c;
        begin
            i = 0; stop = 0;
            while (!stop) begin
                recv_byte(c);
                if (c == 8'h0A) stop = 1;
                else begin rbuf[i] = c;  i = i + 1; end
            end
            rlen = i;
        end
    endtask

    // 尝试收一行：max_cc 拍内没等到起始位就算「没收到」（不是失败）
    task try_recv_line(output integer got, input integer max_cc);
        integer w, i; reg stop, first; reg [7:0] c;
        begin
            w = 0;
            while ((uart_txd !== 1'b0) && (w < max_cc)) begin
                @(posedge sys_clk);  w = w + 1;
            end
            if (w >= max_cc) begin
                got = 0;
            end else begin
                // ⚠️ 用 first 标记，不要用 `i == 0` —— 万一第一行是空行，
                //    i 会一直为 0，下一字节就会被当成「起始位已看到」而采错。
                i = 0; stop = 0; first = 1;
                while (!stop) begin
                    if (first) begin recv_byte_raw(c); first = 0; end
                    else             recv_byte(c);
                    if (c == 8'h0A) stop = 1;
                    else begin rbuf[i] = c;  i = i + 1; end
                end
                rlen = i;
                got = 1;
            end
        end
    endtask

    // =====================================================================
    // 6. 期望值构建与比对
    // =====================================================================
    reg [8*128-1:0] expbuf;
    integer         explen;

    // 把「正文 s（n 字符）」+ 自算校验 装进 expbuf（与 rbuf 同一套右对齐字节序）
    task exp_set(input [8*32-1:0] s, input integer n);
        integer i, ebi; reg [7:0] k;
        begin
            explen = n + 3;                                 // 正文 + '*' + 2 位
            expbuf = {8*128{1'b0}};
            for (i = 0; i < n; i = i + 1) begin
                ebi = (explen - 1 - i) * 8;
                expbuf[ebi +: 8] = schar(s, n, i);
            end
            k = xorsum(s, n);
            ebi = (explen - 1 - n) * 8;         expbuf[ebi +: 8] = 8'h2A;
            ebi = (explen - 2 - n) * 8;         expbuf[ebi +: 8] = hexchar(k[7:4]);
            ebi = (explen - 3 - n) * 8;         expbuf[ebi +: 8] = hexchar(k[3:0]);
        end
    endtask

    // 可打印版本，出错时看原样
    //   ⚠️ 形参 dummy 是白给的：iverilog 要求函数至少有一个输入端口，
    //      而这两个函数只读全局量。调用写 rbuf_str(1'b0)。
    function [8*128-1:0] rbuf_str(input dummy);
        integer i, ib;
        begin
            rbuf_str = {8*128{1'b0}};
            for (i = 0; i < rlen; i = i + 1) begin
                ib = (rlen - 1 - i) * 8;
                rbuf_str[ib +: 8] = rbuf[i];
            end
        end
    endfunction

    function [8*128-1:0] expbuf_str(input dummy);
        integer i, ib;
        begin
            expbuf_str = {8*128{1'b0}};
            for (i = 0; i < explen; i = i + 1) begin
                ib = (explen - 1 - i) * 8;
                expbuf_str[ib +: 8] = expbuf[ib +: 8];
            end
        end
    endfunction

    // 整行比对（用 exp_set 装好的期望）
    //   ⚠️ 结果要先落进一个变量再进 $display —— iverilog 不接受把函数调用
    //      直接当 $display 的实参（"does not support argument type vpiFunction"）。
    task exp_check(input [8*48-1:0] tag);
        integer i, bad, ebi;
        reg [8*128-1:0] rs, es;
        begin
            nchk = nchk + 1;
            bad  = 0;
            rs = rbuf_str(1'b0);
            es = expbuf_str(1'b0);
            if (rlen !== explen) bad = 1;
            else for (i = 0; i < rlen; i = i + 1) begin
                ebi = (explen - 1 - i) * 8;
                if (rbuf[i] !== expbuf[ebi +: 8]) bad = 1;
            end
            if (bad) begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", tag);
                $display("         实收 = %0s  (%0d 字符)", rs, rlen);
                $display("         期望 = %0s  (%0d 字符)", es, explen);
            end else begin
                $display("  [ ok ] %-18s -> %0s", tag, rs);
            end
        end
    endtask

    // 只比前 n 个字符（用于位置/数值无所谓、只要类别对的场合）
    task exp_check_prefix(input [8*48-1:0] tag, input integer n, input [8*32-1:0] want, input integer wn);
        integer i, bad;
        reg [8*128-1:0] rs;
        begin
            nchk = nchk + 1;
            bad = 0;
            rs = rbuf_str(1'b0);
            if (rlen < n) bad = 1;
            else for (i = 0; i < n; i = i + 1) begin
                if (rbuf[i] !== schar(want, wn, i)) bad = 1;
            end
            if (bad) begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s：前 %0d 个字符不符", tag, n);
                $display("         实收 = %0s", rs);
            end else begin
                $display("  [ ok ] %-18s -> %0s", tag, rs);
            end
        end
    endtask

    // =====================================================================
    // 7. 黄金向量
    // =====================================================================
    localparam integer NV = 16;                         // 文件里有 16 组
    reg [11:0] vin  [0:NV*256-1];
    reg [11:0] vexp [0:NV*256-1];

    // FNTT pe1 的读出顺序：第 m 拍 / 第 m 行 对应**系数下标** perm(m)
    //   依据 refsim/pe1/fntt_batch_tb.v:108-113 —— 每 4 拍一组，组内顺序 0,2,1,3
    //   （即交换组内的第 2、3 个）。装载侧三档都是自然序，不用管。
    function integer perm(input integer m);
        integer q;
        begin
            q = m % 4;
            if      (q == 1) perm = m + 1;
            else if (q == 2) perm = m - 1;
            else             perm = m;
        end
    endfunction

    // =====================================================================
    // 8. 主流程
    // =====================================================================
    integer i, m, got, nerr, idx, uniq, j, dup;
    reg [11:0] v;
    reg [7:0]  c;
    integer    skip_ntt;

    initial begin
        $readmemh("batch/ntt_batch_in.txt" , vin);
        $readmemh("batch/ntt_batch_exp.txt", vexp);

        skip_ntt = $test$plusargs("fast");

        // ---- 复位 ----
        sys_rst_n = 1'b0;
        #200;
        sys_rst_n = 1'b1;
        #2000;

        // =============================================================
        // T0 ★ 测试台自检：拿协议文档里逐字给出的 7 个校验和验自己的异或
        //
        //   全对 ⇒ 本测试台这份异或实现与协议一致，后面的判据才是判据。
        //   有一条不对 ⇒ 立刻停，不然下面测出来的全是测试台自己的错。
        //   出处：host/proto.md:218/221/233/237/304 与 §5.4 的 `#PING*33`/`#ABORT*69`。
        // =============================================================
        $display("");
        $display("========== T0 测试台自检（异或 vs 协议文档的 7 个已发表值）==========");
        begin : t0
            integer bad;
            bad = 0;
            bad = bad + xcheck("#PMUL TIME 1"          , 13, 8'h03);
            bad = bad + xcheck("#OK PMUL TIME 1"       , 16, 8'h27);
            bad = bad + xcheck("#BEGIN PMUL TIME 1 256", 22, 8'h75);
            bad = bad + xcheck("#DONE PMUL TIME 1 256" , 21, 8'h32);
            bad = bad + xcheck("#ERR 03 got=3f exp=a2" , 21, 8'h52);
            bad = bad + xcheck("#PING"                 ,  5, 8'h33);
            bad = bad + xcheck("#ABORT"                ,  6, 8'h69);
            if (bad != 0) begin
                $display("  **测试台自己的异或实现就是错的，后面的用例没有意义。停。**");
                nfail = nfail + bad;
                $finish;
            end
            $display("  7/7 全对 —— 测试台的判据与协议一致。");
        end

        // =============================================================
        $display("");
        $display("========== T1  #PING ==========");
        send_cmd("#PING", 5);
        recv_line();
        exp_set("#OK PING", 8);
        exp_check("T1 #OK PING");

        // =============================================================
        $display("");
        $display("========== T2  #ABORT ==========");
        send_cmd("#ABORT", 6);
        recv_line();
        exp_set("#OK ABORT", 9);
        exp_check("T2 #OK ABORT");

        // =============================================================
        $display("");
        $display("========== T3  未知命令 #FOO 1 ==========");
        send_cmd("#FOO 1", 6);
        recv_line();
        exp_set("#ERR 01 0", 9);
        exp_check("T3 #ERR 01 0");

        // =============================================================
        $display("");
        $display("========== T4  校验和故意写错 ==========");
        // #PING 的真校验是 33；故意发 00 → 板子应回 #ERR 03 got=00 exp=33
        send_ps("#PING", 5, 8'h00);
        recv_line();
        exp_set("#ERR 03 got=00 exp=33", 21);
        exp_check("T4 #ERR 03");

        // =============================================================
        $display("");
        $display("========== T5  #NTT 1 端到端（256 行进、256 行出）==========");

        // ---- 非退化检查：先看这一组向量是不是「有内容的」----
        //   §CLAUDE.md 约定 3：全 0 / 常量的向量「全中」可能只是巧合。
        uniq = 0;
        for (i = 0; i < 256; i = i + 1) begin
            dup = 0;
            for (j = 0; j < i; j = j + 1)
                if (vexp[j] === vexp[i]) dup = 1;
            if (!dup) uniq = uniq + 1;
        end
        $display("  第 0 组期望值：256 个系数里 %0d 个不同值（要求 > 128，否则判据是退化的）", uniq);
        nchk = nchk + 1;
        if (uniq > 128) $display("  [ ok ] 非退化");
        else begin
            $display("  [FAIL] 向量退化 —— 「全中」不能算通过");
            nfail = nfail + 1;
        end

        if (!skip_ntt) begin
            // ---- 发命令，等 #OK（协议：收到 #OK 之前一个数据字节都不许发）----
            send_cmd("#NTT 1", 6);
            recv_line();
            exp_set("#OK NTT 1", 9);
            exp_check("T5 #OK NTT 1");

            // ---- 规律地灌 256 行（FNTT 装载 = 自然序）----
            for (i = 0; i < 256; i = i + 1) send_data(vin[i]);
            $display("  已发 256 条数据行，等 #BEGIN ...");

            // ---- 等 #BEGIN（真值 T_BEGIN = 5 s；这里核只跑 ~2500 拍）----
            recv_line();
            exp_set("#BEGIN NTT 1 256", 16);
            exp_check("T5 #BEGIN");

            // ---- 收 256 行结果，逐行对拍 ----
            nerr = 0;
            for (m = 0; m < 256; m = m + 1) begin
                recv_line();
                nchk = nchk + 1;
                if (rlen !== 3) begin
                    if (nerr < 5) $display("  [FAIL] 第 %0d 行不是 3 个字符（收到 %0d）", m, rlen);
                    nerr = nerr + 1;
                end else begin
                    v   = hex3val(rbuf[0], rbuf[1], rbuf[2]);
                    idx = perm(m);
                    if (v !== vexp[idx]) begin
                        if (nerr < 5)
                            $display("  [FAIL] 第 %0d 行：实收 %03x，期望 %03x（系数下标 %0d）",
                                     m, v, vexp[idx], idx);
                        nerr = nerr + 1;
                    end
                end
            end
            if (nerr == 0) $display("  [ ok ] 256/256 行结果与黄金向量一致（读出顺序已按 0,2,1,3 还原）");
            else begin
                $display("  [FAIL] 256 行里有 %0d 行不符", nerr);
                nfail = nfail + 1;
            end

            // ---- 等 #DONE ----
            recv_line();
            exp_set("#DONE NTT 1 256", 15);
            exp_check("T5 #DONE");
        end
        else $display("  （+fast：已跳过 T5）");

        // =============================================================
        $display("");
        $display("========== T6  数据行里放一个非十六进制字符 ==========");
        //   §5.5 注入错误 ②：应回 #ERR 04 并报出**第一个非法字符的位置**（1 基）
        //   `0z4` —— 第 2 个字符非法 → 位置 2
        send_cmd("#NTT 1", 6);
        recv_line();
        exp_set("#OK NTT 1", 9);
        exp_check("T6 #OK NTT 1");
        send_byte(8'h30); send_byte(8'h7A); send_byte(8'h34); send_byte(8'h0A);   // "0z4\n"
        recv_line();
        exp_set("#ERR 04 2", 9);
        exp_check("T6 #ERR 04 2");

        // =============================================================
        $display("");
        $display("========== T7  T_LINE 行超时 ==========");
        //   §5.5 注入错误 ①：发半行就停 → 应回 #ERR 05，位置 = 已收到的行数
        //   板子必须回到「等命令行」，否则后面全线错位（关键规则一）
        send_cmd("#NTT 1", 6);
        recv_line();
        exp_set("#OK NTT 1", 9);
        exp_check("T7 #OK NTT 1");
        send_data(vin[0]);                              // 收满 1 行
        send_byte(8'h30); send_byte(8'h34);             // 再发半个行就停住
        $display("  已发 1 行 + 半行，停住等 T_LINE（%0d 拍 = %.2f ms）...",
                 T_LINE_CC, T_LINE_CC * 20.0 / 1000000.0);
        recv_line();
        exp_set("#ERR 05 1", 9);
        exp_check("T7 #ERR 05 1");

        // ---- 关键规则一验证：板子确实回到了「等命令行」----
        //   按关键规则二，电脑此时该先发 #ABORT 再判败。板子必须正常应答。
        $display("  （关键规则二）超时后先发 #ABORT，验板子已回到「等命令行」：");
        send_cmd("#ABORT", 6);
        recv_line();
        exp_set("#OK ABORT", 9);
        exp_check("T7 #OK ABORT（回到等命令行）");

        // =============================================================
        $display("");
        $display("========== T8  等数据段时板子必须一个字都不发 ==========");
        //   §5.5：板子在收到完整命令行之前一个字节都不许主动发（否则电脑看到
        //   归属不明的行 → 按关键规则四停整轮测试）。
        //   这里反过来验：发出命令、收到 #OK 之后**故意不发数据**，
        //   板子除了它该发的 #OK 之外不该再有任何动作 —— 直到 T_LINE 到点回 #ERR 05。
        send_cmd("#NTT 1", 6);
        recv_line();
        exp_set("#OK NTT 1", 9);
        exp_check("T8 #OK NTT 1");

        // 在 T_LINE 到点**之前**的窗口里偷看：应该一无所获
        try_recv_line(got, 100_000);                    // 100000 拍 = 2 ms，T_LINE 是 6 ms
        nchk = nchk + 1;
        if (got == 0) begin
            $display("  [ ok ] 2 ms 内板子保持安静（只发了它该发的 #OK）");
        end else begin
            dbg_rs = rbuf_str(1'b0);
            $display("  [FAIL] 板子主动发了意料外的一行：%0s", dbg_rs);
            nfail = nfail + 1;
        end

        // 到点后它应该发 #ERR 05（位置 0：一行都没收到）
        recv_line();
        exp_set("#ERR 05 0", 9);
        exp_check("T8 #ERR 05 0（一行未收）");

        // ---- 收尾：清干净，别让下一条命令踩到半行 ----
        send_cmd("#ABORT", 6);
        recv_line();
        exp_set("#OK ABORT", 9);
        exp_check("T8 收尾 #OK ABORT");

        // =============================================================
        $display("");
        $display("==================== 汇总 ====================");
        $display("  比对点 %0d 个，失败 %0d 个", nchk, nfail);
        if (nfail == 0) $display("  结论：全部通过。");
        else            $display("  结论：**有失败**（上面标 [FAIL] 的行）。");
        $display("==============================================");
        $display("");
        $finish;
    end

    // ---- T0 用的小工具：验一条已知值的异或 ----
    function integer xcheck(input [8*32-1:0] s, input integer n, input [7:0] want);
        reg [7:0] got;
        begin
            got = xorsum(s, n);
            if (got !== want) begin
                $display("  [FAIL] xorsum(\"%0s\") = %02x，协议文档写的是 %02x", s, got, want);
                xcheck = 1;
            end else begin
                $display("  [ ok ] xorsum(\"%0s\") = %02x", s, got);
                xcheck = 0;
            end
        end
    endfunction

endmodule

// ===========================================================================
// 移交说明（A → B，2026-10-04）—— B 取走后可以整段删掉
// ===========================================================================
//
// 一、怎么跑
//
//     sh run_uart_check.sh            # 全套（含 T5 端到端 NTT，慢，几分钟）
//     sh run_uart_check.sh +fast      # 跳过 T5，只跑协议与错误处理（秒级）
//
//     ⚠️ 脚本里已经 cd 到本目录再跑 —— `$readmemh` 的相对路径是按**进程工作
//        目录**解析的，不是按 .v 文件的位置。
//        —— 2026-10-06 已照此办理：搬进 `refsim/pe1/` 后，两条 `$readmemh`
//           改成 `batch/ntt_batch_*.txt`（工作目录 = refsim/，与兄弟 tb 一致）。
//
// 二、这套东西抓到过什么（都是 `rtl/board/proto_fsm.v` 的真 bug，A 已修）
//
//     bug 1  回显多带一个 `#`。`#PING` 回了 `#OK #PING`，而 proto.md:211/221
//            逐字要求回 `#OK PING`。按关键规则四，回显对不上 = 停整轮测试，
//            是代价最大的一类错。
//            ⚠️ 修法有个坑值得记：**不能靠多右移一位去掉行首字符**。
//               右移只能从**低位**丢字节，而右对齐串的行首在**最高**字节上，
//               移多少都丢不掉（试过 `>>32`：`#PING*33` 变成 `#PIN`，把 `G` 也丢了）。
//               正解是**字节位原样不动、只把声明长度减 1**，取值口径自然从第 2 个
//               字符读起。改动在 `proto_fsm.v` 两处（S_IDLE 与 S_DATA 的 #ABORT 分支）。
//
//     bug 2  应答长度把校验算了两遍。`S_RESP` 相位 1 已经把 `*xx` 的 3 字节计进
//            `tx_len`，相位 2 又写了 `tx_len + 7'd3` —— 多发 3 个字节，而那 3 个
//            字节取自正文**上方**的残留位（首次应答时是全 0），现象是回帧前面
//            挂一串 `0x00`。改成 `txl_len <= tx_len` 即可。
//
//     bug 3  **超时之后板子再也不出声**（T7 抓到，最隐蔽的一个）。
//            §5.5 关键规则一要求超时后回到「等命令行」，电脑按关键规则二会先发
//            `#ABORT*69`。实测：T_LINE 超时回了 `#ERR 05 1` 之后，紧接着的
//            `#ABORT` **完全没有应答**，测试卡死。
//            根因不在协议机，在 `rtl/board/uart_line_rx.v`：协议机的两个 `clr`
//            调用点都是超时，而 `clr` 当时的语义是「丢掉半行、**等 LF 重新同步**」
//            （`drop <= 1'b1`，只在 LF 分支清 0）。可超时的前提恰恰是「本行的 LF
//            不会来了」—— 于是 `drop` 挂起在一个永远等不到的 LF 上，把**下一条
//            完整命令行**整条吞掉。
//            改成**硬清**（`drop <= 1'b0`，下一个字节就重开一行）。
//            ⚠️ 现象具有强烈的误导性：「板子一开始好好的，超时一次之后就再也不
//               回话」，第一反应会去怀疑电脑侧或串口线。写协议类 RTL 时，
//               「丢半行」到底是丢到行尾还是立刻重开，这两种语义得分清楚。
//
//     三个 bug 都属于「上了板才会看见、看见了也很难定位」那种 —— 回帧里多几个
//     不可见字符，串口助手上就是一串乱码。这是 §七 红线「仿真能抓到的问题不要
//     留到板上去抓」的一个具体例子。
//
//     ⚠️ 另有两处**不是板子的问题**，是本测试台自己写错了期望串长度，A 已改：
//        `"#OK NTT 1"` 是 9 个字符（写成了 8）、
//        `"#ERR 03 got=00 exp=33"` 是 21 个字符（写成了 20）。
//        长度少 1 会让 tb 从第 2 个字符起比对、校验和也随之算错，
//        现象是「板子回的帧看起来完全正确，tb 却判 FAIL」。板子那两个值
//        按 §5.4 手算是 0x58 和 0x54，没错。
//
// 三、A 这边没有覆盖的（别当成测过了）
//
//     T5 之外 A 另有一个**冒烟台** `tb/smoke_tb.v`（只验 `#PING` 回帧 + `#NTT`
//     端到端）。两者的分工：冒烟台是 A 上板前的闸门，本文件是协议验收。
//     A 不维护本文件 —— 有改动、有新增用例，都在 B 那边做。
//
// 四、A 没有验证过的协议条目（本文件里也没有）
//
//     `#ERR 02`（参数非法）、`#ERR 06`（板内核超时）、`#ERR 07`（忙）三条都是
//     靠读代码确认的，没有用例。06 需要让核不回 done、07 需要违反一问一答，
//     本测试台都在协议内动作，造不出来。见文件头「没测到的」一节。
//
// ===========================================================================
