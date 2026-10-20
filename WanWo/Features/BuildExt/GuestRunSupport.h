//
//  GuestRunSupport.h
//  WanWo
//
//  【N9a · guest 签名与安装链 · 万我层 ObjC 薄壳】万我自有代码（非 vendored——
//  零 vendored 改动声明见 docs/gpl-compliance.md §N9）。作用：把 LC 官方
//  .run 签名链里 C 回调形态的 MachO 补片函数（block 回调不便 Swift 直调）
//  与 trust 层 NXTR token 追加封装成 Swift 友好的 ObjC 接口。
//
//  官方语义出处（0.10.3 快照 _nyxian_probe/0.10.3/Nyxian-0.10.3/）：
//    · 可执行补片：LCUtils.signAppBundleWithZSign 补片段
//      （Nyxian/LindChain/LiveContainer/LCUtils.m:57-100）——
//      LCParseMachO(macho, false, callback){ cputype==CPU_TYPE_ARM64 且
//      LCPatchExecSlice(path, header, YES)==0 }（MH_EXECUTE→MH_DYLIB 补片）
//      + LCPatchAppBundleFixupARM64eSlice(bundleURL)（arm64e
//      CPU_SUBTYPE_LIB64 修正）。
//    · token 追加：macho_after_sign（Nyxian/LindChain/ProcEnvironment/
//      Surface/trust.c:212-276）——cdhash→entitlement_token_mach_gen
//      （宿主 ksurface EC key 自签，ksurface_kinit N8 起随万我启动在位）
//      →token blob+长度+APPEND_TAG 追加 macho EOF（幂等：重签先剥旧
//      token）。【必须在 ZSign 之后调用】——token 绑定签名后 cdhash，
//      签名重写 CodeDirectory 会使先追加的 token 失效（官方顺序
//      sign→token，Builder.swift:301-307 照抄）。
//    · entitlement 位图来源：官方 NXEntitlementsConfig.entitlement
//      （0.10.3 LindChain/Project/NXProject.h:52-54 + NXProject.m:137-163，
//      Config/Entitlements.plist 布尔键→PEEntitlement 位）——万我 vendored
//      NXProject.h 的该属性已随 §N4N5 适配删除（N4 实测空引用），位图
//      映射在万我层等义重建（键名=万我出 scaffold 的 com.wanwo.build.*
//      常量 + 官方 com.nyxian.pe.* 别名双收，默认值语义逐键照抄官方）。
//

#import <Foundation/Foundation.h>
#import <LindChain/ProcEnvironment/Surface/entitlement.h>
#import <LindChain/Services/applicationmgmtd/LDEApplicationWorkspaceProtocol.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WanWoGuestRunErrorDomain;

/// 【N9 调试轮二分探针】判别查询目标 id——testapp 工程真实 bundle id
///（历轮 build_and_run 目标工程，Config/Project.plist
/// NXBundleIdentifier=com.wanwo.testapp）。L1/L2 判别语义见
/// probeInstalldTestAppRoundTripWithError: 与 docs/gpl-compliance.md §N9。
FOUNDATION_EXPORT NSString * const WanWoGuestProbeTestAppBundleID;

/// 【N9 装后通知层修复（L2 实锤轮）】installd 装后广播 observer（万我自有
/// ObjC 类，非 vendored——登记 docs/gpl-compliance.md §N9）。语义出处：
/// 官方宿主侧 observer = LDEApplicationWorkspace（0.10.3
/// LDEApplicationWorkspace.m:361-373 applicationWasInstalled:/…WasUninstalled:
/// → ApplicationManagementViewController UI 呈现）——万我没有应用管理 UI
/// 呈现层，两方法实现为 no-op + NSLog 调试行（协议方法清单全文核对：
/// LDEApplicationWorkspaceProtocol.h 仅此两方法）。
/// 存在动机（L2 实锤链）：daemon 侧 Service.m:66 对**每个新连接**无条件设
/// remoteObjectInterface=LDEApplicationWorkspaceProtocol 并在
/// clientDidConnectWithConnection:（LDEApplicationWorkspaceInternal.m:575-587）
/// 与 installApplicationWithPayloadPath: 内（:280-283）向全部 client 广播
/// applicationWasInstalled:(LDEApplicationObject*)——万我层连接此前
/// observer=nil（exportedObject=nil + exportedInterface=NSObject 空协议），
/// 广播选择器不在导出面 → NSXPCConnection 失效 → install 的 reply 回执丢失
/// → host 侧 xpcError（install 本体在 daemon 侧每次都成功——判别探针
/// YES 实锤）。挂本 observer 后导出面=LDEApplicationWorkspaceProtocol，
/// LDEApplicationObject 经协议方法签名自动放行解码（官方宿主从未调
/// ResecureDecoder() 仍正常收广播——同机制实证，无需白名单 hook）。
@interface WanWoGuestInstallObserver : NSObject <LDEApplicationWorkspaceProtocol>

