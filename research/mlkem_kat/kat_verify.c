/* ===========================================================================
 * kat_verify.c —— ML-KEM-768 官方 KAT 校验器
 *
 * 读入 kat_MLKEM_768.rsp（FIPS 203 格式，含 z/d/msg/pk/sk/ct/ss/ct_n/ss_n），
 * 对每一条记录做 4 项独立复算：
 *
 *   ① KeyGen : coins = d||z  →  keypair_derand → 比对 pk、sk
 *   ② Encaps : coins = msg   →  enc_derand     → 比对 ct、ss
 *   ③ Decaps : dec(ct, sk)                     → 比对 ss
 *   ④ 隐式拒绝: dec(ct_n, sk) == ss_n  且  ss_n != ss
 *
 * 为什么用 derand 接口：FIPS 203 的 KAT 把随机性显式写成 d/z/msg 字段，
 * 走 derand 可以完全绕开 DRBG，既不依赖 OpenSSL，也不依赖 /dev/urandom，
 * 结果逐比特可复现。
 *
 * 编译见 build_kat.sh。用法：
 *     kat_verify.exe kat_MLKEM_768.rsp [最多打印几条失败]
 *
 * ★ 迁移到 FPGA：把 ① 的 keypair_derand / ② 的 enc_derand 换成"从 FPGA 取回
 *   pk/sk/ct/ss"，其余三个比对函数一字不改，这个 harness 就直接变成
 *   软硬件一致性测试台。
 * =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../kyber_ref/kem.h"
#include "../kyber_ref/params.h"

#define MAXLINE 16384

typedef struct {
    int  count;
    int  seen;               /* 是否已出现 count 字段 */

    unsigned char z[KYBER_SYMBYTES];
    unsigned char d[KYBER_SYMBYTES];
    unsigned char msg[KYBER_SYMBYTES];
    unsigned char seed[48];

    unsigned char pk[CRYPTO_PUBLICKEYBYTES];
    unsigned char sk[CRYPTO_SECRETKEYBYTES];
    unsigned char ct[CRYPTO_CIPHERTEXTBYTES];
    unsigned char ss[CRYPTO_BYTES];
    unsigned char ct_n[CRYPTO_CIPHERTEXTBYTES];
    unsigned char ss_n[CRYPTO_BYTES];

    unsigned int got;        /* 位掩码：哪些字段到齐了 */
} kat_rec_t;

#define G_Z      (1u << 0)
#define G_D      (1u << 1)
#define G_MSG    (1u << 2)
#define G_PK     (1u << 3)
#define G_SK     (1u << 4)
#define G_CT     (1u << 5)
#define G_SS     (1u << 6)
#define G_CT_N   (1u << 7)
#define G_SS_N   (1u << 8)
#define G_REQUIRED (G_Z|G_D|G_MSG|G_PK|G_SK|G_CT|G_SS|G_CT_N|G_SS_N)

/* ---- 十六进制解析 ------------------------------------------------------- */
static int hex2bin(const char *hex, unsigned char *out, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        unsigned int b;
        if (sscanf(hex + 2 * i, "%2x", &b) != 1) return 0;
        out[i] = (unsigned char)b;
    }
    return 1;
}

/* ---- 逐字段填入一条记录。字段名以 '=' 前的部分（去空格）为准 -------------- */
static void fill(kat_rec_t *r, const char *name, const char *val)
{
    if      (!strcmp(name, "count")) { r->count = atoi(val); r->seen = 1; }
    else if (!strcmp(name, "z"))     { hex2bin(val, r->z,   KYBER_SYMBYTES); r->got |= G_Z;    }
    else if (!strcmp(name, "d"))     { hex2bin(val, r->d,   KYBER_SYMBYTES); r->got |= G_D;    }
    else if (!strcmp(name, "msg"))   { hex2bin(val, r->msg, KYBER_SYMBYTES); r->got |= G_MSG;  }
    else if (!strcmp(name, "seed"))  { hex2bin(val, r->seed, 48);                                 }
    else if (!strcmp(name, "pk"))    { hex2bin(val, r->pk, CRYPTO_PUBLICKEYBYTES);  r->got |= G_PK;   }
    else if (!strcmp(name, "sk"))    { hex2bin(val, r->sk, CRYPTO_SECRETKEYBYTES);  r->got |= G_SK;   }
    else if (!strcmp(name, "ct"))    { hex2bin(val, r->ct, CRYPTO_CIPHERTEXTBYTES); r->got |= G_CT;   }
    else if (!strcmp(name, "ss"))    { hex2bin(val, r->ss, CRYPTO_BYTES);           r->got |= G_SS;   }
    else if (!strcmp(name, "ct_n"))  { hex2bin(val, r->ct_n, CRYPTO_CIPHERTEXTBYTES); r->got |= G_CT_N; }
    else if (!strcmp(name, "ss_n"))  { hex2bin(val, r->ss_n, CRYPTO_BYTES);         r->got |= G_SS_N; }
    /* 其余字段（如 seed 之外的扩展）忽略 */
}

