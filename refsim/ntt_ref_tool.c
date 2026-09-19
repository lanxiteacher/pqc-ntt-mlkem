/* ===========================================================================
 * ntt_ref_tool.c —— 拿 KAT 校验过的 C 参考实现算 NTT，供 RTL 对拍
 *
 * 为什么需要它：RTL 作者自带的 testbench 是"作者的数据 vs 作者的 RTL"，
 * 只能证明自洽。要证明 RTL 真的对，得拿一份已经用 FIPS 203 官方向量
 * 校验过的参考实现来独立复算 —— 这个程序就是那个参考实现的外壳。
 *
 * 用法：
 *   ntt_ref_tool.exe <in.txt> <out.txt>            # 正变换
 *   ntt_ref_tool.exe <in.txt> <out.txt> --invntt   # 逆变换
 *
 * 输入格式：每行一个十六进制系数（允许无前导零，与 RTL 测试数据一致）
 * 输出格式：每行一个十六进制系数，小写、无前导零 —— 便于直接 diff
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
    if (argc < 3) {
        fprintf(stderr,
            "用法: %s <in.txt> <out.txt> [--invntt]\n"
            "  读每行一个十六进制系数的文件（共 %d 个），\n"
            "  用参考实现做 NTT/INTT，结果写回同样的文本格式。\n",
            argv[0], KYBER_N);
        return 2;
    }

    int do_inv = (argc > 3 && !strcmp(argv[3], "--invntt"));

    FILE *fi = fopen(argv[1], "r");
    if (!fi) { fprintf(stderr, "打不开 %s\n", argv[1]); return 2; }

    poly p;
    int n = 0;
    char line[256];
    while (fgets(line, sizeof(line), fi) && n < KYBER_N) {
        char *s = line;
        while (*s && isspace((unsigned char)*s)) s++;
        if (*s == '\0' || *s == '#' || *s == '/') continue;   /* 空行/注释 */
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

    /* 用 "wb" 而不是 "w"：Windows 文本模式会把 \n 翻译成 \r\n，
     * 而 RTL 测试数据是 LF 行尾。这个差异会让 diff 把 256 行全报成"不同"，
     * 明明数值一个不差 —— 白排查半天。统一写 LF。 */
    FILE *fo = fopen(argv[2], "wb");
    if (!fo) { fprintf(stderr, "写不了 %s\n", argv[2]); return 2; }
    int i;
    for (i = 0; i < KYBER_N; i++)
        fprintf(fo, "%x\n", (unsigned)(p.coeffs[i] & 0x0FFF));
    fclose(fo);

    fprintf(stderr, "✅ %s → %s  (%s, %d 个系数)\n",
            argv[1], argv[2], do_inv ? "INTT" : "NTT", KYBER_N);
    return 0;
}
