#include "mt_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
MtHle mt_arm32_unicode_hle(const char *name);
void mt_arm32_unicode_reset(Mt *m);
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"Unicode check failed at line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static uint32_t invoke(Mt *m,const char *name,int count,const uint32_t *args) {
    X86 *c=&m->main->cpu; c->r[ESP]=m->main->stack_top-512;
    for (int i=0;i<count;i++) wr32(c,c->r[ESP]+4+4*(uint32_t)i,args[i]);
    MtHle handler=mt_arm32_unicode_hle(name); CHECK(handler!=NULL); handler(m,c); return c->r[EAX];
}
#define CALL(name,...) invoke(m,name,sizeof((uint32_t[]){__VA_ARGS__})/sizeof(uint32_t),(uint32_t[]){__VA_ARGS__})
int main(void) {
    char error[512]={0}; Mt *m=mt_create_arm32(error,sizeof error); CHECK(m!=NULL);
    jmp_buf fault; m->fault=m->main->cpu.fault=&fault;
    if (setjmp(fault)) { fprintf(stderr,"Unicode fault: %s%s\n",m->err,m->main->cpu.err); return 1; }
    const char *input="Cafe\xcc\x81 \xf0\x9f\x98\x80 X";
    uint32_t text=mt_cf_string(m,input,strlen(input));
    CHECK(CALL("_CFStringGetLength",text)==10);
    uint32_t utf16=mt_static(m,32); CALL("_CFStringGetCharacters",text,0,10,utf16);
    CHECK(rd16(&m->main->cpu,utf16+6)=='e'); CHECK(rd16(&m->main->cpu,utf16+8)==0x301);
    CHECK(rd16(&m->main->cpu,utf16+12)==0xd83d); CHECK(rd16(&m->main->cpu,utf16+14)==0xde00);
    uint32_t iterator=mt_static(m,128);
    CALL("__ZN3icu10NormalizerC1EPKti18UNormalizationMode",iterator,utf16,10,4);
    uint32_t expected[]={'C','a','f',0xe9,' ',0x1f600,' ','X'};
    uint32_t indexes[]={1,2,3,5,6,8,9,10};
    for (unsigned i=0;i<8;i++) {
        CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)==expected[i]);
        CHECK(CALL("__ZNK3icu10Normalizer8getIndexEv",iterator)==indexes[i]);
    }
    CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)==0xffff);
    CALL("__ZN3icu10NormalizerD1Ev",iterator);
    wr16(&m->main->cpu,utf16,0xfb03);
    CALL("__ZN3icu10NormalizerC1EPKti18UNormalizationMode",iterator,utf16,1,3);
    CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)=='f'); CHECK(CALL("__ZNK3icu10Normalizer8getIndexEv",iterator)==0);
    CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)=='f'); CHECK(CALL("__ZNK3icu10Normalizer8getIndexEv",iterator)==0);
    CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)=='i'); CHECK(CALL("__ZNK3icu10Normalizer8getIndexEv",iterator)==1);
    CHECK(CALL("__ZN3icu10Normalizer4nextEv",iterator)==0xffff); CALL("__ZN3icu10NormalizerD1Ev",iterator);
    uint32_t emoji=mt_cf_string(m,"\xf0\x9f\x98\x80",4), locale=mt_cf_string(m,"en",2);
    CHECK(CALL("_CFStringGetLength",emoji)==2); CHECK(CALL("_CEMStringContainsEmoji",emoji)!=0);
    CHECK(CALL("_CEMStringContainsEmoji",mt_cf_string(m,"hello",5))==0);
    uint32_t data=CALL("_CEMCreateEmojiLocaleData",locale);
    uint32_t token=CALL("_CEMEmojiTokenCreateWithString",emoji,data);
    uint32_t token_text=CALL("_CEMEmojiTokenGetString",token);
    CHECK(CALL("_CFStringGetLength",token_text)==2);
    uint32_t name=CALL("_CEMEmojiTokenCopyName",token,1);
    CHECK(CALL("_CFStringGetLength",name)>0);
    uint32_t copy=CALL("_CFStringCreateMutableCopy",0,0,emoji), prefix=mt_cf_string(m,"caf\xc3\xa9",5);
    CALL("_CFStringInsert",copy,0,prefix); CHECK(CALL("_CFStringGetLength",copy)==6);
    uint32_t replacement=mt_cf_string(m,"X",1); CALL("_CFStringReplace",copy,4,2,replacement);
    uint32_t output=mt_static(m,64); CHECK(CALL("_CFStringGetCString",copy,output,64,0x08000100));
    CHECK(!strcmp(mt_str(m,output),"caf\xc3\xa9X"));
    // Bytes are not character indexes: the accent encodes as two UTF-8 bytes.
    CHECK(CALL("_CFStringGetLength",prefix)==4);
    CHECK(CALL("_CFStringGetCStringPtr",prefix,0)==0); // MacRoman pointer cannot alias UTF-8 backing
    CHECK(CALL("_CFStringGetCString",prefix,output,64,0));
    CHECK(rd8(&m->main->cpu,output+3)==0x8e); // MacRoman e-acute
    CALL("_CFRelease",copy); CALL("_CFRelease",prefix); CALL("_CFRelease",name);
    CALL("_CFRelease",token_text); CALL("_CFRelease",token); CALL("_CFRelease",data);
    mt_arm32_unicode_reset(m); mt_destroy(m);
    printf("%u Unicode/normalization/emoji checks passed\n",checks);
}
