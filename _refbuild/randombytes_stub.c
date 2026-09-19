/* 确定性 PRNG 替身，跑基准测试用（竞赛实机不会用到，仅为可复现） */
#include <stddef.h>
#include <stdint.h>

static uint64_t s = 88172645463325252ULL;

void randombytes(uint8_t *out, size_t outlen) {
  for (size_t i = 0; i < outlen; i++) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    out[i] = (uint8_t)(s >> 24);
  }
}
