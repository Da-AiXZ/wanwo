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

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WanWoGuestRunErrorDomain;

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
+ (BOOL)appendEntitlementTokenToMachOAtPath:(NSString *)machoPath
                                entitlement:(PEEntitlement)entitlement
                                      error:(NSError **)error;

/// Config/Entitlements.plist 字典 → PEEntitlement 位图。官方
/// NXEntitlementsConfig.entitlement 实现等义（0.10.3 NXProject.m:137-163）：
/// 布尔键逐位映射，get-task-allow 缺省 YES、其余缺省 NO（官方
/// withDefaultValue 语义逐键照抄）。键名双收：万我 scaffold 出厂键
///（com.wanwo.build.*，Vendor/nyxian/LindChain/Utils/entitlement.c:35-71
/// 常量值）+ 官方 0.10.3 键（com.nyxian.pe.*，官方 NXProject.m:145-163）。
+ (uint64_t)entitlementBitsFromEntitlementsPlist:(nullable NSDictionary *)plist;

@end

NS_ASSUME_NONNULL_END
