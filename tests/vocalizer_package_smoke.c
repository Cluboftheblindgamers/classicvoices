#include "vxstream.h"
#include <stdio.h>
#include <string.h>
void cv_set_native_dir(const char *directory);
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr,"usage: vocalizer_package_smoke voices native voice-key...\n"); return 2; }
    cv_set_native_dir(argv[2]);
    for (int i=3;i<argc;i++) {
        double open=0,first=0,total=0,audio=0;
        int rc=vxs_benchmark(argv[1],argv[1],argv[i],"Hello. This is a voice test.",100,&open,&first,&total,&audio);
        if (rc || audio<=0 || first<0) {fprintf(stderr,"FAIL %s rc=%d audio=%.1f\n",argv[i],rc,audio);return 1;}
        printf("PASS %s: audio %.0fms, first %.0fms, total %.0fms\n",argv[i],audio,first,total);fflush(stdout);
    }
    return 0;
}
