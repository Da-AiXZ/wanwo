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

// 单例激活态标记（进程内一次——ensureActivated 置位）：NXWindowServer +shared
// 内部实现是 sharedWithWindowScene:nil（NXWindowServer.m 无 scene 懒创建形
// 态）——永不返回 nil，直接调 shared 会在 ensureActivated 之前以无 scene 形
// 态创建单例（dispatch_once 已消耗 → 之后 sharedWithWindowScene: 真实 scene
// 也拿不回，windowScene 恒 nil → openWindow 恒败）。本文件全部 shared 消费
// 点先查本标记，未激活一律不触碰 [NXWindowServer shared]。
static BOOL wanwoServerActivated = NO;

@implementation GuestWindowBridge

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

@end
