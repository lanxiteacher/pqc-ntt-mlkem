// ===========================================================================
// batch_testbench.v —— 批量对拍 testbench 骨架（16 组向量循环）
//
// 这个骨架解决三件事，三件都是本项目实际踩过的：
//
//   ① **等 done 用有界循环。** 上游作者版写的是 `while (done == 1'b0)`，无界。
//      单次跑没事；套进 16 轮循环后，任何一轮异常都会让仿真**永久挂死**，
//      而不是报错退出 —— 跑批脚本等到超时被杀，看不出是哪一轮、什么原因。
//      这里加 `TIMEOUT` 计数护栏，超时**报错并继续**，不卡住。
//
//   ② **报错要带下标、期望值、实际值。** 只说「255/256」没法排查；
//      `向量 7 [100]: 期望 001 得到 3d4` 一眼就能定位。
//      这条格式也方便做「阴性对照」：改坏一条期望值，看它抓不抓得到。
//
//   ③ **灌数据 / 读回的顺序要写进注释。** 顺序不是笔误 ——
//      常见是存储器分 bank 交织的结果（例如 0,2,1,3,4,6,5,7,...）。
//      ⚠️ 而且**不同运算、不同并行度的顺序可能不一样**：
//      照抄一种去做另一种，会得到「256 个系数全错」的假失败。
//
// 用法：把 <尖括号> 与 TODO 处换成你的设计，然后
//   iverilog -g2012 -o batch.vvp batch_testbench.v <设计源码...> && vvp batch.vvp
// ===========================================================================

`timescale 1ns / 1ps

module batch_testbench();

    parameter HP      = 5;              // 半周期
    parameter NV      = 16;             // 向量组数
    parameter NCOEF   = 256;            // 每组系数个数
    parameter PE      = 1;              // 并行度（若设计有参数）
    parameter TIMEOUT = 5000;           // 等 done 的护栏（先按标称周期数的 5 倍取）

    reg clk, reset;

    // TODO: 换成你的设计的端口
    reg                    start;
    reg  [12*PE-1:0]       din;
    wire [12*PE-1:0]       dout;
    wire                   done;

    always #HP clk = ~clk;

    // ---------------------------------------------------------------- 数据
    // $readmemh 直接读文本向量。⚠️ 文件路径是**相对当前工作目录**的，
    // 不是相对这个 .v 文件 —— 从仓库根跑，就写 "batch/xxx.txt"。
    reg [11:0] vin  [0:NV*NCOEF-1];
    reg [11:0] vexp [0:NV*NCOEF-1];
    initial begin
        $readmemh("batch/vectors_in.txt" , vin);
        $readmemh("batch/vectors_exp.txt", vexp);
    end

    // ---------------------------------------------------------------- 测试
    integer v, k, m, guard, bad, total_err;
    reg [11:0] fout [0:NCOEF-1];

    initial begin: MAIN
        clk = 0; reset = 0; start = 0; din = 0;
        total_err = 0;

        // 复位（⚠️ 注意极性：板上复位键常常与 RTL 的复位**极性相反**）
        #(4*HP); reset = 1; #(4*HP); reset = 0; #(4*HP);

        for (v = 0; v < NV; v = v + 1) begin
            // ---- 灌数据 ----
            // TODO: 按你的设计的加载协议灌。注意本项目踩过的坑：
            //   · `load_*` 可能**没有数据有效选通**，不能断续灌、不能灌一半停
            //   · 有的端口按「低半区」摆放、有的按「高半区」，名字像但用途不同
            for (k = 0; k < NCOEF; k = k + 1) begin
                din = vin[v*NCOEF + k];
                @(posedge clk);
            end

            // ---- 启动 ----
            start = 1; @(posedge clk); start = 0;

            // ---- 等 done（有界！见文件头 ①）----
            guard = 0;
            while (done == 1'b0 && guard < TIMEOUT) begin
                @(posedge clk);
                guard = guard + 1;
            end

            if (guard >= TIMEOUT) begin
                // 超时**报错并继续下一组**，不挂死（这是这个骨架的意义所在）
                $display("向量 %2d: ❌ 超时（等了 %0d 拍，done 一直没来）", v, TIMEOUT);
                total_err = total_err + 1;
            end
            else begin
                // ---- 读回 ----
                // TODO: 按你的设计的读出顺序读回（见文件头 ③）
                for (m = 0; m < NCOEF; m = m + 1) begin
                    @(posedge clk);
                    fout[m] = dout;
                end

                // ---- 比对（见文件头 ②）----
                bad = 0;
                for (m = 0; m < NCOEF; m = m + 1) begin
                    if (fout[m] !== vexp[v*NCOEF + m]) begin
                        bad = bad + 1;
                        if (bad <= 3)           // 只打印前 3 处，免得刷屏
                            $display("向量 %2d [%3d]: 期望 %03x 得到 %03x",
                                     v, m, vexp[v*NCOEF+m], fout[m]);
                    end
                end
                if (bad == 0)
                    $display("向量 %2d: ✅ %0d/%0d", v, NCOEF, NCOEF);
                else begin
                    $display("向量 %2d: ❌ %0d/%0d", v, NCOEF - bad, NCOEF);
                    total_err = total_err + bad;
                end
            end
        end

        if (total_err == 0)
            $display("★ 全部 %0d 组向量通过 —— 共 %0d 个系数逐位一致",
                     NV, NV*NCOEF);
        else
            $display("✗ 共 %0d 个系数不符", total_err);

        $finish;      // ⚠️ 用 $finish 而不是 $stop：
                      //    非交互跑批时 $stop 会掉进交互模式并挂住
    end

endmodule

// ===========================================================================
// 配套要做的两件「验证方法学」的事（比这个骨架本身更重要）
//
// 1. **非退化统计。** 灌之前先数一下输入里有多少个**不同的值**。
//    全是 0 / 全是常量时，「全中」可能只是巧合。
//    本项目基准：4096 个系数里 2355~2374 个不同值、最常见值占比 < 0.25%。
//    现成脚本：`../scripts/check_nondegenerate.sh`
//
// 2. **阴性对照。** 故意改坏一条期望值，看它抓不抓得到、是不是**恰好**抓一处。
//    实测输出应当像这样：
//        向量  7 [100]: 期望 001 得到 3d4
//        向量  7: ❌ 255/256
//        ✗ 共 1 个系数不符
//    「恰好 1 个不符、位置正确」才说明这个测试有牙齿。
//    一个永远通过的测试没有价值。
//
// 3. 还有一条：**别用「作者自己给的期望输出」当唯一判据。**
//    那是「作者的数据 vs 作者的 RTL」，只能证明自洽。
//    期望输出必须来自**经过外部标准校验过**的实现。
// ===========================================================================
