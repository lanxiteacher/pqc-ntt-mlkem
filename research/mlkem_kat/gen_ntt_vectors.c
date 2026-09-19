/* ===========================================================================
 * ntt_golden.c —— 为 FPGA testbench 生成 NTT / INTT / basemul 黄金向量
 *
 * 为什么 KAT 不够：KAT 的字段是 KEM 级的（pk/sk/ct/ss），一个只有 NTT 的
 * 硬件模块既吃不进也吐不出这些字段。NTT 核必须用另一套方法验 —— 直接对拍
 * 参考实现的输出。这个程序就是产对拍向量用的。
 *
 * 所有输出都是 int16 的规范形式（canonical，落在 [0, q) 内），
 * 这样 FPGA 侧不需要关心参考实现内部的 Montgomery 表示。
 *
 * 生成文件：
 *   ntt_in.hex      ntt_out.hex       —— 正变换对拍
 *   intt_in.hex     intt_out.hex      —— 逆变换对拍
 *   basemul_a.hex   basemul_b.hex  basemul_out.hex  —— 点乘对拍
 *
 * .hex 格式：每行一个系数，3 位十六进制（12 bit），向量按顺序首尾相接。
 * 共 NVEC 个向量，每个 256 个系数 —— 第 v 个向量的第 i 个系数在第 v*256+i 行。
 * 可直接喂给 Verilog 的 $readmemh。
 * =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "poly.h"
#include "ntt.h"
#include "params.h"
#include "reduce.h"
#include "symmetric.h"

#define NVEC 16

static poly F, G, H, T;

/* ---- 确定性伪随机（xorshift32），保证每次跑出一样的向量 ---------------- */
static uint32_t rng_state = 0x12345678u;
static uint32_t rnd(void)
{
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

/* ---- 归一到规范形式 [0, q) --------------------------------------------- */
static void to_canon(int16_t *a, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        int32_t t = a[i] % KYBER_Q;
        if (t < 0) t += KYBER_Q;
        a[i] = (int16_t)t;
    }
}

/* ---- 模 q 求逆（费马小定理，q 是素数）---------------------------------- */
static int32_t modinv(int32_t a)
{
    int32_t r = 1, b = a % KYBER_Q, e = KYBER_Q - 2;
    if (b < 0) b += KYBER_Q;
    while (e) {
        if (e & 1) r = (int32_t)(((int64_t)r * b) % KYBER_Q);
        b = (int32_t)(((int64_t)b * b) % KYBER_Q);
        e >>= 1;
    }
    return r;
}

static FILE *open_or_die(const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "写不了 %s\n", path); exit(1); }
    return f;
}

static void dump(FILE *f, const int16_t *a, int n)
{
    int i;
    for (i = 0; i < n; i++)
        fprintf(f, "%03x\n", (unsigned)(a[i] & 0x0FFF));
}

