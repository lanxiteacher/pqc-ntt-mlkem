/* ===========================================================================
 * randombytes_stub.c —— randombytes() 的"哨兵"桩
 *
 * 背景：KAT 校验器全程只走确定性接口
 *           crypto_kem_keypair_derand(pk, sk, d||z)
 *           crypto_kem_enc_derand(ct, ss, pk, msg)
 *       这两个都不碰系统随机数。kem.o 里虽然还留着对 randombytes 的引用
 *       （非 derand 版本在用），但那条路径根本不会被走到。
 *
 * 为什么不直接给个返回 0 的空实现：那样一旦哪天误用了 crypto_kem_keypair，
 *       程序会拿着一堆假随机数算出"看似正常"的结果，是最难查的一类 bug。
 *       这里让它在被调用时立刻炸掉，把错误暴露在第一现场。
 *
 * 注：上游 kyber_ref/randombytes.c 未能下载成功（拿到的是 GitHub 限流页），
 *     故以此桩替代。它不参与任何密码学运算，不影响 KAT 校验的正确性。
 * =========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include "randombytes.h"

void randombytes(uint8_t *out, size_t outlen)
{
    (void)out;
    (void)outlen;
    fprintf(stderr,
        "\nFATAL: randombytes() 被调用了。\n"
        "       KAT 校验器不应依赖系统随机数 —— 请确认调用的是\n"
        "       crypto_kem_keypair_derand / crypto_kem_enc_derand，\n"
        "       而不是不带 _derand 的版本。\n\n");
    exit(99);
}
