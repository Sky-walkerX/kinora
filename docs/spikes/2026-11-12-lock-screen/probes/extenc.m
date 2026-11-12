#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
extern const char *_protocol_getMethodTypeEncoding(Protocol *, SEL, BOOL isRequiredMethod, BOOL isInstanceMethod);
int main(int argc, const char **argv) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/Versions/A/WallpaperExtensionKit", RTLD_NOW);
    for (int a = 1; a < argc; a++) {
        Protocol *p = objc_getProtocol(argv[a]); printf("@protocol %s\n", argv[a]); if (!p) continue;
        unsigned c; struct objc_method_description *m = protocol_copyMethodDescriptionList(p, YES, YES, &c);
        for (unsigned i = 0; i < c; i++) printf("  %s\n      %s\n", sel_getName(m[i].name), _protocol_getMethodTypeEncoding(p, m[i].name, YES, YES));
    }
}