/// 进程级单例（多条连接共用一份 no-op 导出对象——无状态，免每连新建）。
+ (instancetype)sharedObserver;

@end

/// 【N9d 诊断增强】installApplication 包装结果（vendored 版 BOOL 无法区分
/// reply(NO)/2s 超时/XPC 错误回调——诊断轮核心区分点）。
typedef NS_ENUM(NSInteger, WanWoGuestInstallResult) {
    WanWoGuestInstallInstalled    = 0,  ///< installd 回复 YES
    WanWoGuestInstallRejected     = 1,  ///< installd 回复 NO（信任校验/解压失败，非超时）
    WanWoGuestInstallTimeout      = 2,  ///< 2s semaphore 超时（无 reply 无错误回调）
    WanWoGuestInstallXPCError     = 3,  ///< remoteObjectProxyWithErrorHandler 触发（无 reply）
    WanWoGuestInstallNoConnection = 4,  ///< registry/endpoint/proxy 不可达
    WanWoGuestInstallInvalidInput = 5,  ///< 入参缺失 / ArchiveObject 构造失败
};

@interface GuestRunSupport : NSObject

/// 官方 LCUtils.signAppBundleWithZSign 补片段等义（LCUtils.m:57-100）：
/// 对 machoPath 做 LCPatchExecSlice（MH_EXECUTE→MH_DYLIB）+
/// 对 bundleURL 做 LCPatchAppBundleFixupARM64eSlice。失败返回 NO 并填 error
///（错误文案区分 cputype 不支持/补片失败/解析失败）。
+ (BOOL)patchGuestExecutableAtPath:(NSString *)machoPath
                         bundleURL:(NSURL *)bundleURL
                             error:(NSError **)error;

/// macho_after_sign 包装（trust.c:212-276 语义）：对已签名 macho 追加
/// NXTR entitlement token（ksurface 自签自验）。返回 NO = token 未追加
///（此时 guest spawn 链残废——entitlementForExecutableAtPath 读不到
/// token → proc_fork 无 entitlements → dyld 隐藏钩子族不激活）。
/// 选择器形态与 patchGuestExecutableAtPath 同构（动词+宾语+AtPath——
/// Swift 导入器对中缀 ToMachO 的剪枝不可预测，run 39368919449 实证）。
+ (BOOL)appendEntitlementTokenAtPath:(NSString *)machoPath
                         entitlement:(PEEntitlement)entitlement
                               error:(NSError **)error;

/// Config/Entitlements.plist 字典 → PEEntitlement 位图。官方
/// NXEntitlementsConfig.entitlement 实现等义（0.10.3 NXProject.m:137-163）：
/// 布尔键逐位映射，get-task-allow 缺省 YES、其余缺省 NO（官方
/// withDefaultValue 语义逐键照抄）。键名双收：万我 scaffold 出厂键
///（com.wanwo.build.*，Vendor/nyxian/LindChain/Utils/entitlement.c:35-71
/// 常量值）+ 官方 0.10.3 键（com.nyxian.pe.*，官方 NXProject.m:145-163）。
+ (uint64_t)entitlementBitsFromEntitlementsPlist:(nullable NSDictionary *)plist;

