#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
int main(int argc, char **argv) {
    dlopen(argv[1], RTLD_NOW);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) if (!strcmp(_dyld_get_image_name(i), argv[1])) {
        const char *base = (const char *)_dyld_get_image_header(i);
        for (int a = 2; a < argc; a++) { unsigned long off = strtoul(argv[a], 0, 0); Dl_info di = {0};
            dladdr(base + off, &di); printf("0x%lx -> %s +0x%lx\n", off, di.dli_sname ? di.dli_sname : "?", di.dli_saddr ? (unsigned long)(base + off - (const char *)di.dli_saddr) : 0); }
    }
}
