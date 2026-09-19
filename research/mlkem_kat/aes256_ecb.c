/* ===========================================================================
 * aes256_ecb.c —— 自包含的 AES-256 单块加密
 *
 * 用途：替换 NIST CTR_DRBG (rng.c) 里对 OpenSSL 的依赖。
 *       原 rng.c 只用 OpenSSL 做一件事：AES256_ECB(key, in, out) 单块加密。
 *       本文件提供同一签名的实现，于是整个 KAT 生成器可以零外部依赖编译。
 *
 * 参数：AES-256 → Nk=8 字密钥，Nr=14 轮，轮密钥 60 字 = 240 字节
 * 状态布局：AES 的列主序，state[4*c + r] = input[4*c + r]
 *
 * 正确性：已用 FIPS-197 附录 C.3 的 AES-256 官方测试向量验证通过。
 * =========================================================================== */

#include <stdint.h>
#include <string.h>
#include "aes_tables.h"

/* ---- 轮常量 Rcon（AES-256 只需 7 个） ---------------------------------- */
static const uint8_t aes_rcon[8] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40
};

/* ---- GF(2^8) 乘法，模 x^8+x^4+x^3+x+1 -------------------------------- */
static uint8_t xtime(uint8_t x)
{
    return (uint8_t)((x << 1) ^ ((x >> 7) * 0x1B));
}

/* ---- 密钥扩展：32 字节密钥 → 240 字节轮密钥 ---------------------------- */
static void aes256_key_expansion(const uint8_t *key, uint8_t *rk)
{
    uint32_t w[60];
    int i;

    for (i = 0; i < 8; i++) {
        w[i] = ((uint32_t)key[4 * i]     << 24) |
               ((uint32_t)key[4 * i + 1] << 16) |
               ((uint32_t)key[4 * i + 2] <<  8) |
               ((uint32_t)key[4 * i + 3]);
    }

    for (i = 8; i < 60; i++) {
        uint32_t t = w[i - 1];

        if (i % 8 == 0) {
            /* RotWord + SubWord + Rcon */
            t = ((t << 8) | (t >> 24));
            t = ((uint32_t)aes_sbox[(t >> 24) & 0xFF] << 24) |
                ((uint32_t)aes_sbox[(t >> 16) & 0xFF] << 16) |
                ((uint32_t)aes_sbox[(t >>  8) & 0xFF] <<  8) |
                ((uint32_t)aes_sbox[ t        & 0xFF]);
            t ^= ((uint32_t)aes_rcon[i / 8] << 24);
        } else if (i % 8 == 4) {
            /* 仅 SubWord */
            t = ((uint32_t)aes_sbox[(t >> 24) & 0xFF] << 24) |
                ((uint32_t)aes_sbox[(t >> 16) & 0xFF] << 16) |
                ((uint32_t)aes_sbox[(t >>  8) & 0xFF] <<  8) |
                ((uint32_t)aes_sbox[ t        & 0xFF]);
        }

        w[i] = w[i - 8] ^ t;
    }

    for (i = 0; i < 60; i++) {
        rk[4 * i]     = (uint8_t)(w[i] >> 24);
        rk[4 * i + 1] = (uint8_t)(w[i] >> 16);
        rk[4 * i + 2] = (uint8_t)(w[i] >>  8);
        rk[4 * i + 3] = (uint8_t)(w[i]);
    }
}

/* ---- 轮变换 ------------------------------------------------------------ */
static void add_round_key(uint8_t *s, const uint8_t *rk)
{
    int i;
    for (i = 0; i < 16; i++)
        s[i] ^= rk[i];
}

static void sub_bytes(uint8_t *s)
{
    int i;
    for (i = 0; i < 16; i++)
        s[i] = aes_sbox[s[i]];
}

/* 状态索引 = 4*列 + 行；每行左移 0/1/2/3 --------------------------------- */
static void shift_rows(uint8_t *s)
{
    uint8_t t;

    /* 第 1 行左移 1 */
    t = s[1];  s[1] = s[5];  s[5] = s[9];  s[9] = s[13];  s[13] = t;
    /* 第 2 行左移 2 */
    t = s[2];  s[2] = s[10]; s[10] = t;
    t = s[6];  s[6] = s[14]; s[14] = t;
    /* 第 3 行左移 3（等价于右移 1） */
    t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
}

static void mix_columns(uint8_t *s)
{
    int c;
    for (c = 0; c < 4; c++) {
        uint8_t *p = s + 4 * c;
        uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
        uint8_t all = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);

        p[0] = (uint8_t)(a0 ^ all ^ xtime((uint8_t)(a0 ^ a1)));
        p[1] = (uint8_t)(a1 ^ all ^ xtime((uint8_t)(a1 ^ a2)));
        p[2] = (uint8_t)(a2 ^ all ^ xtime((uint8_t)(a2 ^ a3)));
        p[3] = (uint8_t)(a3 ^ all ^ xtime((uint8_t)(a3 ^ a0)));
    }
}

/* ---- 对外接口：与 OpenSSL 版同签名 -------------------------------------- */
void AES256_ECB(unsigned char *key, unsigned char *ctr, unsigned char *buffer)
{
    uint8_t rk[240];
    uint8_t s[16];
    int round;

    aes256_key_expansion((const uint8_t *)key, rk);
    memcpy(s, ctr, 16);

    add_round_key(s, rk);
    for (round = 1; round < 14; round++) {
        sub_bytes(s);
        shift_rows(s);
        mix_columns(s);
        add_round_key(s, rk + 16 * round);
    }
    /* 末轮不含 MixColumns */
    sub_bytes(s);
    shift_rows(s);
    add_round_key(s, rk + 224);

    memcpy(buffer, s, 16);
}
