// Dumps bytes [off-before, off+after) of a loaded image as an assembler .byte file, plus referenced C strings later.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
int main(int argc, char **argv) {
    const char *path = argv[1]; unsigned long off = strtoul(argv[2], 0, 0), before = strtoul(argv[3], 0, 0), after = strtoul(argv[4], 0, 0);
    dlopen(path, RTLD_NOW);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) if (!strcmp(_dyld_get_image_name(i), path)) {
        const unsigned char *base = (const unsigned char *)_dyld_get_image_header(i);
        fprintf(stderr, "base=%p\n", base);
        printf(".text\n.globl _start\n_start:\n");
        for (unsigned long a = off - before; a < off + after; a += 4) {
            printf("  .byte 0x%02x,0x%02x,0x%02x,0x%02x  ; +0x%lx\n", base[a], base[a+1], base[a+2], base[a+3], a);
        }
        return 0;
    }
    return 1;
}