int
main(void)
{
    int v, i;

    FILE *f_ni = open_or_die("ntt_in.hex");
    FILE *f_no = open_or_die("ntt_out.hex");
    FILE *f_ii = open_or_die("intt_in.hex");
    FILE *f_io = open_or_die("intt_out.hex");
    FILE *f_ba = open_or_die("basemul_a.hex");
    FILE *f_bb = open_or_die("basemul_b.hex");
    FILE *f_bo = open_or_die("basemul_out.hex");
    FILE *f_tx = open_or_die("ntt_vectors.txt");

    fprintf(f_tx,
        "ML-KEM-768 (Kyber-768) NTT 黄金向量\n"
        "====================================\n"
        " q = %d,  n = %d,  向量数 = %d\n"
        " 所有系数均为规范形式 [0, q)\n"
        " .hex 文件每行一个系数（3 位十六进制），第 v 个向量第 i 个系数在第 v*n+i 行\n\n",
        KYBER_Q, KYBER_N, NVEC);

    int32_t scale = -1;      /* invntt(ntt(f)) = f * scale  (mod q) */
    int scale_ok = 1;

    for (v = 0; v < NVEC; v++) {
        /* ---- 造输入：规范形式随机多项式 ---- */
        for (i = 0; i < KYBER_N; i++) F.coeffs[i] = (int16_t)(rnd() % KYBER_Q);
        for (i = 0; i < KYBER_N; i++) G.coeffs[i] = (int16_t)(rnd() % KYBER_Q);

        dump(f_ni, F.coeffs, KYBER_N);
        dump(f_ba, F.coeffs, KYBER_N);
        dump(f_bb, G.coeffs, KYBER_N);

        /* ---- 正变换 ---- */
        T = F;
        poly_ntt(&T);                 /* 内含 ntt() + poly_reduce() */
        to_canon(T.coeffs, KYBER_N);
        dump(f_no, T.coeffs, KYBER_N);

        /* ---- 逆变换（喂正变换的输出）---- */
        dump(f_ii, T.coeffs, KYBER_N);
        H = T;
        poly_invntt_tomont(&H);
        to_canon(H.coeffs, KYBER_N);
        dump(f_io, H.coeffs, KYBER_N);

        /* ---- 标定往返缩放 invntt(ntt(f)) = f * scale (mod q) ---- */
        {
            int32_t lhs = H.coeffs[0];
            int32_t rhs = F.coeffs[0];
            if (rhs == 0) {
                /* 罕见，换个下标来标定 */
                for (i = 1; i < KYBER_N; i++) if (F.coeffs[i]) { rhs = F.coeffs[i]; lhs = H.coeffs[i]; break; }
            }
            int32_t s = (int32_t)(((int64_t)lhs * modinv(rhs)) % KYBER_Q);
            if (scale < 0) scale = s;
            else if (scale != s) scale_ok = 0;

            /* 全系数复核 */
            for (i = 0; i < KYBER_N; i++) {
                int32_t want = (int32_t)(((int64_t)F.coeffs[i] * s) % KYBER_Q);
                if (want != H.coeffs[i]) { scale_ok = 0; break; }
            }
        }

        /* ---- basemul：点乘 ---- */
        {
            poly A = F, B = G, R;
            poly_ntt(&A); poly_ntt(&B);
            poly_basemul_montgomery(&R, &A, &B);
            to_canon(R.coeffs, KYBER_N);
            dump(f_bo, R.coeffs, KYBER_N);
        }
    }

    fprintf(f_tx,
        "往返缩放：invntt(ntt(f)) = f * %d  (mod q)\n"
        "  %s\n\n",
        scale,
        scale_ok
            ? "✅ 所有向量、所有系数都满足同一个缩放因子（纯缩放，无畸变）"
            : "❌ 缩放因子不一致 —— 存在畸变，需排查");

    fprintf(f_tx,
        "文件对应关系\n"
        "------------\n"
        "  正变换：  ntt_in.hex   → ntt_out.hex\n"
        "  逆变换：  intt_in.hex  → intt_out.hex\n"
        "             （intt_in 就是上一条的 ntt_out，所以逆变换可直接复用正变换结果）\n"
        "  点乘：    basemul_a.hex, basemul_b.hex → basemul_out.hex\n"
        "             （a、b 是规范形式输入；输出是 a 与 b 各自做 NTT 后逐对相乘的结果）\n\n"
        "注意\n"
        "----\n"
        "  basemul_out 对应的是「两个 NTT 域多项式做 basemul」，不是「两个规范形式\n"
        "  多项式直接相乘」。硬件侧要么先各做一次 NTT，要么直接把 a/b 当 NTT 域用。\n");

    fclose(f_ni); fclose(f_no); fclose(f_ii); fclose(f_io);
    fclose(f_ba); fclose(f_bb); fclose(f_bo); fclose(f_tx);

    printf("✅ 已生成 %d 个向量（每个 %d 个系数）的黄金向量\n", NVEC, KYBER_N);
    printf("   往返缩放因子 = %d  (%s)\n", scale,
           scale_ok ? "全部向量、全部系数一致" : "不一致！");

    /* 顺带报告几个硬件侧会用到的常数 */
    {
        /* R = 2^16 mod q；R^2 mod q 是 Montgomery 域转换要用的 */
        int32_t R   = 65536 % KYBER_Q;
        int32_t R2  = (int32_t)(((int64_t)R * R) % KYBER_Q);
        int32_t inv128 = (int32_t)modinv(128);
        printf("\n   R   = 2^16 mod q = %d\n", R);
        printf("   R^2 mod q        = %d   (转到 Montgomery 域要乘它)\n", R2);
        printf("   128^-1 mod q     = %d\n", inv128);
        printf("   128 * %d mod q   = %d  %s\n", inv128,
               (int)(((int64_t)128 * inv128) % KYBER_Q),
               (((int64_t)128 * inv128) % KYBER_Q) == 1 ? "✅ 互逆" : "❌");
    }
    return scale_ok ? 0 : 1;
}
