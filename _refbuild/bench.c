/* ML-KEM (Kyber768) 参考实现基准 —— 回答"NTT 在整个 KEM 里占多少" */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "params.h"
#include "kem.h"
#include "randombytes.h"

#define ITER 3000

int main(void) {
  uint8_t pk[KYBER_PUBLICKEYBYTES], sk[KYBER_SECRETKEYBYTES];
  uint8_t ct[KYBER_CIPHERTEXTBYTES], ss1[KYBER_SSBYTES], ss2[KYBER_SSBYTES];
  clock_t t0, t1;
  double kp, en, de;

  t0 = clock();
  for (int i = 0; i < ITER; i++) crypto_kem_keypair(pk, sk);
  t1 = clock();
  kp = 1e6 * (double)(t1 - t0) / CLOCKS_PER_SEC / ITER;

  crypto_kem_keypair(pk, sk);

  t0 = clock();
  for (int i = 0; i < ITER; i++) crypto_kem_enc(ct, ss1, pk);
  t1 = clock();
  en = 1e6 * (double)(t1 - t0) / CLOCKS_PER_SEC / ITER;

  t0 = clock();
  for (int i = 0; i < ITER; i++) crypto_kem_dec(ss2, ct, sk);
  t1 = clock();
  de = 1e6 * (double)(t1 - t0) / CLOCKS_PER_SEC / ITER;

  printf("=== ML-KEM-768 参考实现（纯 C，本机 CPU）===\n");
  printf("keypair : %8.1f us/op\n", kp);
  printf("encaps  : %8.1f us/op\n", en);
  printf("decaps  : %8.1f us/op\n", de);
  printf("共享密钥一致 (decaps==encaps): %s\n",
         memcmp(ss1, ss2, KYBER_SSBYTES) == 0 ? "YES" : "NO");
  printf("\n参数: KYBER_K=%d  n=%d  q=%d  pk=%d B  sk=%d B  ct=%d B\n",
         KYBER_K, KYBER_N, KYBER_Q,
         KYBER_PUBLICKEYBYTES, KYBER_SECRETKEYBYTES, KYBER_CIPHERTEXTBYTES);
  return 0;
}
