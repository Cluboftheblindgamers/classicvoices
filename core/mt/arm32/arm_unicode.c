#ifdef CV_MT_ARM32_EXPERIMENT
// Native Unicode services behind 32-bit guest CF objects. Guest pointers
// never escape to CoreFoundation/ICU. No C++ ICU object layout is assumed.
#include "../mt_internal.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// Stable ICU C interfaces, provided by Apple's libicucore on both platforms.
typedef struct UNormalizer2 UNormalizer2;
extern const UNormalizer2 *unorm2_getNFCInstance(int32_t *);
extern const UNormalizer2 *unorm2_getNFDInstance(int32_t *);
extern const UNormalizer2 *unorm2_getNFKCInstance(int32_t *);
extern const UNormalizer2 *unorm2_getNFKDInstance(int32_t *);
extern int8_t unorm2_hasBoundaryBefore(const UNormalizer2 *, int32_t);
extern int32_t unorm2_normalize(const UNormalizer2 *, const uint16_t *, int32_t, uint16_t *, int32_t, int32_t *);
extern int32_t u_charName(int32_t, int, char *, int32_t, int32_t *);
extern int8_t u_isgraph(int32_t);

enum { O_FLAGS=4, O_CSTR=8, O_LEN=12, O_MAGIC=16, O_RC=24 };
#define CF_MAGIC 0x4d544346u
#define MAX_TEXT 1000000u
static uint32_t A(X86 *c, int i) { return x86_arg(c, i); }

typedef struct Object { Mt *owner; uint32_t guest; CFTypeRef value; struct Object *next; } Object;
static Object *objects;
static pthread_mutex_t object_mutex = PTHREAD_MUTEX_INITIALIZER;
static void reset_iterators(Mt *m);