/* ---- 一条记录的四项校验。返回 0 = 全过，否则返回失败位掩码 -------------- */
#define F_KEYGEN  1
#define F_ENCAPS  2
#define F_DECAPS  4
#define F_REJECT  8

static unsigned verify(const kat_rec_t *r, int verbose)
{
    unsigned fail = 0;

    unsigned char coins[2 * KYBER_SYMBYTES];
    unsigned char pk2[CRYPTO_PUBLICKEYBYTES];
    unsigned char sk2[CRYPTO_SECRETKEYBYTES];
    unsigned char ct2[CRYPTO_CIPHERTEXTBYTES];
    unsigned char ss2[CRYPTO_BYTES];
    unsigned char ss3[CRYPTO_BYTES];
    unsigned char ssn[CRYPTO_BYTES];

    /* ① KeyGen：coins = d || z */
    memcpy(coins, r->d, KYBER_SYMBYTES);
    memcpy(coins + KYBER_SYMBYTES, r->z, KYBER_SYMBYTES);
    if (crypto_kem_keypair_derand(pk2, sk2, coins) != 0) {
        fail |= F_KEYGEN;
        if (verbose) printf("      crypto_kem_keypair_derand 返回非 0\n");
    } else {
        if (memcmp(pk2, r->pk, CRYPTO_PUBLICKEYBYTES)) {
            fail |= F_KEYGEN;
            if (verbose) printf("      pk 不符\n");
        }
        if (memcmp(sk2, r->sk, CRYPTO_SECRETKEYBYTES)) {
            fail |= F_KEYGEN;
            if (verbose) printf("      sk 不符\n");
        }
    }

    /* ② Encaps：coins = msg */
    if (crypto_kem_enc_derand(ct2, ss2, r->pk, r->msg) != 0) {
        fail |= F_ENCAPS;
        if (verbose) printf("      crypto_kem_enc_derand 返回非 0\n");
    } else {
        if (memcmp(ct2, r->ct, CRYPTO_CIPHERTEXTBYTES)) {
            fail |= F_ENCAPS;
            if (verbose) printf("      ct 不符\n");
        }
        if (memcmp(ss2, r->ss, CRYPTO_BYTES)) {
            fail |= F_ENCAPS;
            if (verbose) printf("      ss 不符\n");
        }
    }

    /* ③ Decaps：正常密文必须还原出同一个 ss */
    if (crypto_kem_dec(ss3, r->ct, r->sk) != 0) {
        fail |= F_DECAPS;
        if (verbose) printf("      crypto_kem_dec 返回非 0\n");
    } else if (memcmp(ss3, r->ss, CRYPTO_BYTES)) {
        fail |= F_DECAPS;
        if (verbose) printf("      decaps 结果与 ss 不符\n");
    }

    /* ④ 隐式拒绝：无效密文 ct_n 必须落到 ss_n，且不能等于真 ss */
    if (crypto_kem_dec(ssn, r->ct_n, r->sk) != 0) {
        fail |= F_REJECT;
        if (verbose) printf("      crypto_kem_dec(ct_n) 返回非 0\n");
    } else {
        if (memcmp(ssn, r->ss_n, CRYPTO_BYTES)) {
            fail |= F_REJECT;
            if (verbose) printf("      隐式拒绝输出与 ss_n 不符（FO 变换的 z 用错了？）\n");
        }
        if (!memcmp(ssn, r->ss, CRYPTO_BYTES)) {
            fail |= F_REJECT;
            if (verbose) printf("      隐式拒绝输出等于真 ss —— 拒绝路径没生效\n");
        }
    }

    return fail;
}

