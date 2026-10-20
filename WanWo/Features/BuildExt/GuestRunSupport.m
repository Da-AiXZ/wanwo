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
#import <LindChain/ProcEnvironment/Process/PELaunchServiceRegistry.h>
#import <LindChain/ProcEnvironment/Object/ArchiveObject.h>
#import <LindChain/Services/applicationmgmtd/LDEApplicationWorkspace.h>

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

+ (BOOL)appendEntitlementTokenAtPath:(NSString *)machoPath
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

// ── 【N9d 诊断增强→已回退 · CS_KILL 雷区】签名自查 ─────────────────────
// ⚠️ **禁用于 F_ADDFILESIGS 后将被修改的文件**——同进程
// F_ADDFILESIGS→改文件→mmap = 内核 CS_KILL Invalid Page（真机双闪退
// 实证 2026-10-20；prepareGuestRun 内 S1/S2 调用点已全部移除——
// 见 docs/gpl-compliance.md §N9「S1/S2 回退」）。方法保留仅作语义封装。

+ (BOOL)selfCheckCodeSignatureAtPath:(NSString *)path
{
    if (path.length == 0) {
        return NO;
    }
    // LCMachOUtils.m:392-433 全局函数（LCMachOUtils.h:45 已声明——本编译
    // 单元已 #import 该头，无需 LDEApplicationWorkspaceInternal.m:30 形态
    // 的前置 extern）。readOnly=true 解析（与官方消费者同参），内核同款
    // F_ADDFILESIGS_RETURN + F_CHECK_LV 校验语义。
    return checkCodeSignature(path.UTF8String) ? YES : NO;
}

// ── 【N9d 诊断增强】installApplication 包装 ───────────────────────────────
// vendored LDEApplicationWorkspace.m:91-119 逐行对照等义重写（万我层消费
// 公开 API，vendored 版未动）。

+ (WanWoGuestInstallResult)installApplicationAtPath:(NSString *)bundlePath
                                              error:(NSError **)error
{
    if (bundlePath.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:6
                                     userInfo:@{ NSLocalizedDescriptionKey: @"install 入参缺失（bundle path 为空）" }];
        }
        return WanWoGuestInstallInvalidInput;
    }

    // connect（官方 connect 段等义：PEBootstrapRegistry endpoint → XPC 连接；
    // 差异：连接不驻留（诊断包装每次新建——官方驻留 self.connection 复用）、
    // observer=nil（本包装不消费 applicationWasInstalled 回调——导出面给
    // NSObject 空协议，daemon 侧单向回调派发到 nil 导出对象无害）。
    NSXPCConnection *connection = nil;
    PELaunchServiceRegistry *registry = [PELaunchServiceRegistry shared];
    if (registry != nil) {
        connection = [registry connectToService:@"com.wanwo.installd"
                                       protocol:@protocol(LDEApplicationWorkspaceProxyProtocol)
                                       observer:nil
                               observerProtocol:@protocol(NSObject)];
    }
    if (connection == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:7
                                     userInfo:@{ NSLocalizedDescriptionKey: @"XPC 连接不可达（PEBootstrapRegistry endpoint 缺失——installd daemon 未起？pe_smoke mode=status）" }];
        }
        return WanWoGuestInstallNoConnection;
    }

    ArchiveObject *archiveObject = [ArchiveObject objectForDirectoryAtPath:bundlePath];
    if (archiveObject == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:8
                                     userInfo:@{ NSLocalizedDescriptionKey: @"ArchiveObject 构造失败（目录不可 zip——bundle 路径不存在/不可读？）" }];
        }
        return WanWoGuestInstallInvalidInput;
    }

    __block BOOL replied = NO;
    __block BOOL replyResult = NO;
    __block NSError *xpcError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    id proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *err) {
        /* semaphores remember the signal, it doesnt have to catch them in time（官方注释同款） */
        xpcError = err;
        dispatch_semaphore_signal(sema);
    }];

    if (proxy == NULL)
    {
        /* semaphores remember the signal, it doesnt have to catch them in time（官方同款分支） */
        dispatch_semaphore_signal(sema);
    }
    else
    {
        [proxy installApplicationWithArchiveObject:archiveObject withReply:^(BOOL replyValue) {
            replied = YES;
            replyResult = replyValue;
            dispatch_semaphore_signal(sema);
        }];
    }

    // 2s 超时官方硬编码（vendored :117 同值）。
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));

    // 与 vendored 版的关键差异：回复/超时/错误回调三态可分（vendored 版
    // 2s 返回后统一 return result——reply(NO) 与超时同显 NO）。
    WanWoGuestInstallResult result;
    NSString *detail = nil;
    if (replied) {
        if (replyResult) {
            result = WanWoGuestInstallInstalled;
        } else {
            result = WanWoGuestInstallRejected;
            detail = @"installd 回复拒装（reply=NO——信任校验/解压失败，非超时；对照细目 b 段宿主 id/profile app-id 判候选①身份链错配）";
        }
    } else if (xpcError != nil) {
        result = WanWoGuestInstallXPCError;
        detail = [NSString stringWithFormat:@"XPC 错误回调（%@）", xpcError.localizedDescription];
    } else if (proxy == NULL) {
        result = WanWoGuestInstallNoConnection;
        detail = @"remoteObjectProxy 创建失败";
    } else {
        result = WanWoGuestInstallTimeout;
        detail = @"2s XPC 超时（无 reply 无错误回调——installd 无响应：daemon 未起/忙/解压超 2s）";
    }

    if (result != WanWoGuestInstallInstalled && error != NULL) {
        *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                     code:9
                                 userInfo:@{ NSLocalizedDescriptionKey: detail ?: @"installApplication 失败" }];
    }
    return result;
}

