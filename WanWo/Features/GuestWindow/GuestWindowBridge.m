//
//  GuestWindowBridge.m
//  WanWo
//
//  【N10b · NXWindowServer 独立 UIWindow 宿主薄壳】实现——语义出处见头注释
//  （docs/gpl-compliance.md §N10）。万我自有代码，零 vendored 改动。
//

#import "GuestWindowBridge.h"

#import <LindChain/WindowServer/NXWindowServer.h>
#import <LindChain/WindowServer/Session/NXWindowSessionTerminal.h>

#import <objc/runtime.h>

// 单例激活态标记（进程内一次——ensureActivated 置位）：NXWindowServer +shared
// 内部实现是 sharedWithWindowScene:nil（NXWindowServer.m 无 scene 懒创建形
// 态）——永不返回 nil，直接调 shared 会在 ensureActivated 之前以无 scene 形
// 态创建单例（dispatch_once 已消耗 → 之后 sharedWithWindowScene: 真实 scene
// 也拿不回，windowScene 恒 nil → openWindow 恒败）。本文件全部 shared 消费
// 点先查本标记，未激活一律不触碰 [NXWindowServer shared]。
static BOOL wanwoServerActivated = NO;

// ── 【N10d · A1】window 级 hitTest 透传（万我层对 vendored NXWindowServer
//    的运行时方法覆盖——零 vendored 源码 diff，登记 docs/gpl-compliance.md
//    §N10「A1 运行时方法覆盖」小节）────────────────────────────────────
// 根因：NXWindowServer 本身是全屏 UIWindow（背景透明），UIView 级 hitTest
// 默认「点在 bounds 内 + 子视图无人认领 → 返回窗口自身」= 吞整屏触摸——
// 官方 NXWindowLayerView.hitTest（NXWindowServer.m:31-37）只保护 _windowLayer
// 子视图层，window 自身无同等保护。官方单窗口形态天然无此问题（主界面就是
// NXWindowServer 本体）；万我双 UIWindow 形态下主 SwiftUI 窗口在下层，
// NXWindowServer 持 key 时整屏触摸被吞=关不掉的浮窗态。
//
// ⚠️ swizzle 形态雷区：hitTest:withEvent: 是 UIView 的方法且 NXWindowServer
// **未重写**它——method_exchangeImplementations(class_getInstanceMethod(...))
// 会拿到继承链上 UIView 的 Method，交换会污染所有 UIView（灾难性）。正确
// 形态：进程内一次（dispatch_once）取 originalImp = method_getImplementation
// (class_getInstanceMethod([NXWindowServer class], sel))（此时为 UIView 实现），
// 然后 class_addMethod 在 NXWindowServer 本类挂万我 IMP 覆盖——万我 IMP 内部
// 直接调用 originalImp 后按 NXWindowLayerView 同款语义返回（hit==self→nil）。
// 对类的方法表生效与实例创建时序无关；+load 在首个 NXWindowServer 实例消费
// 前运行（ObjC 运行时装载早于任何 UI 装配）。
//
// 边界核验（N10d 施工规格）：全屏态 maximize（NXWindowServer.m:842-873
// windowWantsToMaximize 把 NXWindow.view 直挂 self）——super 命中
// NXWindow.view（非 self）照常认领，不受影响；长按手势仅 iPhone 且 iOS<26
// 挂载（NXWindowServer.m:304-329），iPad 主路径无手势影响。
static void wanwoInstallWindowServerHitTestOverride(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL sel = @selector(hitTest:withEvent:);
        Method method = class_getInstanceMethod([NXWindowServer class], sel);
        if (method == NULL)
        {
            NSLog(@"[WanWo][GuestWindowBridge] A1 hitTest override skipped: "
                  @"hitTest:withEvent: not found on NXWindowServer（异常态——UIView 链必有其实现）");
            return;
        }
        IMP originalImp = method_getImplementation(method);
        const char *typeEncoding = method_getTypeEncoding(method);
        IMP overrideImp = imp_implementationWithBlock(
            ^UIView *(id receiver, CGPoint point, UIEvent *event) {
                UIView *hit = ((UIView * (*)(id, SEL, CGPoint, UIEvent *))originalImp)(
                    receiver, @selector(hitTest:withEvent:), point, event);
                return (hit == receiver) ? nil : hit;
            });
        BOOL added = class_addMethod([NXWindowServer class], sel, overrideImp, typeEncoding);
        if (!added)
        {
            // 理论不发生（NXWindowServer 未重写 hitTest——方法不在本类）。
            // 若发生（未来 vendored 版本自行实现了 hitTest）：退回直接覆盖
            // 形态（originalImp 已先取=本类原实现，语义等价 exchange）并报告。
            method_setImplementation(method, overrideImp);
            NSLog(@"[WanWo][GuestWindowBridge] A1 hitTest override: class_addMethod "
                  @"returned NO（NXWindowServer 自身已实现 hitTest？）——已退回 "
                  @"method_setImplementation 覆盖形态，请核对 vendored 版本变更");
        }
    });
}

