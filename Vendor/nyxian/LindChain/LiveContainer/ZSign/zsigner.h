//
//  zsigner.h
//  LiveContainer
//
//  Created by s s on 2024/11/10.
//
#import <Foundation/Foundation.h>


@interface ZSigner : NSObject
// 【万我 N7c 修 2026-10-19】容器身份覆写开关（默认 NO=标准签名交付；N9
// LC 容器运行链在调用签名前置 YES——语义见 zsigner.m 实现注释与
// bundle.cpp 消费点。0.10.3 原行为=无条件容器覆写，对独立 app 交付是
// 三方身份错乱）。diff 登记 docs/gpl-compliance.md §N7c。
+ (void)wanwo_setHostIdentityOverride:(BOOL)on;
+ (NSProgress*)signWithAppPath:(NSString *)appPath prov:(NSData *)prov key:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (BOOL)adhocSignMachOAtPath:(NSString *)path bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData;
+ (BOOL)signMachOAtPath:(NSString *)path prov:(NSData *)prov key:(NSData *)key pass:(NSString *)pass;
// this method is used to get teamId for ADP/Enterprise certs ,don't use it in normal jitless
+ (NSString*)getTeamIdWithProv:(NSData *)prov key:(NSData *)key pass:(NSString *)pass;
+ (int)checkCertWithProv:(NSData *)prov key:(NSData *)key pass:(NSString *)pass completionHandler:(void(^)(int status, NSDate* expirationDate, NSString *error))completionHandler;
@end
