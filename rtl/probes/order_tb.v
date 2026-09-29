/*
 * order_tb.v —— 量 pe4 / pe16 的装载顺序与读出顺序
 *
 * 装载侧假设：一拍里 din 的最高 12 位切片 = 本拍最低下标（与 pe1「din 就是
 * 下标 k 那个系数」的角色对应：pe4/pe16 的 din[47:36] / din[191:180] 顶替了
 * pe1 单个 din 的位置）。这个假设由「多重集合相等」判据证实。
 *
 * 读出侧不做假设：把每一拍的 dout 原样打印，由 run_probes.sh 去反推。
 *
 * 用法：
 *   iverilog -g2012 -o o4.vvp <pe4 全部 .v> order_tb.v
 *   iverilog -g2012 -DPE16 -o o16.vvp <pe16 全部 .v> order_tb.v
 */
`timescale 1ns / 1ps

`ifdef PE16
  `define DUT_MOD KyberHPM16PE
  `define PE 16
`else
  `define DUT_MOD KyberHPM4PE
  `define PE 4
`endif

module order_tb();

	parameter HP = 5;
	parameter FP = 2*HP;
	parameter PE_NUMBER = `PE;

	reg                      clk,reset;
	reg                      load_a_f,load_a_i;
	reg                      load_b_f,load_b_i;
	reg                      read_a,read_b;
	reg                      start_ab;
	reg                      start_fntt,start_pwm2,start_intt;
	reg  [12*PE_NUMBER-1:0]  din;
	wire [12*PE_NUMBER-1:0]  dout;
	wire                     done;

	always #HP clk = ~clk;

	reg [11:0] vin  [0:255];
	reg [11:0] vexp [0:255];

	initial begin
		$readmemh("in.txt" , vin);
		$readmemh("exp.txt", vexp);
	end

	integer k,m,guard,j,b;
	reg [11:0] raw [0:255];

	initial begin: MAIN
		clk = 0; reset = 0;
		load_a_f = 0; load_a_i = 0;
		load_b_f = 0; load_b_i = 0;
		read_a = 0; read_b = 0;
		start_ab = 0;
		start_fntt = 0; start_pwm2 = 0; start_intt = 0;
		din = 0;

		#200; reset = 1;
		#200; reset = 0;
		#100;
		#1000;

		// ---- 装载：1 拍脉冲 + 256/PE 拍，每拍 PE_NUMBER 个系数 ----
		load_a_f = 1;
		#FP;
		load_a_f = 0;

		for (k = 0; k < 256; k = k + PE_NUMBER) begin
			din = 0;
			for (j = 0; j < PE_NUMBER; j = j + 1)
				din[12*j +: 12] = vin[k + PE_NUMBER - 1 - j];
			#FP;
		end

		#(2*FP);

		// ---- 启动 FNTT ----
		start_fntt = 1; start_ab = 0;
		#FP;
		start_fntt = 0; start_ab = 0;
		#(2*FP);

		guard = 0;
		while (done == 1'b0 && guard < 3000) begin
			#FP;
			guard = guard + 1;
		end
		$display("ORDER done_guard=%0d", guard);

		#FP;

		// ---- 读出：多打 4 拍，看边界 ----
		read_a = 1;
		#FP;
		read_a = 0;
		#(2*FP);

		for (b = 0; b < (256/PE_NUMBER + 4); b = b + 1) begin
			$display("BEAT %0d %h", b, dout);
			if (b < 256/PE_NUMBER)
				for (j = 0; j < PE_NUMBER; j = j + 1)
					raw[PE_NUMBER*b + j] = dout[12*j +: 12];
			#FP;
		end

		for (m = 0; m < 256; m = m + 1)
			$display("RAW %0d %h", m, raw[m]);

		$finish;
	end

	`DUT_MOD uut (clk,reset,
		          load_a_f,load_a_i,
		          load_b_f,load_b_i,
		          read_a,read_b,
	              start_ab,
		          start_fntt,start_pwm2,start_intt,
		          din,
		          dout,
		          done);

endmodule
