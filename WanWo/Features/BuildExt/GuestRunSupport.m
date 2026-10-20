//
//  GuestRunSupport.m
//  WanWo
//
//  【N9a · guest 签名与安装链 · 万我层 ObjC 薄壳】实现——语义出处见头注释。
//  万我自有代码，零 vendored 改动（登记 docs/gpl-compliance.md §N9）。
//

#import "GuestRunSupport.h"
#import <LindChain/LiveContainer/LCMachOUtils.h>
#import <LindChain/LiveContainer/ZSign/zsigner.h>
#import <LindChain/ProcEnvironment/Surface/trust.h>
#import <LindChain/ProcEnvironment/Process/PELaunchServiceRegistry.h>
#import <LindChain/ProcEnvironment/Object/ArchiveObject.h>
#import <LindChain/Services/applicationmgmtd/LDEApplicationWorkspace.h>
#import <LindChain/Services/applicationmgmtd/LDEApplicationWorkspaceProtocol.h>

NSErrorDomain const WanWoGuestRunErrorDomain = @"com.wanwo.guestrun";

// 【N9 调试轮二分探针】判别查询目标 id（testapp 工程真实 bundle id——
// Config/Project.plist NXBundleIdentifier，历轮 build_and_run 目标工程）。
NSString * const WanWoGuestProbeTestAppBundleID = @"com.wanwo.testapp";

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

// ── 【N9 装后通知层修复（L2 实锤轮）】installd 装后广播 observer ──────────
// 官方宿主侧 observer=LDEApplicationWorkspace（0.10.3
// LDEApplicationWorkspace.m:361-373——两回调 dispatch_async 主队列转
// ApplicationManagementViewController UI 呈现）。万我没有应用管理 UI 呈现
// 层，语义对齐官方宿主侧 observer 但去掉 UI：两方法 no-op + NSLog 调试行。
// 协议方法清单全文核对（LDEApplicationWorkspaceProtocol.h:27-32）：
// 仅 applicationWasInstalled:/applicationWithBundleIdentifierWasUninstalled:
// 两方法——全部实现，无遗漏（NSXPCConnection 导出面要求导出对象实现导出
// 协议全部方法，否则运行期 doesNotRecognizeSelector 风险）。
// 解码机制判定（白名单 hook 不需要的证据，本轮判定依据）：
// 官方 0.10.3 全仓 ResecureDecoder() 调用点仅 LiveProcess appex main.m:265
//（grep 实证）——官方宿主 App（Nyxian target）从未调用，但其宿主侧 observer
//（LDEApplicationWorkspace，observer:self + exportedInterface=
// LDEApplicationWorkspaceProtocol，LDEApplicationWorkspace.m:71）正常接收
// applicationWasInstalled:(LDEApplicationObject*) 广播（官方应用管理列表
// 机制，0.10.3 用户实测可用）——即协议方法签名内的自定义类
//（LDEApplicationObject 在 applicationWasInstalled: 参数位）经
// NSXPCInterface 从协议方法签名自动放行解码，无需 ResecureDecoder 白名单
// hook。与上轮 FDObject 跨进程解码实证（FDObject 在 PEContainerProtocol
// 方法签名内自动放行）同机制。故本轮零 vendored diff（ResecureDecoder.m
// 不改、宿主编译面不加），仅修导出面。
@implementation WanWoGuestInstallObserver

+ (instancetype)sharedObserver
{
    static WanWoGuestInstallObserver *sharedObserver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedObserver = [[WanWoGuestInstallObserver alloc] init];
    });
    return sharedObserver;
}

// 官方 LDEApplicationWorkspace.m:361-366 宿主侧回调等义（去 UI 呈现层）：
// 广播到达本身即连接健康的证明——记调试行供 klog/控制台侧事后审读。
- (void)applicationWasInstalled:(LDEApplicationObject *)app
{
    NSLog(@"[WanWoGuestInstallObserver] applicationWasInstalled: %@ (%@)",
          app.bundleIdentifier, app.bundlePath);
}

// 官方 LDEApplicationWorkspace.m:368-373 宿主侧回调等义（去 UI 呈现层）。
- (void)applicationWithBundleIdentifierWasUninstalled:(NSString *)bundleIdentifier
{
    NSLog(@"[WanWoGuestInstallObserver] applicationWithBundleIdentifierWasUninstalled: %@",
          bundleIdentifier);
}

