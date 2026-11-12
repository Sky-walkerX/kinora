// Walks instructions of a function in a loaded image; resolves ADRP+ADD/LDR targets and BL targets to symbols/strings.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
static void show(const char *pc_s, unsigned long pc, const char *base, unsigned long tgt, const char *what) {
    Dl_info di = {0}; dladdr((void *)tgt, &di);
    const char *s = (const char *)tgt; int printable = 1;
    for (int i = 0; i < 4; i++) if (!isprint((unsigned char)s[i])) { printable = 0; break; }
    printf("  +0x%lx %s @0x%lx -> %s+0x%lx %s%s%s\n", pc - (unsigned long)base, what, tgt - (unsigned long)base, di.dli_sname ? di.dli_sname : "?",
           di.dli_saddr ? tgt - (unsigned long)di.dli_saddr : 0, printable ? "\"" : "", printable ? s : "", printable ? "\"" : "");
}
int main(int argc, char **argv) {
    dlopen(argv[1], RTLD_NOW);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) if (!strcmp(_dyld_get_image_name(i), argv[1])) {
        const char *base = (const char *)_dyld_get_image_header(i);
        unsigned long start = strtoul(argv[2], 0, 0), len = strtoul(argv[3], 0, 0);
        unsigned long page[32] = {0};
        for (unsigned long a = start; a < start + len; a += 4) {
            unsigned long pc = (unsigned long)base + a; uint32_t ins = *(uint32_t *)pc;
            if ((ins & 0x9f000000) == 0x90000000) { // ADRP
                int rd = ins & 31; long imm = ((ins >> 29) & 3) | (((ins >> 5) & 0x7ffff) << 2); if (imm & (1L << 20)) imm -= (1L << 21);
                page[rd] = (pc & ~0xfffUL) + (imm << 12);
            } else if ((ins & 0xffc00000) == 0x91000000) { // ADD imm (64-bit, no shift)
                int rd = ins & 31, rn = (ins >> 5) & 31; unsigned long imm = (ins >> 10) & 0xfff;
                if (page[rn]) { show("", pc, base, page[rn] + imm, "add"); page[rd] = 0; }
            } else if ((ins & 0xffc00000) == 0xf9400000) { // LDR x, [xn, #imm]
                int rn = (ins >> 5) & 31; unsigned long imm = ((ins >> 10) & 0xfff) << 3;
                if (page[rn]) { show("", pc, base, page[rn] + imm, "ldr"); }
                if (page[rn]) { const char *sp = *(const char **)(page[rn] + imm); if (sp && (unsigned long)sp > 0x100000000UL && isalpha((unsigned char)sp[0])) printf("      sel/ptr -> %.80s\n", sp); }
            } else if ((ins & 0x7f800000) == 0x52800000 || (ins & 0x7f800000) == 0x72800000) { // MOVZ/MOVK
                static unsigned long imm64[32]; int rd = ins & 31; unsigned long v = (ins >> 5) & 0xffff; int hw = (ins >> 21) & 3;
                if (((ins >> 29) & 3) == 2) imm64[rd] = 0; imm64[rd] = (imm64[rd] & ~(0xffffUL << (16*hw))) | (v << (16*hw));
                char b[9] = {0}; int ok = 1, len = 0; for (int k = 0; k < 8; k++) { unsigned char ch = (imm64[rd] >> (8*k)) & 0xff; if (!ch) break; if (ch < 32 || ch > 126) { ok = 0; break; } b[len++] = ch; }
                if (ok && len >= 3) printf("  +0x%lx imm x%d = \"%s\"\n", a, rd, b);
            } else if ((ins & 0xfc000000) == 0x94000000) { // BL
                long imm = ins & 0x3ffffff; if (imm & (1L << 25)) imm -= (1L << 26);
                show("", pc, base, pc + imm * 4, "bl ");
            } else if ((ins & 0xffff0000) == 0xd4200000) printf("  +0x%lx brk\n", a);
            else if (ins == 0xd65f0fff || ins == 0xd65f03c0) printf("  +0x%lx ret\n", a);
        }
    }
}
