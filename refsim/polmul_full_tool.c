/* ===========================================================================
 * polmul_full_tool.c —— 完整多项式乘法（时域进、时域出）的参考实现外壳
 *
 * 对应 RTL 的 ALL_FULL 通路：FNTT(a) → FNTT(b) → PWM2 → INTT
 *
 * 用法：
 *   polmul_full_tool.exe <a.txt> <b.txt> <out.txt> --full
 *   polmul_full_tool.exe <a.txt> <b.txt> <out.txt> --half   (b 已在 NTT 域)
 *
 * 读两个每行一个十六进制系数的文件（各 256 个）：
 *   --full : poly_ntt(a); poly_ntt(b); poly_basemul_montgomery(r,a,b);
 *            poly_invntt_tomont(r);            → 时域结果
 *   --half : poly_ntt(a); poly_basemul_montgomery(r,a,b);
 *            poly_invntt_tomont(r);            → 时域结果（b 直接当 NTT 域用）
 *
 * 输出格式：小写、无前导零、LF 行尾 —— 便于直接 diff。
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
    int half = 0;
    if (argc < 5 ||
        (strcmp(argv[4], "--full") && (half = 1, strcmp(argv[4], "--half")))) {
        fprintf(stderr,
            "用法: %s <a.txt> <b.txt> <out.txt> --full|--half\n"
            "  --full: a、b 均为时域；--half: b 已在 NTT 域。\n"
            "  结果为时域（多项式的完整乘积）。\n", argv[0]);
        return 2;
    }

    poly A, B, R;
    if (read_poly(argv[1], &A) != KYBER_N) return 3;
    if (read_poly(argv[2], &B) != KYBER_N) return 3;

    poly_ntt(&A);
    if (!half) poly_ntt(&B);
    poly_basemul_montgomery(&R, &A, &B);
    poly_invntt_tomont(&R);
    to_canon(R.coeffs, KYBER_N);

    /* "wb" 强制 LF：Windows 文本模式会把 \n 翻成 \r\n，数值全对而 diff 报全不同 */
    FILE *fo = fopen(argv[3], "wb");
    if (!fo) { fprintf(stderr, "写不了 %s\n", argv[3]); return 2; }
    int i;
    for (i = 0; i < KYBER_N; i++)
        fprintf(fo, "%x\n", (unsigned)(R.coeffs[i] & 0x0FFF));
    fclose(fo);

    fprintf(stderr, "✅ %s ⊗ %s → %s  (%s, %d 个系数)\n",
            argv[1], argv[2], argv[3], half ? "half" : "full", KYBER_N);
    return 0;
}
