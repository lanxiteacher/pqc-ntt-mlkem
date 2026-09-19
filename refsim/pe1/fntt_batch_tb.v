
/*
 * fntt_batch_tb.v —— 用「自己生成的」黄金向量批量对拍 RTL 的 FNTT
 *
 * 和作者自带 KyberHPM1PE_test_FNTT.v 的区别：
 *   作者版：2 组向量，输入和期望输出都是作者自己给的
 *           → 只能证明 RTL 和作者的期望自洽
 *   本版本：16 组向量，输入随机生成、期望输出来自**已用 FIPS 203 KAT 校验过的
 *           C 参考实现** → 才叫拿到了外部地面真值
 *
 * 控制时序完全照抄作者版（那是已知能跑通的），只把单次执行改成循环：
 *   load_a_f → 灌 256 个系数 → start_fntt → 等 done → read_a → 收 256 个
 *
 * 两处对作者版的改动，都是有理由的：
 *   1. 等待 done 用**有界**循环。作者版是 while(done==0)，无界；放进 16 轮
 *      循环里，任何一轮异常都会让仿真永久挂死，而不是报错退出。
 *   2. 读取顺序仍是 0,2,1,3,4,6,5,7,...（BRAM 分两 bank 交织），原样保留。
 */

`timescale 1ns / 1ps

module fntt_batch_tb();

	parameter HP = 5;
	parameter FP = (2*HP);          // 一个流水线周期
	parameter PE_NUMBER = 1;
	parameter NV = 16;              // 向量组数
	parameter TIMEOUT = 5000;       // 等 done 的护栏（FNTT_CC=904，绰绰有余）

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
		$readmemh("batch/ntt_batch_in.txt" , vin);
		$readmemh("batch/ntt_batch_exp.txt", vexp);
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

		// 复位时序照抄作者版
		#200; reset = 1;
		#200; reset = 0;
		#100;
		#1000;

		total_err = 0;

		for (v = 0; v < NV; v = v + 1) begin
			// ---- 灌输入（每轮重灌，load 写 bank 0，可重复）----------
			load_a_f = 1;
			#FP;
			load_a_f = 0;

			for (k = 0; k < 256; k = k + PE_NUMBER) begin
				din = vin[v*256+k];
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

			if (guard >= TIMEOUT) begin
				$display("向量 %2d: ❌ 超时 —— done 在 %0d 个周期内未拉高", v, TIMEOUT);
				total_err = total_err + 256;
				#(10*FP);
			end
			else begin
				#FP;

				// ---- 读出（顺序 0,2,1,3,4,6,5,7,...）----------
				read_a = 1;
				#FP;
				read_a = 0;
				#(2*FP);

				for (m = 0; m < 64; m = m + PE_NUMBER) begin
					fout[4*m+0] = dout; #FP;
					fout[4*m+2] = dout; #FP;
					fout[4*m+1] = dout; #FP;
					fout[4*m+3] = dout; #FP;
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
			$display("★ 全部 %0d 组向量通过 —— RTL 输出与 KAT 校验过的参考实现逐比特一致", NV);
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
