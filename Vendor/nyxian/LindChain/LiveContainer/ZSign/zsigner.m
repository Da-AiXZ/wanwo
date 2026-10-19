//
//  zsigner.m
//  LiveContainer
//
//  Created by s s on 2024/11/10.
//

#import "zsigner.h"
#import "zsign.hpp"

NSProgress* currentZSignProgress;

// 【万我 N7c 修 2026-10-19】容器身份覆写开关（bundle.cpp GetSignFolderInfo
// 消费）。默认 NO=标准签名交付模式（签名身份=包 Info.plist 对齐证书后的
// 值——N7c 交付场景）；YES=LiveContainer 容器模式（覆写 CFBundleExecutable/
// CFBundleIdentifier 为宿主 App 值——guest 代码跑在宿主进程内签名身份必须
// =宿主，N9 运行链在调用签名前经 wanwo_setHostIdentityOverride:YES 开启）。
// 0.10.3 原行为=无条件 YES（无开关）——轻松签实测对独立 app 交付是三方
// 身份错乱。diff 登记 docs/gpl-compliance.md §N7c。
static BOOL s_wanwo_host_identity = NO;

BOOL wanwo_zsign_host_identity(void) {
    return s_wanwo_host_identity ? YES : NO;
}

@implementation ZSigner
+ (void)wanwo_setHostIdentityOverride:(BOOL)on {
    s_wanwo_host_identity = on ? YES : NO;
}
+ (NSProgress*)signWithAppPath:(NSString *)appPath prov:(NSData *)prov key:(NSData *)key pass:(NSString *)pass
             completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSProgress* ans = [NSProgress progressWithTotalUnitCount:1000];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            zsign(appPath, prov, key, pass, ans, completionHandler);
        });
    return ans;
}

+ (BOOL)adhocSignMachOAtPath:(NSString *)path bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData {
    return adhocSignMachO(path, bundleId, entitlementData);
}

+ (BOOL)signMachOAtPath:(NSString *)path prov:(NSData *)prov key:(NSData *)key pass:(NSString *)pass
{
    return zsignMachO(path, prov, key, pass);
}

// this method is used to get teamId for ADP/Enterprise certs ,don't use it in normal jitless
+ (NSString*)getTeamIdWithProv:(NSData *)prov key:(NSData *)key pass:(NSString *)pass {
    return getTeamId(prov, key, pass);
}

+ (int)checkCertWithProv:(NSData *)prov key:(NSData *)key pass:(NSString *)pass completionHandler:(void(^)(int status, NSDate* expirationDate, NSString *error))completionHandler {
    return checkCert(prov, key, pass, completionHandler);
}
@end

const char *getExecutablePath(void)
{
    return [[[NSBundle mainBundle] executablePath] UTF8String];
}

const char *getBundleIdentifier(void)
{
    return [[[NSBundle mainBundle] bundleIdentifier] UTF8String];
}
