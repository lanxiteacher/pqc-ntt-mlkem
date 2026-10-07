// ===========================================================================
// smoke_tb.v —— 板级 wrapper 的**冒烟台**（A 的，上板前的闸门）
//
// 这不是协议验收台。协议验收（§5.5 三条注入错误、校验和、错误码、超时）
// 是 **B 的 W2 活**，见 `host/proto.md` §六第 12 条第 3 问 ——
// A 起草的那版在 `tb/uart_proto_tb.v`，等 B 取走，A 不维护。
//
// 这里只回答一个问题：**这块板子值得花十几分钟去综合、实现、下载吗？**
// 所以只验四条，都是「错了就是白烧一遍板子」的那种：
//
//   S0  上电自发的 `#RDY 1 <build> 0`（§5.2）—— 复位释放后**不等命令**先发
//   S1  #PING 的回帧逐字节正确（含校验和）—— 协议通路的端点检查
//   S2  #NTT 1 端到端：256 行数据进去、256 行结果出来，装**一个** bank，
//       结果逐行对拍 refsim/batch/ntt_batch_exp.txt 第 0 组
//       （按该折叠度下 FNTT 的读出顺序还原系数下标）
//   S3  #PMUL NTT 1 端到端：512 行进去、256 行出来，装**两个** bank，
//       对拍 refsim/batch/pwm2_batch_exp.txt 第 0 组，读出恒 σ
//
// S2/S3 是重点：它们是**整个数据通路**的检查 —— 串口收发 + 行组装 + 协议机 +
// 十六进制解析 + 装载口时序 + NTT 核 + 读出顺序 + 回传。任何一环接错，
// 都会红。红了就不该上板（§七 红线：仿真能抓到的问题不要留到板上抓）。
//
// ★ 为什么 2026-10-04 补了 S3：S2 只装一个 bank，盖不到 **A→B 的 bank 切换**，
//   而那次切换的间隔是个**写死的 lc 常数**（proto_fsm.v 里 DATA_LINES+3），
//   核的装载相位却是 256+PE_NUMBER 拍 —— 两者只在 pe1 对得上。
//   结果 pe4 上板时 S2 过、五条事务里三条 #PMUL 全挂。教训：
//   **「过了冒烟台」的覆盖面就是冒烟台自己写的那几条**，别外推。
//
// ★ 同一个写死常数还有第二个症状，而且它**连 S2 都挂**（2026-10-04 实测）：
//   三档跑本台，pe1 ✅ pe4 ✅ **pe16 ❌**（S2 卡在「板子没回话」）。
//   真因不在数据通路，在 `core_start_*` 的**脉冲宽度**：它是一拍宽的，
//   而核把它在自由跑时钟上寄存成 sf_R（KyberHPMNTT_top.v:134），
//   所以 sf_R 高那一拍必须正好撞上 `ce` 被门控打开的一拍。
//   装载相位没结束时 ce 按 PE 分频，1 拍宽的脉冲撞不上（pe16 分频 16 → 必丢；
//   pe4 分频 4 恰好对上 → 侥幸过）。start 丢了 ⇒ 核不跑 ⇒ 不回 done
//   ⇒ 板子 100 ms 后回 `#ERR 06`。
//   ⚠️ 当时本台报的是「板子没回话」，因为 GUARD_CC（16 ms）短过板子的
//      核看门狗 T_CORE_CC（100 ms）—— tb 抢在板子前面放弃了，
//      把一条 `#ERR 06` 误诊成「板子死了」。**护栏必须长过被测方自己的看门狗**。
//
// ---------------------------------------------------------------------------
// ★ 三个折叠度都能跑（2026-10-04 加）。折叠度是**编译期**开关：
//
//     sh rtl/board/run_board_check.sh            # pe1（默认）
//     PE=4  sh rtl/board/run_board_check.sh      # pe4
//     PE=16 sh rtl/board/run_board_check.sh      # pe16
//
//   随折叠度变的东西只有两样，都是**从 PE_NUM 推出来的**，不是另抄一份：
//     · READ_LAT = 2*PE_NUM + 3   （核的读出延迟，随核时钟门控比例变）
//     · FNTT 的**读出**顺序：pe1 = 交织 0,2,1,3｜pe4、pe16 = **自然序**
//   装载顺序**不随折叠度变**（本台只发 FNTT，走 `load_*_f` → 三档都自然序），
//   所以灌进去的 256 行、命令文本 `#NTT 1`（那个 1 是 n 批次，不是折叠度）
//   三档全都一样。
//   ⚠️ 三档**必须分别跑**：一次只用一份宏定义，跑完一档再跑下一档。
//
//   为什么值得单独跑 pe4/pe16：探针 ⑩（`rtl/probes/ntt_func_tb.v`）已经在
//   三档 × 3 运算 × 16 组上验到 4096/4096，但那是核级的。本台多盖的是
//   **板级**那一段：折叠度从综合参数一路传到 READ_LAT，以及板子的收发时序
//   在更慢的核时钟（pe16 的核时钟只有 1/16）下还成不成立。
//
// ---------------------------------------------------------------------------
// ⚠️ 这里**故意不测**的东西（不要以为测过了）：
//   · 各种 #ERR 错误码、超时行为、#ABORT  —— 归 B 的协议验收台
//   · #INTT，以及 #PMUL 的另外两个域（#PMUL TIME / #PMUL FULL）
//     —— 它们的**装载顺序**与 S2/S3 都不同（见下面那张表），
//        要加得照抄 S3 换向量与 pm_ld，不是改个文件名的事
//   · FNTT 以外的读出顺序（S3 恒 σ，不随折叠度变）
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

    // ---- 折叠度：编译期选（见文件头）。默认 pe1 --------------------------
    //   ⚠️ 用 `ifdef 而不是运行时变量：PE_NUMBER 是**综合期**参数，
    //      核的 generate 分支要它在编译时就定下来。
    //   ⚠️ 这三档**不是**「2 的幂的任意取值」—— 核的数据通路是「每档一份」而不是
    //      公式（`KyberHPMNTT.v:90`），pe2/pe8 拿不到正确的地址位宽，核与顶层各有一句
    //      FATAL 守卫拦这件事。所以**别往这里加 TB_PE2 / TB_PE8** —— 加了也不会通过，
    //      只会把「不支持」伪装成「没测过」。