static Object *find(Mt *m, uint32_t guest) {
    pthread_mutex_lock(&object_mutex);
    Object *o = objects;
    while (o && (o->owner != m || o->guest != guest)) o = o->next;
    pthread_mutex_unlock(&object_mutex);
    return o;
}
static Object *add(Mt *m, X86 *c, uint32_t guest, CFTypeRef value) {
    Object *o = calloc(1, sizeof *o);
    if (!o || !value) { free(o); x86_fault(c, "cannot create native Unicode object"); }
    o->owner = m; o->guest = guest; o->value = value;
    pthread_mutex_lock(&object_mutex);
    for (Object *existing=objects;existing;existing=existing->next) if (existing->owner==m && existing->guest==guest) {
        pthread_mutex_unlock(&object_mutex); CFRelease(value); free(o); return existing;
    }
    o->next = objects; objects = o; pthread_mutex_unlock(&object_mutex);
    return o;
}
static void forget(Mt *m, uint32_t guest) {
    pthread_mutex_lock(&object_mutex);
    Object **p = &objects;
    while (*p && ((*p)->owner != m || (*p)->guest != guest)) p = &(*p)->next;
    Object *o = *p;
    if (o) *p = o->next;
    pthread_mutex_unlock(&object_mutex);
    if (o) { CFRelease(o->value); free(o); }
}
void mt_arm32_unicode_reset(Mt *m) {
    reset_iterators(m);
    for (;;) {
        pthread_mutex_lock(&object_mutex);
        Object *o = objects;
        while (o && o->owner != m) o = o->next;
        uint32_t guest = o ? o->guest : 0;
        pthread_mutex_unlock(&object_mutex);
        if (!guest) break;
        forget(m, guest);
    }
}
static CFMutableStringRef string(Mt *m, X86 *c, uint32_t guest) {
    if (!guest) x86_fault(c, "NULL Unicode string");
    Object *o = find(m, guest);
    if (!o) {
        uint32_t length = rd32(c, guest + O_LEN), data = rd32(c, guest + O_CSTR);
        if (length > MAX_TEXT) x86_fault(c, "Unicode string too large");
        int is_ours = rd32(c, guest + O_MAGIC) == CF_MAGIC;
        int utf16 = !is_ours && (rd32(c, guest + O_FLAGS) & 0x10);
        mt_check(m, c, data, length * (utf16 ? 2 : 1));
        CFStringRef value = utf16
            ? CFStringCreateWithCharacters(NULL, (const UniChar *)G(m, data), length)
            : CFStringCreateWithBytes(NULL, G(m, data), length, kCFStringEncodingUTF8, false);
        if (!value) x86_fault(c, "invalid guest UTF-8 string");
        CFMutableStringRef mutable = CFStringCreateMutableCopy(NULL, 0, value);
        CFRelease(value);
        o = add(m, c, guest, mutable);
    }
    if (CFGetTypeID(o->value) != CFStringGetTypeID()) x86_fault(c, "Unicode call on non-string object");
    return (CFMutableStringRef)o->value;
}
static void sync_bytes(Mt *m, X86 *c, uint32_t guest, CFStringRef value) {
    if (rd32(c, guest + O_MAGIC) != CF_MAGIC) x86_fault(c, "attempt to mutate a constant CFString");
    CFIndex length = CFStringGetLength(value);
    if (length > MAX_TEXT) x86_fault(c, "Unicode string too large");
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    uint32_t data = mt_malloc(m, (uint32_t)capacity);
    if (!CFStringGetCString(value, (char *)G(m, data), capacity, kCFStringEncodingUTF8)) {
        mt_free(m, data); x86_fault(c, "cannot encode guest UTF-8 string");
    }
    uint32_t old = rd32(c, guest + O_CSTR);
    wr32(c, guest + O_CSTR, data); wr32(c, guest + O_LEN, (uint32_t)strlen((char *)G(m, data)));
    mt_free(m, old);
}
static uint32_t wrap_string(Mt *m, X86 *c, CFStringRef value) {
    if (!value) return 0;
    CFMutableStringRef mutable = CFStringCreateMutableCopy(NULL, 0, value);
    uint32_t guest = mt_cf_string(m, "", 0);
    add(m, c, guest, mutable); sync_bytes(m, c, guest, mutable);
    return guest;
}
static void check_range(X86 *c, CFStringRef text, uint32_t location, uint32_t length) {
    if ((uint64_t)location + length > (uint64_t)CFStringGetLength(text)) x86_fault(c, "CFString range outside UTF-16 length");
}
static void h_release(Mt *m, X86 *c) {
    uint32_t guest = A(c, 0);
    mt_lookup_hle("_CFRelease")(m, c);
    if (guest && rd32(c, guest + O_MAGIC) == CF_MAGIC && !rd32(c, guest + O_RC)) forget(m, guest);
}
static void h_length(Mt *m, X86 *c) { c->r[EAX] = (uint32_t)CFStringGetLength(string(m, c, A(c, 0))); }
static void h_character(Mt *m, X86 *c) {
    CFStringRef text = string(m, c, A(c, 0)); uint32_t index = A(c, 1);
    check_range(c, text, index, 1); c->r[EAX] = CFStringGetCharacterAtIndex(text, index);
}
static void h_characters(Mt *m, X86 *c) {
    CFStringRef text = string(m, c, A(c, 0)); uint32_t start = A(c, 1), length = A(c, 2), out = A(c, 3);
    check_range(c, text, start, length); mt_check(m, c, out, length * 2);
    CFStringGetCharacters(text, CFRangeMake(start, length), (UniChar *)G(m, out));
}
static void h_character_pointer(Mt *m, X86 *c) { (void)m; c->r[EAX] = 0; } // byte-backed guest strings
static void h_create_characters(Mt *m, X86 *c) {
    uint32_t data = A(c, 1), length = A(c, 2);
    if (length > MAX_TEXT) x86_fault(c, "CFString input too large");
    mt_check(m, c, data, length * 2);
    CFStringRef value = CFStringCreateWithCharacters(NULL, (const UniChar *)G(m, data), length);
    c->r[EAX] = wrap_string(m, c, value); if (value) CFRelease(value);
}
static void h_create_cstring(Mt *m, X86 *c) {
    const char *data = mt_str(m, A(c, 1));
    CFStringRef value = CFStringCreateWithCString(NULL, data, A(c, 2));
    c->r[EAX] = wrap_string(m, c, value); if (value) CFRelease(value);
}
static void h_create_pascal(Mt *m, X86 *c) {
    uint32_t data = A(c, 1), length = rd8(c, data); mt_check(m, c, data + 1, length);
    CFStringRef value = CFStringCreateWithBytes(NULL, G(m, data + 1), length, A(c, 2), false);
    c->r[EAX] = wrap_string(m, c, value); if (value) CFRelease(value);
}
static void h_create_mutable(Mt *m, X86 *c) { c->r[EAX] = mt_cf_string(m, "", 0); }
static void h_copy(Mt *m, X86 *c) { c->r[EAX] = wrap_string(m, c, string(m, c, A(c, 1))); }
static void h_mutable_copy(Mt *m, X86 *c) { c->r[EAX] = wrap_string(m, c, string(m, c, A(c, 2))); }
static void h_get_cstring(Mt *m, X86 *c) {
    uint32_t out = A(c, 1), capacity = A(c, 2); mt_check(m, c, out, capacity);
    c->r[EAX] = CFStringGetCString(string(m, c, A(c, 0)), (char *)G(m, out), capacity, A(c, 3));
}
static void h_get_pointer(Mt *m, X86 *c) {
    uint32_t guest = A(c, 0), encoding = A(c, 1); CFStringRef text = string(m, c, guest);
    int ascii = true;
    if (encoding != kCFStringEncodingUTF8 && encoding != kCFStringEncodingASCII && encoding != kCFStringEncodingMacRoman) { c->r[EAX] = 0; return; }
    if (encoding != kCFStringEncodingUTF8) for (CFIndex i = 0; i < CFStringGetLength(text); i++)
        if (CFStringGetCharacterAtIndex(text, i) >= 128) { ascii = false; break; }
    if (encoding != kCFStringEncodingUTF8 && !ascii) { c->r[EAX] = 0; return; }
    if (rd32(c, guest + O_MAGIC) != CF_MAGIC && (rd32(c, guest + O_FLAGS) & 0x10)) { c->r[EAX] = 0; return; }
    c->r[EAX] = rd32(c, guest + O_CSTR);
}
static void h_max_encoding(Mt *m, X86 *c) { (void)m; c->r[EAX] = (uint32_t)CFStringGetMaximumSizeForEncoding((int32_t)A(c, 0), A(c, 1)); }
static void h_max_path(Mt *m, X86 *c) { c->r[EAX] = (uint32_t)CFStringGetMaximumSizeOfFileSystemRepresentation(string(m, c, A(c, 0))); }
static void h_get_path(Mt *m, X86 *c) {
    uint32_t out = A(c, 1), capacity = A(c, 2); mt_check(m, c, out, capacity);
    c->r[EAX] = CFStringGetFileSystemRepresentation(string(m, c, A(c, 0)), (char *)G(m, out), capacity);
}
static void h_compare(Mt *m, X86 *c) { c->r[EAX] = (uint32_t)CFStringCompare(string(m,c,A(c,0)), string(m,c,A(c,1)), A(c,2)); }
static void h_append(Mt *m, X86 *c) {
    uint32_t guest = A(c, 0); CFMutableStringRef dest = string(m,c,guest);
    CFStringAppend(dest, string(m,c,A(c,1))); sync_bytes(m,c,guest,dest);
}
static void h_append_characters(Mt *m, X86 *c) {
    uint32_t guest = A(c,0), data = A(c,1), length = A(c,2); if (length > MAX_TEXT) x86_fault(c,"append too large");
    mt_check(m,c,data,length*2); CFMutableStringRef dest=string(m,c,guest);
    CFStringAppendCharacters(dest,(const UniChar *)G(m,data),length); sync_bytes(m,c,guest,dest);
}
static void h_insert(Mt *m, X86 *c) {
    uint32_t guest=A(c,0), index=A(c,1); CFMutableStringRef dest=string(m,c,guest); check_range(c,dest,index,0);
    CFStringInsert(dest,index,string(m,c,A(c,2))); sync_bytes(m,c,guest,dest);
}
static void h_replace(Mt *m, X86 *c) {
    uint32_t guest=A(c,0), index=A(c,1), length=A(c,2); CFMutableStringRef dest=string(m,c,guest); check_range(c,dest,index,length);
    CFStringReplace(dest,CFRangeMake(index,length),string(m,c,A(c,3))); sync_bytes(m,c,guest,dest);
}
static void h_external(Mt *m, X86 *c) {
    CFDataRef data=CFStringCreateExternalRepresentation(NULL,string(m,c,A(c,1)),A(c,2),(UInt8)A(c,3));
    if (!data) { c->r[EAX]=0; return; }
    CFIndex length=CFDataGetLength(data); if (length>MAX_TEXT*4) { CFRelease(data); x86_fault(c,"encoded CFData too large"); }
    uint32_t bytes=mt_malloc(m,(uint32_t)length+1); memcpy(G(m,bytes),CFDataGetBytePtr(data),(size_t)length); CFRelease(data);
    wr32(c,c->r[ESP]+4,0); wr32(c,c->r[ESP]+8,bytes); wr32(c,c->r[ESP]+12,(uint32_t)length);
    mt_lookup_hle("_CFDataCreate")(m,c); mt_free(m,bytes);
}

