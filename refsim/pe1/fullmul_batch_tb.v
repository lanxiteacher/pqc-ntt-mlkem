/*
 * fullmul_batch_tb.v —— 批量对拍 RTL 的**完整多项式乘法**（ALL_FULL 通路）
 *
 *   A、B 都在时域  → FNTT(A) → FNTT(B) → PWM2 → INTT → 时域结果
 *
 * 控制时序照抄作者版 KyberHPM1PE_test_ALL_FULL.v，改动：
 *   1. 16 组向量循环（作者版单组）
 *   2. 等 done 全部改成**有界**循环（作者版无界 while(done==0)）
 *   3. 抽了个 WAIT_DONE 任务，避免 4 处等待写 4 遍
 *
 * ⭐ 这条链上**没有缩放因子**：期望值就是参考实现的输出，逐比特直接比。
 *    （② 的 R 与 ③ 的 R^-1 在此抵消，见 gen_batch_vectors.gen_polmul 的说明）
 *
 * 加载方式用的是 load_a_f / load_b_f（"f" = 给 FNTT 用）：
 *   顺序灌 k=0..255，硬件写进各 BRAM 的**低半区**。
 *   对照：load_*_i（"i" = 给 INTT 用）是交织灌 0,2,1,3,...，写**高半区**。
 *   这个区别写在 KyberHPM1PE.v 的 load_type 逻辑里（第 134-145 / 303-310 行）。
 *
 * 读出顺序：m, m+128（与 INTT 相同，与 FNTT 的交织读出不同）。
 */

`timescale 1ns / 1ps

module fullmul_batch_tb();

	parameter HP = 5;
	parameter FP = (2*HP);          // 一个流水线周期
	parameter PE_NUMBER = 1;
	parameter NV = 16;              // 向量组数
	parameter TIMEOUT = 3000;       // 单次等 done 的护栏（最长 FNTT_CC=904）

	reg                     clk,reset;
	reg                     load_a_f,load_a_i;
	reg                     load_b_f,load_b_i;
	reg                     read_a,read_b;
	reg                     start_ab;
	reg                     start_fntt,start_pwm2,start_intt;
	reg  [12*PE_NUMBER-1:0] din;
	wire [12*PE_NUMBER-1:0] dout;
	wire                    done;

	always #HP clk = ~clk;

	// ------------------------------------------------------------ 数据
	reg [11:0] vin_a [0:NV*256-1];
	reg [11:0] vin_b [0:NV*256-1];
	reg [11:0] vexp  [0:NV*256-1];

	initial begin
		$readmemh("batch/fullmul_a.txt"  , vin_a);
		$readmemh("batch/fullmul_b.txt"  , vin_b);
		$readmemh("batch/fullmul_exp.txt", vexp);
	end

	// ------------------------------------------------------------ 测试
	integer v,k,m,e,guard,noise;
	integer total_err;
	integer timed_out;
	reg [11:0] fout [0:255];

	// 等 done，带护栏。作者版是无界 while，放进 16 轮循环会永久挂死。
	task WAIT_DONE;
		begin
			guard = 0;
			while (done == 1'b0 && guard < TIMEOUT) begin
				#FP;
				guard = guard + 1;
			end
			timed_out = (guard >= TIMEOUT);
		end
	endtask

	initial begin: MAIN
		clk = 0; reset = 0;
		load_a_f = 0; load_a_i = 0;
		load_b_f = 0; load_b_i = 0;
		read_a   = 0; read_b   = 0;
		start_ab = 0;
		start_fntt = 0; start_pwm2 = 0; start_intt = 0;
		din = 0;

		#200; reset = 1;
		#200; reset = 0;
		#100;
		#1000;

		total_err = 0;

		for (v = 0; v < NV; v = v + 1) begin
			// ---- 灌 A（load_a_f，顺序）--------------------------
			load_a_f = 1;
			#FP;
			load_a_f = 0;

			for (k = 0; k < 256; k = k + PE_NUMBER) begin
				din = vin_a[v*256+k]; #FP;
			end

			#(2*FP);

			// ---- 灌 B（load_b_f，顺序）--------------------------
			load_b_f = 1;
			#FP;
			load_b_f = 0;

			for (k = 0; k < 256; k = k + PE_NUMBER) begin
				din = vin_b[v*256+k]; #FP;
			end

			#(2*FP);

			// ---- FNTT(A) ---------------------------------------
			start_fntt = 1; start_ab = 0;
			#FP;
			start_fntt = 0; start_ab = 0;
			#(2*FP);
			WAIT_DONE;
			if (timed_out) begin
				$display("向量 %2d: ❌ FNTT(A) 超时", v);
				total_err = total_err + 256;
			end

			// ---- FNTT(B) ---------------------------------------
			start_fntt = 1; start_ab = 1;
			#FP;
			start_fntt = 0; start_ab = 0;
			#(2*FP);
			WAIT_DONE;
			if (timed_out) begin
				$display("向量 %2d: ❌ FNTT(B) 超时", v);
				total_err = total_err + 256;
			end

			// ---- PWM2（点乘）-----------------------------------
			start_pwm2 = 1; start_ab = 0;
			#FP;
			start_pwm2 = 0; start_ab = 0;
			#(2*FP);
			WAIT_DONE;
			if (timed_out) begin
				$display("向量 %2d: ❌ PWM2 超时", v);
				total_err = total_err + 256;
			end

			// ---- INTT ------------------------------------------
			start_intt = 1; start_ab = 0;
			#FP;
			start_intt = 0; start_ab = 0;
			#(2*FP);
			WAIT_DONE;
			if (timed_out) begin
				$display("向量 %2d: ❌ INTT 超时", v);
				total_err = total_err + 256;
			end

			if (timed_out) begin
				#(10*FP);
			end
			else begin
				#FP;

				// ---- 读出（顺序 m, m+128）----------------------
				read_a = 1;
				#FP;
				read_a = 0;
				#(2*FP);

				for (m = 0; m < 128; m = m + PE_NUMBER) begin
					fout[m]     = dout; #FP;
					fout[m+128] = dout; #FP;
				end

				#100;

				// ---- 比对 -------------------------------------
				e = 0; noise = 0;
				for (m = 0; m < 256; m = m + 1) begin
					if (fout[m] == vexp[v*256+m])
						e = e + 1;
					else begin
						if (noise < 3) begin
							$display("  向量 %2d [%3d]: 期望 %h 得到 %h", v, m, vexp[v*256+m], fout[m]);
							noise = noise + 1;
						end
						total_err = total_err + 1;
					end
				end

				if (e == 256)
					$display("向量 %2d: ✅ 256/256", v);
				else
					$display("向量 %2d: ❌ %0d/256", v, e);

				#(5*FP);
			end
		end

		$display("");
		if (total_err == 0)
			$display("★ 全部 %0d 组完整乘法（FULL）通过 —— FNTT→FNTT→PWM2→INTT 端到端与参考实现逐比特一致", NV);
		else
			$display("✗ 共 %0d 个系数不符", total_err);

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
