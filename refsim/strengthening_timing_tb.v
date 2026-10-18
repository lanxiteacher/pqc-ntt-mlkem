// Batch FNTT timing and output capture. Python supplies the independent oracle.
`timescale 1ns/1ps
`ifndef CFG_PE_NUM
`define CFG_PE_NUM 0
`endif
module strengthening_timing_tb;
localparam PE = `CFG_PE_NUM;
localparam NV = 103; // 100 random, then zero / q-1 / alternating
reg clk=0;
always #5 clk=~clk;
reg reset, load_a_f, read_a, start_fntt;
reg [11:0] din;
wire [11:0] dout;
wire done;
reg [11:0] vin[0:NV*256-1];
reg [11:0] cap[0:320];
integer cyc, done_cyc, mark, base, g, i, m, guard;
reg capture, monitor;
KyberHPMNTT_top #(.PE_NUMBER(PE)) dut (
 .clk(clk),.reset(reset),.load_a_f(load_a_f),.load_a_i(1'b0),
 .load_b_f(1'b0),.load_b_i(1'b0),.read_a(read_a),.read_b(1'b0),
 .start_ab(1'b0),.start_fntt(start_fntt),.start_pwm2(1'b0),
 .start_intt(1'b0),.din(din),.dout(dout),.done(done));
always @(posedge clk) begin
 #1;
 if(!reset) begin
  cyc=cyc+1;
  if(done===1'b1 && done_cyc<0) done_cyc=cyc;
  if(capture && cyc>=base && cyc-base<=320) cap[cyc-base]=dout;
  if(monitor) $display("ADDR %0d %0d %h %h %h %h %h %b %b",g,cyc-mark,
   dut.u_core.raddr0,dut.u_core.raddr1,dut.u_core.waddr0,
   dut.u_core.waddr1,dut.u_core.raddr_tw,dut.u_core.ag.wen0,dut.u_core.ag.wen1);
 end
end
task step; input integer n; integer t; begin
 for(t=0;t<n;t=t+1) @(negedge clk);
end endtask
initial begin
 if(PE!=1 && PE!=4 && PE!=16) $fatal(1,"CFG_PE_NUM required");
 $readmemh("timing_in.txt",vin);
 cyc=0; done_cyc=-1; capture=0; monitor=0;
 reset=1; load_a_f=0; read_a=0; start_fntt=0; din=0;
 step(4); reset=0; step(2);
 for(g=0;g<NV;g=g+1) begin
  @(negedge clk); load_a_f=1;
  @(negedge clk); load_a_f=0; din=vin[g*256];
  for(i=1;i<256;i=i+1) begin @(negedge clk); din=vin[g*256+i]; end
  @(negedge clk); step(257+PE+8);
  @(negedge clk); done_cyc=-1; mark=cyc; start_fntt=1; monitor=1;
  @(negedge clk); start_fntt=0;
  guard=0;
  while(done_cyc<0 && guard<2000) begin step(1); guard=guard+1; end
  monitor=0;
  if(done_cyc<0) $fatal(1,"FNTT timeout");
  $display("CYCLES %0d %0d",g,done_cyc-mark);
  step(8);
  @(negedge clk); read_a=1; base=cyc; capture=1;
  @(negedge clk); read_a=0;
  step(324); capture=0;
  for(m=0;m<256;m=m+1) $display("VALUE %0d %0d %03x",g,m,cap[2*PE+3+m]);
 end
 $display("COMPLETE_TIMING %0d %0d",PE,NV);
 $finish;
end
endmodule