typedef struct Iterator {
    Mt *owner; uint32_t guest; const UNormalizer2 *form;
    uint16_t *input,*buffer; int32_t length,start,end,position,buffer_length;
    struct Iterator *next;
} Iterator;
static Iterator *iterators;
static pthread_mutex_t iterator_mutex=PTHREAD_MUTEX_INITIALIZER;
static int32_t codepoint(const uint16_t *text,int32_t length,int32_t *index) {
    int32_t value=text[(*index)++];
    if (value>=0xd800 && value<=0xdbff && *index<length && text[*index]>=0xdc00 && text[*index]<=0xdfff)
        value=0x10000+((value-0xd800)<<10)+(text[(*index)++]-0xdc00);
    return value;
}
static Iterator *iterator(Mt *m,X86 *c) {
    pthread_mutex_lock(&iterator_mutex); Iterator *it=iterators;
    while (it && (it->owner!=m || it->guest!=A(c,0))) it=it->next;
    pthread_mutex_unlock(&iterator_mutex); if (!it) x86_fault(c,"unknown ICU iterator"); return it;
}
static void h_normalizer_new(Mt *m,X86 *c) {
    uint32_t data=A(c,1), length=A(c,2), mode=A(c,3);
    if (length>MAX_TEXT) x86_fault(c,"ICU input too large"); mt_check(m,c,data,length*2);
    Iterator *it=calloc(1,sizeof *it); if (!it) x86_fault(c,"cannot allocate ICU iterator");
    it->input=malloc((length+1)*2); if (!it->input) { free(it); x86_fault(c,"cannot copy ICU input"); }
    memcpy(it->input,G(m,data),length*2); it->owner=m; it->guest=A(c,0); it->length=(int32_t)length;
    int32_t error=0;
    if (mode==2) it->form=unorm2_getNFDInstance(&error);
    else if (mode==3) it->form=unorm2_getNFKDInstance(&error);
    else if (mode==4) it->form=unorm2_getNFCInstance(&error);
    else if (mode==5) it->form=unorm2_getNFKCInstance(&error);
    else if (mode!=1) { free(it->input); free(it); x86_fault(c,"unsupported ICU normalization mode %u",mode); }
    if (error>0) { free(it->input); free(it); x86_fault(c,"cannot open ICU normalization mode"); }
    pthread_mutex_lock(&iterator_mutex); it->next=iterators; iterators=it; pthread_mutex_unlock(&iterator_mutex);
}
static void h_normalizer_next(Mt *m,X86 *c) {
    Iterator *it=iterator(m,c);
    while (it->position>=it->buffer_length) {
        if (it->end>=it->length) { c->r[EAX]=0xffff; return; }
        it->start=it->end; int32_t end=it->end; codepoint(it->input,it->length,&end);
        if (it->form) while (end<it->length) {
            int32_t following=end, cp=codepoint(it->input,it->length,&following);
            if (unorm2_hasBoundaryBefore(it->form,cp)) break;
            end=following;
        }
        free(it->buffer); it->buffer=NULL; it->position=0; it->end=end;
        int32_t length=end-it->start, error=0;
        if (it->form) {
            int32_t needed=unorm2_normalize(it->form,it->input+it->start,length,NULL,0,&error);
            if (error>0 && error!=15) x86_fault(c,"ICU normalization preflight failed: %d",error);
            it->buffer=malloc(((size_t)needed+1)*2); if (!it->buffer) x86_fault(c,"cannot allocate ICU normalized segment");
            error=0; it->buffer_length=unorm2_normalize(it->form,it->input+it->start,length,it->buffer,needed+1,&error);
            if (error>0) x86_fault(c,"ICU normalization failed: %d",error);
        } else {
            it->buffer=malloc(((size_t)length+1)*2); if (!it->buffer) x86_fault(c,"cannot allocate ICU segment");
            memcpy(it->buffer,it->input+it->start,(size_t)length*2); it->buffer_length=length;
        }
    }
    c->r[EAX]=(uint32_t)codepoint(it->buffer,it->buffer_length,&it->position);
}
static void h_normalizer_index(Mt *m,X86 *c) { Iterator *it=iterator(m,c); c->r[EAX]=(uint32_t)(it->position<it->buffer_length ? it->start : it->end); }
static void h_normalizer_delete(Mt *m,X86 *c) {
    pthread_mutex_lock(&iterator_mutex); Iterator **p=&iterators;
    while (*p && ((*p)->owner!=m || (*p)->guest!=A(c,0))) p=&(*p)->next;
    Iterator *it=*p; if (it) *p=it->next; pthread_mutex_unlock(&iterator_mutex);
    if (!it) x86_fault(c,"unknown ICU destructor"); free(it->input); free(it->buffer); free(it);
}
static void reset_iterators(Mt *m) {
    pthread_mutex_lock(&iterator_mutex);
    Iterator **p=&iterators;
    while (*p) {
        Iterator *it=*p;
        if (it->owner!=m) { p=&it->next; continue; }
        *p=it->next; free(it->input); free(it->buffer); free(it);
    }
    pthread_mutex_unlock(&iterator_mutex);
}
static void h_char_name(Mt *m,X86 *c) {
    uint32_t out=A(c,2), capacity=A(c,3), status=A(c,4); mt_check(m,c,out,capacity);
    int32_t error=(int32_t)rd32(c,status); c->r[EAX]=(uint32_t)u_charName((int32_t)A(c,0),(int)A(c,1),(char *)G(m,out),(int32_t)capacity,&error); wr32(c,status,(uint32_t)error);
}
static void h_isgraph(Mt *m,X86 *c) { (void)m; c->r[EAX]=(uint32_t)u_isgraph((int32_t)A(c,0)); }