int
main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "kat_MLKEM_768.rsp";
    int max_show = (argc > 2) ? atoi(argv[2]) : 5;

    FILE *fp = fopen(path, "r");
    if (!fp) { printf("打不开 %s\n", path); return 2; }

    printf("=== ML-KEM-768 KAT 校验 ===\n");
    printf("向量文件: %s\n", path);
    printf("参数: K=%d  pk=%d B  sk=%d B  ct=%d B  ss=%d B\n\n",
           KYBER_K, CRYPTO_PUBLICKEYBYTES, CRYPTO_SECRETKEYBYTES,
           CRYPTO_CIPHERTEXTBYTES, CRYPTO_BYTES);

    kat_rec_t rec;
    memset(&rec, 0, sizeof(rec));

    char line[MAXLINE];
    int  total = 0, passed = 0, shown = 0, skipped = 0;
    unsigned agg = 0;

    while (fgets(line, sizeof(line), fp)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (line[0] == '\0' || line[0] == '#') continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';

        /* 字段名去掉首尾空格 */
        char *name = line;
        while (*name == ' ' || *name == '\t') name++;
        char *e = name + strlen(name);
        while (e > name && (e[-1] == ' ' || e[-1] == '\t')) *--e = '\0';

        char *val = eq + 1;
        while (*val == ' ' || *val == '\t') val++;

        /* 遇到新的 count 且上一条已收齐 → 先结算上一条 */
        if (!strcmp(name, "count") && rec.seen && (rec.got & G_REQUIRED) == G_REQUIRED) {
            total++;
            unsigned f = verify(&rec, shown < max_show);
            if (f == 0) passed++;
            else {
                agg |= f;
                if (shown < max_show) {
                    printf("  ❌ count=%d 失败位: %s%s%s%s\n", rec.count,
                           (f & F_KEYGEN) ? "KeyGen " : "",
                           (f & F_ENCAPS) ? "Encaps " : "",
                           (f & F_DECAPS) ? "Decaps " : "",
                           (f & F_REJECT) ? "隐式拒绝" : "");
                    shown++;
                }
            }
            memset(&rec, 0, sizeof(rec));
        }

        fill(&rec, name, val);
    }

    /* 文件末尾的最后一条（可能因截断而不完整） */
    if (rec.seen) {
        if ((rec.got & G_REQUIRED) == G_REQUIRED) {
            total++;
            unsigned f = verify(&rec, shown < max_show);
            if (f == 0) passed++;
            else {
                agg |= f;
                if (shown < max_show) printf("  ❌ count=%d 失败\n", rec.count);
                shown++;
            }
        } else {
            skipped++;
            printf("  ⚠️  末尾 count=%d 记录不完整（字段掩码 0x%03x），已跳过\n",
                   rec.count, rec.got);
        }
    }
    fclose(fp);

    printf("\n=== 汇总 ===\n");
    printf("  完整记录: %d\n", total);
    printf("  通过:     %d\n", passed);
    printf("  失败:     %d\n", total - passed);
    if (skipped) printf("  跳过(截断): %d\n", skipped);

    if (total == 0) {
        printf("\n  ⚠️  没解析到任何完整记录 —— 检查文件是否下载完整。\n");
        printf("      完整文件应为 12,012,890 字节 / 128 条记录。\n");
        return 3;
    }

    if (passed == total) {
        printf("\n  ✅ 全部通过 —— 参考实现与该向量集逐比特一致\n"
               "     （注意：这是社区维护的 FIPS 203 兼容向量集，非 NIST 官方发布；\n"
               "       可信度来自本次独立复算本身）\n");
        return 0;
    }

    printf("\n  ❌ 存在失败。失败类型汇总: %s%s%s%s\n",
           (agg & F_KEYGEN) ? "KeyGen " : "",
           (agg & F_ENCAPS) ? "Encaps " : "",
           (agg & F_DECAPS) ? "Decaps " : "",
           (agg & F_REJECT) ? "隐式拒绝" : "");
    return 1;
}
