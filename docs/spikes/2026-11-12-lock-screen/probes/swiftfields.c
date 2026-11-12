// Dumps Swift reflection field metadata (__swift5_fieldmd) of a loaded image.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
static const char *rel(const int32_t *p) { return *p ? (const char *)p + *p : NULL; }
static const char *descName(const uint8_t *d, char *buf, size_t n);
static void parentChain(const uint8_t *d, char *buf, size_t n) {
    // ContextDescriptor: flags u32, parent i32 rel (may be indirect if low bit set)
    int32_t po = *(const int32_t *)(d + 4); if (!po) { buf[0]=0; return; }
    const uint8_t *p;
    if (po & 1) p = *(const uint8_t **)(d + 4 + (po & ~1)); else p = d + 4 + po;
    uint32_t kind = (*(const uint32_t *)p) & 0x1f;
    if (kind == 0) { buf[0]=0; return; } // module
    if (kind >= 16 && kind <= 18) { descName(p, buf, n); strncat(buf, ".", n-strlen(buf)-1); } else buf[0]=0;
}
static const char *descName(const uint8_t *d, char *buf, size_t n) {
    char par[512]; parentChain(d, par, sizeof par);
    const char *nm = rel((const int32_t *)(d + 8));
    snprintf(buf, n, "%s%s", par, nm ? nm : "?"); return buf;
}
static void mangled(const char *s, char *out, size_t n) {
    size_t o = 0; out[0] = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p && o + 64 < n; ) {
        if (*p >= 1 && *p <= 0x17) {
            const int32_t *r = (const int32_t *)(p + 1); const uint8_t *t = (const uint8_t *)r + *r;
            if (*p == 2) t = *(const uint8_t **)t; // indirect
            char nb[512] = "?"; if (*p == 1 || *p == 2) descName(t, nb, sizeof nb);
            o += snprintf(out + o, n - o, "<%s>", nb); p += 5;
        } else if (*p >= 0x18 && *p <= 0x1f) { o += snprintf(out + o, n - o, "<sym>"); p += 9; }
        else out[o++] = *p++, out[o] = 0;
    }
}
int main(int argc, char **argv) {
    const char *filter = argc > 2 ? argv[2] : NULL;
    if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), argv[1])) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        unsigned long size; uint8_t *sec = getsectiondata(h, "__TEXT", "__swift5_fieldmd", &size);
        if (!sec) { fprintf(stderr, "no fieldmd\n"); return 1; }
        for (uint8_t *p = sec; p < sec + size; ) {
            const int32_t *mt = (const int32_t *)p; uint16_t kind = *(uint16_t *)(p + 8), rsz = *(uint16_t *)(p + 10); uint32_t nf = *(uint32_t *)(p + 12);
            char tn[1024] = "?"; if (*mt) mangled(rel(mt), tn, sizeof tn);
            const char *kinds[] = {"struct","class","enum","enum(multi)","protocol","classprotocol","objcprotocol","objcclass"};
            int show = !filter || strcasestr(tn, filter);
            if (show) printf("%s %s\n", kind < 8 ? kinds[kind] : "?", tn);
            uint8_t *r = p + 16;
            for (uint32_t f = 0; f < nf; f++, r += rsz) {
                const int32_t *ft = (const int32_t *)(r + 4), *fn = (const int32_t *)(r + 8);
                char ftn[1024] = ""; if (*ft) mangled(rel(ft), ftn, sizeof ftn);
                if (show) printf("    %s : %s\n", *fn ? rel(fn) : "?", ftn);
            }
            p = r;
        }
    }
}
