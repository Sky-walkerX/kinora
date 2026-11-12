#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
static void dumpProto(Protocol *p) {
    printf("@protocol %s\n", protocol_getName(p));
    unsigned n; Protocol * __unsafe_unretained *adopted = protocol_copyProtocolList(p, &n);
    for (unsigned i=0;i<n;i++) printf("  <adopts %s>\n", protocol_getName(adopted[i]));
    for (int req=1; req>=0; req--) for (int inst=1; inst>=0; inst--) {
        unsigned c; struct objc_method_description *m = protocol_copyMethodDescriptionList(p, req, inst, &c);
        for (unsigned i=0;i<c;i++) printf("  %s%s %s  %s\n", req?"":"@optional ", inst?"-":"+", sel_getName(m[i].name), m[i].types);
        free(m);
    }
}
static void dumpClass(Class c) {
    Class s = class_getSuperclass(c);
    printf("@interface %s : %s", class_getName(c), s?class_getName(s):"-");
    unsigned pn; Protocol * __unsafe_unretained *ps = class_copyProtocolList(c, &pn);
    if (pn) { printf(" <"); for (unsigned i=0;i<pn;i++) printf("%s%s", i?", ":"", protocol_getName(ps[i])); printf(">"); }
    printf("\n");
    unsigned iv; Ivar *ivs = class_copyIvarList(c, &iv);
    for (unsigned i=0;i<iv;i++) printf("  ivar %s %s\n", ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i])?:"");
    unsigned pc; objc_property_t *props = class_copyPropertyList(c, &pc);
    for (unsigned i=0;i<pc;i++) printf("  @property %s [%s]\n", property_getName(props[i]), property_getAttributes(props[i]));
    for (int meta=1; meta>=0; meta--) {
        unsigned mc; Method *ms = class_copyMethodList(meta? object_getClass((id)c): c, &mc);
        for (unsigned i=0;i<mc;i++) printf("  %s%s  %s\n", meta?"+":"-", sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i])?:"");
        free(ms);
    }
}
int main(int argc, const char **argv) {
    for (int a=1; a<argc; a++) {
        void *h = dlopen(argv[a], RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen failed %s: %s\n", argv[a], dlerror()); continue; }
        Dl_info info; 
        unsigned cn; const char **names = objc_copyClassNamesForImage(argv[a], &cn);
        printf("\n######## IMAGE %s (%u classes)\n", argv[a], cn);
        for (unsigned i=0;i<cn;i++) { Class c = objc_getClass(names[i]); if (c) dumpClass(c); }
        free(names);
    }
    printf("\n######## PROTOCOLS matching Wallpaper/Extension\n");
    unsigned pn; Protocol * __unsafe_unretained *ps = objc_copyProtocolList(&pn);
    for (unsigned i=0;i<pn;i++) { const char *nm = protocol_getName(ps[i]);
        if (strcasestr(nm, "wallpaper") || strcasestr(nm, "WP") == nm) dumpProto(ps[i]); }
    return 0;
}
