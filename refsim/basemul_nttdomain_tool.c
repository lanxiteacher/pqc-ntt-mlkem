/* ===========================================================================
 * basemul_nttdomain_tool.c —— 在 **NTT 域** 上直接做 basemul（点乘）
 *
 * 和 polmul_ref_tool.c 的区别：
 *   polmul_ref_tool   : 吃「时域」系数，自己先做两次 poly_ntt，再 basemul
 *   basemul_nttdomain : 吃「已经是 NTT 域」的系数，**跳过 NTT**，直接 basemul
 *
 * 为什么需要两个：要分清 RTL 作者的数据文件到底处在哪个域。
 * 作者的 KYBER_DIN*_MFNTT.txt 已经是 NTT 域，拿 polmul_ref_tool 去喂
 * 会多做一次 NTT，结果必然全错 —— 白排查半天。
 *
 * 内部调用参考实现的 poly_basemul_montgomery()，它做的是
 *     r[4i..4i+1] = basemul(a,b, zetas[64+i])
 *     r[4i+2..]   = basemul(a,b,-zetas[64+i])
 * 即 Zq[X]/(X^2-zeta) 上的乘法，每 4 个系数一组 —— **不是逐系数相乘**。
 *
 * 用法：
 *   basemul_nttdomain_tool.exe <a.txt> <b.txt> <out.txt>
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

static int read_poly(const char *path, poly *p)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); exit(2); }
    int n = 0;
    char line[256];
    while (fgets(line, sizeof(line), f) && n < KYBER_N) {
        char *s = line;
        while (*s && isspace((unsigned char)*s)) s++;
        if (*s == '\0' || *s == '#' || *s == '/') continue;
        unsigned v;
        if (sscanf(s, "%x", &v) != 1) continue;
        p->coeffs[n++] = (int16_t)(v & 0x0FFF);
    }
    fclose(f);
    if (n != KYBER_N)
        fprintf(stderr, "⚠️  %s 只读到 %d 个系数（期望 %d）\n", path, n, KYBER_N);
    return n;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "用法: %s <a.txt> <b.txt> <out.txt>   （输入须已在 NTT 域）\n",
                argv[0]);
        return 2;
    }

    poly A, B, R;
    if (read_poly(argv[1], &A) != KYBER_N) return 3;
    if (read_poly(argv[2], &B) != KYBER_N) return 3;

    /* 不做 NTT —— 输入按约定已在 NTT 域 */
    poly_basemul_montgomery(&R, &A, &B);
    to_canon(R.coeffs, KYBER_N);

    FILE *fo = fopen(argv[3], "wb");   /* "wb" 保持 LF 行尾 */
    if (!fo) { fprintf(stderr, "写不了 %s\n", argv[3]); return 2; }
    int i;
    for (i = 0; i < KYBER_N; i++)
        fprintf(fo, "%x\n", (unsigned)(R.coeffs[i] & 0x0FFF));
    fclose(fo);

    fprintf(stderr, "✅ %s ⊗ %s → %s  (basemul on NTT-domain)\n",
            argv[1], argv[2], argv[3]);
    return 0;
}
