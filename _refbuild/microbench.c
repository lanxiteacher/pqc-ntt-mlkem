/* 微基准：测 NTT 家族原语单次耗时，配合 indcpa.c 里数出来的调用次数，
   推算 NTT 在 keypair/encaps/decaps 中的占比。 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "params.h"
#include "ntt.h"
#include "poly.h"

#define IT 200000

static poly pa, pb, pr;

static double bench(void (*f)(void)) {
  clock_t t0 = clock();
  for (int i = 0; i < IT; i++) f();
  clock_t t1 = clock();
  return 1e6 * (double)(t1 - t0) / CLOCKS_PER_SEC / IT;
}

static void f_ntt_raw(void)      { ntt(pa.coeffs); }
static void f_ntt_wrap(void)     { poly_ntt(&pa); }
static void f_invntt(void)       { poly_invntt_tomont(&pa); }
static void f_basemul(void)      { poly_basemul_montgomery(&pr, &pa, &pb); }

int main(void) {
  for (int i = 0; i < KYBER_N; i++) {
    pa.coeffs[i] = (int16_t)(i * 13 % KYBER_Q);
    pb.coeffs[i] = (int16_t)(i * 29 % KYBER_Q);
  }
  /* 让被调用者保持在合法输入范围内 */
  poly_ntt(&pa); poly_ntt(&pb);

  double t_raw = bench(f_ntt_raw);
  double t_ntt = bench(f_ntt_wrap);
  double t_inv = bench(f_invntt);
  double t_bm  = bench(f_basemul);

  printf("=== NTT 家族原语单次耗时（本机 CPU，-O2）===\n");
  printf("ntt()            裸变换      : %9.3f us\n", t_raw);
  printf("poly_ntt()       变换+Barrett: %9.3f us\n", t_ntt);
  printf("poly_invntt()    逆变换+缩放 : %9.3f us\n", t_inv);
  printf("poly_basemul()   逐点乘      : %9.3f us\n", t_bm);

  /* 调用次数由 indcpa.c / polyvec.c 源码静态数出（KYBER_K=3）：
       keypair: 6 poly_ntt, 9 poly_basemul
       enc    : 3 poly_ntt, 12 poly_basemul, 4 poly_invntt
       dec    : 3 poly_ntt, 3 poly_basemul, 1 poly_invntt            */
  struct { const char *name; int nn, ni, nb; double total; } ops[] = {
    {"keypair", 6,  0,  9, 36.7},
    {"encaps",  3,  4, 12, 40.0},
    {"decaps",  6,  5, 15, 90.3},   /* decaps = dec + 重加密(enc) */
  };

  printf("\n=== NTT 家族占比推算 ===\n");
  printf("%-9s %8s %8s %8s %11s %9s\n",
         "操作", "ntt数", "inv数", "bm数", "NTT家族us", "占整操作");
  for (int i = 0; i < 3; i++) {
    double ntt_t = ops[i].nn * t_ntt + ops[i].ni * t_inv + ops[i].nb * t_bm;
    printf("%-9s %8d %8d %8d %11.2f %8.1f%%\n",
           ops[i].name, ops[i].nn, ops[i].ni, ops[i].nb,
           ntt_t, 100.0 * ntt_t / ops[i].total);
  }
  printf("\n（decaps 实测量取 dec+enc 之和，因为 FO 变换要重加密）\n");
  printf("（余下部分是 SHAKE/Keccak 哈希、CBD 噪声采样、压缩编解码、序列化）\n");
  return 0;
}
