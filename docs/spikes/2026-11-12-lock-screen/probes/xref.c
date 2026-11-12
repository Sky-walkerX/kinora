// Finds functions in an image whose ADRP+ADD/LDR resolve to a target offset.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
int main(int argc, char **argv) {
    dlopen(argv[1], RTLD_NOW);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) if (!strcmp(_dyld_get_image_name(i), argv[1])) {
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i); const char *base = (const char *)h;
        unsigned long target = (unsigned long)base + strtoul(argv[2], 0, 0);
        unsigned long sz; const char *t = (const char *)getsectiondata(h, "__TEXT", "__text", &sz); unsigned long page[32] = {0};
        for (unsigned long o = 0; o < sz; o += 4) {
            unsigned long pc = (unsigned long)t + o; uint32_t ins = *(uint32_t *)pc; unsigned long tg = 0;
            if ((ins & 0x9f000000) == 0x90000000) { int rd = ins & 31; long imm = ((ins >> 29) & 3) | (((ins >> 5) & 0x7ffff) << 2); if (imm & (1L << 20)) imm -= (1L << 21); page[rd] = (pc & ~0xfffUL) + (imm << 12); continue; }
            if ((ins & 0xffc00000) == 0x91000000) { int rn = (ins >> 5) & 31; if (page[rn]) tg = page[rn] + ((ins >> 10) & 0xfff); }
            if ((ins & 0xffc00000) == 0xf9400000 || (ins & 0xffc00000) == 0xf9000000) { int rn = (ins >> 5) & 31; if (page[rn]) tg = page[rn] + (((ins >> 10) & 0xfff) << 3); }
            if (tg == target) { Dl_info di = {0}; dladdr((void *)pc, &di); printf("0x%lx in %s\n", pc - (unsigned long)base, di.dli_sname ? di.dli_sname : "?"); }
        }
    }
}
