/* B boundary oracle: strict signed decimal input, original poly_ntt.
 * Unlike ntt_once_tool, do not mask to 12 bits before calculating.
 */
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <errno.h>
#include "../research/kyber_ref/poly.h"
int main(int argc, char **argv) {
    if(argc!=3) return 2;
    FILE *f=fopen(argv[1],"rb"); if(!f) return 2;
    poly p; char line[128];
    for(int i=0;i<256;i++) {
        if(!fgets(line,sizeof line,f)) { fclose(f);return 3; }
        errno=0;char *end;long x=strtol(line,&end,10);
        if(end==line || errno || x < -3329 || x > 3329) { fclose(f);return 3; }
        while(isspace((unsigned char)*end)) end++;
        if(*end) { fclose(f);return 3; }
        p.coeffs[i]=(int16_t)x;
    }
    if(fgets(line,sizeof line,f)) { fclose(f);return 3; }
    fclose(f);poly_ntt(&p);
    f=fopen(argv[2],"wb");if(!f) return 2;
    for(int i=0;i<256;i++) {
        int x=p.coeffs[i]%3329;if(x<0)x+=3329;
        fprintf(f,"%03x\n",x);
    }
    return fclose(f)!=0;
}