/// 【N9d 诊断增强→已回退 · CS_KILL 雷区】签名自查（纯诊断，不设门）：
/// 对指定 macho 执行官方 checkCodeSignature（LCMachOUtils.m:392-433——
/// F_ADDFILESIGS_RETURN + F_CHECK_LV，内核同款校验语义）。
/// ⚠️ **禁用于 F_ADDFILESIGS 后将被修改的文件**——同进程
/// F_ADDFILESIGS→改文件→mmap = 内核 CS_KILL Invalid Page（真机双闪退
/// 实证 2026-10-20，两份 .ips 同栈：cd_hash_of_executable_at_fd ←
/// macho_after_sign ← appendEntitlementTokenAtPath ← prepareGuestRun；
/// prepareGuestRun 内 S1/S2 调用点已全部移除——见 docs/gpl-compliance.md
/// §N9「S1/S2 回退」）。方法保留仅作语义封装，新调用点引入前必须复核
/// 该文件后续是否还会被同进程修改。
/// LCMachOUtils.h:45 已声明该全局函数——直接 #import 消费，无需前置
/// extern（LDEApplicationWorkspaceInternal.m:30 的前置声明先例属其编译
/// 单元无该头的情况）。
+ (BOOL)selfCheckCodeSignatureAtPath:(NSString *)path;

/// 【N9d 诊断增强】installApplication 诊断包装（万我层对公开 API 的消费，
/// 非 vendored 改动）：照 vendored LDEApplicationWorkspace
/// installApplicationAtBundlePath 官方形态等义重写（PELaunchServiceRegistry
/// connectToService + ArchiveObject objectForDirectoryAtPath +
/// remoteObjectProxyWithErrorHandler + 2s semaphore——vendored 版
/// WanWoLiveProcess/LindChain/Services/applicationmgmtd/LDEApplicationWorkspace.m
/// :91-119 逐行对照；差异仅三点：①连接不驻留（诊断包装每次新建——官方
/// 驻留 self.connection）②observer 挂 WanWoGuestInstallObserver
///（【N9 装后通知层修复（L2 实锤轮）】——原 observer=nil +
/// exportedInterface=NSObject 空协议形态在 daemon 装后广播
/// applicationWasInstalled:(LDEApplicationObject*)（
/// LDEApplicationWorkspaceInternal.m:280-283）时导出面无该选择器 →
/// NSXPCConnection 失效 → reply 回执丢失 → host 侧 xpcError（判别探针
/// YES 实锤 install 本体每次都成功）；现导出面=LDEApplicationWorkspaceProtocol
/// + 导出对象=no-op observer，广播可解码可投递、回执正常返回——官方宿主
/// LDEApplicationWorkspace.m:71 observer:self 同构）
/// ③返回枚举区分 installed/rejected/timeout/
/// xpcError/noConnection/invalidInput——vendored 版 2s 返回后统一
/// return result 无法区分 reply(NO) 与超时）。
/// 失败时 error 恒填浅因文案（成功为 nil）。
+ (WanWoGuestInstallResult)installApplicationAtPath:(NSString *)bundlePath
                                              error:(NSError **)error;

/// 【N9 调试轮 · installd 回环探针（纯诊断零行为变更）】install=xpcError
/// 层级钉死探针：对 com.wanwo.installd 调
/// LDEApplicationWorkspaceProxyProtocol.applicationInstalledWithBundleID:
///（官方源 :33——纯 BOOL 回环、零自定义对象载荷，对比
/// installApplicationWithArchiveObject 带 fd 载荷；daemon 侧实现
/// LDEApplicationWorkspaceInternal.m:317-324 查 bundles 字典→reply(YES/NO)，
/// 查询不存在 id 回 NO 零副作用）。probe id 恒取
/// com.wanwo.probe.nonexistent（不存在→预期 reply=NO）。
/// 连接形态与 installApplicationAtPath 同款（connectToService + 2s
/// semaphore + remoteObjectProxyWithErrorHandler），但独立临时连接
///（不缓存不复用 prepareGuestRun 连接）；observer 挂
/// WanWoGuestInstallObserver（【N9 装后通知层修复（L2 实锤轮）】——
/// daemon clientDidConnectWithConnection: 对每个新连接广播已有 bundles
///（LDEApplicationWorkspaceInternal.m:575-587），observer=nil 形态下探针
/// 连接一建立即收广播——此前靠「纯 BOOL reply 先于广播失效到达」时序
/// 侥幸存活；统一挂 observer 后不再依赖该时序，全部连 installd 的
/// 万我层连接导出面一致）。
/// 判定表：①reply 回来（预期 NO）=「installd 回环 OK（reply=NO）——
/// 连接层健康，失败在 install 载荷层（ArchiveObject/fd/解码）」
/// ②错误回调=「installd 回环 XPC 错误：<原文>——连接层失效（与载荷
/// 无关）」③2s 超时=「installd 回环超时」。
/// 返回值=报告行文本（PESmoke probe 直译输出）；error 出参填失败浅因
///（NSString 文本，成功/回环 OK 为 nil）——不用 NSError** 避免与
/// installApplicationAtPath 的六态枚举语义混淆（本探针只钉层级）。
+ (NSString *)probeInstalldRoundTripWithError:(NSString **)error;

