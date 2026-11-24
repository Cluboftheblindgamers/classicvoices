#include "mtengine.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int alex_probe_main(int argc,char **argv);
typedef struct { size_t count; uint64_t hash; float peak; } Audio;
static int capture(void *ctx,const float *pcm,size_t n) {
    Audio *a=ctx;
    for (size_t i=0;i<n;i++) {
        float value=pcm[i]; if (!isfinite(value)) { fprintf(stderr,"non-finite control PCM\n"); exit(1); }
        int32_t sample=(int32_t)lrintf(value*32767);
        a->hash=(a->hash^(uint32_t)sample)*UINT64_C(1099511628211);
        if (fabsf(value)>a->peak) a->peak=fabsf(value);
    }
    a->count+=n; return 0;
}
static Audio control(const char *root) {
    char error[512]={0}; MtEngine *e=mte_open(root,error,sizeof error);
    if (!e) { fprintf(stderr,"x86 control open: %s\n",error); exit(1); }
    Audio a={.hash=UINT64_C(14695981039346656037)};
    if (mte_speak(e,"Fred","Hello. This is the existing Mac voice.",100,100,-1,capture,&a)) {
        fprintf(stderr,"x86 control speak: %s\n",mte_error(e)); exit(1);
    }
    mte_close(e);
    if (!a.count || a.peak<.001) { fprintf(stderr,"silent x86 control\n"); exit(1); }
    fprintf(stderr,"x86 control: %zu samples, hash=%llx\n",a.count,(unsigned long long)a.hash);
    return a;
}
int main(int argc,char **argv) {
    if (argc!=5) return 2;
    Audio before=control(argv[1]);
    for (int run=0;run<2;run++) {
        char *args[]={"alex-probe",argv[2],argv[3],argv[4],NULL};
        if (alex_probe_main(4,args)) return 1;
        Audio after=control(argv[1]);
        if (after.count!=before.count || after.hash!=before.hash) { fprintf(stderr,"x86 control changed after ARM engine\n"); return 1; }
    }
    puts("PASS x86 -> ARM -> x86 switching twice, identical control audio");
}
