/* ===========================================================================
 * ntt_layers.c —— 把 ref/ntt.c 的 twiddle 层序**原样导出来**，供 RTL 逐行对照
 *
 * 为什么要有这个程序：
 *   项目记录里挂着一条"W1 最高优先级、无捷径"的待办 —— 试图凭记忆重建
 *   invntt 的 twiddle 层序，反复失败，正变换连"同态性"都对不上。
 *
 *   根因是**根本不存在 `zetas_inv` 这张表**。全仓库只在 ntt.c 开头一句注释里
 *   出现过 "zetas_inv" 这个词，可执行代码里 zetas[] 只被引用两次：
 *       ntt()    : k = 1;   zeta = zetas[k++];   // 正向，一路加
 *       invntt() : k = 127; zeta = zetas[k--];   // 逆向，一路减
 *   同一张表、方向相反，仅此而已。找一张不存在的表，当然怎么"重建"都对不上。
 *
 * 这个程序做两件事：
 *   ① 打印 7 层正变换 + 7 层逆变换的完整层序表（含每层吃掉的 zetas 下标区间）
 *   ② 拿自己按这张表实现的 ntt/invntt 去对拍 ref/ntt.c，证明表是对的
 *
 * 编译运行：见同目录 run_ntt_layers.sh
 * =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../research/kyber_ref/params.h"
#include "../research/kyber_ref/ntt.h"
#include "../research/kyber_ref/reduce.h"
#include "../research/kyber_ref/poly.h"

/* zetas[] 由 ntt.h 经 KYBER_NAMESPACE 宏提供，别再自己 extern 一遍 */

/* fqmul 在 ntt.c 里是 static（不导出），只能自己写一份等价的。
 * 它就是 montgomery_reduce(a*b)，而 montgomery_reduce 是导出的。 */
static int16_t my_fqmul(int16_t a, int16_t b)
{
    return montgomery_reduce((int32_t)a * b);
}
#define fqmul my_fqmul

/* ---- 按 ref/ntt.c 的结构重新实现一遍，用来验证"表"本身 ----------------
 * 循环写成和 ntt.c 字面一致，方便逐行对照。 */

/* 正变换：CT 蝶形（DIT），len 从 128 递减到 2，k 从 1 递增 */
static void my_ntt(int16_t r[256])
{
    unsigned int len, start, j, k;
    int16_t t, zeta;
    k = 1;
    for (len = 128; len >= 2; len >>= 1) {
        for (start = 0; start < 256; start = j + len) {
            zeta = zetas[k++];
            for (j = start; j < start + len; j++) {
                t = fqmul(zeta, r[j + len]);
                r[j + len] = r[j] - t;
                r[j] = r[j] + t;
            }
        }
    }
}

/* 逆变换：GS 蝶形（DIF），len 从 2 递增到 128，k 从 127 递减 */
static void my_invntt(int16_t r[256])
{
    unsigned int start, len, j, k;
    int16_t t, zeta;
    const int16_t f = 1441;      /* mont^2/128 */
    k = 127;
    for (len = 2; len <= 128; len <<= 1) {
        for (start = 0; start < 256; start = j + len) {
            zeta = zetas[k--];
            for (j = start; j < start + len; j++) {
                t = r[j];
                r[j] = barrett_reduce(t + r[j + len]);
                r[j + len] = r[j + len] - t;
                r[j + len] = fqmul(zeta, r[j + len]);
            }
        }
    }
    for (j = 0; j < 256; j++)
        r[j] = fqmul(r[j], f);
}

/* ---- 打印层序表 -------------------------------------------------------- */

static void print_table(int inverse)
{
    unsigned int len, start, j;
    int k, layer = 0, total = 0;

    printf("\n  %s   （%s 蝶形，7 层）\n",
           inverse ? "【逆变换 INTT】" : "【正变换 NTT】",
           inverse ? "GS / DIF" : "CT / DIT");
    printf("  %-5s %-6s %-7s %-14s %-10s %s\n",
           "层", "len", "组数", "zetas 下标", "取用顺序", "该层首个 zeta");
    printf("  ----------------------------------------------------------------------\n");

    k = inverse ? 127 : 1;

    if (!inverse) {
        for (len = 128; len >= 2; len >>= 1) {
            int kfirst = k, groups = 0;
            for (start = 0; start < 256; start = j + len) {
                k++;                       /* 本组消耗 zetas[k] */
                groups++;
                for (j = start; j < start + len; j++) { }
            }
            printf("  %-5d %-6u %-7d zetas[%d]→[%d]   %-10s zetas[%d] = %d\n",
                   ++layer, len, groups, kfirst, k - 1, "递增 ↑",
                   kfirst, zetas[kfirst]);
            total += groups;
        }
    } else {
        for (len = 2; len <= 128; len <<= 1) {
            int kfirst = k, klast = k, groups = 0;
            for (start = 0; start < 256; start = j + len) {
                klast = k;                 /* 本组消耗 zetas[k] */
                k--;
                groups++;
                for (j = start; j < start + len; j++) { }
            }
            printf("  %-5d %-6u %-7d zetas[%d]→[%d]   %-10s zetas[%d] = %d\n",
                   ++layer, len, groups, kfirst, klast, "递减 ↓",
                   kfirst, zetas[kfirst]);
            total += groups;
        }
    }

    printf("  ----------------------------------------------------------------------\n");
    printf("  合计 %d 个蝶形；zetas 下标消耗 %d 个\n", total, total);
}

