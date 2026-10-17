/*
 * fntt_wave_tb.v —— 波形 dump 变体：只为出 H5 的「对拍波形截图」
 *
 * 与 fntt_batch_tb.v 的区别（三处，都有理由）：
 *   ① 只跑 1 组向量。波形图只需要一个完整的
 *      「灌数 → start_fntt → done → 读出」周期，16 组没有必要。
 *   ② 加 $dumpfile/$dumpvars，并且**只 dump 顶层少量信号**。
 *      fntt_batch_tb.v 里的 vin/vexp 是 4096 项的数组，若用
 *      $dumpvars(0, tb) 无脑全 dump，.vcd 会爆到 GB 级。这里改成
 *      显式列出信号名，数组不进波形。本文件的数组也缩到 256 项兜底。
 *   ③ 引出 exp_now（当前应读出的期望值）与 cmp（两者是否相等），
 *      与 RTL 的 dout 并排显示 —— 这样波形的「对拍」才看得见：
 *      读出的每个数旁边就摆着它该等于多少。
 *
 * 用途：出图用，**不参与 refsim 的自动判定**（判定仍由 fntt_batch_tb.v 负责）。
 * 跑法（从 refsim/ 目录）：
 *   export PATH="/c/iverilog/bin:$PATH"
 *   iverilog -g2012 -o batch_fntt_wave.vvp <pe1 下的 .v 模块列表> pe1/fntt_wave_tb.v
 *   vvp batch_fntt_wave.vvp          # -> fntt_wave.vcd
 *   gtkwave fntt_wave.vcd
 */
`timescale 1ns / 1ps

module fntt_wave_tb();

	parameter HP = 5;
	parameter FP = (2*HP);          // 一个流水线周期
	parameter PE_NUMBER = 1;
	parameter TIMEOUT = 5000;       // 等 done 的护栏（FNTT_CC=904）

	reg                     clk, reset;
	reg                     load_a_f, load_a_i;
	reg                     load_b_f, load_b_i;
	reg                     read_a, read_b;
	reg                     start_ab;
	reg                     start_fntt, start_pwm2, start_intt;
	reg  [12*PE_NUMBER-1:0] din;
	wire [12*PE_NUMBER-1:0] dout;
	wire                    done;

	always #HP clk = ~clk;

	// ------------------------------------------------------------ 数据
	// 读取完整 16 组文件以免截断告警，只驱动第 0 组；dump 不含数组
	reg [11:0] vin  [0:4095];
	reg [11:0] vexp [0:4095];

	initial begin
		$readmemh("batch/ntt_batch_in.txt" , vin);
		$readmemh("batch/ntt_batch_exp.txt", vexp);
	end

	// ------------------------------------------------------------ 波形专用信号
	reg  [11:0] exp_now;            // 当前应读出的期望值
	reg         reading;            // 读出窗口内为 1
	// cmp_ok：每个读出节拍**采样一次** dout 是否等于期望值。
	// 不用组合 wire 比较，是因为 dout 由 DUT 在时钟上升沿更新、期望值由本
	// 测试台在下降沿赋值，两者差半拍 —— 组合比较会在每个节拍抖出一个 5ns
	// 假低电平，波形上看着像对拍失败。采样式每拍只判一次，电平干净。
	reg         cmp_ok;
	reg  [8:0]  beat;               // 读出节拍计数：每采一个系数 +1，最终停在 256

	// ------------------------------------------------------------ 测试
	integer k, m, guard, e;
	reg [11:0] fout [0:255];

	initial begin: MAIN
		clk = 0; reset = 0;
		load_a_f = 0; load_a_i = 0;
		load_b_f = 0; load_b_i = 0;
		read_a   = 0; read_b   = 0;
		start_ab = 0;
		start_fntt = 0; start_pwm2 = 0; start_intt = 0;
		din = 0; exp_now = 0; reading = 0; cmp_ok = 1; beat = 0;

		$dumpfile("fntt_wave.vcd");
		$dumpvars(0, clk, reset, load_a_f, start_fntt, done, read_a,
		             din, dout, exp_now, reading, cmp_ok, beat);

		// 复位时序照抄 fntt_batch_tb.v
		#200; reset = 1;
		#200; reset = 0;
		#100;
		#1000;

		// ---- 灌 256 个系数（load 写 bank 0）----------------
		load_a_f = 1;
		#FP;
		load_a_f = 0;

		for (k = 0; k < 256; k = k + PE_NUMBER) begin
			din = vin[k];
			#FP;
		end

		#(2*FP);

		// ---- 启动 FNTT -------------------------------------
		start_fntt = 1; start_ab = 0;
		#FP;
		start_fntt = 0; start_ab = 0;
		#(2*FP);

		// ---- 等 done（有界）--------------------------------
		guard = 0;
		while (done == 1'b0 && guard < TIMEOUT) begin
			#FP;
			guard = guard + 1;
		end

		if (guard >= TIMEOUT)
			$display("波形测试台: 超时 —— done 在 %0d 个周期内未拉高", TIMEOUT);
		else
			$display("波形测试台: done 在 %0d 个流水线周期后拉高", guard);

		#FP;

		// ---- 读出（顺序 0,2,1,3,4,6,5,7,...），同步摆出期望值 ----
		reading = 1;
		read_a = 1;
		#FP;
		read_a = 0;
		#(2*FP);

		// 每拍四件事：记下 RTL 的输出值、摆出该系数的期望值、判一次对拍、节拍 +1。
		// 读出顺序是 0,2,1,3（DUT 每 4 个系数按这个次序吐出）。
		for (m = 0; m < 64; m = m + PE_NUMBER) begin
			fout[4*m+0] = dout; exp_now = vexp[4*m+0]; cmp_ok = (dout === exp_now); beat = beat + 1; #FP;
			fout[4*m+2] = dout; exp_now = vexp[4*m+2]; cmp_ok = (dout === exp_now); beat = beat + 1; #FP;
			fout[4*m+1] = dout; exp_now = vexp[4*m+1]; cmp_ok = (dout === exp_now); beat = beat + 1; #FP;
			fout[4*m+3] = dout; exp_now = vexp[4*m+3]; cmp_ok = (dout === exp_now); beat = beat + 1; #FP;
		end

		reading = 0;
		#100;

		// ---- 比对（与 fntt_batch_tb.v 同一口径）------------
		e = 0;
		for (m = 0; m < 256; m = m + 1)
			if (fout[m] == vexp[m]) e = e + 1;

		$display("");
		if (e == 256)
			$display("★ 波形覆盖的这一组：256/256 全中");
		else
			$display("✗ 波形覆盖的这一组：%0d/256", e);

		#(10*FP);
		$finish;
	end

	// ------------------------------------------------------------ UUT
	KyberHPM1PE uut (clk,reset,
		             load_a_f,load_a_i,
		             load_b_f,load_b_i,
		             read_a,read_b,
	                 start_ab,
		             start_fntt,start_pwm2,start_intt,
		             din,
		             dout,
		             done);

endmodule
