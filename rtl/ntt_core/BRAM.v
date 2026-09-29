/*
The designers:

Ahmet Can Mert <ahmetcanmert@sabanciuniv.edu>
Ferhat Yaman <ferhatyaman@sabanciuniv.edu>

To the extent possible under law, the implementer has waived all copyright
and related or neighboring rights to the source code in this file.
http://creativecommons.org/publicdomain/zero/1.0/
*/

// read latency is 1 cc
//
// 参数化：地址位宽 ADDR_W = L+1（pe1→8, pe4→6, pe16→4），
// 深度 = 2**ADDR_W，数据位宽三档恒为 12（一个地址存一个系数）。
// 端口名与位序与上游 rtl/pe1/BRAM.v 完全一致，只把写死的常数换成 ADDR_W。

module ntt_BRAM #(
    parameter ADDR_W = 8
)(
    input  wire                clk,
    input  wire                wen,
    input  wire [ADDR_W-1:0]   waddr,
    input  wire [11:0]         din,
    input  wire [ADDR_W-1:0]   raddr,
    output reg  [11:0]         dout
);
// bram
(* ram_style="block" *) reg [11:0] blockram [0:2**ADDR_W-1];

// write operation
always @(posedge clk) begin
    if(wen)
        blockram[waddr] <= din;
end

// read operation
always @(posedge clk) begin
    dout <= blockram[raddr];
end

endmodule