@end

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
    // observer 挂 WanWoGuestInstallObserver（【N9 装后通知层修复（L2 实锤
    // 轮）】——原 observer=nil + exportedInterface=NSObject 空协议形态死因：
    // daemon installApplicationWithPayloadPath: 装完在方法内广播
    // applicationWasInstalled:(LDEApplicationObject*)（vendored
    // LDEApplicationWorkspaceInternal.m:280-283）后才回 YES，广播选择器不在
    // 导出面 → 连接当场失效 → reply 回执丢失 → host 错误回调 xpcError；
    // 官方宿主 LDEApplicationWorkspace.m:71 observer:self 同构——导出面=
    // LDEApplicationWorkspaceProtocol，广播经协议方法签名自动放行解码）。
    NSXPCConnection *connection = nil;
    PELaunchServiceRegistry *registry = [PELaunchServiceRegistry shared];
    if (registry != nil) {
        connection = [registry connectToService:@"com.wanwo.installd"
                                       protocol:@protocol(LDEApplicationWorkspaceProxyProtocol)
                                       observer:[WanWoGuestInstallObserver sharedObserver]
                               observerProtocol:@protocol(LDEApplicationWorkspaceProtocol)];
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

// ── 【N9 调试轮二分探针】installd 装载状态查询（纯诊断零行为变更）────────
// 动机：N9 双轨制修复后（commit 3736209）prepare 细目 e 段仍为
// install=xpcError，5 次尝试确定性复现。上一轮回环探针（6a3da26）实证
// installd 的 XPC 连接层健康（纯 BOOL 回环 reply=NO 干净返回），失败钉死
// 在 install 的 ArchiveObject 载荷层——载荷层再二分为两个候选：
//   · L1：ArchiveObject+fd 解码失败于 daemon（fileport_makefd 在 uid=1 的
//     installd 内行为异常）→ guest 从未被安装 → 修 fd 传输/解码层。
//   · L2：install 实际成功、死在装后通知（daemon 广播
//     applicationWasInstalled:(LDEApplicationObject*) 给 observer=nil
//     连接 + 宿主无 ResecureDecoder 白名单（appex-only，main.m:265）→
//     解码失败 → 连接失效 → reply 丢失 → host 侧 xpcError）→ 修通知层。
// 判别法：用工程真实 bundle id（com.wanwo.testapp）调
// applicationInstalledWithBundleID:withReply: 查 daemon 侧 bundles 字典
//（LDEApplicationWorkspaceInternal.m:317-324）——YES=L2 实锤 / NO=L1 实锤。
// 实现共用 static 查询函数（bundleId 参数化，文件内私有——不入 Swift
// 导出面，避开导入器剪枝雷区）；两条公开薄壳方法选择器形状与已实证可
// 导入的回环探针同构（首段全并入基名 + NSString** 尾参）。

static NSString *WanWoGuestProbeInstalldQuery(NSString *bundleID, NSString **error)
{
    if (error != NULL) {
        *error = nil;
    }
    if (bundleID.length == 0) {
        if (error != NULL) {
            *error = @"probe bundle id 为空";
        }
        return @"installd 查询失败（bundle id 入参为空——连接层未测）";
    }

    // 判别线（testapp）用「installd 查询 <id> → …」格式；回环线
    //（nonexistent）保留既有报告文案（既有逻辑保留——逐字不动）。
    BOOL isTestappProbe = [bundleID isEqualToString:WanWoGuestProbeTestAppBundleID];

    // connect：与 installApplicationAtPath 同款形态（endpoint → XPC 连接），
    // 独立临时连接（不缓存不复用 prepareGuestRun 的连接——探针只读诊断，
    // 不驻留不污染既有消费链）；observer 挂 WanWoGuestInstallObserver
    //（【N9 装后通知层修复（L2 实锤轮）】统一修——daemon
    // clientDidConnectWithConnection:（vendored
    // LDEApplicationWorkspaceInternal.m:575-587）对每个新连接广播已有
    // bundles，observer=nil 形态下探针连接一建立即收 LDEApplicationObject
    // 广播（testapp 历轮已装、bundles 非空）——此前探针靠「纯 BOOL reply
    // 先于广播失效到达」时序侥幸存活，本轮统一挂 observer 后不再依赖该
    // 时序（这也正是「回环探针 OK 但 install 死」时序差异的成因之一：
    // install 的广播在方法内先于 reply 发出）。
    NSXPCConnection *connection = nil;
    PELaunchServiceRegistry *registry = [PELaunchServiceRegistry shared];
    if (registry != nil) {
        connection = [registry connectToService:@"com.wanwo.installd"
                                       protocol:@protocol(LDEApplicationWorkspaceProxyProtocol)
                                       observer:[WanWoGuestInstallObserver sharedObserver]
                               observerProtocol:@protocol(LDEApplicationWorkspaceProtocol)];
    }
    if (connection == nil) {
        if (error != NULL) {
            *error = @"XPC 连接不可达（PEBootstrapRegistry endpoint 缺失——installd daemon 未起？pe_smoke mode=status）";
        }
        if (isTestappProbe) {
            return [NSString stringWithFormat:@"installd 查询 %@ → 连接失败（无连接——连接层未测）", bundleID];
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
        [proxy applicationInstalledWithBundleID:bundleID withReply:^(BOOL replyValue) {
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
            if (isTestappProbe) {
                // L1 实锤：daemon 侧 bundles 字典无此 id——guest 从未装上。
                return [NSString stringWithFormat:@"installd 查询 %@ → NO——L1 实锤：guest 从未被安装（ArchiveObject+fd 解码失败于 daemon——fileport_makefd@uid=1 行为异常；修 fd 传输/解码层）", bundleID];
            }
            // 预期形态：probe id 不存在 → daemon 查 bundles 字典回 NO。
            return @"installd 回环 OK（reply=NO）——连接层健康，失败在 install 载荷层（ArchiveObject/fd/解码）";
        }
        if (isTestappProbe) {
            // L2 轮实锤形态：install 实际成功——装后通知层已修复（observer+
            // 导出面），本查询转常态健康指标（YES=guest 已在 daemon 侧注册）。
            return [NSString stringWithFormat:@"installd 查询 %@ → YES——guest 已在 daemon 侧注册（N9 判别轮 L2 实锤形态：install 本体成功；装后通知层已修复——observer+导出面，本查询为常态健康指标）", bundleID];
        }
        // 意外形态：probe id 不应存在（如实报告原值，不吞异常）。
        return @"installd 回环 OK（reply=YES——意外：probe id com.wanwo.probe.nonexistent 不应存在，如实上报）";
    }
    if (xpcErrorText != nil) {
        if (error != NULL) {
            *error = xpcErrorText;
        }
        if (isTestappProbe) {
            return [NSString stringWithFormat:@"installd 查询 %@ → 错误：%@（连接层态——不参与 L1/L2 判别）", bundleID, xpcErrorText];
        }
        return [NSString stringWithFormat:@"installd 回环 XPC 错误：%@——连接层失效（与载荷无关）", xpcErrorText];
    }
    if (proxy == NULL) {
        if (error != NULL) {
            *error = @"remoteObjectProxy 创建失败";
        }
        if (isTestappProbe) {
            return [NSString stringWithFormat:@"installd 查询 %@ → 失败（remoteObjectProxy 创建失败——连接层态）", bundleID];
        }
        return @"installd 回环失败（remoteObjectProxy 创建失败——连接层失效）";
    }
    if (error != NULL) {
        *error = @"2s XPC 超时（无 reply 无错误回调）";
    }
    if (isTestappProbe) {
        return [NSString stringWithFormat:@"installd 查询 %@ → 超时（无 reply 无错误回调——连接层态）", bundleID];
    }
    return @"installd 回环超时";
}

+ (NSString *)probeInstalldRoundTripWithError:(NSString **)error
{
    return WanWoGuestProbeInstalldQuery(@"com.wanwo.probe.nonexistent", error);
}

+ (NSString *)probeInstalldTestAppRoundTripWithError:(NSString **)error
{
    return WanWoGuestProbeInstalldQuery(WanWoGuestProbeTestAppBundleID, error);
}

// ── 【N10c · utility 签名编排薄壳】官方 LCUtils.signMachOAtURL 等义 ─────
// 语义出处见头注释（官方 .run utility 签名段 Builder.swift:358-364 的
// signBinaryAtPath 展开形态——LCUtils.m:102-131 逐段对照）。

+ (BOOL)patchGuestExecutableOnlyAtPath:(NSString *)machoPath
                                 error:(NSError **)error
{
    if (machoPath.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"补片入参缺失（macho path 为空）" }];
        }
        return NO;
    }

    __block NSError *patchError = nil;

    // 官方形态照抄（LCUtils.m:107-113）：LCParseMachO 回调内 cputype 门 +
    // LCPatchExecSlice(path, header, YES)。readOnly=false（官方同参——补片要写回）。
    // utility 无 bundle：不调 LCPatchAppBundleFixupARM64eSlice（官方单 macho
    // 形态无此段）。
    NSString *parseError = LCParseMachO(machoPath.UTF8String, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype != CPU_TYPE_ARM64 ||
            LCPatchExecSlice(path, header, YES) != 0) {
            patchError = WanWoGuestRunUnsupportedFormatError();
        }
    });

    if (parseError != nil && patchError == nil) {
        // 官方同语义：解析层错误归一为 unsupported executable format（LCUtils.m:115-118）
        patchError = WanWoGuestRunUnsupportedFormatError();
    }

    if (patchError != nil) {
        if (error != NULL) {
            *error = patchError;
        }
        return NO;
    }

    return YES;
}

