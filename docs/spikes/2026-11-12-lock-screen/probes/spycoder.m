#import <Foundation/Foundation.h>
#include <dlfcn.h>
// Black-box probe: a keyed coder that logs every key and class a class asks for while decoding.
@interface Spy : NSCoder
@property (nonatomic, strong) NSDictionary *answers; // key -> object to return
@end
@implementation Spy
- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return YES; }
- (NSDecodingFailurePolicy)decodingFailurePolicy { return NSDecodingFailurePolicySetErrorAndReturn; }
- (void)failWithError:(NSError *)error { printf("    failWithError: %s\n    userInfo: %s\n", error.description.UTF8String, error.userInfo.description.UTF8String); }
- (BOOL)containsValueForKey:(NSString *)key { printf("    containsValueForKey:%s\n", key.UTF8String); return self.answers[key] != nil; }
- (id)decodeObjectOfClass:(Class)c forKey:(NSString *)key { printf("    decodeObjectOfClass:%s forKey:%s\n", NSStringFromClass(c).UTF8String, key.UTF8String); return self.answers[key]; }
- (id)decodeObjectOfClasses:(NSSet *)cs forKey:(NSString *)key { printf("    decodeObjectOfClasses:%s forKey:%s\n", [[cs.allObjects valueForKey:@"description"] componentsJoinedByString:@","].UTF8String, key.UTF8String); return self.answers[key]; }
- (id)decodeObjectForKey:(NSString *)key { printf("    decodeObjectForKey:%s\n", key.UTF8String); return self.answers[key]; }
- (BOOL)decodeBoolForKey:(NSString *)key { printf("    decodeBoolForKey:%s\n", key.UTF8String); return NO; }
- (int)decodeIntForKey:(NSString *)key { printf("    decodeIntForKey:%s\n", key.UTF8String); return 0; }
- (int32_t)decodeInt32ForKey:(NSString *)key { printf("    decodeInt32ForKey:%s\n", key.UTF8String); return 0; }
- (int64_t)decodeInt64ForKey:(NSString *)key { printf("    decodeInt64ForKey:%s\n", key.UTF8String); return 0; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { printf("    decodeIntegerForKey:%s\n", key.UTF8String); return 0; }
- (double)decodeDoubleForKey:(NSString *)key { printf("    decodeDoubleForKey:%s\n", key.UTF8String); return 0; }
- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)len { printf("    decodeBytesForKey:%s\n", key.UTF8String); *len = 0; return NULL; }
- (id)decodeTopLevelObjectOfClasses:(NSSet *)cs forKey:(NSString *)key error:(NSError **)e { printf("    decodeTopLevelObjectOfClasses forKey:%s\n", key.UTF8String); return self.answers[key]; }
- (id)decodePropertyListForKey:(NSString *)key { printf("    decodePropertyListForKey:%s\n", key.UTF8String); return self.answers[key]; }
- (NSArray *)decodeArrayOfObjectsOfClasses:(NSSet *)cs forKey:(NSString *)key { printf("    decodeArrayOfObjectsOfClasses:%s forKey:%s\n", [[cs.allObjects valueForKey:@"description"] componentsJoinedByString:@","].UTF8String, key.UTF8String); return self.answers[key]; }
- (NSDictionary *)decodeDictionaryWithKeysOfClasses:(NSSet *)kc objectsOfClasses:(NSSet *)oc forKey:(NSString *)key { printf("    decodeDictionaryWithKeysOfClasses forKey:%s\n", key.UTF8String); return self.answers[key]; }
- (NSData *)decodeDataObject { printf("    decodeDataObject\n"); return nil; }
- (NSError *)error { return nil; }
@end
int main(int argc, const char **argv) {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/Versions/A/WallpaperExtensionKit", RTLD_NOW);
    for (int a = 1; a < argc; a++) {
        Class c = NSClassFromString(@(argv[a]));
        printf("== %s (%s)\n", argv[a], c ? "found" : "missing");
        if (!c) continue;
        Spy *spy = [Spy new];
        NSMutableDictionary *ans = [NSMutableDictionary dictionary];
        while (a + 1 < argc && strchr(argv[a+1], '=')) { a++; NSString *kv = @(argv[a]); NSRange r = [kv rangeOfString:@"="];
            NSString *k = [kv substringToIndex:r.location], *v = [kv substringFromIndex:r.location+1];
            if ([v hasPrefix:@"hex:"]) { NSString *h=[v substringFromIndex:4]; NSMutableData *d=[NSMutableData data]; for (NSUInteger i=0;i+1<h.length;i+=2){unsigned x; [[NSScanner scannerWithString:[h substringWithRange:NSMakeRange(i,2)]] scanHexInt:&x]; uint8_t b=x; [d appendBytes:&b length:1];} ans[k]=d; }
            else if ([v hasPrefix:@"str:"]) ans[k]=[[v substringFromIndex:4] dataUsingEncoding:NSUTF8StringEncoding];
            else if ([v hasPrefix:@"arr:"]) ans[k]=@[];
            else if ([v hasPrefix:@"file:"]) ans[k]=[NSData dataWithContentsOfFile:[v substringFromIndex:5]]; }
        spy.answers = ans;
        id obj = [[c alloc] initWithCoder:spy];
        printf("    -> %s\n", obj ? [obj description].UTF8String : "nil");
    }
}
