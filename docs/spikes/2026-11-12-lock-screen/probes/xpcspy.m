#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
// Spy XPC coder: logs which XPC objects and keys a class decodes; answers with a real IOSurface.
@interface XSpy : NSXPCCoder @end
@implementation XSpy
- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return YES; }
- (xpc_object_t)decodeXPCObjectOfType:(xpc_type_t)type forKey:(NSString *)key {
    printf("    decodeXPCObjectOfType:%s forKey:%s\n", xpc_type_get_name(type), key.UTF8String);
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((unsigned)'BGRA')});
    xpc_object_t x = IOSurfaceCreateXPCObject(s); CFRelease(s); return x;
}
- (id)decodeObjectOfClass:(Class)c forKey:(NSString *)key { printf("    decodeObjectOfClass:%s forKey:%s\n", NSStringFromClass(c).UTF8String, key.UTF8String); return nil; }
- (id)decodeObjectOfClasses:(NSSet *)cs forKey:(NSString *)key { printf("    decodeObjectOfClasses forKey:%s\n", key.UTF8String); return nil; }
- (BOOL)containsValueForKey:(NSString *)key { printf("    containsValueForKey:%s\n", key.UTF8String); return YES; }
- (void)encodeXPCObject:(xpc_object_t)o forKey:(NSString *)key { printf("    encodeXPCObject:%s forKey:%s\n", xpc_type_get_name(xpc_get_type(o)), key.UTF8String); }
- (void)encodeObject:(id)o forKey:(NSString *)key { printf("    encodeObject:%s forKey:%s\n", NSStringFromClass([o class]).UTF8String, key.UTF8String); }
- (void)failWithError:(NSError *)e { printf("    failWithError %s\n", e.description.UTF8String); }
- (BOOL)isKindOfClass:(Class)c { printf("    isKindOfClass:%s\n", NSStringFromClass(c).UTF8String); return [super isKindOfClass:c] || [NSStringFromClass(c) hasPrefix:@"NSXPC"]; }
- (BOOL)respondsToSelector:(SEL)s { printf("    respondsToSelector:%s\n", sel_getName(s)); return [super respondsToSelector:s]; }
- (xpc_object_t)decodeXPCObjectForKey:(NSString *)key { printf("    decodeXPCObjectForKey:%s\n", key.UTF8String); return [self decodeXPCObjectOfType:XPC_TYPE_DICTIONARY forKey:key]; }
- (NSXPCConnection *)connection { printf("    connection\n"); return nil; }
@end
int main(void) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/Versions/A/WallpaperExtensionKit", RTLD_NOW);
    Class c = NSClassFromString(@"WallpaperSnapshotXPC");
    XSpy *spy = [XSpy new];
    id obj = [[c alloc] initWithCoder:spy];
    printf("decoded -> %s\n", obj ? [obj description].UTF8String : "nil");
    if (obj) { printf("re-encode:\n"); [obj encodeWithCoder:spy]; }
}