// ── 【N9 调试轮】installd 回环探针（纯诊断零行为变更）────────────────────
// 动机：N9 双轨制修复后（commit 3736209）prepare 细目 e 段仍为
// install=xpcError，5 次尝试确定性复现，而 installd 的 XPC 从未被单独
// 验证过（pe_smoke probe 只测 containerd；installApplication 是第一次
// 真实使用）。本探针用零自定义对象载荷的纯 BOOL 回环方法
//（applicationInstalledWithBundleID——LDEApplicationWorkspaceProxyProtocol.h:33，
// daemon 侧 LDEApplicationWorkspaceInternal.m:317-324 查 bundles 字典
// reply(YES/NO)，查询不存在 id 回 NO 零副作用）单变量隔离层级：
// 回环 OK→连接层健康→失败在 install 载荷层（ArchiveObject/fd/解码）；
// 回环错误/超时→连接层失效（与载荷无关）。

+ (NSString *)probeInstalldRoundTripWithError:(NSString **)error
{
    if (error != NULL) {
        *error = nil;
    }

    // connect：与 installApplicationAtPath 同款形态（endpoint → XPC 连接），
    // 独立临时连接（不缓存不复用 prepareGuestRun 的连接——探针只读诊断，
    // 不驻留不污染既有消费链），observer=nil（连接不驻留语义同
    // installApplicationAtPath 既有处理——daemon 侧单向回调派发到 nil
    // 导出对象无害）。
    NSXPCConnection *connection = nil;
    PELaunchServiceRegistry *registry = [PELaunchServiceRegistry shared];
    if (registry != nil) {
        connection = [registry connectToService:@"com.wanwo.installd"
                                       protocol:@protocol(LDEApplicationWorkspaceProxyProtocol)
                                       observer:nil
                               observerProtocol:@protocol(NSObject)];
    }
    if (connection == nil) {
        if (error != NULL) {
            *error = @"XPC 连接不可达（PEBootstrapRegistry endpoint 缺失——installd daemon 未起？pe_smoke mode=status）";
        }
        return @"installd 回环连接失败（无连接——连接层失效）";
    }

    __block BOOL replied = NO;
    __block BOOL replyResult = NO;
    __block NSString *xpcErrorText = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    id proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *err) {
        /* semaphores remember the signal, it doesnt have to catch them in time（官方注释同款） */
        xpcErrorText = err.localizedDescription ?: [err description];
        dispatch_semaphore_signal(sema);
    }];

    if (proxy == NULL)
    {
        /* semaphores remember the signal, it doesnt have to catch them in time（官方同款分支） */
        dispatch_semaphore_signal(sema);
    }
    else
    {
        [proxy applicationInstalledWithBundleID:@"com.wanwo.probe.nonexistent" withReply:^(BOOL replyValue) {
            replied = YES;
            replyResult = replyValue;
            dispatch_semaphore_signal(sema);
        }];
    }

    // 2s 超时与 installApplicationAtPath 同值（官方硬编码 vendored :117 同源）。
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));

    // 三态判定（+连接失败/代理创建失败防御态——报告行直译给 PESmoke）。
    if (replied) {
        if (!replyResult) {
            // 预期形态：probe id 不存在 → daemon 查 bundles 字典回 NO。
            return @"installd 回环 OK（reply=NO）——连接层健康，失败在 install 载荷层（ArchiveObject/fd/解码）";
        }
        // 意外形态：probe id 不应存在（如实报告原值，不吞异常）。
        return @"installd 回环 OK（reply=YES——意外：probe id com.wanwo.probe.nonexistent 不应存在，如实上报）";
    }
    if (xpcErrorText != nil) {
        if (error != NULL) {
            *error = xpcErrorText;
        }
        return [NSString stringWithFormat:@"installd 回环 XPC 错误：%@——连接层失效（与载荷无关）", xpcErrorText];
    }
    if (proxy == NULL) {
        if (error != NULL) {
            *error = @"remoteObjectProxy 创建失败";
        }
        return @"installd 回环失败（remoteObjectProxy 创建失败——连接层失效）";
    }
    if (error != NULL) {
        *error = @"2s XPC 超时（无 reply 无错误回调）";
    }
    return @"installd 回环超时";
}

@end
