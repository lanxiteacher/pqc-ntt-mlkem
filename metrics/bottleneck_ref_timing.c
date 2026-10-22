/* ===========================================================================
 * bottleneck_ref_timing.c —— 给「软件参考实现」那一段计时。
 *
 * 它干什么
 *     量的是 **poly_ntt() 的语义**（`ntt()` + `poly_reduce()`），不是裸 `ntt()`。
 *     后者不约减，反复调用会让系数越界；硬件那条通路（`#NTT`）对应的是 poly_ntt。
 *
 *     每一轮都先把一个**合法输入**（系数已在 [0, q)）拷回工作数组，再算 ——
 *     否则第二轮起输入就是上一轮的输出，既不是同一个任务，也不是合法输入。
 *
 *     输入准备（512 字节 memcpy）与计算**分开计时**，好让调用方把两笔账分开记。
 *
 * 输出（一行）
 *     <n> <prep_secs> <total_secs> <checksum> <bad>
 *       prep_secs  —— n 次「只做输入准备」的总秒数
 *       total_secs —— n 次「准备 + poly_ntt()」的总秒数
 *       净计算     = total_secs - prep_secs（由调用方算）
 *       checksum   —— 最后一次输出的 FNV-1a 64 位摘要，用来确认跑的是同一份结果
 *       bad        —— 最后一次输出里落在中心代表区间 [-(q-1)/2, (q-1)/2] 之外的
 *                     系数个数（barrett_reduce 给的是中心代表，不是 [0,q)）；必须为 0
 *
 * 为什么不是精确到单次的计时
 *     `clock_gettime(CLOCK_MONOTONIC)` 在 Windows 上的粒度是百纳秒到微秒级，
 *     而单次 poly_ntt() 只有几个微秒 —— 只跑一次，读数的相对误差能到几十个百分点。
 *     所以跑 n 次量总时间再除。n 由调用方给（默认 200000）。
 *
 * ⚠️ 这个数**随机器变**：CPU、编译器、优化级、电源模式都能动它。
 *     调用方（bottleneck.py）负责把机器与编译命令写进产物。
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
#include <string.h>
#include <time.h>

#include "params.h"
#include "ntt.h"
#include "reduce.h"

static void poly_ntt_ref(int16_t r[KYBER_N])
{
    ntt(r);
    for (int i = 0; i < KYBER_N; i++)
        r[i] = barrett_reduce(r[i]);
}

static uint64_t fnv1a(const int16_t r[KYBER_N])
{
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < KYBER_N; i++) {
        h ^= (uint16_t)r[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static double now_secs(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) {
        fprintf(stderr, "!! clock_gettime 用不了 —— 本机没有单调时钟。\n");
        exit(1);
    }
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    long n = (argc > 1) ? atol(argv[1]) : 200000;
    if (n <= 0) {
        fprintf(stderr, "!! 次数要正数，收到 %s\n", argv[1]);
        return 1;
    }

    /* 合法输入：系数已在 [0, q)。别填常量 —— 全 0 可能被优化整段折掉。 */
    int16_t in[KYBER_N], work[KYBER_N];
    for (int i = 0; i < KYBER_N; i++)
        in[i] = (int16_t)((i * 7 + 1) % KYBER_Q);

    /* 预热：页错、分支预测、指令缓存都不计进循环。 */
    for (int i = 0; i < 1000; i++) {
        memcpy(work, in, sizeof work);
        poly_ntt_ref(work);
    }

    /* sink 防止「只保留最后一次拷贝」的优化把前面 n-1 次消掉。 */
    volatile int64_t sink = 0;

    double t0 = now_secs();
    for (long k = 0; k < n; k++) {
        memcpy(work, in, sizeof work);
        sink += work[0];
    }
    double t1 = now_secs();

    for (long k = 0; k < n; k++) {
        memcpy(work, in, sizeof work);
        poly_ntt_ref(work);
        sink += work[0];
    }
    double t2 = now_secs();

    const int16_t half = (KYBER_Q - 1) / 2;
    int bad = 0;
    for (int i = 0; i < KYBER_N; i++)
        if (work[i] < -half || work[i] > half)
            bad++;

    printf("%ld %.9f %.9f %llu %d\n", n, t1 - t0, t2 - t1,
           (unsigned long long)fnv1a(work), bad);
    (void)sink;
    return 0;
}
