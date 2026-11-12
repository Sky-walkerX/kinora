#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
// Prints image-relative offsets of a class's method implementations.
int main(int argc, const char **argv) {
    const char *img = argv[1]; dlopen(img, RTLD_NOW);
    const char *base = NULL; for (uint32_t i = 0; i < _dyld_image_count(); i++) if (!strcmp(_dyld_get_image_name(i), img)) base = (const char *)_dyld_get_image_header(i);
    Class c = objc_getClass(argv[2]);
    for (int meta = 0; meta < 2; meta++) { unsigned n; Method *m = class_copyMethodList(meta ? object_getClass((id)c) : c, &n);
        for (unsigned i = 0; i < n; i++) printf("%s%s 0x%lx\n", meta ? "+" : "-", sel_getName(method_getName(m[i])), (unsigned long)((const char *)method_getImplementation(m[i]) - base)); }
}
