// ===========================================================================
// smoke_tb.v —— 板级 wrapper 的**冒烟台**（A 的，上板前的闸门）
//
// 这不是协议验收台。协议验收（§5.5 三条注入错误、校验和、错误码、超时）
// 是 **B 的 W2 活**，见 `host/proto.md` §六第 12 条第 3 问 ——
// A 起草的那版在 `tb/uart_proto_tb.v`，等 B 取走，A 不维护。
//
// 这里只回答一个问题：**这块板子值得花十几分钟去综合、实现、下载吗？**
// 所以只验两条，都是「错了就是白烧一遍板子」的那种：
//
//   S1  #PING 的回帧逐字节正确（含校验和）—— 协议通路的端点检查
//   S2  #NTT 1 端到端：256 行数据进去、256 行结果出来，
//       结果逐行对拍 refsim/batch/ntt_batch_exp.txt 第 0 组
//       （按 FNTT pe1 的交织读出顺序 0,2,1,3 还原系数下标）
//
// S2 是重点：它是**整个数据通路**的检查 —— 串口收发 + 行组装 + 协议机 +
// 十六进制解析 + 装载口时序 + NTT 核 + 读出顺序 + 回传。任何一环接错，
// S2 都会红。而 S2 红了就不该上板（§七 红线：仿真能抓到的问题不要留到板上抓）。
//
// ---------------------------------------------------------------------------
// ⚠️ 这里**故意不测**的东西（不要以为测过了）：
//   · 各种 #ERR 错误码、超时行为、#ABORT  —— 归 B 的协议验收台
//   · #INTT / #PMUL（三种域）—— 本轮只做 pe1 折叠度的 NTT 一条路
//   · FNTT 以外的读出顺序
//
// 跑法：sh run_board_check.sh        （必须经脚本跑 —— 见脚本里的路径说明）
//       sh run_board_check.sh +dump  ← 诊断用：S2 只读到第 24 行就收工，
//         逐行打印「收到的值原本落在黄金向量的第几号」。顺序类问题靠肉眼比对
//         数字是猜（第 0 行 000、后面各自错位都能编出故事），把命中的下标打出来，
//         映射关系一眼可见；命中 -1 就说明这个值根本不在黄金向量里 ——
//         那问题在装载侧或核，不在读出顺序。
// ===========================================================================

