//
//  OpenOffload.m
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/OpenOffload.m
//   全文 130 行，语义 1:1。适配点（简报 B1b，其余逐行 1:1）：
//   ①头注释 MinisApp→WanWo；②open_offload_register()：
//   native_offload_add_handler→wanwo_offload_register_checked（权限门控
//   trampoline，10-design:818 v2）；③NSLog 前缀『NativeOffloads:』→
//   『WanWoOffload:』；④文案/路径 Minis→WanWo、/var/minis→/var/wanwo
//   （如有）。GCD 队列标签 com.openminis.* 保留原样（内部标识符，
//   不在授权适配点内）——见 B1b 报告。】
//
//  Native offload handler for `apple-open`.
//  Opens URLs, URL schemes, and system settings via UIApplication.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#import "WanWoOffloadGate.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-open";

static NSString *const HELP_TEXT =
    @"apple-open - Open URLs, apps, and system settings\n"
     "\n"
     "USAGE:\n"
     "  apple-open <url>\n"
     "  apple-open settings[://page]\n"
     "\n"
     "ARGUMENTS:\n"
     "  <url>            URL to open (http, https, tel, mailto, sms, app schemes)\n"
     "  settings         Open iOS Settings app\n"
     "  settings://wifi  Open specific settings page\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-open \"https://example.com\"\n"
     "  apple-open \"tel:10086\"\n"
     "  apple-open \"mailto:user@example.com\"\n"
     "  apple-open settings\n"
     "  apple-open \"maps://?q=coffee\"\n";

// Map shorthand settings names to URL strings
static NSString *resolve_settings_url(NSString *input) {
    if ([input isEqualToString:@"settings"]) {
        return UIApplicationOpenSettingsURLString;
    }
    // settings://wifi → App-Prefs:root=WIFI (approximate; actual deep links vary by iOS version)
    // We use the standard openSettingsURLString which goes to our app's settings
    // For system-level deep links, the user can pass the full prefs: URL
    if ([input hasPrefix:@"settings://"]) {
        NSString *page = [input substringFromIndex:@"settings://".length];
        NSDictionary *map = @{
            @"wifi":          @"App-Prefs:root=WIFI",
            @"bluetooth":     @"App-Prefs:root=Bluetooth",
            @"notifications": @"App-Prefs:root=NOTIFICATIONS_ID",
            @"general":       @"App-Prefs:root=General",
            @"display":       @"App-Prefs:root=DISPLAY",
            @"sounds":        @"App-Prefs:root=Sounds",
            @"battery":       @"App-Prefs:root=BATTERY_USAGE",
            @"privacy":       @"App-Prefs:root=Privacy",
            @"cellular":      @"App-Prefs:root=MOBILE_DATA_SETTINGS_ID",
        };
        NSString *url = map[page.lowercaseString];
        return url ?: [NSString stringWithFormat:@"App-Prefs:root=%@", page];
    }
    return input;
}

static int open_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    // The URL is the first positional argument (subcommand position)
    NSString *urlArg = noff_get_subcommand(argc, argv);
    if (!urlArg) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No URL specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *resolvedURL = resolve_settings_url(urlArg);
    NSURL *url = [NSURL URLWithString:resolvedURL];
    if (!url) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Invalid URL: %@", urlArg]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(sem);
        }];
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSDictionary *data = @{
        @"url": urlArg,
        @"resolved_url": resolvedURL,
        @"opened": @(opened),
    };
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"open", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

void open_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("apple-open", open_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-open");
        NSLog(@"WanWoOffload: apple-open handler registered");
    } else {
        NSLog(@"WanWoOffload: failed to register apple-open handler (err=%d)", err);
    }
}
