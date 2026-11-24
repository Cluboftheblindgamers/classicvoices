#include "thumb_ops.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void vx_fault_mem(const char *kind, uint32_t addr, uint32_t pc) { fprintf(stderr, "%s %x at %x\n", kind, addr, pc); abort(); }
void vx_undef(uint32_t h1, uint32_t h2, uint32_t pc) { fprintf(stderr, "unsupported %04x %04x at %x\n", h1, h2, pc); abort(); }
static unsigned char code[17 * 16], memory[0x2000];
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "NEON check failed at line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static uint64_t floats(float a, float b) { uint32_t x, y; memcpy(&x, &a, 4); memcpy(&y, &b, 4); return x | (uint64_t)y << 32; }
static void run(Core *c, unsigned index) {
    uint16_t h1, h2; memcpy(&h1, code + index * 16, 2); memcpy(&h2, code + index * 16 + 2, 2);
    exec32(c, h1, h2, 0x1000);
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
    // Last fixture needs no final alignment padding.
    if (fread(code, 1, sizeof code, f) < 16 * 16 + 4) return 2;
    fclose(f);
    Core c = {0}; c.mem = memory;
    c.d[9] = floats(9, 10); c.d[0] = floats(1, 3); run(&c, 0); CHECK(c.d[1] == floats(8, 7));
    c.d[2] = floats(1, -2); c.d[3] = floats(3, -4); c.d[4] = floats(5, 6); c.d[5] = floats(-7, -8);
    run(&c, 1); CHECK(c.d[0] == floats(6, 4)); CHECK(c.d[1] == floats(-4, -12));
    c.d[1] = floats(2, 4); c.d[17] = floats(3, -2); run(&c, 2); CHECK(c.d[16] == floats(6, -8));
    c.d[18] = UINT64_C(0xffc1234580000000); c.d[19] = UINT64_C(0x80000001c0000000);
    run(&c, 3); CHECK(c.d[16] == UINT64_C(0x7fc1234500000000)); CHECK(c.d[17] == UINT64_C(0x0000000140000000));
    run(&c, 4); CHECK(c.d[16] == UINT64_C(0xffc1234580000000)); CHECK(c.d[17] == UINT64_C(0x80000001c0000000));
    c.d[16] = c.d[17] = UINT64_C(0xff7f01fffe02ff01); c.d[18] = c.d[19] = UINT64_C(0x0180ff0202fe0101);
    run(&c, 5); CHECK(c.d[16] == UINT64_C(0x00ff000100000002)); CHECK(c.d[17] == c.d[16]);
    c.d[16] = c.d[17] = UINT64_C(0x00008000ffff0000); c.d[18] = c.d[19] = UINT64_C(0x000100010001ffff);
    run(&c, 6); CHECK(c.d[16] == UINT64_C(0xffff7ffffffe0001)); CHECK(c.d[17] == c.d[16]);
    c.d[16] = c.d[17] = UINT64_C(0xffffffff7fffffff); c.d[18] = c.d[19] = UINT64_C(0x0000000100000001);
    run(&c, 7); CHECK(c.d[16] == UINT64_C(0x0000000080000000)); CHECK(c.d[17] == c.d[16]);
    c.d[16] = 0; c.d[17] = 5; c.d[18] = 1; c.d[19] = 3;
    run(&c, 8); CHECK(c.d[16] == UINT64_MAX); CHECK(c.d[17] == 2);
    c.d[0] = floats(1, 5); c.d[16] = floats(3, 4); run(&c, 9); CHECK(c.d[16] == floats(1, 4));
    c.d[18] = floats(2, 3); run(&c, 10); CHECK(c.d[0] == floats(2, 4));
    c.d[0] = 0; c.d[16] = UINT64_C(0x8000000080000000); run(&c, 9); CHECK(c.d[16] == UINT64_C(0x8000000080000000));
    c.d[18] = 0; run(&c, 10); CHECK(c.d[0] == 0);
    c.d[0] = UINT64_C(0x7f8000017fc12345); c.d[16] = floats(2, 3); run(&c, 9); CHECK(c.d[16] == UINT64_C(0x7fc000007fc00000));
    c.d[17] = UINT64_C(0x123456789abcdef0); c.r[0] = 0x1000; run(&c, 11); CHECK(g32(&c, 0x1000) == 0x12345678); CHECK(c.r[0] == 0x1004);
    s8(&c, 0x1000, 0xef); c.r[0] = 0x1000; run(&c, 12); CHECK(c.d[17] == UINT64_C(0x1234ef789abcdef0)); CHECK(c.r[0] == 0x1001);
    s16(&c, 0x1000, 0x7654); c.r[0] = 0x1000; run(&c, 13); CHECK(c.d[17] == UINT64_C(0x123476549abcdef0)); CHECK(c.r[0] == 0x1002);
    c.r[0] = 0x1000; run(&c, 14); CHECK(g8(&c, 0x1000) == 0x76); CHECK(c.r[0] == 0x1001);
    c.r[0] = 0x1000; run(&c, 15); CHECK(g16(&c, 0x1000) == 0x7654); CHECK(c.r[0] == 0x1002);
    s32(&c, 0x1000, 0x11223344); c.r[0] = 0x1000; run(&c, 16); CHECK(c.d[17] == UINT64_C(0x112233449abcdef0)); CHECK(c.r[0] == 0x1004);
    printf("%u NEON checks passed\n", checks);
}