/* ---- 主程序 ------------------------------------------------------------ */

int main(void)
{
    printf("=========================================================\n");
    printf(" ML-KEM NTT twiddle 层序表（从 ref/ntt.c 原样导出）\n");
    printf("=========================================================\n");
    printf("\n  q = %d,  n = 256\n", KYBER_Q);
    printf("  MONT = %d  （即 2^16 mod q = %d 的有符号表示）\n",
           MONT, MONT + KYBER_Q);
    printf("  zetas[0] = %d = MONT —— 它**不作为 twiddle 使用**，正逆都从下标 1 起\n",
           zetas[0]);
    printf("  末级缩放 f = 1441 = mont^2/128（只有逆变换有这一步）\n");
    printf("\n  ★ 关键结论：**不存在 zetas_inv 表**。正逆变换共用同一张 zetas[]，\n");
    printf("     正着走 k++（1 → 127），倒着走 k--（127 → 1）。\n");

    print_table(0);
    print_table(1);

    /* ---- 对拍：自己按表实现 vs 参考实现 ---------------------------------- */
    printf("\n=========================================================\n");
    printf(" 对拍：按上表实现的 ntt/invntt  vs  ref/ntt.c（200 组随机输入）\n");
    printf("=========================================================\n");

    srand(20260918);
    int trial, i, bad_f = 0, bad_i = 0, bad_red = 0;
    for (trial = 0; trial < 200; trial++) {
        int16_t a[256], b[256], c[256], orig[256];
        for (i = 0; i < 256; i++)
            orig[i] = (int16_t)(rand() % KYBER_Q);

        /* --- 正变换：裸 ntt()，不带 poly_reduce ------------------------ */
        memcpy(a, orig, sizeof(a));
        memcpy(b, orig, sizeof(b));
        my_ntt(a);
        ntt(b);                       /* 导出的是裸 ntt() */
        for (i = 0; i < 256; i++)
            if (a[i] != b[i]) { bad_f++; break; }

        /* --- 逆变换：同样在 ntt 之后的域上比 --------------------------- */
        memcpy(c, orig, sizeof(c));
        ntt(c);
        my_invntt(a);                 /* a 此时已是 ntt(orig) */
        invntt(c);
        for (i = 0; i < 256; i++)
            if (a[i] != c[i]) { bad_i++; break; }

        /* --- 附带确认：poly_ntt == ntt + poly_reduce ------------------- */
        memcpy(a, orig, sizeof(a));
        poly_ntt((poly *)a);
        memcpy(b, orig, sizeof(b));
        ntt(b);
        {
            poly tmp;
            memcpy(tmp.coeffs, b, sizeof(b));
            poly_reduce(&tmp);
            for (i = 0; i < 256; i++)
                if (a[i] != tmp.coeffs[i]) { bad_red++; break; }
        }
    }

    printf("\n    my_ntt    vs 裸 ntt()      : %s\n",
           bad_f ? "❌ 不一致" : "✅ 逐比特完全一致");
    printf("    my_invntt vs 裸 invntt()   : %s\n",
           bad_i ? "❌ 不一致" : "✅ 逐比特完全一致");
    printf("    poly_ntt == ntt + reduce   : %s\n",
           bad_red ? "❌ 不成立" : "✅ 成立");
    printf("\n    ⚠️ 注意 `poly_ntt()` 比裸 `ntt()` **多一步 `poly_reduce()`**，\n");
    printf("       两者输出**不相等**。RTL 对拍时想清楚该比哪一个 ——\n");
    printf("       作者的期望输出对应的是 `poly_ntt()`（带约减）。\n");

    /* ---- 往返缩放因子 ---------------------------------------------------- */
    int16_t p[256], rt[256];
    for (i = 0; i < 256; i++) p[i] = (int16_t)(rand() % KYBER_Q);
    memcpy(rt, p, sizeof(p));
    my_ntt(rt);
    my_invntt(rt);

    int32_t sf = -1; int ok = 1;
    for (i = 0; i < 256; i++) {
        int32_t in  = ((int32_t)p[i]  % KYBER_Q + KYBER_Q) % KYBER_Q;
        int32_t out = ((int32_t)rt[i] % KYBER_Q + KYBER_Q) % KYBER_Q;
        int32_t t, s = -1;
        if (in == 0) continue;                 /* 0 无信息，跳过 */
        for (t = 0; t < KYBER_Q; t++)
            if ((int32_t)(((int64_t)in * t) % KYBER_Q) == out) { s = t; break; }
        if (sf < 0) sf = s;
        else if (sf != s) { ok = 0; break; }
    }
    printf("    往返 invntt(ntt(f)) = f * %d (mod q)   : %s\n",
           sf, ok ? "✅ 全系数同一因子（纯缩放，无畸变）"
                  : "❌ 因子不唯一");
    printf("    （%d = 2^16 mod q = MONT，符合预期）\n", sf);

    printf("\n=========================================================\n");
    return (bad_f || bad_i || !ok) ? 1 : 0;
}
