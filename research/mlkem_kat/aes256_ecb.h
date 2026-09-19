/* AES-256 单块加密，签名与 OpenSSL 版 AES256_ECB 兼容。
   供 NIST CTR_DRBG (rng.c) 使用，使其摆脱 OpenSSL 依赖。 */
#ifndef AES256_ECB_H
#define AES256_ECB_H

void AES256_ECB(unsigned char *key, unsigned char *ctr, unsigned char *buffer);

#endif /* AES256_ECB_H */
