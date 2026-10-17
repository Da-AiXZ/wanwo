/*
 XCButtonCompat — 万我 N3b 环境适配层（非官方 Nyxian 代码）
 见 XCButtonCompat.h 头注。
*/

#import "XCButtonCompat.h"

NSNotificationName const WANWOBootstrapProgressNotification = @"com.wanwo.bootstrap.progress";
NSNotificationName const WANWOBootstrapIconNotification = @"com.wanwo.bootstrap.icon";

static double _wanwoBootstrapProgress = 0.0;
static NSString * _Nullable _wanwoBootstrapIcon = nil;

@implementation XCButton

+ (instancetype)shared
{
    /* 官方形态为单例视图；万我无对应 UI，Compat 层无实体可返回。
     * NXBootstrap 不消费 shared，仅为接口完整性保留。 */
    static XCButton *token = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        token = [[XCButton alloc] initWithFrame:CGRectZero];
    });
    return token;
}

+ (void)updateProgressWithValue:(double)value
{
    _wanwoBootstrapProgress = value;
    [[NSNotificationCenter defaultCenter] postNotificationName:WANWOBootstrapProgressNotification
                                                        object:nil
                                                      userInfo:@{ @"value": @(value) }];
}

+ (void)incrementProgressWithValue:(double)value
{
    [self updateProgressWithValue:_wanwoBootstrapProgress + value];
}

+ (void)resetProgress
{
    [self updateProgressWithValue:0.0];
}

+ (double)getProgress
{
    return _wanwoBootstrapProgress;
}

+ (void)switchImageWithSystemName:(NSString*)systemName animated:(BOOL)animated withDuration:(double)duration
{
    _wanwoBootstrapIcon = systemName;
    [[NSNotificationCenter defaultCenter] postNotificationName:WANWOBootstrapIconNotification
                                                        object:nil
                                                      userInfo:@{ @"systemName": systemName,
                                                                  @"animated": @(animated),
                                                                  @"duration": @(duration) }];
}

+ (void)switchImageWithSystemName:(NSString*)systemName animated:(BOOL)animated
{
    [self switchImageWithSystemName:systemName animated:animated withDuration:0.25];
}

/* UIView 子类无实际视图职责（init 私有用途，见 shared）。 */
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    return self;
}

@end