@implementation GuestWindowBridge

// A1 覆盖安装（进程内一次——+load 时点早于任何 NXWindowServer 实例创建）。
+ (void)load
{
    wanwoInstallWindowServerHitTestOverride();
}

// foregroundActive UIWindowScene（双 UIWindow 共用同一 scene——设计说明见
// 头注释；次选任意 UIWindowScene 兜底，避免多 scene 形态下取不到）。
+ (UIWindowScene *)wanwoForegroundScene
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive)
        {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if ([scene isKindOfClass:[UIWindowScene class]])
        {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

+ (NSString *)ensureActivated
{
    NSAssert([NSThread isMainThread], @"GuestWindowBridge.ensureActivated 必须在主线程（UIWindow 纪律）");

    UIWindowScene *scene = [self wanwoForegroundScene];
    if (scene == nil)
    {
        return @"NXWindowServer 未初始化（无可用 UIWindowScene——App 前台态异常）";
    }

    // 官方工厂单例（NXWindowServer.m:87-95 dispatch_once；幂等——重复调用
    // 返回既有单例，hasInitialized 异常守卫不触发）。
    NXWindowServer *server = [NXWindowServer sharedWithWindowScene:scene];
    wanwoServerActivated = YES;

    // makeKeyAndVisible 仅首次（官方 App 启动同款单次语义——NXWindowServer.m:
    // 304-329 内部 addSubview(_windowLayer) + 长按手势，重复调用会叠加手势）。
    static BOOL madeKeyAndVisible = NO;
    if (!madeKeyAndVisible)
    {
        if (server.windowScene == nil)
        {
            return @"NXWindowServer 单例已被无 scene 形态懒创建（windowScene=nil——"
                   @"openWindow 将恒败；重启 App 恢复。正常流不应出现：首个 guest run "
                   @"前本方法已以 scene 初始化）";
        }
        [server makeKeyAndVisible];
        madeKeyAndVisible = YES;
        return @"NXWindowServer 已激活（独立 UIWindow——首次 makeKeyAndVisible，键窗语义见 §N10 设计说明）";
    }
    if (server.isHidden)
    {
        server.hidden = NO;
    }
    return @"NXWindowServer 已在位（可见）";
}

+ (void)ensureActivatedSync
{
    if ([NSThread isMainThread])
    {
        [self ensureActivated];
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        [GuestWindowBridge ensureActivated];
    });
}

+ (void)showGuestOverlay
{
    // 未激活直接静默返回（[NXWindowServer shared] 会以无 scene 形态懒创建
    // 单例——见文件头 wanwoServerActivated 注记；懒创建=死局，禁触发）。
    if (!wanwoServerActivated)
    {
        return;
    }
    NXWindowServer *server = [NXWindowServer shared];
    server.hidden = NO;
    [server makeKeyAndVisible];
}

+ (void)hideGuestOverlay
{
    // 同 showGuestOverlay：未激活不触碰单例。
    if (!wanwoServerActivated)
    {
        return;
    }
    NXWindowServer *server = [NXWindowServer shared];
    server.hidden = YES;
    // 把 key 归还 SwiftUI 主窗口（键盘输入回归主界面——设计说明「键窗语义」）。
    UIWindowScene *scene = [self wanwoForegroundScene];
    for (UIWindow *window in scene.windows)
    {
        if (![window isKindOfClass:[NXWindowServer class]])
        {
            [window makeKeyAndVisible];
            break;
        }
    }
}

+ (BOOL)openUtilityTerminalWithPath:(NSString *)utilityPath
                         processOut:(PEProcess **)processOut
                            noteOut:(NSString **)noteOut
{
    NSAssert([NSThread isMainThread], @"GuestWindowBridge.openUtilityTerminalWithPath 必须在主线程");

    if (processOut != NULL)
    {
        *processOut = nil;
    }
    if (noteOut != NULL)
    {
        *noteOut = nil;
    }
    if (utilityPath.length == 0)
    {
        if (noteOut != NULL)
        {
            *noteOut = @"utility path 为空";
        }
        return NO;
    }

    // 幂等激活（首次调用完成 sharedWithWindowScene + makeKeyAndVisible——
    // openWindow 产出的 NXWindow 需 _windowLayer 在位才可见）。
    NSString *activateNote = [self ensureActivated];

    // 激活失败（无可用 scene）=单例仍处于未创建态——此时禁触碰
    // [NXWindowServer shared]（无 scene 懒创建死局，见文件头注记），
    // 带激活失败注记直接失败返回。
    if (!wanwoServerActivated)
    {
        if (noteOut != NULL)
        {
            *noteOut = [NSString stringWithFormat:@"NXWindowServer 未激活（无 scene）——开窗中止；%@",
                        activateNote];
        }
        return NO;
    }

    // 官方 Builder.swift:367-370 逐段对齐：
    //   NXWindowSessionTerminal(utilityPath:) → NXWindowServer.shared()
    //   .openWindow(with:withCompletion:)——openWindow 内部（vendored 官方
    //   原样）：TTY 分配+termios → FDMapObject 三路 SLAVEFD 映射 →
    //   utilityHomePath → spawnProcessWithItems(PEExecutablePath=fastpath
    //   路径) → tty_attach_proc → TerminalViewObjC(MASTERFD)。
    NXWindowSessionTerminal *terminal =
        [[NXWindowSessionTerminal alloc] initWithUtilityPath:utilityPath];
    [[NXWindowServer shared] openWindowWithSession:terminal withCompletion:nil];

    PEProcess *process = terminal.process;
    if (process == nil)
    {
        if (noteOut != NULL)
        {
            *noteOut = [NSString stringWithFormat:@"openWindow 后无 PEProcess"
                       @"（TTY 分配/spawn/fastpath 路径失败；%@）", activateNote];
        }
        return NO;
    }

    if (processOut != NULL)
    {
        *processOut = process;
    }
    if (noteOut != NULL)
    {
        *noteOut = [NSString stringWithFormat:@"utility=%@ pid=%d window=%lu（%@；"
                    @"终端窗口关闭=进程 terminate——官方 closeWindow 同款）",
                    [utilityPath lastPathComponent], process.pid,
                    (unsigned long)terminal.windowIdentifier, activateNote];
    }
    return YES;
}

// ── 【N10d · A2】生命周期收尾：窗口清空时隐藏 + 归还键窗 ───────────────
// 残留机制（首轮真机实证）：hideGuestOverlay 全树零调用点 → guest 退出/关窗
// 后 NXWindowServer 常驻 visible+key → 主界面触摸/审批卡全被吞（A1 修触摸
// 穿透后此残留仍会持 key 挡键盘输入）→ 本方法在 guest 退出收尾点统一判定
// windows.count==0 时隐藏+归还 key。
// 竞态说明：官方进程退出关窗走 processDidExit 内 dispatch_async(main) 异步
// 链（PEProcess.m:286-294），退出回调同步段之后窗口可能仍在关闭途中——调用
// 方传 delay 余量（如 1.0s）防「窗口尚在」误判跳过隐藏。主队列 FIFO 保证
// 本判定排在官方 closeWindow dispatch 之后。
+ (void)hideGuestOverlayIfNoWindowsAfterDelay:(NSTimeInterval)delay
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!wanwoServerActivated)
        {
            return;
        }
        NXWindowServer *server = [NXWindowServer shared];
        if (server.windows.count == 0)
        {
            [GuestWindowBridge hideGuestOverlay];
        }
    });
}

+ (void)hideGuestOverlayIfNoWindows
{
    [self hideGuestOverlayIfNoWindowsAfterDelay:0.0];
}

@end
