//
//  GuestWindowBridge.h
//  WanWo
//
//  【N10b · NXWindowServer 独立 UIWindow 宿主薄壳（拍板项 2）】万我自有
//  ObjC 薄壳（非 vendored——零 vendored 改动声明见 docs/gpl-compliance.md
//  §N10）。动机：官方工厂 sharedWithWindowScene:/openWindowWithSession:
//  的 Swift 导入名不可静态确定（万我导入器剪枝雷区纪律——
//  GuestRunSupport.h 选择器纪律同款），全部跨语言调用收拢本薄壳固定形态。
//
//  设计说明（双 UIWindow 并存语义——拍板项 2 方案 A）：
//    官方 0.10.3 的主界面本身就是 NXWindowServer（UIWindow 子类，桌面式
//    窗口管理器——NXWindowServer.m 995 行：windows 字典/windowOrder/
//    appSwitcher/presentationState/手势全套），官方在 App 启动时
//    initWithWindowScene: 绑定宿主 scene 并 makeKeyAndVisible。万我主界面
//    是自己的 SwiftUI（WindowGroup 主窗口），采用独立 UIWindow 形态：
//    NXWindowServer 以【同一 UIWindowScene】初始化为第二个 UIWindow，零
//    vendored 改动，与 SwiftUI 主窗口并存：
//      · 初始化（ensureActivated，进程内一次）：sharedWithWindowScene:
//        单例（NXWindowServer.m:87-95 dispatch_once + :52 hasInitialized
//        异常守卫）+ makeKeyAndVisible（官方同款入口——NXWindowServer.m:
//        304-329，内部挂 _windowLayer 与 iPhone 长按手势；单次调用防手势
//        重复叠加）。
//      · 触摸穿透（N10d 修正——首轮真机实证双案 A）：仅 NXWindowLayerView
//        的 hitTest 对自身返回 nil（NXWindowServer.m:31-37）不够——
//        NXWindowServer 本身是全屏 UIWindow，UIView 级 hitTest 默认「点在
//        bounds 内+子视图无人认领→返回窗口自身」=吞整屏触摸（背景透明故
//        渲染正常、触摸全被吞）。修法=A1 window 级 hitTest 透传（本文件
//        +load 内对 NXWindowServer 的 hitTest:withEvent: 做万我层覆盖：
//        原实现命中自身时改返 nil——NXWindowLayerView 同款逻辑提到
//        window 级；零 vendored 源码 diff，登记 docs/gpl-compliance.md
//        §N10「A1 运行时方法覆盖」小节）。
//      · 键窗语义：makeKeyAndVisible 后 NXWindowServer 持 key——guest 终端
//        （TerminalViewObjC becomeFirstResponder）需要 key window 才能弹
//        键盘；这是官方单窗口形态天然自洽、万我双窗口需真机验证的点
//        （N10d 验收项 / N10 方案 §三 1）。hideGuestOverlay 提供归还 key
//        的显式出口（工具卡消费的呈现/隐藏切换接口——拍板项 3 配套）。
//    app 路线的窗口叠加是自动的：vendored PEProcess（零 diff）
//    scene:didCompleteUpdateWithContext:（PEProcess.m:243-267）在 guest
//    FBScene 到达时 dispatch_once 创建 NXWindowSessionApplication 并
//    openWindowWithSession——官方 Builder.swift:321-349 .run app 段同语义
//    （FDMapObject 管道照旧 + 窗口会话叠加；进程退出自动关窗
//    PEProcess.m:286-294）。万我侧唯一时序义务：NXWindowServer 必须先于
//    spawn 以真实 scene 初始化（若先经 [NXWindowServer shared] 无 scene
//    形态懒创建，windowScene 恒 nil → session openWindow 恒败，NXWindow
//    永不出现）。
//    utility 路线（N10c）：openUtilityTerminalWithPath 官方 Builder.swift:
//    367-370 同语义——NXWindowSessionTerminal initWithUtilityPath →
//    NXWindowServer openWindowWithSession（openWindow 内部：TTY 分配 +
//    termios + 三路 SLAVEFD 映射 + spawn + tty_attach_proc +
//    TerminalViewObjC——vendored 官方原样消费）。终端窗口关闭=进程
//    terminate（官方 closeWindow 同款）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <LindChain/ProcEnvironment/Process/PEProcess.h>

NS_ASSUME_NONNULL_BEGIN

@interface GuestWindowBridge : NSObject

/// 主线程调用：NXWindowServer 单例以 foregroundActive scene 初始化（幂等，
/// dispatch_once）+ 首次 makeKeyAndVisible。返回状态注记（Swift 侧直显）。
+ (NSString *)ensureActivated;

/// ensureActivated 的任意线程形态（主线程直调；后台线程 dispatch_sync
/// 主队列——GuestRunService.spawnRun 专用队列的 spawn 前调用点）。
+ (void)ensureActivatedSync;

/// 窗口层显隐切换（工具卡消费的呈现/隐藏接口——设计说明见文件头）。
/// show：窗口可见 + makeKey（不重复 makeKeyAndVisible——防手势叠加）。
/// hide：窗口隐藏 + 把 key 归还 SwiftUI 主窗口（键盘输入回归主界面）。
+ (void)showGuestOverlay;
+ (void)hideGuestOverlay;

/// 【N10d · A2 生命周期收尾】窗口清空判定隐藏：NXWindowServer.windows 为空
/// （guest 全部退出/关窗——官方 PEProcess 进程退出自动关窗链已收束）时调
/// hideGuestOverlay（隐藏 NXWindowServer 本体 + 归还 key）——防 guest 退出
/// 后 NXWindowServer 常驻 key 吞主界面触摸/审批卡的残留缺陷收口（原
/// hideGuestOverlay 全树零调用点）。任意线程可调（内部 dispatch 主队列）。
/// @param delay 判定前的主队列延迟秒数——official closeWindow 走
/// processDidExit 内 dispatch_async(main) 的异步链（PEProcess.m:286-294），
/// 退出回调同步段之后窗口可能仍在关闭途中，调用方传 >0 的余量（如 1.0s）
/// 防竞态误判「窗口尚在」跳过隐藏。
+ (void)hideGuestOverlayIfNoWindowsAfterDelay:(NSTimeInterval)delay;

/// 上式的零延迟便捷形态（窗口关闭链已确认收束的调用点用）。
+ (void)hideGuestOverlayIfNoWindows;

/// 【N10c】utility 终端开窗（主线程调用）：ensureActivated →
/// NXWindowSessionTerminal initWithUtilityPath → NXWindowServer
/// openWindowWithSession（官方 Builder.swift:367-370 同语义；openWindow
/// 内部 spawn + TTY 三映射 + TerminalViewObjC）。返回 YES 时 processOut
/// 填终端 spawn 出的 PEProcess（stop_build 接线登记用——BuildTools 挂
/// exitingCallback 包装注销），noteOut 填注记；NO 时 noteOut 填失败浅因。
+ (BOOL)openUtilityTerminalWithPath:(NSString *)utilityPath
                         processOut:(PEProcess **)processOut
                            noteOut:(NSString **)noteOut;

@end

NS_ASSUME_NONNULL_END
