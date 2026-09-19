/* AES-256 自检：
 *   1. FIPS-197 附录 C.3 官方测试向量
 *   2. 读取 testvec.txt（由 Python cryptography 库生成）逐条交叉验证
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "aes256_ecb.h"

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

int main(void)
{
    int pass = 0, fail = 0;

    /* ---- 1. FIPS-197 附录 C.3 ---- */
    {
        unsigned char key[32], pt[16], ct[16], want[16];
        const char *KH = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        const char *PH = "00112233445566778899aabbccddeeff";
        const char *CH = "8ea2b7ca516745bfeafc49904b496089";

        hex2bin(KH, key, 32); hex2bin(PH, pt, 16); hex2bin(CH, want, 16);
        AES256_ECB(key, pt, ct);

        printf("=== 1. FIPS-197 附录 C.3 官方向量 ===\n");
        printf("  期望: ");
        for (int i = 0; i < 16; i++) printf("%02x", want[i]);
        printf("\n  实得: ");
        for (int i = 0; i < 16; i++) printf("%02x", ct[i]);
        if (memcmp(ct, want, 16) == 0) { printf("\n  ✅ 通过\n\n"); pass++; }
        else                            { printf("\n  ❌ 失败\n\n"); fail++; }
    }

    /* ---- 2. 与 Python cryptography 交叉验证 ---- */
    {
        FILE *f = fopen("testvec.txt", "r");
        char line[256];
        int n = 0, bad = 0;

        printf("=== 2. 交叉验证（Python cryptography 生成的随机向量）===\n");
        if (!f) {
            printf("  ⚠️  找不到 testvec.txt，跳过\n");
        } else {
            while (fgets(line, sizeof(line), f)) {
                char kh[65], ph[33], ch[33];
                unsigned char key[32], pt[16], ct[16], want[16];

                if (sscanf(line, "%64s %32s %32s", kh, ph, ch) != 3) continue;
                hex2bin(kh, key, 32); hex2bin(ph, pt, 16); hex2bin(ch, want, 16);
                AES256_ECB(key, pt, ct);
                n++;
                if (memcmp(ct, want, 16) != 0) {
                    if (bad < 3) {
                        printf("  ❌ 第 %d 条不符\n", n);
                        printf("     key=%s\n", kh);
                        printf("     期望=");
                        for (int i = 0; i < 16; i++) printf("%02x", want[i]);
                        printf("  实得=");
                        for (int i = 0; i < 16; i++) printf("%02x", ct[i]);
                        printf("\n");
                    }
                    bad++;
                }
            }
            fclose(f);
            printf("  共 %d 条，通过 %d，失败 %d\n", n, n - bad, bad);
            if (bad == 0 && n > 0) { printf("  ✅ 全部通过\n\n"); pass++; }
            else                   { printf("  ❌ 存在失败\n\n"); fail++; }
        }
    }

    printf("=== 汇总: %d 通过 / %d 失败 ===\n", pass, fail);
    return fail ? 1 : 0;
}
