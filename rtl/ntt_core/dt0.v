
/*
The designers:

Ahmet Can Mert <ahmetcanmert@sabanciuniv.edu>
Ferhat Yaman <ferhatyaman@sabanciuniv.edu>

To the extent possible under law, the implementer has waived all copyright
and related or neighboring rights to the source code in this file.
http://creativecommons.org/publicdomain/zero/1.0/
*/

module ntt_dt0(
    input [7-1:0] t0_0,
    input [8-1:0] t0_1,
    input [8-1:0] t0_2,
    input [7-1:0] t0_3,
    input [7-1:0] t0_4,
    input [5-1:0] t0_5,
    input [6-1:0] t0_6,
    input [4-1:0] t0_7,
    input [9-1:0] t0_8,
    input [6-1:0] t0_9,
    input [8-1:0] t0_10,
    input [2-1:0] t0_11,
    input [1-1:0] t0_13,
    input [1-1:0] t0_14,
    output [15-1:0] s,
    output [15-1:0] c);

// ------------------------------- Connections

    // --------------------- Level 1

    wire [6-1:0] t1_0;
    wire [6-1:0] t1_1;
    wire [6-1:0] t1_2;
    wire [6-1:0] t1_3;
    wire [6-1:0] t1_4;
    wire [6-1:0] t1_5;
    wire [6-1:0] t1_6;
    wire [5-1:0] t1_7;
    wire [6-1:0] t1_8;
    wire [6-1:0] t1_9;
    wire [6-1:0] t1_10;
    wire [4-1:0] t1_11;
    wire [1-1:0] t1_13;
    wire [1-1:0] t1_14;

    // --------------------- Level 2

    wire [4-1:0] t2_0;
    wire [4-1:0] t2_1;
    wire [4-1:0] t2_2;
    wire [4-1:0] t2_3;
    wire [4-1:0] t2_4;
    wire [4-1:0] t2_5;
    wire [4-1:0] t2_6;
    wire [4-1:0] t2_7;
    wire [4-1:0] t2_8;
    wire [4-1:0] t2_9;
    wire [4-1:0] t2_10;
    wire [4-1:0] t2_11;
    wire [1-1:0] t2_12;
    wire [1-1:0] t2_13;
    wire [1-1:0] t2_14;

    // --------------------- Level 3

    wire [3-1:0] t3_0;
    wire [3-1:0] t3_1;
    wire [3-1:0] t3_2;
    wire [3-1:0] t3_3;
    wire [3-1:0] t3_4;
    wire [3-1:0] t3_5;
    wire [3-1:0] t3_6;
    wire [3-1:0] t3_7;
    wire [3-1:0] t3_8;
    wire [3-1:0] t3_9;
    wire [3-1:0] t3_10;
    wire [3-1:0] t3_11;
    wire [2-1:0] t3_12;
    wire [1-1:0] t3_13;
    wire [1-1:0] t3_14;

    // --------------------- Level 4

    wire [2-1:0] t4_0;
    wire [2-1:0] t4_1;
    wire [2-1:0] t4_2;
    wire [2-1:0] t4_3;
    wire [2-1:0] t4_4;
    wire [2-1:0] t4_5;
    wire [2-1:0] t4_6;
    wire [2-1:0] t4_7;
    wire [2-1:0] t4_8;
    wire [2-1:0] t4_9;
    wire [2-1:0] t4_10;
    wire [2-1:0] t4_11;
    wire [2-1:0] t4_12;
    wire [2-1:0] t4_13;
    wire [1-1:0] t4_14;

