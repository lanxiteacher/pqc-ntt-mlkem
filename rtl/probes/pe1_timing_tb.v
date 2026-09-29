/*
 * pe1_timing_tb.v —— 量 KyberHPM1PE 的接口时序（周期级）
 *
 * 所有激励都在时钟上升沿之后改变，保证 DUT 在每个上升沿采到的就是激励里写的值。
 * 输出一张带周期编号的时间线。默认测核本身；加 -DUSE_TOP 测带输入/输出寄存的 _top。
 *
 * 用法：
 *   iverilog -g2012 -o t.vvp <pe1 全部 .v> pe1_timing_tb.v     # 核
 *   iverilog -g2012 -DUSE_TOP ...                              # _top
 *   vvp t.vvp
 */
`timescale 1ns / 1ps

module pe1_timing_tb();

	parameter HP = 5;
	parameter FP = 2*HP;
	parameter PE_NUMBER = 1;

	reg                     clk,reset;
	reg                     load_a_f,load_a_i;
	reg                     load_b_f,load_b_i;
	reg                     read_a,read_b;
	reg                     start_ab;
	reg                     start_fntt,start_pwm2,start_intt;
	reg  [12*PE_NUMBER-1:0] din;
	wire [12*PE_NUMBER-1:0] dout;
	wire                    done;

	integer cyc;
	always #HP clk = ~clk;

	reg [11:0] vin [0:255];

	initial begin
		$readmemh("in.txt", vin);
		cyc = 0;
	end

	// 周期计数：以复位释放后的第一个上升沿为 1
	reg counting;
	always @(posedge clk) if (counting) cyc = cyc + 1;

	integer k, m, guard;
	reg [11:0] fout [0:263];
	integer first_load, last_load, c_start, c_done, c_read, c_first_out, c_last_out;

	initial begin: MAIN
		clk = 0; reset = 0; counting = 0;
		load_a_f = 0; load_a_i = 0;
		load_b_f = 0; load_b_i = 0;
		read_a = 0; read_b = 0;
		start_ab = 0;
		start_fntt = 0; start_pwm2 = 0; start_intt = 0;
		din = 0;

		#200; reset = 1;
		#200; reset = 0;
		#100;

		@(posedge clk); counting = 1;

		// ---- 装载：load_a_f 拉高 1 个上升沿 ----
		@(posedge clk); #1;
		load_a_f = 1;
		first_load = cyc;

		@(posedge clk); #1;
		load_a_f = 0;

		for (k = 0; k < 256; k = k + 1) begin
			din = vin[k];
			@(posedge clk); #1;
			if (k == 255) last_load = cyc;
		end
		din = 0;

		@(posedge clk); #1;
		@(posedge clk); #1;

		// ---- 启动 FNTT ----
		start_fntt = 1; start_ab = 0;
		c_start = cyc;
		@(posedge clk); #1;
		start_fntt = 0;

		// ---- 等 done ----
		guard = 0;
		while (done !== 1'b1 && guard < 5000) begin
			@(posedge clk); #1;
			guard = guard + 1;
		end
		c_done = cyc;
		$display("TIMELINE load_pulse_cc=%0d last_din_cc=%0d start_cc=%0d done_cc=%0d done_start_delta=%0d",
		         first_load, last_load, c_start, c_done, c_done - c_start);

		@(posedge clk); #1;

		// ---- 读出 ----
		read_a = 1;
		c_read = cyc;
		@(posedge clk); #1;
		read_a = 0;

		c_first_out = -1; c_last_out = -1;
		for (m = 0; m < 264; m = m + 1) begin
			if (dout !== 0) begin
				if (c_first_out < 0) c_first_out = cyc;
				c_last_out = cyc;
			end
			fout[m] = dout;
			@(posedge clk); #1;
		end
		$display("TIMELINE read_pulse_cc=%0d first_dout_cc=%0d last_dout_cc=%0d nonzero_beats=%0d",
		         c_read, c_first_out, c_last_out, c_last_out - c_first_out + 1);

		for (m = 0; m < 264; m = m + 1)
			$display("OUT %0d %h", m, fout[m]);

		$finish;
	end

`ifdef USE_TOP
	KyberHPM1PE_top uut (clk,reset,
`else
	KyberHPM1PE uut (clk,reset,
`endif
		             load_a_f,load_a_i,
		             load_b_f,load_b_i,
		             read_a,read_b,
	                 start_ab,
		             start_fntt,start_pwm2,start_intt,
		             din,
		             dout,
		             done);

endmodule