`timescale 1ns/1ps

module smoke_tb;

    // =====================================================================
    // 0. 常量
    // =====================================================================
    localparam integer CLK_FREQ = 50_000_000;
    localparam integer UART_BPS = 115200;

    localparam real    CLK_HALF_NS = 10.0;          // 20 ns 周期 → 50 MHz
    localparam integer BIT_NS      = 8680;          // 1 位 = 434 拍 × 20 ns
    localparam integer HALF_BIT_NS = 4340;

    // ★ 超时用真值。板子这边平时不触发，触发才花时间，所以不占仿真预算。
    //   ⚠️ T_LINE 不能用真值 1 s —— 原因见 uart_proto_tb.v 的文件头：
    //      板子一进数据段 T_LINE 就开始计时，而这时电脑还在收 #OK（约 47740 拍）。
    //      真值下余量两万倍，这里按 4 倍余量取 300000 拍（6 ms）省时间。
    localparam integer T_LINE_CC = 300_000;
    localparam integer T_CMD_CC  = 500_000_000;
    localparam integer T_CORE_CC =   5_000_000;
    localparam integer READ_LAT  = 5;               // H1 §二：走 _top 时 read_* 后第 5 拍

    localparam integer GUARD_CC  = 800_000;         // 收一个字节的护栏（16 ms）
    localparam real    MAX_NS    = 900_000_000.0;   // 全局护栏（0.9 s）

    // H1 §五：FNTT pe1 的读出顺序 = 交织 0,2,1,3。
    //   依据 refsim/pe1/fntt_batch_tb.v:108-113 —— 每 4 拍一组，组内顺序 0,2,1,3。
    //   即第 m 行结果对应**系数下标** perm(m)。装载侧三档都是自然序，不用管。
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
    // 1. DUT
    // =====================================================================
    reg  sys_clk   = 1'b0;
    reg  sys_rst_n = 1'b0;
    reg  uart_rxd  = 1'b1;
    wire uart_txd;

    always #(CLK_HALF_NS) sys_clk = ~sys_clk;

    ntt_board_top #(
        .PE_NUMBER (1),
        .CLK_FREQ  (CLK_FREQ),
        .UART_BPS  (UART_BPS),
        .T_LINE_CC (T_LINE_CC),
        .T_CMD_CC  (T_CMD_CC),
        .T_CORE_CC (T_CORE_CC),
        .READ_LAT  (READ_LAT)
    ) dut (
        .sys_clk   (sys_clk),
        .sys_rst_n (sys_rst_n),
        .uart_rxd  (uart_rxd),
        .uart_txd  (uart_txd)
    );

    // =====================================================================
    // 2. 全局护栏 —— 任何等待都不许没有上限（CLAUDE.md 约定 2）
    // =====================================================================
    initial begin
        #(MAX_NS);
        $display("");
        $display("FAIL_WATCHDOG: 跑到 %0.0f ns 还没结束 —— 有等待没有上限。", MAX_NS);
        $finish;
    end

    // =====================================================================
    // 3. 小工具
    // =====================================================================
    integer nfail = 0;
    integer nchk  = 0;

    // ---- 半字节 → 小写 ASCII ----
    function [7:0] hexchar(input [3:0] n);
        begin
            hexchar = (n < 4'd10) ? (8'h30 + {4'b0, n})
                                  : (8'h61 + {4'b0, n} - 8'd10);
        end
    endfunction

    // ---- ASCII → 半字节（只吃小写，本测试台只发小写）----
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
    //   §5.4。⚠️ 先算进 integer 再 bit-select —— 直接写表达式会静默截断。
    function [7:0] xorsum(input [8*32-1:0] s, input integer n);
        integer i, ib;
        begin
            xorsum = 8'h00;
            for (i = 0; i < n; i = i + 1) begin
                ib = (n - 1 - i) * 8;
                xorsum = xorsum ^ s[ib +: 8];
            end
        end
    endfunction

    // ---- 取右对齐串的第 i 个字符（0 基）----
    function [7:0] schar(input [8*32-1:0] s, input integer n, input integer i);
        integer ib;
        begin
            ib = (n - 1 - i) * 8;
            schar = s[ib +: 8];
        end
    endfunction

    // ---- 把 (s, n) 摆成右对齐串，供 %0s 打印 ----
    //   ⚠️ 形参 dummy 是白给的：iverilog 要求函数至少有一个输入端口，
    //      而 pad 只读全局/实参以外的东西……这里其实是喂给 s/n 用的，
    //      保留 dummy 是为了和 uart_proto_tb.v 的写法一致。调用写 pad(s, n)。
    function [8*64-1:0] pad(input [8*32-1:0] s, input integer n);
        integer i, ib;
        begin
            pad = {8*64{1'b0}};
            for (i = 0; i < n; i = i + 1) begin
                ib = (n - 1 - i) * 8;
                pad[ib +: 8] = schar(s, n, i);
            end
        end
    endfunction

    // ---- 收缓冲区 ----
    reg [7:0] rbuf [0:1023];
    integer   rlen;

    // ---- rbuf → 右对齐串，供 %0s 打印 ----
    //   ⚠️ dummy 是必需的：iverilog 不接受零输入端口的函数（"Functions must
    //      have at least one input port"）。调用写 rbuf_str(1'b0)。
    function [8*64-1:0] rbuf_str(input dummy);
        integer i, ib;
        begin
            rbuf_str = {8*64{1'b0}};
            for (i = 0; i < rlen; i = i + 1) begin
                ib = (rlen - 1 - i) * 8;
                rbuf_str[ib +: 8] = rbuf[i];
            end
        end
    endfunction

    // =====================================================================
    // 4. 假的串口发送侧（本测试台 = 电脑）
    // =====================================================================
    task send_byte(input [7:0] b);
        integer i;
        begin
            uart_rxd = 1'b0;  #(BIT_NS);                 // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                uart_rxd = b[i];  #(BIT_NS);             // LSB 先发
            end
            uart_rxd = 1'b1;  #(BIT_NS);                 // 停止位
        end
    endtask

    // 正文 n 字符 + 自算校验 + LF
    task send_cmd(input [8*32-1:0] s, input integer n);
        integer i; reg [7:0] k;
        begin
            for (i = 0; i < n; i = i + 1) send_byte(schar(s, n, i));
            k = xorsum(s, n);
            send_byte(8'h2A);                            // '*'
            send_byte(hexchar(k[7:4]));
            send_byte(hexchar(k[3:0]));
            send_byte(8'h0A);                            // LF
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
    // 5. 假的串口接收侧（板子 → 本测试台）
    // =====================================================================
    // 假定起始位**已经**被看到（调用方轮询到 uart_txd==0），此刻约在起始位开头。
    task recv_byte_raw(output [7:0] b);
        integer i;
        begin
            // ⚠️⚠️ 这里必须等 **1.5 位**，不是 0.5 位。
            //   等 0.5 位落点是**起始位的正中**，接着采样的第一个值就是起始位 0 ——
            //   于是整字节左移一位：`#`(0x23) 收成 0x46、`O`(0x4f) 收成 0x9e。
            //   错位是静默的：校验、行尾、长度全都不成立，现象是「板子没回话」，
            //   而板子其实回得好好的。踩过一次，排查了很久。
            //   1.5 位才是 **bit0 的正中**；之后每 BIT_NS 采一位，
            //   循环结束时正好落在停止位正中。
            #(BIT_NS + HALF_BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_txd;                         // 每一位的正中采样
                #(BIT_NS);
            end
        end
    endtask

    task recv_byte(output [7:0] b);
        integer w;
        begin
            w = 0;
            while ((uart_txd !== 1'b0) && (w < GUARD_CC)) begin
                @(posedge sys_clk);  w = w + 1;
            end
            if (w >= GUARD_CC) begin
                $display("");
                $display("FAIL_TIMEOUT: 等串口起始位超过 %0d 拍 —— 板子没回话。", GUARD_CC);
                $finish;
            end
            recv_byte_raw(b);
        end
    endtask

    // 收一整行（到 LF 为止，LF 不计入长度）
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

    // =====================================================================
    // 6. 整行比对：正文 s（n 字符）+ 自算校验
    // =====================================================================
    task chk(input [8*32-1:0] s, input integer n, input [8*48-1:0] tag);
        integer i, bad; reg [7:0] k; reg [8*64-1:0] rs;
        begin
            nchk = nchk + 1;
            k    = xorsum(s, n);
            bad  = 0;
            rs   = rbuf_str(1'b0);
            if (rlen !== n + 3) bad = 1;
            else begin
                for (i = 0; i < n; i = i + 1)
                    if (rbuf[i] !== schar(s, n, i)) bad = 1;
                if (rbuf[n]   !== 8'h2A            ) bad = 1;
                if (rbuf[n+1] !== hexchar(k[7:4]))  bad = 1;
                if (rbuf[n+2] !== hexchar(k[3:0]))  bad = 1;
            end
            if (bad) begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", tag);
                $display("         实收 = %0s   (%0d 字符)", rs, rlen);
                $display("         期望 = %0s*%c%c", pad(s, n),
                                                           hexchar(k[7:4]), hexchar(k[3:0]));
            end else begin
                $display("  [ ok ] %-16s -> %0s", tag, rs);
            end
        end
    endtask

    // =====================================================================
    // 7. 黄金向量
    // =====================================================================
    localparam integer NV = 16;
    reg [11:0] vin  [0:NV*256-1];
    reg [11:0] vexp [0:NV*256-1];

    // =====================================================================
    // 8. 主流程
    // =====================================================================
    integer i, m, nerr, idx, uniq, j, dup, hit;
    reg [11:0] v;
    reg        dump;

    initial begin
        dump = 0;
        if ($test$plusargs("dump")) dump = 1;
        $readmemh("../../../refsim/batch/ntt_batch_in.txt" , vin);
        $readmemh("../../../refsim/batch/ntt_batch_exp.txt", vexp);

        sys_rst_n = 1'b0;
        #200;
        sys_rst_n = 1'b1;
        #2000;

        // =============================================================
        $display("");
        $display("========== S1  #PING 回帧 ==========");
        // =============================================================
        // 协议 §5.2：收到 `#PING` 回 `#OK PING*17`。校验和 0x17 由本测试台
        // 自己按 §5.4 算（xorsum），不抄硬编码值 —— 抄了就测不出校验错。
        send_cmd("#PING", 5);
        recv_line();
        chk("#OK PING", 8, "S1 #OK PING");

        // =============================================================
        $display("");
        $display("========== S2  #NTT 1 端到端（256 行进、256 行出）==========");
        // =============================================================

        // ---- 非退化检查：向量全是 0/常量时「全中」可能只是巧合（约定 3）----
        uniq = 0;
        for (i = 0; i < 256; i = i + 1) begin
            dup = 0;
            for (j = 0; j < i; j = j + 1)
                if (vexp[j] === vexp[i]) dup = 1;
            if (!dup) uniq = uniq + 1;
        end
        nchk = nchk + 1;
        $display("  第 0 组期望值：256 个系数里 %0d 个不同值（要求 > 128）", uniq);
        if (uniq > 128) $display("  [ ok ] 非退化");
        else begin
            $display("  [FAIL] 向量退化 —— 「全中」不能算通过");
            nfail = nfail + 1;
        end

        // ---- 发命令，等 #OK（协议：收到 #OK 之前一个数据字节都不许发）----
        send_cmd("#NTT 1", 6);
        recv_line();
        chk("#OK NTT 1", 9, "S2 #OK NTT 1");

        // ---- 灌 256 行（FNTT 装载 = 自然序，三档都一样）----
        for (i = 0; i < 256; i = i + 1) send_data(vin[i]);
        $display("  已发 256 条数据行，等 #BEGIN ...");

        recv_line();
        chk("#BEGIN NTT 1 256", 16, "S2 #BEGIN");

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
                // ---- `+dump`：诊断用，把「收到的值原本在 vexp 的第几号」直接打出来 ----
                //   顺序类问题靠肉眼比对数字是猜；把命中的下标打出来，映射关系一眼可见。
                //   只在头 24 行打，然后立刻收工（不跑完 256 行，省时间）。
                if (dump) begin
                    hit = -1;
                    for (j = 0; j < 256; j = j + 1)
                        if (vexp[j] === v && hit == -1) hit = j;
                    $display("  dump m=%0d  收 %03x  → vexp[%0d]   (本行期望 vexp[%0d]=%03x  perm=%0d)",
                             m, v, hit, idx, vexp[idx], idx);
                    if (m >= 23) begin
                        $display("  （+dump 到头 24 行，提前结束）");
                        $finish;
                    end
                end
            end
        end
        if (nerr == 0) begin
            $display("  [ ok ] 256/256 行结果与黄金向量一致（读出顺序已按 0,2,1,3 还原）");
        end else begin
            $display("  [FAIL] 256 行里有 %0d 行不符", nerr);
            nfail = nfail + 1;
        end

        recv_line();
        chk("#DONE NTT 1 256", 15, "S2 #DONE");

        // =============================================================
        $display("");
        $display("==================== 汇总 ====================");
        $display("  比对点 %0d 个，失败 %0d 个", nchk, nfail);
        if (nfail == 0) $display("  结论：通过 —— 可以进综合/上板。");
        else            $display("  结论：**有失败** —— 先别上板，回 RTL 查。");
        $display("==============================================");
        $display("");
        $finish;
    end

endmodule
