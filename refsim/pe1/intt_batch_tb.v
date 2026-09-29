/*
 * intt_batch_tb.v —— 用「FIPS 203 校验过的参考实现」生成的黄金向量批量对拍 RTL 的 INTT
 *
 * 和 fntt_batch_tb.v 的关系：控制时序同源（照抄作者版 KyberHPM1PE_test_INTT.v），
 * 但 **读出的索引规则不同**，这是最容易踩的坑：
 *
 *   FNTT : 输入 0,2,1,3,4,6,5,7,...   输出 0,2,1,3,4,6,5,7,...   （同一个交织）
 *   INTT : 输入 0,2,1,3,4,6,5,7,...   输出 0,128,1,129,2,130,... （对半交叉！与 FNTT 不同）
 *   PWM2 : 输入(A/B 各一份) 0,2,1,3,...  输出 0,2,1,3,...          （同 FNTT）
 *
 * 照抄 FNTT 的读出循环去做 INTT，会得到 256 个系数"全错"的假失败。
 *
 * 两处对作者版的改动（与 fntt_batch_tb.v 相同理由）：
 *   1. 等 done 用**有界**循环，作者版是 while(done==0) 无界 —— 放进 16 轮循环会永久挂死
 *   2. 循环 16 组向量，每轮重新灌数，不复位（load 写 bank0，可重复）
 */

`timescale 1ns / 1ps

module intt_batch_tb();

	parameter HP = 5;
	parameter FP = (2*HP);          // 一个流水线周期
	parameter PE_NUMBER = 1;
	parameter NV = 16;              // 向量组数
	parameter TIMEOUT = 5000;       // 等 done 的护栏

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
	reg [11:0] vin  [0:NV*256-1];
	reg [11:0] vexp [0:NV*256-1];

	initial begin
		$readmemh("batch/intt_batch_in.txt" , vin);
		$readmemh("batch/intt_batch_exp.txt", vexp);
	end

	// ------------------------------------------------------------ 测试
	integer v,k,m,e,guard,noise;
	integer total_err;
	reg [11:0] fout [0:255];

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
			// ---- 灌输入（交织顺序 0,2,1,3,...，作者版原样）----------
			load_a_i = 1;
			#FP;
			load_a_i = 0;

			for (k = 0; k < 64; k = k + PE_NUMBER) begin
				din = vin[v*256+4*k+0]; #FP;
				din = vin[v*256+4*k+2]; #FP;
				din = vin[v*256+4*k+1]; #FP;
				din = vin[v*256+4*k+3]; #FP;
			end

			#(2*FP);

			// ---- 启动 INTT -------------------------------------
			start_intt = 1; start_ab = 0;
			#FP;
			start_intt = 0; start_ab = 0;
			#(2*FP);

			// ---- 等 done（有界）--------------------------------
			guard = 0;
			while (done == 1'b0 && guard < TIMEOUT) begin
				#FP;
				guard = guard + 1;
			end

			if (guard >= TIMEOUT) begin
				$display("向量 %2d: ❌ 超时 —— done 在 %0d 个周期内未拉高", v, TIMEOUT);
				total_err = total_err + 256;
				#(10*FP);
			end
			else begin
				#FP;

				// ---- 读出（0,128,1,129,...：第 2m 拍出下标 m，第 2m+1 拍出 m+128）⚠️ 2026-09-29 纠正：原注释写「顺序 0,1,2,3,...」是错的，代码才是对的
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
			$display("★ 全部 %0d 组 INTT 向量通过 —— RTL 输出与 KAT 校验过的参考实现逐比特一致", NV);
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
