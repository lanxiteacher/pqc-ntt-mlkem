/* 驱动 pq-crystals/kyber 的 ref/ntt.c + ref/reduce.c，导出中间结果供 Python 对拍 */
#include <stdio.h>
#include <stdint.h>
#include "params.h"
#include "ntt.h"
#include "reduce.h"

static uint32_t st = 20260918u;
static uint32_t rnd(void) { st = st * 1664525u + 1013904223u; return st >> 16; }

static void dump(const char *tag, const int16_t *v, int n) {
  printf("%s", tag);
  for (int i = 0; i < n; i++) printf(" %d", v[i]);
  printf("\n");
}

int main(void) {
  int16_t a[256], b[256], na[256], nb[256], prod[256];

  for (int i = 0; i < 256; i++) { a[i] = (int16_t)(rnd() % KYBER_Q); b[i] = (int16_t)(rnd() % KYBER_Q); }
  dump("A", a, 256);
  dump("B", b, 256);

  /* 导出 zetas 表 */
  dump("ZETAS", zetas, 128);

  /* 单个模乘单元抽查（fqmul 在 ntt.c 里是 static，这里等价展开） */
  printf("FQMUL");
  for (int i = 0; i < 32; i++)
    printf(" %d", montgomery_reduce((int32_t)a[i] * (int32_t)b[i]));
  printf("\n");

  for (int i = 0; i < 256; i++) { na[i] = a[i]; nb[i] = b[i]; }
  ntt(na); ntt(nb);
  dump("NTT_A", na, 256);
  dump("NTT_B", nb, 256);

  /* basemul + invntt，复刻 poly_basemul_montgomery 的索引规则 */
  for (int i = 0; i < KYBER_N / 4; i++) {
    basemul(&prod[4 * i],     &na[4 * i],     &nb[4 * i],     zetas[64 + i]);
    basemul(&prod[4 * i + 2], &na[4 * i + 2], &nb[4 * i + 2], (int16_t)-zetas[64 + i]);
  }
  invntt(prod);
  dump("PROD", prod, 256);

  /* barrett_reduce 抽查 */
  printf("BARRETT");
  for (int i = 0; i < 32; i++) printf(" %d", barrett_reduce((int16_t)(a[i] - b[i])));
  printf("\n");

  return 0;
}