// Forward CoreEmoji's CF-based interface to the platform implementation.
// Signatures are established from the iOS engine's call sites; ranges and
// block callbacks are translated explicitly from host CFIndex to guest32.
static void *emoji;
static pthread_once_t emoji_once=PTHREAD_ONCE_INIT;
static void load_emoji(void) { emoji=dlopen("/System/Library/PrivateFrameworks/CoreEmoji.framework/CoreEmoji",RTLD_LOCAL|RTLD_LAZY); }
static void *emoji_function(X86 *c,const char *name) {
    pthread_once(&emoji_once,load_emoji); void *fn=emoji ? dlsym(emoji,name) : NULL;
    if (!fn) x86_fault(c,"platform CoreEmoji function unavailable: %s",name); return fn;
}
static CFTypeRef opaque(Mt *m,X86 *c,uint32_t guest) { Object *o=find(m,guest); if (!o) x86_fault(c,"unknown CoreEmoji object"); return o->value; }
static uint32_t wrap_owned(Mt *m,X86 *c,CFTypeRef value) {
    if (!value) return 0;
    if (CFGetTypeID(value)==CFStringGetTypeID()) { uint32_t guest=wrap_string(m,c,(CFStringRef)value); CFRelease(value); return guest; }
    uint32_t guest=mt_cf_string(m,"",0); add(m,c,guest,value); return guest;
}
static void h_emoji_locale(Mt *m,X86 *c) {
    CFTypeRef (*fn)(CFStringRef)=emoji_function(c,"CEMCreateEmojiLocaleData"); c->r[EAX]=wrap_owned(m,c,fn(string(m,c,A(c,0))));
}
static void h_contains_emoji(Mt *m,X86 *c) {
    Boolean (*fn)(CFStringRef)=emoji_function(c,"CEMStringContainsEmoji"); c->r[EAX]=fn(string(m,c,A(c,0)));
}
static void h_emoji_token(Mt *m,X86 *c) {
    CFTypeRef (*fn)(CFStringRef,CFTypeRef)=emoji_function(c,"CEMEmojiTokenCreateWithString");
    c->r[EAX]=wrap_owned(m,c,fn(string(m,c,A(c,0)),opaque(m,c,A(c,1))));
}
static void h_emoji_string(Mt *m,X86 *c) {
    CFStringRef (*fn)(CFTypeRef)=emoji_function(c,"CEMEmojiTokenGetString"); c->r[EAX]=wrap_string(m,c,fn(opaque(m,c,A(c,0))));
}
static void h_emoji_name(Mt *m,X86 *c) {
    CFStringRef (*fn)(CFTypeRef,Boolean)=emoji_function(c,"CEMEmojiTokenCopyName");
    CFStringRef name=fn(opaque(m,c,A(c,0)),(Boolean)A(c,1)); c->r[EAX]=wrap_string(m,c,name); if (name) CFRelease(name);
}
static void h_emoji_enumerate(Mt *m,X86 *c) {
    uint32_t block=A(c,4), invoke=rd32(c,block+12); CFStringRef text=string(m,c,A(c,0)); uint32_t start=A(c,1), length=A(c,2);
    check_range(c,text,start,length); CFTypeRef locale=opaque(m,c,A(c,3));
    void (*fn)(CFStringRef,CFRange,CFTypeRef,void (^)(CFTypeRef,CFRange))=emoji_function(c,"CEMEnumerateEmojiTokensInStringWithLocaleAndBlock");
    fn(text,CFRangeMake(start,length),locale,^(CFTypeRef token,CFRange range) {
        if (range.location<0 || range.length<0 || range.location>UINT32_MAX || range.length>UINT32_MAX) x86_fault(c,"CoreEmoji range outside guest bounds");
        uint32_t guest=wrap_owned(m,c,CFRetain(token));
        uint32_t args[]={block,guest,(uint32_t)range.location,(uint32_t)range.length}; mt_call_on(m,c,invoke,4,args);
        forget(m,guest); // borrowed token expires when its synchronous block returns
    });
}