/// 【N9 调试轮二分探针（纯诊断零行为变更）】L1/L2 判别查询：对
/// com.wanwo.installd 用工程真实 bundle id（WanWoGuestProbeTestAppBundleID
/// =com.wanwo.testapp）调 applicationInstalledWithBundleID:withReply:——
/// 回环探针（probeInstalldRoundTripWithError:）实证连接层健康、失败钉死在
/// install 载荷层之后，本查询用「guest 是否已在 daemon 侧注册」把载荷层
/// 再二分：
///   · reply=YES → **L2 实锤**：install 实际成功、死在装后通知
///    （daemon 广播 applicationWasInstalled: LDEApplicationObject 给
///     observer=nil 连接 + 宿主无 ResecureDecoder 白名单（appex-only，
///     main.m:265）→ 解码失败 → 连接失效 → reply 丢失 → host 侧 xpcError。
///     修复方向=通知层：给 install 包装连接配 observer/导出面，或扩白名单）。
///   · reply=NO → **L1 实锤**：guest 从未被安装（fileport_makefd 在 uid=1
///     的 installd 内行为异常 → ArchiveObject+fd 解码失败于 daemon →
///     方法进入前连接失效。修复方向=fd 传输/解码层）。
///   · 错误/超时/连接失败 → 连接层态（如实上报，不参与 L1/L2 判别）。
/// 连接形态与 probeInstalldRoundTripWithError: 完全同款（独立临时连接、
/// observer 挂 WanWoGuestInstallObserver——【N9 装后通知层修复（L2 实锤
/// 轮）】统一修，2s semaphore、remoteObjectProxyWithErrorHandler）；实现
/// 共用 .m 内 static 查询函数（bundleId 参数化，不入 Swift 导出面——避开
/// 导入器剪枝雷区，本探针方法选择器形状与已实证可导入的回环探针同构）。
/// 返回值=报告行文本（PESmoke probe 直译输出，格式
/// 「installd 查询 com.wanwo.testapp → YES/NO/错误：<原文>/超时」）；
/// error 出参填失败浅因（NSString 文本，同回环探针语义）。
+ (NSString *)probeInstalldTestAppRoundTripWithError:(NSString **)error;

/// 【N10c · utility 签名编排薄壳 ①】官方 LCUtils.signMachOAtURL 补片段等义
///（0.10.3 LCUtils.m:102-131 单 macho 形态——LCParseMachO 回调内 cputype 门
/// + LCPatchExecSlice(path, header, YES)；utility 无 .app bundle，故无
/// patchGuestExecutableAtPath:bundleURL: 形态的
/// LCPatchAppBundleFixupARM64eSlice 段）。官方 .run utility 签名段
///（Builder.swift:358-364）首步即此补片（signBinaryAtPath→signMachOAtURL）。
/// 失败返回 NO 并填 error（文案与 app 形态同源）。
+ (BOOL)patchGuestExecutableOnlyAtPath:(NSString *)machoPath
                                 error:(NSError **)error;

/// 【N10c · utility 签名编排薄壳 ②】官方 LCUtils.signMachOAtURL 签名段等义
///（LCUtils.m:126-130——ZSigner.signMachOAtPath + prov=宿主 embedded
/// profile + key/pass=用户导入 p12+密码（官方同构：LCUtils
/// certificateData/certificatePassword 同为用户导入形态）；单 macho 无
/// bundle 身份覆写面，wanwo_setHostIdentityOverride 不参与）。选择器形状
/// 与已实证可导入的 patchGuestExecutableAtPath 同构（动词+宾语+AtPath+
/// error——ZSigner.signMachOAtPath 直调的 Swift 导入名不可静态确定，
/// 导入器剪枝雷区纪律）。
+ (BOOL)signUtilityMachOAtPath:(NSString *)machoPath
                           prov:(NSData *)prov
                            key:(NSData *)key
                           pass:(NSString *)pass
                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