+ (BOOL)signUtilityMachOAtPath:(NSString *)machoPath
                           prov:(NSData *)prov
                            key:(NSData *)key
                           pass:(NSString *)pass
                          error:(NSError **)error
{
    if (machoPath.length == 0 || prov == nil || key == nil || pass == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"utility 签名入参缺失（macho path / prov / key / pass）" }];
        }
        return NO;
    }

    // 官方同款调用（LCUtils.m:130）：ZSigner.signMachOAtPath(prov:key:pass:)
    // ——单 macho ZSign 签名（万我双轨制同 app 运行路线：prov=宿主 embedded
    // profile、私钥=用户导入 p12+密码；wanwo_setHostIdentityOverride 为
    // bundle 身份覆写开关，单 macho 无 bundle 面，不参与）。
    BOOL ok = [ZSigner signMachOAtPath:machoPath prov:prov key:key pass:pass];
    if (!ok && error != NULL) {
        *error = [NSError errorWithDomain:WanWoGuestRunErrorDomain
                                     code:10
                                 userInfo:@{ NSLocalizedDescriptionKey: @"signMachOAtPath 失败（单 macho ZSign 签名——官方 LCUtils.signMachOAtURL 签名段等义；核对 p12/密码）" }];
    }
    return ok;
}

@end