// ------------------------------- Operations

    // --------------------- Level 1

    ntt_HA u000(t0_0[0],t0_0[1],t1_1[0],t1_0[0]);
    assign t1_0[1] = t0_0[2];
    assign t1_0[2] = t0_0[3];
    assign t1_0[3] = t0_0[4];
    assign t1_0[4] = t0_0[5];
    assign t1_0[5] = t0_0[6];
    ntt_FA u010(t0_1[0],t0_1[1],t0_1[2],t1_2[0],t1_1[1]);
    ntt_HA u011(t0_1[3],t0_1[4],t1_2[1],t1_1[2]);
    assign t1_1[3] = t0_1[5];
    assign t1_1[4] = t0_1[6];
    assign t1_1[5] = t0_1[7];
    ntt_FA u020(t0_2[0],t0_2[1],t0_2[2],t1_3[0],t1_2[2]);
    ntt_FA u021(t0_2[3],t0_2[4],t0_2[5],t1_3[1],t1_2[3]);
    assign t1_2[4] = t0_2[6];
    assign t1_2[5] = t0_2[7];
    ntt_FA u030(t0_3[0],t0_3[1],t0_3[2],t1_4[0],t1_3[2]);
    ntt_HA u031(t0_3[3],t0_3[4],t1_4[1],t1_3[3]);
    assign t1_3[4] = t0_3[5];
    assign t1_3[5] = t0_3[6];
    ntt_FA u040(t0_4[0],t0_4[1],t0_4[2],t1_5[0],t1_4[2]);
    ntt_HA u041(t0_4[3],t0_4[4],t1_5[1],t1_4[3]);
    assign t1_4[4] = t0_4[5];
    assign t1_4[5] = t0_4[6];
    ntt_HA u050(t0_5[0],t0_5[1],t1_6[0],t1_5[2]);
    assign t1_5[3] = t0_5[2];
    assign t1_5[4] = t0_5[3];
    assign t1_5[5] = t0_5[4];
    ntt_HA u060(t0_6[0],t0_6[1],t1_7[0],t1_6[1]);
    assign t1_6[2] = t0_6[2];
    assign t1_6[3] = t0_6[3];
    assign t1_6[4] = t0_6[4];
    assign t1_6[5] = t0_6[5];
    assign t1_7[1] = t0_7[0];
    assign t1_7[2] = t0_7[1];
    assign t1_7[3] = t0_7[2];
    assign t1_7[4] = t0_7[3];
    ntt_FA u080(t0_8[0],t0_8[1],t0_8[2],t1_9[0],t1_8[0]);
    ntt_HA u081(t0_8[3],t0_8[4],t1_9[1],t1_8[1]);
    assign t1_8[2] = t0_8[5];
    assign t1_8[3] = t0_8[6];
    assign t1_8[4] = t0_8[7];
    assign t1_8[5] = t0_8[8];
    ntt_FA u090(t0_9[0],t0_9[1],t0_9[2],t1_10[0],t1_9[2]);
    assign t1_9[3] = t0_9[3];
    assign t1_9[4] = t0_9[4];
    assign t1_9[5] = t0_9[5];
    ntt_FA u0100(t0_10[0],t0_10[1],t0_10[2],t1_11[0],t1_10[1]);
    ntt_HA u0101(t0_10[3],t0_10[4],t1_11[1],t1_10[2]);
    assign t1_10[3] = t0_10[5];
    assign t1_10[4] = t0_10[6];
    assign t1_10[5] = t0_10[7];
    assign t1_11[2] = t0_11[0];
    assign t1_11[3] = t0_11[1];
    assign t1_13[0] = t0_13[0];
    assign t1_14[0] = t0_14[0];

    // --------------------- Level 2

    ntt_FA u100(t1_0[0],t1_0[1],t1_0[2],t2_1[0],t2_0[0]);
    assign t2_0[1] = t1_0[3];
    assign t2_0[2] = t1_0[4];
    assign t2_0[3] = t1_0[5];
    ntt_FA u110(t1_1[0],t1_1[1],t1_1[2],t2_2[0],t2_1[1]);
    ntt_HA u111(t1_1[3],t1_1[4],t2_2[1],t2_1[2]);
    assign t2_1[3] = t1_1[5];
    ntt_FA u120(t1_2[0],t1_2[1],t1_2[2],t2_3[0],t2_2[2]);
    ntt_FA u121(t1_2[3],t1_2[4],t1_2[5],t2_3[1],t2_2[3]);
    ntt_FA u130(t1_3[0],t1_3[1],t1_3[2],t2_4[0],t2_3[2]);
    ntt_FA u131(t1_3[3],t1_3[4],t1_3[5],t2_4[1],t2_3[3]);
    ntt_FA u140(t1_4[0],t1_4[1],t1_4[2],t2_5[0],t2_4[2]);
    ntt_FA u141(t1_4[3],t1_4[4],t1_4[5],t2_5[1],t2_4[3]);
    ntt_FA u150(t1_5[0],t1_5[1],t1_5[2],t2_6[0],t2_5[2]);
    ntt_FA u151(t1_5[3],t1_5[4],t1_5[5],t2_6[1],t2_5[3]);
    ntt_FA u160(t1_6[0],t1_6[1],t1_6[2],t2_7[0],t2_6[2]);
    ntt_FA u161(t1_6[3],t1_6[4],t1_6[5],t2_7[1],t2_6[3]);
    ntt_FA u170(t1_7[0],t1_7[1],t1_7[2],t2_8[0],t2_7[2]);
    ntt_HA u171(t1_7[3],t1_7[4],t2_8[1],t2_7[3]);
    ntt_FA u180(t1_8[0],t1_8[1],t1_8[2],t2_9[0],t2_8[2]);
    ntt_FA u181(t1_8[3],t1_8[4],t1_8[5],t2_9[1],t2_8[3]);
    ntt_FA u190(t1_9[0],t1_9[1],t1_9[2],t2_10[0],t2_9[2]);
    ntt_FA u191(t1_9[3],t1_9[4],t1_9[5],t2_10[1],t2_9[3]);
    ntt_FA u1100(t1_10[0],t1_10[1],t1_10[2],t2_11[0],t2_10[2]);
    ntt_FA u1101(t1_10[3],t1_10[4],t1_10[5],t2_11[1],t2_10[3]);
    ntt_FA u1110(t1_11[0],t1_11[1],t1_11[2],t2_12[0],t2_11[2]);
    assign t2_11[3] = t1_11[3];
    assign t2_13[0] = t1_13[0];
    assign t2_14[0] = t1_14[0];

    // --------------------- Level 3

    ntt_HA u200(t2_0[0],t2_0[1],t3_1[0],t3_0[0]);
    assign t3_0[1] = t2_0[2];
    assign t3_0[2] = t2_0[3];
    ntt_FA u210(t2_1[0],t2_1[1],t2_1[2],t3_2[0],t3_1[1]);
    assign t3_1[2] = t2_1[3];
    ntt_FA u220(t2_2[0],t2_2[1],t2_2[2],t3_3[0],t3_2[1]);
    assign t3_2[2] = t2_2[3];
    ntt_FA u230(t2_3[0],t2_3[1],t2_3[2],t3_4[0],t3_3[1]);
    assign t3_3[2] = t2_3[3];
    ntt_FA u240(t2_4[0],t2_4[1],t2_4[2],t3_5[0],t3_4[1]);
    assign t3_4[2] = t2_4[3];
    ntt_FA u250(t2_5[0],t2_5[1],t2_5[2],t3_6[0],t3_5[1]);
    assign t3_5[2] = t2_5[3];
    ntt_FA u260(t2_6[0],t2_6[1],t2_6[2],t3_7[0],t3_6[1]);
    assign t3_6[2] = t2_6[3];
    ntt_FA u270(t2_7[0],t2_7[1],t2_7[2],t3_8[0],t3_7[1]);
    assign t3_7[2] = t2_7[3];
    ntt_FA u280(t2_8[0],t2_8[1],t2_8[2],t3_9[0],t3_8[1]);
    assign t3_8[2] = t2_8[3];
    ntt_FA u290(t2_9[0],t2_9[1],t2_9[2],t3_10[0],t3_9[1]);
    assign t3_9[2] = t2_9[3];
    ntt_FA u2100(t2_10[0],t2_10[1],t2_10[2],t3_11[0],t3_10[1]);
    assign t3_10[2] = t2_10[3];
    ntt_FA u2110(t2_11[0],t2_11[1],t2_11[2],t3_12[0],t3_11[1]);
    assign t3_11[2] = t2_11[3];
    assign t3_12[1] = t2_12[0];
    assign t3_13[0] = t2_13[0];
    assign t3_14[0] = t2_14[0];

    // --------------------- Level 4

    ntt_HA u300(t3_0[0],t3_0[1],t4_1[0],t4_0[0]);
    assign t4_0[1] = t3_0[2];
    ntt_FA u310(t3_1[0],t3_1[1],t3_1[2],t4_2[0],t4_1[1]);
    ntt_FA u320(t3_2[0],t3_2[1],t3_2[2],t4_3[0],t4_2[1]);
    ntt_FA u330(t3_3[0],t3_3[1],t3_3[2],t4_4[0],t4_3[1]);
    ntt_FA u340(t3_4[0],t3_4[1],t3_4[2],t4_5[0],t4_4[1]);
    ntt_FA u350(t3_5[0],t3_5[1],t3_5[2],t4_6[0],t4_5[1]);
    ntt_FA u360(t3_6[0],t3_6[1],t3_6[2],t4_7[0],t4_6[1]);
    ntt_FA u370(t3_7[0],t3_7[1],t3_7[2],t4_8[0],t4_7[1]);
    ntt_FA u380(t3_8[0],t3_8[1],t3_8[2],t4_9[0],t4_8[1]);
    ntt_FA u390(t3_9[0],t3_9[1],t3_9[2],t4_10[0],t4_9[1]);
    ntt_FA u3100(t3_10[0],t3_10[1],t3_10[2],t4_11[0],t4_10[1]);
    ntt_FA u3110(t3_11[0],t3_11[1],t3_11[2],t4_12[0],t4_11[1]);
    ntt_HA u3120(t3_12[0],t3_12[1],t4_13[0],t4_12[1]);
    assign t4_13[1] = t3_13[0];
    assign t4_14[0] = t3_14[0];

    // --------------------- Rewire

    assign c[0] = t4_0[0];
    assign c[1] = t4_1[0];
    assign c[2] = t4_2[0];
    assign c[3] = t4_3[0];
    assign c[4] = t4_4[0];
    assign c[5] = t4_5[0];
    assign c[6] = t4_6[0];
    assign c[7] = t4_7[0];
    assign c[8] = t4_8[0];
    assign c[9] = t4_9[0];
    assign c[10] = t4_10[0];
    assign c[11] = t4_11[0];
    assign c[12] = t4_12[0];
    assign c[13] = t4_13[0];
    assign c[14] = t4_14[0];
    assign s[0] = t4_0[1];
    assign s[1] = t4_1[1];
    assign s[2] = t4_2[1];
    assign s[3] = t4_3[1];
    assign s[4] = t4_4[1];
    assign s[5] = t4_5[1];
    assign s[6] = t4_6[1];
    assign s[7] = t4_7[1];
    assign s[8] = t4_8[1];
    assign s[9] = t4_9[1];
    assign s[10] = t4_10[1];
    assign s[11] = t4_11[1];
    assign s[12] = t4_12[1];
    assign s[13] = t4_13[1];
    assign s[14] = 1'b0;

endmodule
