/* Deterministic ML-KEM-768 transcript; input is public test-vector material. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "kem.h"
#include "poly.h"

static FILE *trace_file;
static const char *phase;
static int call_id;
static int16_t saved[256];

void trace_before(const poly *p) { memcpy(saved, p->coeffs, sizeof(saved)); }
void trace_after(const poly *p) {
    int i;
    fprintf(trace_file, "{\"id\":%d,\"phase\":\"%s\",\"input_signed\":[", call_id++, phase);
    for(i=0;i<256;i++) fprintf(trace_file, "%s%d", i ? "," : "", saved[i]);
    fprintf(trace_file, "],\"output_signed\":[");
    for(i=0;i<256;i++) fprintf(trace_file, "%s%d", i ? "," : "", p->coeffs[i]);
    fprintf(trace_file, "]}\n");
}

static void read_exact(FILE *f, void *p, size_t n) {
    if(fread(p,1,n,f)!=n) { fprintf(stderr,"short fixture\n"); exit(2); }
}
int main(int argc, char **argv) {
    uint8_t coins[64], msg[32], pk[CRYPTO_PUBLICKEYBYTES], sk[CRYPTO_SECRETKEYBYTES];
    uint8_t ct[CRYPTO_CIPHERTEXTBYTES], ss[32], dec[32];
    uint8_t epk[CRYPTO_PUBLICKEYBYTES], esk[CRYPTO_SECRETKEYBYTES];
    uint8_t ect[CRYPTO_CIPHERTEXTBYTES], ess[32];
    FILE *f, *out;
    if(argc!=4) return 2;
    f=fopen(argv[1],"rb"); trace_file=fopen(argv[2],"wb"); out=fopen(argv[3],"wb");
    if(!f || !trace_file || !out) return 2;
    read_exact(f,coins,sizeof(coins)); read_exact(f,msg,sizeof(msg));
    read_exact(f,epk,sizeof(epk)); read_exact(f,esk,sizeof(esk));
    read_exact(f,ect,sizeof(ect)); read_exact(f,ess,sizeof(ess));
    if(fgetc(f)!=EOF) return 2;
    fclose(f);
    phase="keygen";
    if(crypto_kem_keypair_derand(pk,sk,coins)) return 3;
    phase="encaps";
    if(crypto_kem_enc_derand(ct,ss,pk,msg)) return 3;
    phase="decaps";
    if(crypto_kem_dec(dec,ct,sk)) return 3;
    if(memcmp(pk,epk,sizeof(pk)) || memcmp(sk,esk,sizeof(sk)) ||
       memcmp(ct,ect,sizeof(ct)) || memcmp(ss,ess,32) || memcmp(dec,ess,32)) {
        fprintf(stderr,"KAT mismatch\n"); return 4;
    }
    fwrite(pk,1,sizeof(pk),out); fwrite(sk,1,sizeof(sk),out);
    fwrite(ct,1,sizeof(ct),out); fwrite(ss,1,32,out); fwrite(dec,1,32,out);
    if(fclose(out) || fclose(trace_file)) return 2;
    puts("PASS: keygen pk/sk, encaps ct/ss, decaps ss match public compatible KAT");
    return 0;
}
