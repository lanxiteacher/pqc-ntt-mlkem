/* ===========================================================================
 * ntt_once_tool.c —— 单输入 NTT/INTT 外壳（只处理一个多项式）
 *
 * ntt_ref_tool.c 也能做这件事，但那个程序是给「一次 256 个系数」设计的，
 * 且不带 --ntt 正变换选项。本工具补上 --ntt，用于定位点乘约定：
 *   若点乘 RTL 正确，应有  NTT(DOUT) == NTT(DIN0) ⊙ NTT(DIN1)
 *
 * 用法：
 *   ntt_once_tool.exe <in.txt> <out.txt> --ntt      # 正变换 poly_ntt
 *   ntt_once_tool.exe <in.txt> <out.txt> --invntt   # 逆变换 poly_invntt_tomont
 *
 * 输出：小写、无前导零、LF 行尾。
 * =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../research/kyber_ref/poly.h"
#include "../research/kyber_ref/ntt.h"
#include "../research/kyber_ref/params.h"

static void to_canon(int16_t *a, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        int32_t t = a[i] % KYBER_Q;
        if (t < 0) t += KYBER_Q;
        a[i] = (int16_t)t;
    }
}

int main(int argc, char **argv)
{
    if (argc < 4 || (strcmp(argv[3], "--ntt") && strcmp(argv[3], "--invntt"))) {
        fprintf(stderr, "用法: %s <in.txt> <out.txt> [--ntt|--invntt]\n", argv[0]);
        return 2;
    }
    int do_inv = !strcmp(argv[3], "--invntt");

    FILE *fi = fopen(argv[1], "r");
    if (!fi) { fprintf(stderr, "打不开 %s\n", argv[1]); return 2; }

    poly p;
    int n = 0;
    char line[256];
    while (fgets(line, sizeof(line), fi) && n < KYBER_N) {
        char *s = line;
        while (*s && isspace((unsigned char)*s)) s++;
        if (*s == '\0' || *s == '#' || *s == '/') continue;
        unsigned v;
        if (sscanf(s, "%x", &v) != 1) continue;
        p.coeffs[n++] = (int16_t)(v & 0x0FFF);
    }
    fclose(fi);
    if (n != KYBER_N) {
        fprintf(stderr, "⚠️  %s 只读到 %d 个系数（期望 %d）\n", argv[1], n, KYBER_N);
        return 3;
    }

    if (do_inv) poly_invntt_tomont(&p);
    else        poly_ntt(&p);
    to_canon(p.coeffs, KYBER_N);

    FILE *fo = fopen(argv[2], "wb");   /* "wb" 保持 LF 行尾 */
    if (!fo) { fprintf(stderr, "写不了 %s\n", argv[2]); return 2; }
    int i;
    for (i = 0; i < KYBER_N; i++)
        fprintf(fo, "%x\n", (unsigned)(p.coeffs[i] & 0x0FFF));
    fclose(fo);

    fprintf(stderr, "✅ %s → %s  (%s)\n", argv[1], argv[2], do_inv ? "INTT" : "NTT");
    return 0;
}
