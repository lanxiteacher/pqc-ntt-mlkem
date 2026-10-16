/* ===========================================================================
 * bottleneck_ref_timing.c —— 给「软件参考实现」那一段计时。
 *
 * 它干什么
 *     把 `research/kyber_ref/` 的参考 ntt() 反复调 n 次，量总耗时，打印一行：
 *
 *         <n> <秒数>
 *
 *     单次耗时 = 秒数 ÷ n。本文件不做除法、不做四舍五入 —— 那是
 *     metrics/bottleneck.py 的事，这里只吐两个数，好核对。
 *
 * 为什么要有它
 *     「瓶颈归因表」要求把一趟 NTT 事务的耗时拆成三段，其中一段是
 *     「同一件事在 PC 上用软件参考实现要多久」。这个数只能真编译真跑。
 *
 * 为什么不是精确到单次的计时
 *     `clock_gettime(CLOCK_MONOTONIC)` 在 Windows 上的粒度是百纳秒到微秒级，
 *     而单次 ntt() 只有几个微秒 —— 只跑一次，读数的相对误差能到几十个百分点。
 *     所以跑 n 次量总时间再除。n 由调用方给（默认 200000，本机约 0.67 s）。
 *
 * ⚠️ 这个数**随机器变**：CPU、编译器、优化级都能动它。
 *     所以报告里引它必须连机器与编译命令一起写。本文件**不打印**这些 ——
 *     它们是调用方（bottleneck.py）的上下文，写在这里会漂移。
 *
 * 编译（由 bottleneck.py 负责，这里写明是为了能手跑复核）
 *     gcc -O2 -I research/kyber_ref \
 *         metrics/bottleneck_ref_timing.c \
 *         research/kyber_ref/ntt.c research/kyber_ref/reduce.c \
 *         -o <输出>
 * =========================================================================== */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "params.h"
#include "ntt.h"

int main(int argc, char **argv)
{
    long n = (argc > 1) ? atol(argv[1]) : 200000;
    if (n <= 0) {
        fprintf(stderr, "!! 次数要正数，收到 %s\n", argv[1]);
        return 1;
    }

    /* 输入随便填，但**别填常量** —— 全 0 的向量有些优化会把它整段折掉。
     * 模 q 的伪随机样即可（内容不影响耗时，只影响可不可信）。 */
    int16_t poly[KYBER_N];
    for (int i = 0; i < KYBER_N; i++)
        poly[i] = (int16_t)((i * 7 + 1) % KYBER_Q);

    /* 预热：让第一次调用的页错、分支预测、指令缓存都不计进循环。 */
    for (int i = 0; i < 1000; i++)
        ntt(poly);

    struct timespec t0, t1;
    if (clock_gettime(CLOCK_MONOTONIC, &t0) != 0) {
        fprintf(stderr, "!! clock_gettime 用不了 —— 本机没有单调时钟。\n");
        return 1;
    }
    for (long k = 0; k < n; k++)
        ntt(poly);
    if (clock_gettime(CLOCK_MONOTONIC, &t1) != 0) {
        fprintf(stderr, "!! clock_gettime 用不了。\n");
        return 1;
    }

    double secs = (double)(t1.tv_sec - t0.tv_sec)
                + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("%ld %.9f\n", n, secs);
    return 0;
}