`ifdef TB_PE16
    localparam integer PE_NUM = 16;
`elsif TB_PE4
    localparam integer PE_NUM = 4;
`else
    localparam integer PE_NUM = 1;
`endif

    // ---- 上电自发的那行 `#RDY`（协议 §5.2）------------------------------
    //   板子复位释放后**不等命令**先吐一行 `#RDY 1 <build> <errs>`，
    //   <build> 就是折叠度、<errs> 上电初值为 0。于是测试台的**第一行**
    //   收到的不是 `#OK PING` 而是它 —— 不先收掉，后面每一行都错位一格。
    //   ⚠️ 期望值**按档写死**而不是从 PE_NUM 拼：拼出来的话，RTL 里
    //      真把 <build> 写错了（比如恒发 1），这里会跟着一起错、测不出来。
    //      校验和那两位由 chk() 自算，不抄 —— 抄了就测不出校验错。
`ifdef TB_PE16
    localparam [8*32-1:0] RDY_EXP = "#RDY 1 16 0";
    localparam integer    RDY_N   = 11;
`elsif TB_PE4
    localparam [8*32-1:0] RDY_EXP = "#RDY 1 4 0";
    localparam integer    RDY_N   = 10;
`else
    localparam [8*32-1:0] RDY_EXP = "#RDY 1 1 0";
    localparam integer    RDY_N   = 10;
`endif

    // READ_LAT 随折叠度变 —— 口径在 rtl/ntt_core/KyberHPMNTT_top.v 文件头（第 38 行）：
    //   第一条有效 dout = read_* 之后 2*PE_NUMBER + 3 拍。
    //   道理：核的时钟被按 1/PE 门控，第一拍宽结果最早也要等第 3 个 ce 才凑齐；
    //   硬要三档都用 read+5（旧版这里就是写死的 5），pe4/pe16 只能吐出假数据。
    //   ⚠️ 板级顶层 ntt_board_top.v 里也写着同一个表达式 —— 两处必须一致。
    localparam integer READ_LAT  = 2 * PE_NUM + 3;

    // ⚠️ 护栏必须**长过板子自己的核看门狗** T_CORE_CC（下面传 5e6 = 100 ms），
    //    否则「核没回 done」这种错会表现成 tb 先超时 —— 打出来的是
    //    「板子没回话」，而板子其实正准备在 100 ms 时回一条 `#ERR 06`。
    //    2026-10-04 pe16 就是这么误诊的：真因是 start 丢了（核没跑），
    //    现象却像「板子死了」。护栏放到 6e6 = 120 ms，永远让板子先说。
    //    代价只在**失败**时付（多跑 100 ms 仿真），通过时一分不花。
    localparam integer GUARD_CC  = 6_000_000;       // 收一个字节的护栏（120 ms）
    localparam real    MAX_NS    = 900_000_000.0;   // 全局护栏（0.9 s）

    // ---- FNTT 的**读出**顺序：pe1 = 交织 0,2,1,3｜pe4、pe16 = 自然序 ----
    //   pe1 那格依据 refsim/pe1/fntt_batch_tb.v:108-113 —— 每 4 拍一组，
    //   组内顺序 0,2,1,3，即第 m 行结果对应**系数下标** perm(m)。
    //   pe4/pe16 那格依据 `rtl/H1_port_spec.md` §五 实测表（探针 ⑩：
    //   3 运算 × 3 档 × 16 组黄金向量，各 4096/4096 多重集相等）。
    //   于是「第 m 行对应 vexp 的哪一号」= FNTT 那一行的分档：
    //     pe1       → perm(m)   （把交织还原回自然序）
    //     pe4、pe16 → m         （本来就是自然序，不用还原）
    //   ⚠️ 这里只写**读出**。装载是另一套规则，见下面那段长注释。
    //   ⚠️ 实现在 `perm` **之后** —— 函数体里要调 perm，别挪到前面去。

    // ⚠️ **装载顺序按 (运算, 折叠度) 查表 —— 没有一句话能概括**（2026-10-04 第二次改）。
    //    实测（`rtl/H1_port_spec.md` §五、探针 ⑩，崩溃判据：拨成另一个候选必须塌）：
    //      运算    路径   pe1      pe4       pe16
    //      FNTT    _f     自然序   自然序    自然序      拨 σ → 26/4096
    //      INTT    _i     交织 σ   交织 σ    交织 σ      拨自然序 → 19/4096
    //      PWM2    _i     交织 σ   自然序    自然序      拨反 → 22/4096
    //    **最反直觉的一格：`#INTT` 与 `#PMUL NTT` 都走 `load_*_i`，但 pe4/pe16 上要求不同。**
    //    本台只发 FNTT → 三档都自然序，「灌进去的顺序」这一行三档都不用改。
    //    ⚠️ 换个运算就要重查这一格。
    //
    //    这一行改过两次，两次都是**把一格写成了一条规则**：
    //      初版「装载侧三档都是自然序」→ 上位机驱动第一轮五条挂四条。
    //      二版「load_*_i → pe1 交织｜pe4·pe16 自然序」→ 把 PWM2 那格推广到了 INTT。
    //    「FNTT `_f` 三档都自然序」这个事实两版都对，错的一直是推广。
    function integer perm(input integer m);
        integer q;
        begin
            q = m % 4;
            if      (q == 1) perm = m + 1;
            else if (q == 2) perm = m - 1;
            else             perm = m;
        end
    endfunction

    // 「第 m 行结果 ↔ vexp 的第几号」—— 即上一条注释里 FNTT 那行的分档。
    function integer out_idx(input integer m);
        begin
            if (PE_NUM == 1) out_idx = perm(m);
            else             out_idx = m;
        end
    endfunction

    // ---- PWM2（点乘）的两张顺序表 —— 与 FNTT 的**不是同一张** ------------
    //   装载（上面那张表里的 PWM2 行）：pe1 = 交织 σ｜pe4、pe16 = 自然序
    //   读出：三档都是 σ（点乘结果落在 bank A，读出顺序不随折叠度变）
    //   ⚠️ 别把两张表混成一张 —— FNTT 是**读出**那格 pe1 才用 σ，PWM2 是**读出**
    //      三档都用 σ。两者恰好都用 σ 的只有 pe1。
    function integer pm_ld(input integer m);
        begin
            if (PE_NUM == 1) pm_ld = perm(m);
            else             pm_ld = m;
        end
    endfunction

    function integer pm_out(input integer m);
        begin
            pm_out = perm(m);
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
        .PE_NUMBER (PE_NUM),
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
    // 1b. 相位探针 —— 每个 load 请求都必须换来一次慢跑相位
    // =====================================================================
    //   核的装载口是「脉冲进门 + 按慢跑时钟吃宽数据」两件事分开的：
    //     · 脉冲本身直接进 KyberHPMNTT 的状态机（OP_IDLE 见到 load_* → OP_LOAD_DATA）
    //     · 相位机（KyberHPMNTT_top.v:153）负责把核时钟按 1/PE 门控，`ce` 才对
    //   两件事**不同步**。脉冲若落在相位机认定「相位已结束」之后一秒拍、
    //   而核自己还在/刚离开 OP_LOAD_DATA，症状是：
    //     核确实进了 OP_LOAD_DATA，但 ce 一直恒 1（没被门控）——
    //     于是它按 4 倍速把序列化器抽干，装进 bank 的是一堆**错位后仍像模像样**
    //     的值，不是全 0。所以「结果数值全错、但每个值都像真的」这个现象，
    //     既不是顺序错也不是没装，而是这个。
    //
    //   判据用**两个计数相等**，不用「slow 期间来请求」——后者漏掉上面这种
    //   「请求落在相位结束的后一拍」：
    //     n_req     = load 请求脉冲数（#NTT 1 个 / #PMUL 2 个）
    //     n_phase   = 相位机真正起过的装载相位数
    //   相等 ⇒ 每个请求都被伺候了。n_phase < n_req ⇒ 有请求没人管。
    //
    //   ⚠️ 用 negedge 采样：posedge 上相位机与 req_load 同拍更新，采样点会打架。
    // =====================================================================
    integer n_req_load = 0;
    integer n_ph_load  = 0;
    reg     slow_prev  = 1'b0;

    always @(negedge sys_clk) begin
        if (dut.u_core.req_load) n_req_load = n_req_load + 1;
        if (dut.u_core.slow && !dut.u_core.slow_rd && !slow_prev) n_ph_load = n_ph_load + 1;
        slow_prev = dut.u_core.slow;
    end

    // =====================================================================
    // 2. 全局护栏 —— 任何等待都不许没有上限（CLAUDE.md 约定 2）
    // =====================================================================
    initial begin
        #(MAX_NS);
        $display("");
        $display("FAIL_WATCHDOG: 跑到 %0.0f ns 还没结束 —— 有等待没有上限。", MAX_NS);
        $finish;
    end

    // ---- 心跳刷缓冲：输出被重定向到文件时，vvp 是**全缓冲**的 --------
    //   不刷的话，一个跑到半截挂住的仿真在文件里是**一片空白** ——
    //   看不到它死在哪一段，只能看见「它没结束」。2026-10-07 三档并跑
    //   卡了 5 分钟、三份输出都只有两行 shell 的 echo，就是栽在这。
    //   每 1 ms 仿真时间刷一次（= 50000 拍），代价可忽略。
    //   ⚠️ 这不是「让仿真变快」，只是「让挂住的仿真能开口说话」。
    initial begin
        forever begin
            #1_000_000;
            $fflush();
        end
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

    // ---- S3 用：#PMUL NTT 1 的两个 bank 与点乘期望（各取第 0 组 256 个）----
    //   ⚠️ 开 `NV*256`（= 4096），**与上面 vin/vexp 一致**，别开小。
    //      `$readmemh` 遇到比数组长的文件会报 "Too many words in the file
    //      for the requested range" —— 那是**警告不是错误**，值照样填，
    //      但每次跑都刷三行，读日志的人会以为出事了。
    //      `refsim/batch/` 下的向量文件是 **16 组 × 256 = 4096 行**（NV 组），
    //      开 512 正好短一截，所以三行警告都出在这里。
    //      只用前 256 个（第 0 组），开大不影响取到的值。
    reg [11:0] va  [0:NV*256-1];
    reg [11:0] vb  [0:NV*256-1];
    reg [11:0] vpm [0:NV*256-1];

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
        $readmemh("../../../refsim/batch/pwm2_batch_a.txt"  , va);
        $readmemh("../../../refsim/batch/pwm2_batch_b.txt"  , vb);
        $readmemh("../../../refsim/batch/pwm2_batch_exp.txt", vpm);

        sys_rst_n = 1'b0;
        #200;
        sys_rst_n = 1'b1;
        #2000;

        // =============================================================
        $display("");
        $display("========== S0  上电自发 `#RDY`（协议 §5.2）==========");
        // =============================================================
        // ⚠️ S0 必须排在 S1 前面 —— 这行是**板子不等命令先发的**，
        //    谁先收谁就是它。少收这一行，S1 收到的是 `#RDY`，
        //    之后整条流水线全部错位一格（现象会伪装成「板子回错帧」）。
        // 时序：`#2000` 只有 100 拍、不够发完一个字节，所以此刻这行
        // 顶多发到第一个字节 —— 而 recv_byte 是**等电平**（`while
        // (uart_txd !== 1'b0)`），不是等下降沿，所以开始得早或晚都不会错位。
        // ⚠️ tag **只许用 ASCII** —— iverilog 把 tag（右对齐的 48 字节向量）
        //    交给 `%s` 打印时，非 ASCII 会变成乱码（`S0 #R` + 一串问号）。
        //    2026-10-07 踩过：诊断行本身读不出来，等于没有诊断。
        recv_line();
        chk(RDY_EXP, RDY_N, "S0 #RDY auto");

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
        // 先自报这一轮跑的是哪一档 —— 三档共用一套日志格式，不报出来，
        // 事后翻日志分不清哪个结果属于哪一档。
        // ⚠️ 这里用 if/else 两条 $display，不写 `cond ? "串A" : "串B"` ——
        //    三元表达式两侧字符串长度不同时，iverilog 会取较宽的那个宽度、
        //    把短的那个**左边补零**，`%0s` 于是打出一串前导 NUL。
        if (PE_NUM == 1)
            $display("  折叠度 PE_NUM=%0d   READ_LAT=%0d 拍   读出下标 = perm(m)（交织还原）",
                     PE_NUM, READ_LAT);
        else
            $display("  折叠度 PE_NUM=%0d   READ_LAT=%0d 拍   读出下标 = m（自然序）",
                     PE_NUM, READ_LAT);

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

        // ---- 灌 256 行（本台只测 FNTT；FNTT 装载 = 自然序，三档都一样）----
        //   ⚠️ 「三档都一样」说的是**折叠度**，不是**运算** —— 见上面 perm 那段的长注释。
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
                idx = out_idx(m);       // pe1 → perm(m)｜pe4、pe16 → m（见 out_idx 注释）
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
                    $display("  dump m=%0d  收 %03x  → vexp[%0d]   (本行期望 vexp[%0d]=%03x  idx=%0d)",
                             m, v, hit, idx, vexp[idx], idx);
                    if (m >= 23) begin
                        $display("  （+dump 到头 24 行，提前结束）");
                        $finish;
                    end
                end
            end
        end
        if (nerr == 0) begin
            if (PE_NUM == 1)
                $display("  [ ok ] pe1：256/256 行与黄金向量一致（读出顺序已按交织 0,2,1,3 还原）");
            else
                $display("  [ ok ] pe%0d：256/256 行与黄金向量一致（读出自然是自然序，未做还原）",
                         PE_NUM);
        end else begin
            $display("  [FAIL] 256 行里有 %0d 行不符", nerr);
            // ⚠️ 加的是 nerr 不是 1 —— nchk 是**逐行**加的（上面循环里），
            //    这里若只加 1，256 行全挂会报成「比对点 520 个，失败 1 个」，
            //    把 256 个失败点瞒成 1 个。判据本身没错，但数字会误导人
            //    （而且报告要引用这个数）。口径必须与 nchk 一致：一行一个点。
            nfail = nfail + nerr;
        end

        recv_line();
        chk("#DONE NTT 1 256", 15, "S2 #DONE");

        // =============================================================
        $display("");
        $display("========== S3  #PMUL NTT 1 端到端（A、B 两个 bank 都装）==========");
        // =============================================================
        // S2 只装**一个** bank（FNTT 走 load_a_f），S3 装**两个** ——
        // 两者之间隔着一次 bank 切换，而那次切换的时序随折叠度变（见下面
        // 汇总里那条丢弃计数）。2026-10-04 pe4 上板时 S2 过、五条事务里
        // 三条 #PMUL 全挂，就是这条缝 —— S2 盖不到它。
        //
        // ⚠️ 仍然不测 #PMUL TIME / #PMUL FULL（装载顺序与 NTT 那条都不同）。
        //    要加的话照抄本段、换向量与 pm_ld 即可，别只改文件名。
        if (PE_NUM == 1)
            $display("  折叠度 PE_NUM=%0d   装载 A/B 均 交织 σ   读出下标 = perm(m)", PE_NUM);
        else
            $display("  折叠度 PE_NUM=%0d   装载 A/B 均 自然序   读出下标 = perm(m)", PE_NUM);

        send_cmd("#PMUL NTT 1", 11);
        recv_line();
        chk("#OK PMUL NTT 1", 14, "S3 #OK");

        // ---- 两个 bank 各 256 行，连着发（协议里 nload=2）----
        for (i = 0; i < 256; i = i + 1) send_data(va[pm_ld(i)]);
        for (i = 0; i < 256; i = i + 1) send_data(vb[pm_ld(i)]);
        $display("  已发 512 条数据行（A、B 各 256），等 #BEGIN ...");

        recv_line();
        chk("#BEGIN PMUL NTT 1 256", 21, "S3 #BEGIN");

        nerr = 0;
        for (m = 0; m < 256; m = m + 1) begin
            recv_line();
            nchk = nchk + 1;
            if (rlen !== 3) begin
                if (nerr < 5) $display("  [FAIL] 第 %0d 行不是 3 个字符（收到 %0d）", m, rlen);
                nerr = nerr + 1;
            end else begin
                v   = hex3val(rbuf[0], rbuf[1], rbuf[2]);
                idx = pm_out(m);
                if (v !== vpm[idx]) begin
                    if (nerr < 5)
                        $display("  [FAIL] 第 %0d 行：实收 %03x，期望 %03x（系数下标 %0d）",
                                 m, v, vpm[idx], idx);
                    nerr = nerr + 1;
                end
            end
        end
        if (nerr == 0)
            $display("  [ ok ] pe%0d：256/256 行与 pwm2_batch_exp 一致", PE_NUM);
        else begin
            $display("  [FAIL] 256 行里有 %0d 行不符", nerr);
            // ⚠️ 加的是 nerr 不是 1 —— nchk 是**逐行**加的（上面循环里），
            //    这里若只加 1，256 行全挂会报成「比对点 520 个，失败 1 个」，
            //    把 256 个失败点瞒成 1 个。判据本身没错，但数字会误导人
            //    （而且报告要引用这个数）。口径必须与 nchk 一致：一行一个点。
            nfail = nfail + nerr;
        end

        recv_line();
        chk("#DONE PMUL NTT 1 256", 20, "S3 #DONE");

        // =============================================================
        $display("");
        $display("==================== 汇总 ====================");
        $display("  比对点 %0d 个，失败 %0d 个", nchk, nfail);
        // 相位计数：S2 一个请求、S3 两个，合计应当 3 个请求换 3 个相位。
        // 不等就是「有 load 请求没人伺候」—— 别再去调装载顺序，那是另一回事。
        $display("  load 请求 %0d 个，相位机起了 %0d 个装载相位（应当相等；本台应为 3）",
                 n_req_load, n_ph_load);
        nchk = nchk + 1;
        if (n_req_load != n_ph_load) begin
            $display("  [FAIL] 有 load 请求没有换来装载相位 —— 问题在 bank 切换的时序，不是顺序。");
            nfail = nfail + 1;
        end
        if (nfail == 0) $display("  结论：通过 —— 可以进综合/上板。");
        else            $display("  结论：**有失败** —— 先别上板，回 RTL 查。");
        $display("==============================================");
        $display("");
        $finish;
    end

endmodule