MtHle mt_arm32_unicode_hle(const char *name) {
    static const MtHleEntry table[]={
        {"_CFRelease",h_release},{"_CFStringGetLength",h_length},{"_CFStringGetCharacterAtIndex",h_character},
        {"_CFStringGetCharacters",h_characters},{"_CFStringGetCharactersPtr",h_character_pointer},
        {"_CFStringCreateWithCharacters",h_create_characters},{"_CFStringCreateWithCharactersNoCopy",h_create_characters},
        {"_CFStringCreateWithCString",h_create_cstring},{"_CFStringCreateWithCStringNoCopy",h_create_cstring},
        {"_CFStringCreateWithPascalString",h_create_pascal},{"_CFStringCreateMutable",h_create_mutable},
        {"_CFStringCreateCopy",h_copy},{"_CFStringCreateMutableCopy",h_mutable_copy},
        {"_CFStringGetCString",h_get_cstring},{"_CFStringGetCStringPtr",h_get_pointer},
        {"_CFStringGetMaximumSizeForEncoding",h_max_encoding},{"_CFStringGetMaximumSizeOfFileSystemRepresentation",h_max_path},
        {"_CFStringGetFileSystemRepresentation",h_get_path},{"_CFStringCompare",h_compare},
        {"_CFStringAppend",h_append},{"_CFStringAppendCharacters",h_append_characters},{"_CFStringInsert",h_insert},
        {"_CFStringReplace",h_replace},{"_CFStringCreateExternalRepresentation",h_external},
        {"__ZN3icu10NormalizerC1EPKti18UNormalizationMode",h_normalizer_new},{"__ZN3icu10Normalizer4nextEv",h_normalizer_next},
        {"__ZNK3icu10Normalizer8getIndexEv",h_normalizer_index},{"__ZN3icu10NormalizerD1Ev",h_normalizer_delete},
        {"_u_charName",h_char_name},{"_u_isgraph",h_isgraph},
        {"_CEMCreateEmojiLocaleData",h_emoji_locale},{"_CEMStringContainsEmoji",h_contains_emoji},
        {"_CEMEmojiTokenCreateWithString",h_emoji_token},{"_CEMEmojiTokenGetString",h_emoji_string},
        {"_CEMEmojiTokenCopyName",h_emoji_name},{"_CEMEnumerateEmojiTokensInStringWithLocaleAndBlock",h_emoji_enumerate},
        {NULL,NULL}};
    for (const MtHleEntry *e=table;e->name;e++) if (!strcmp(name,e->name)) return e->fn;
    return NULL;
}

#endif
