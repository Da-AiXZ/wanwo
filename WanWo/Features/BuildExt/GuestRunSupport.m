//
//  GuestRunSupport.m
//  WanWo
//
//  【N9a · guest 签名与安装链 · 万我层 ObjC 薄壳】实现——语义出处见头注释。
//  万我自有代码，零 vendored 改动（登记 docs/gpl-compliance.md §N9）。
//

#import "GuestRunSupport.h"
#import <LindChain/LiveContainer/LCMachOUtils.h>
#import <LindChain/ProcEnvironment/Surface/trust.h>

NSErrorDomain const WanWoGuestRunErrorDomain = @"com.wanwo.guestrun";

// 官方 LCUtils.signAppBundleWithZSign 补片段的域/文案（LCUtils.m:76/82），
// 万我域名牌折算（com.nyxian.lcutils → com.wanwo.guestrun，语义等义）。
static NSError *WanWoGuestRunUnsupportedFormatError(void)
{
    return [NSError errorWithDomain:WanWoGuestRunErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: @"unsupported executable format（非 arm64 可执行或补片失败——MH_EXECUTE→MH_DYLIB 补片仅支持 CPU_TYPE_ARM64）" }];
}

// 布尔键读取（多别名依序取第一个在场的；全缺省返回 def——官方
// NXPlist booleanForKey:withDefaultValue: 的多键形态，万我双键名体系需要）。
static BOOL WanWoGuestRunBoolForAliases(NSDictionary *plist, NSArray<NSString *> *keys, BOOL def)
{
    if (plist == nil) {
        return def;
    }
    for (NSString *key in keys) {
        id value = plist[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            return [value boolValue];
        }
    }
    return def;
}

@implementation GuestRunSupport

+ (BOOL)patchGuestExecutableAtPath:(NSString *)machoPath
                         bundleURL:(NSURL *)bundleURL
                             error:(NSError **)error
{
    if (machoPath.length == 0 || bundleURL == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"补片入参缺失（macho path 或 bundle URL 为空）" }];
        }
        return NO;
    }

    __block NSError *patchError = nil;

    // 官方形态照抄（LCUtils.m:72-78）：LCParseMachO 回调内 cputype 门 +
    // LCPatchExecSlice(path, header, YES)。readOnly=false（官方同参——补片要写回）。
    NSString *parseError = LCParseMachO(machoPath.UTF8String, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype != CPU_TYPE_ARM64 ||
            LCPatchExecSlice(path, header, YES) != 0) {
            patchError = WanWoGuestRunUnsupportedFormatError();
        }
    });

    if (parseError != nil && patchError == nil) {
        // 官方同语义：解析层错误归一为 unsupported executable format（LCUtils.m:80-83）
        patchError = WanWoGuestRunUnsupportedFormatError();
    }

    if (patchError != nil) {
        if (error != NULL) {
            *error = patchError;
        }
        return NO;
    }

    // arm64e 修正（LCUtils.m:92——void 返回，官方不检）
    LCPatchAppBundleFixupARM64eSlice(bundleURL);

    return YES;
}

+ (BOOL)appendEntitlementTokenToMachOAtPath:(NSString *)machoPath
                                entitlement:(PEEntitlement)entitlement
                                      error:(NSError **)error
{
    if (machoPath.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:3
                                     userInfo:@{ NSLocalizedDescriptionKey: @"token 追加入参缺失（macho path 为空）" }];
        }
        return NO;
    }

    // macho_after_sign（trust.c:212-276）：cdhash→entitlement_token_mach_gen
    // （ksurface 自签）→EOF 追加（幂等）。rc!=0 = token 未生成/未写入。
    int rc = macho_after_sign(machoPath.UTF8String, entitlement);
    if (rc != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:4
                                     userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"macho_after_sign 失败（rc=%d）——NXTR token 未追加（guest spawn 链将因无 token 残废：proc_fork entitlement 读取失败）", rc] }];
        }
        return NO;
    }
    return YES;
}

+ (uint64_t)entitlementBitsFromEntitlementsPlist:(NSDictionary *)plist
{
    // 官方 NXEntitlementsConfig.entitlement 位映射等义重建
    //（0.10.3 NXProject.m:145-163 逐键对照；默认值语义逐键照抄）。
    // 键双收：万我 scaffold 键（kNXT2Entitlement* 常量值，Utils/entitlement.c:35-71）
    // 优先，官方 com.nyxian.pe.* 键别名兼容。
    uint64_t bits = 0;

    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.get-task-allow", @"com.nyxian.pe.get_task_allowed"],
                                    YES)) {
        bits |= PEEntitlementGetTaskAllowed;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.task-for-pid", @"com.nyxian.pe.task_for_pid"],
                                    NO)) {
        bits |= PEEntitlementTaskForPid;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.process.enumeration", @"com.nyxian.pe.process_enumeration"],
                                    NO)) {
        bits |= PEEntitlementProcessEnumeration;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.process.kill", @"com.nyxian.pe.process_kill"],
                                    NO)) {
        bits |= PEEntitlementProcessKill;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.process.spawn", @"com.nyxian.pe.process_spawn"],
                                    NO)) {
        bits |= PEEntitlementProcessSpawn;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.process.spawn.signed-only", @"com.nyxian.pe.process_spawn_signed_only"],
                                    NO)) {
        bits |= PEEntitlementProcessSpawnSignedOnly;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.nyxian.pe.process_elevate"],
                                    NO)) {
        bits |= PEEntitlementProcessElevate;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.management.host", @"com.nyxian.pe.host_manager"],
                                    NO)) {
        bits |= PEEntitlementHostManager;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.nyxian.pe.credentials_manager"],
                                    NO)) {
        bits |= PEEntitlementCredentialsManager;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.launch-services.start", @"com.nyxian.pe.launch_services_start"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesStart;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.launch-services.stop", @"com.nyxian.pe.launch_services_stop"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesStop;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.launch-services.toggle", @"com.nyxian.pe.launch_services_toggle"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesToggle;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.launch-services.get-endpoint", @"com.nyxian.pe.launch_services_get_endpoint"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesGetEndpoint;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.launch-services.set-endpoint", @"com.nyxian.pe.launch_services_set_endpoint"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesSetEndpoint;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.nyxian.pe.launch_services_manager"],
                                    NO)) {
        bits |= PEEntitlementLaunchServicesManager;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.nyxian.pe.dyld_hide_liveprocess"],
                                    NO)) {
        bits |= PEEntitlementDyldHideLiveProcess;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.process.spawn.inherite-entitlements", @"com.nyxian.pe.process_spawn_inherite_entitlements"],
                                    NO)) {
        bits |= PEEntitlementProcessSpawnInheriteEntitlements;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.platform", @"com.nyxian.pe.platform"],
                                    NO)) {
        bits |= PEEntitlementPlatform;
    }
    if (WanWoGuestRunBoolForAliases(plist,
                                    @[@"com.wanwo.build.platform-root", @"com.nyxian.pe.platform_root"],
                                    NO)) {
        bits |= PEEntitlementPlatformRoot;
    }

    return bits;
}

@end
