#include "mtengine.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { size_t count, cancel_at; float peak; } Audio;
static int capture(void *context,const float *pcm,size_t count) {
    Audio *a=context;
    for (size_t i=0;i<count;i++) {
        if (!isfinite(pcm[i])) { fprintf(stderr,"nonfinite PCM\n"); exit(1); }
        if (fabsf(pcm[i])>a->peak) a->peak=fabsf(pcm[i]);
    }
    a->count+=count;
    return a->cancel_at && a->count>=a->cancel_at;
}
static MtEngine *open_engine(const char *root) {
    char error[512]; MtEngine *e=mte_open(root,error,sizeof error);
    if (!e) { fprintf(stderr,"open: %s\n",error); exit(1); }
    mte_set_voice_options(e,180,100,1,-1,0); return e;
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    for (int cycle=0;cycle<2;cycle++) {
        MtEngine *e=open_engine(argv[1]); Audio interrupted={.cancel_at=11025};
        int rc=mte_speak(e,"Alex","This is a longer paragraph for interruption testing. There should be speech left when cancellation arrives. Continue reading this long sentence until the caller interrupts it.",100,100,-1,capture,&interrupted);
        if (!interrupted.count || interrupted.count>12000) { fprintf(stderr,"bad cancellation boundary %zu\n",interrupted.count); return 1; }
        if (rc) {
            if (!mte_broken(e)) { fprintf(stderr,"cancel failed: %s\n",mte_error(e)); return 1; }
            mte_close(e); e=open_engine(argv[1]);
        }
        Audio resumed={0};
        if (mte_speak(e,"Alex","Caf\xc3\xa9. Hello again. One minute nine seconds.",100,100,-1,capture,&resumed) || !resumed.count || resumed.peak<.001f) {
            fprintf(stderr,"resume failed: %s\n",mte_error(e)); return 1;
        }
        Audio normal={0},spelled={0},after={0};
        if (mte_speak(e,"Alex","cat",100,100,-1,capture,&normal) ||
            mte_speak(e,"Alex","[[char LTRL]]cat",100,100,-1,capture,&spelled) ||
            mte_speak(e,"Alex","cat",100,100,-1,capture,&after)) { fprintf(stderr,"command reset failed: %s\n",mte_error(e)); return 1; }
        size_t delta=normal.count>after.count ? normal.count-after.count : after.count-normal.count;
        if (spelled.count<=normal.count || delta>2205) { fprintf(stderr,"spelling mode persisted: normal=%zu spelled=%zu after=%zu\n",normal.count,spelled.count,after.count); return 1; }
        printf("PASS character-mode reset: normal=%zu spelled=%zu after=%zu\n",normal.count,spelled.count,after.count);
        mte_close(e);
        printf("PASS integrated cycle %d: cancelled %zu frames, resumed %zu frames\n",cycle,interrupted.count,resumed.count); fflush(stdout);
    }
}
