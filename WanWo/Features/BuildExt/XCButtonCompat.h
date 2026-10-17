/*
 XCButtonCompat — 万我 N3b 环境适配层（非官方 Nyxian 代码）

 用途：vendored NXBootstrap.m 引用官方 UI 层 <UI/XCodeButton.h> 的 XCButton
 类方法（进度/图标汇报）。万我主 App 尚无该 UI 层（N4/N5 接线），本壳提供
 同签名的类方法实现：以 NSNotificationCenter 广播（name=com.wanwo.bootstrap.
 progress / icon），万我 UI 后续（N4+）可监听渲染；当前无监听者时为安全
 no-op。接口面与官方 XCodeButton.h 逐一对齐（updateProgressWithValue /
 incrementProgressWithValue / resetProgress / getProgress /
 switchImageWithSystemName 两形态）。

 依据：docs/gpl-compliance.md §N3b 环境适配登记。
*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const WANWOBootstrapProgressNotification;
extern NSNotificationName const WANWOBootstrapIconNotification;

@interface XCButton : UIView

+ (instancetype)shared;

+ (void)updateProgressWithValue:(double)value;
+ (void)incrementProgressWithValue:(double)value;
+ (void)updateProgressIncrement:(double)value;
+ (void)resetProgress;
+ (double)getProgress;

+ (void)switchImageWithSystemName:(NSString*)systemName animated:(BOOL)animated withDuration:(double)duration;
+ (void)switchImageWithSystemName:(NSString*)systemName animated:(BOOL)animated;
+ (void)switchImageSyncWithSystemName:(NSString*)systemName animated:(BOOL)animated withDuration:(double)duration;
+ (void)switchImageSyncWithSystemName:(NSString*)systemName animated:(BOOL)animated;
+ (void)startSpinning;
+ (void)startSpinningWithArcFraction:(CGFloat)fraction duration:(CFTimeInterval)duration;
+ (void)stopSpinning;

@end

NS_ASSUME_NONNULL_END
