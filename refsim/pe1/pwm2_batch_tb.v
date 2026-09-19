/*
 * pwm2_batch_tb.v —— 批量对拍 RTL 的点乘（PWM2）
 *
 * 控制时序照抄作者版 KyberHPM1PE_test_PWM2.v。相对它有两处改动：
 *
 *   1. **两路输入**（这是 PWM2 和 FNTT/INTT 最大的结构差异）。
 *      作者版把「灌 A」和「灌 B」拆在两个 initial 块里，靠 #1500 的时间差错开；
 *      批量循环里不能这么写 —— 所有轮次共用一个时间轴，必须串行化。
 *      本版改成顺序执行：灌 A（load_a_i）→ 灌 B（load_b_i）→ start_pwm2。
 *
 *   2. 等 done 用**有界**循环（作者版无界，放进 16 轮会永久挂死）。
 *
 * 读写顺序（与 FNTT 相同，与 INTT 不同）：
 *   输入 A：0,2,1,3,4,6,5,7,...
 *   输入 B：0,2,1,3,4,6,5,7,...
 *   输出  ：0,2,1,3,4,6,5,7,...
 */

`timescale 1ns / 1ps

module pwm2_batch_tb();

	parameter HP = 5;
	parameter FP = (2*HP);
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
	reg [11:0] vin_a [0:NV*256-1];
	reg [11:0] vin_b [0:NV*256-1];
	reg [11:0] vexp  [0:NV*256-1];

	initial begin
		$readmemh("batch/pwm2_batch_a.txt"  , vin_a);
		$readmemh("batch/pwm2_batch_b.txt"  , vin_b);
		$readmemh("batch/pwm2_batch_exp.txt", vexp);
	end

	// ------------------------------------------------------------ 测试
	integer v,k,m,e,guard,noise;
	integer total_err;
	integer fd_raw;                 // RTL 原始输出的文件句柄（0 = 不写）
	integer dump_on;                // +raw=1 时置位
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

		fd_raw = 0; dump_on = 0;
		if ($value$plusargs("raw=%d", dump_on))
			if (dump_on) begin
				fd_raw = $fopen("batch/pwm2_raw.txt", "w");
				$display("（已开启原始输出 dump → batch/pwm2_raw.txt）");
			end

		total_err = 0;

		for (v = 0; v < NV; v = v + 1) begin
			// ---- 灌 A（交织顺序）--------------------------------
			load_a_i = 1;
			#FP;
			load_a_i = 0;

			for (k = 0; k < 64; k = k + PE_NUMBER) begin
				din = vin_a[v*256+4*k+0]; #FP;
				din = vin_a[v*256+4*k+2]; #FP;
				din = vin_a[v*256+4*k+1]; #FP;
				din = vin_a[v*256+4*k+3]; #FP;
			end

			#(2*FP);

			// ---- 灌 B（同样交织顺序）----------------------------
			load_b_i = 1;
			#FP;
			load_b_i = 0;

			for (k = 0; k < 64; k = k + PE_NUMBER) begin
				din = vin_b[v*256+4*k+0]; #FP;
				din = vin_b[v*256+4*k+2]; #FP;
				din = vin_b[v*256+4*k+1]; #FP;
				din = vin_b[v*256+4*k+3]; #FP;
			end

			#(2*FP);

			// ---- 启动 PWM2 -------------------------------------
			start_pwm2 = 1; start_ab = 0;
			#FP;
			start_pwm2 = 0; start_ab = 0;
			#(2*FP);

			// ---- 等 done（有界）--------------------------------
			guard = 0;
			while (done == 1'b0 && guard < TIMEOUT) begin
				#FP;
				guard = guard + 1;
			end

			if (guard >= TIMEOUT) begin
				$display("向量 %2d: ❌ 超时", v);
				total_err = total_err + 256;
				#(10*FP);
			end
			else begin
				#FP;

				// ---- 读出（交织 0,2,1,3,...，同 FNTT）----------
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

			// 把本组 RTL 原始输出落盘（供约定分析用；最后一组留存）
			if (fd_raw)
				for (m = 0; m < 256; m = m + 1)
					$fdisplay(fd_raw, "%03x", fout[m]);
		end

		if (fd_raw) $fclose(fd_raw);

		$display("");
		if (total_err == 0)
			$display("★ 全部 %0d 组 PWM2 向量通过", NV);
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
