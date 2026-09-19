/* ===========================================================================
 * polmul_ref_tool.c —— 拿 KAT 校验过的 C 参考实现算「点乘」，供 RTL 对拍
 *
 * 为什么需要它：ntt_ref_tool.c 只支持单输入的 NTT/INTT，而点乘（PWM2）是
 * **两输入**运算，没法用那个外壳。
 *
 * 用法：
 *   polmul_ref_tool.exe <a.txt> <b.txt> <out.txt> --basemul
 *
 *   读两个每行一个十六进制系数的文件（各 256 个），做
 *       poly_ntt(a); poly_ntt(b); poly_basemul_montgomery(out, a, b);
 *   结果写回同样的文本格式。
 *
 * 注意步骤：参考实现的 poly_basemul_montgomery 要求两个输入**已经在 NTT 域**
 * （kyber_ref 里它被 polyvec_basemul_acc_montgomery 调用，传入的都是 NTT 后的多项式）。
 * 所以本工具自己补上那两步 NTT —— 调用方只管喂时域系数。
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

/* 读入 KYBER_N 个十六进制系数；返回实际读到的个数 */
static int read_poly(const char *path, poly *p)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); exit(2); }
    int n = 0;
    char line[256];
    while (fgets(line, sizeof(line), f) && n < KYBER_N) {
        char *s = line;
        while (*s && isspace((unsigned char)*s)) s++;
        if (*s == '\0' || *s == '#' || *s == '/') continue;   /* 空行/注释 */
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
    if (argc < 5 || strcmp(argv[4], "--basemul")) {
        fprintf(stderr,
            "用法: %s <a.txt> <b.txt> <out.txt> --basemul\n"
            "  读两个各含 %d 个十六进制系数的文件，\n"
            "  做 NTT(a)、NTT(b) 后逐系数点乘（Montgomery），结果写回文本。\n",
            argv[0], KYBER_N);
        return 2;
    }

    poly A, B, R;
    if (read_poly(argv[1], &A) != KYBER_N) return 3;
    if (read_poly(argv[2], &B) != KYBER_N) return 3;

    poly_ntt(&A);
    poly_ntt(&B);
    poly_basemul_montgomery(&R, &A, &B);
    to_canon(R.coeffs, KYBER_N);

    /* 用 "wb"：Windows 文本模式会把 \n 翻成 \r\n，而 RTL 测试数据是 LF。
     * 这个差异会让 diff 把 256 行全报成"不同"，数值却一个不差。 */
    FILE *fo = fopen(argv[3], "wb");
    if (!fo) { fprintf(stderr, "写不了 %s\n", argv[3]); return 2; }
    int i;
    for (i = 0; i < KYBER_N; i++)
        fprintf(fo, "%x\n", (unsigned)(R.coeffs[i] & 0x0FFF));
    fclose(fo);

    fprintf(stderr, "✅ %s ⊗ %s → %s  (basemul, %d 个系数)\n",
            argv[1], argv[2], argv[3], KYBER_N);
    return 0;
}
