//
//  DebugOffload.m
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/DebugOffload.m
//   全文 563 行，语义 1:1（B1c 批）】
//  `wanwo-debug` 原生 offload handler（OpenMinis minis-debug 改名，§8.2 #27）。
//  多数子命令（viewTree / search / inspect / ls / readFile / writeFile /
//  shellExecute / screenshot / snapshot / overlay）走进程内 DebugJSONRPC
//  分发器（iSH 内嵌同进程）且为 Debug-build-only（DebugLocalDispatch 在
//  Release 编译剔除）。
//  `logs` 子命令是例外：进程内读 App 自身运行日志（OSLogStore），不触碰
//  DebugLocalDispatch，Release 也可用（原件 T-ios-minis-debug-logs-oslogstore
//  语义）。
//  适配点（简报 B1c，共七处，其余逐行 1:1）：
//   1. 文件头注释 MinisApp → WanWo；
//   2. 注册名 minis-debug → wanwo-debug、DEBUG-only 挂测命令 minis-hangtest →
//      wanwo-hangtest（stub 路径同步），注册走 wanwo_offload_register_checked
//      （主命令；hangtest 保留原件 native_offload_add_handler 直连——
//      它是 signal-forward 测试桩，权限面无意义，且 B1b ffmpeg abort 同面）；
//   3. Swift 日志桥 NSClassFromString("MinisDebugLogReader") →
//      ("WanWoDebugLogReader")（桥随本批 vendored，OSLogStore 读 AppLogger
//      的 NSLog/os.log 输出）；
//   4. HELP_TEXT 与错误文案：minis-debug → wanwo-debug、/var/minis →
//      /var/wanwo（§十三.8 路径改名纪律）；
//   5. 错误域 "MinisDebugOffload" → "WanWoDebugOffload"；
//   6. NSLog 前缀 "NativeOffloads:" → "WanWoOffload:"；
//   7. #import "Minis-Swift.h" 守卫 → WanWo-Swift.h（本文件实际只经
//      NSClassFromString 动态触达 Swift 桥，头导入保留原件守卫形态）。
//  注：RPC 子命令依赖的 DebugLocalDispatch/DebugJSONRPC 分发器 WanWo 无等价物
//  （B1c 报告：评估为 UI 层立项面）——NSClassFromString 未命中即回原件的
//  合成 JSON-RPC 错误 envelope（Release 路径同款降级语义），不自创实现。
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "WanWoOffloadGate.h"   // 【终验补】B1c 直连件 register 走 wanwo_offload_register_checked——漏带门控声明头（同族扫尾统一补）
#if __has_include("WanWo-Swift.h")
#import "WanWo-Swift.h"
#endif
#include "kernel/native_offload.h"
#include <unistd.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

static NSString *const TOOL_NAME = @"wanwo-debug";

static NSString *const HELP_TEXT =
    @"wanwo-debug - Debug-build CLI for the in-app DebugJSONRPC dispatcher (in-process, no TCP)\n"
     "\n"
     "USAGE:\n"
     "  wanwo-debug <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  discover                              List every JSON-RPC method (rpc.discover)\n"
     "  viewTree [--maxDepth N]               Dump the live view hierarchy\n"
     "  search <keyword> [--scope all|text|type]\n"
     "                                        Search views by text or class\n"
     "  inspect <address>                     Inspect a view by hex address\n"
     "  highlight <address> [--color red] [--duration 2.0]\n"
     "                                        Flash a colored overlay on a view\n"
     "  trace [--last]                        Dump recorded agent traces\n"
     "  ls [path] [--recursive] [--maxDepth N]\n"
     "                                        List sandbox files (default: Documents)\n"
     "  read <path> [--offset N] [--limit N] [--base64]\n"
     "                                        Read a sandbox file\n"
     "  write <path> --content <text> [--encoding utf8|base64] [--mode 0644]\n"
     "                                        Write a sandbox file\n"
     "  exec <command...>                     Run a shell command via DebugServer\n"
     "  screenshot [--scale N]                Capture a screenshot (returns PNG base64)\n"
     "  snapshot <list|get|clear|enable|disable> [--type markdown|messageList] [--id X]\n"
     "                                        Manage in-memory snapshot ring buffers\n"
     "  overlay <enable|disable|mode> [--mode all|byType|byTypePrefix|byAddress] [--type X] [--address X]\n"
     "                                        Control the debug-overlay layer\n"
     "  logs [--last N] [--minutes N] [--grep <keyword>]\n"
     "                                        Read the app's own runtime log (OSLogStore).\n"
     "                                        Works in RELEASE builds.\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h        Show this help message\n"
     "  --compact         Minimize JSON output\n"
     "  -q, --quiet       Output only the data field\n"
     "\n"
     "EXAMPLES:\n"
     "  wanwo-debug discover\n"
     "  wanwo-debug viewTree --maxDepth 4\n"
     "  wanwo-debug search Chat --scope type\n"
     "  wanwo-debug inspect 0x10abc1234\n"
     "  wanwo-debug highlight 0x10abc1234 --color green --duration 1.5\n"
     "  wanwo-debug ls /var/wanwo/attachments\n"
     "  wanwo-debug read /var/wanwo/log.txt --limit 4096\n"
     "  wanwo-debug exec ls -la /var/wanwo\n"
     "  wanwo-debug snapshot list --type markdown\n"
     "  wanwo-debug overlay mode --mode byTypePrefix --type Selectable\n"
     "  wanwo-debug logs --grep StopDiag --last 50\n"
     "  wanwo-debug logs --minutes 5 --grep RetryDiag\n";

#pragma mark - Arg helpers (shared by all subcommands, incl. Release-safe `logs`)

/// Pick up the first non-flag argument after the subcommand (positional[1]).
static NSString *_Nullable second_positional(int argc, char **argv) {
    NSArray<NSString *> *pos = noff_positional_args(argc, argv);
    return pos.count >= 2 ? pos[1] : nil;
}

/// Build NSNumber from a --flag string; nil if absent.
static NSNumber *_Nullable opt_int(int argc, char **argv, const char *name) {
    NSString *v = noff_find_arg(argc, argv, name);
    if (!v) return nil;
    return @(v.integerValue);
}

static NSNumber *_Nullable opt_double(int argc, char **argv, const char *name) {
    NSString *v = noff_find_arg(argc, argv, name);
    if (!v) return nil;
    return @(v.doubleValue);
}

#pragma mark - logs (Release-safe, in-process — no DebugLocalDispatch)

/// Read the app's own runtime log via the Swift WanWoDebugLogReader bridge
/// (OSLogStore). Unlike every other subcommand this does NOT route through
/// DebugLocalDispatch, so it works in Release builds.
static int cmd_logs(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    Class reader = NSClassFromString(@"WanWoDebugLogReader");
    if (!reader) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"logs", NOFF_ERR_INTERNAL_ERROR,
                                             @"WanWoDebugLogReader bridge unavailable");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id shared = [reader performSelector:@selector(sharedInstance)];
    SEL sel = @selector(readLogsJSONWithLastN:minutes:grep:);
    if (!shared || ![shared respondsToSelector:sel]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"logs", NOFF_ERR_INTERNAL_ERROR,
                                             @"WanWoDebugLogReader.readLogsJSON missing");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSNumber *last = opt_int(argc, argv, "--last");
    NSNumber *minutes = opt_int(argc, argv, "--minutes");
    NSString *grep = noff_find_arg(argc, argv, "--grep");

    NSInteger lastN = last ? last.integerValue : 0;
    NSInteger minutesN = minutes ? minutes.integerValue : 0;

    NSString *(*imp)(id, SEL, NSInteger, NSInteger, NSString *) =
        (NSString *(*)(id, SEL, NSInteger, NSInteger, NSString *))[shared methodForSelector:sel];
    NSString *json = imp(shared, sel, lastN, minutesN, grep) ?: @"{}";

    // The bridge returns a JSON string; parse it back so emit wraps the
    // structured result in the standard noff envelope (matches emit_rpc shape).
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
    id result = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{@"raw": json};

    NSDictionary *env = noff_json_envelope(TOOL_NAME, @"logs", result);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

#if DEBUG

#pragma mark - In-process JSON-RPC dispatch (DEBUG only)

/// Invoke the in-process DebugJSONRPC dispatcher via the Swift bridge.
/// Returns the response body as a JSON string. Never nil — on bridge failure
/// returns a synthetic JSON-RPC error envelope so callers always get JSON.
/// 【WanWo 适配注】WanWo 未移植 DebugLocalDispatch（App 层立项面，见 B1c 报告）
/// ——NSClassFromString 未命中即走本函数原件的合成错误 envelope，语义与原件
/// Release 构建同款。
static NSString *dispatch_local_rpc(NSString *envelopeJSON) {
    Class bridge = NSClassFromString(@"DebugLocalDispatch");
    if (!bridge) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch unavailable (Release build?)\"}}";
    }
    id shared = [bridge performSelector:@selector(sharedInstance)];
    if (!shared) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch.shared nil\"}}";
    }
    SEL sel = @selector(dispatchWithEnvelopeJSON:);
    if (![shared respondsToSelector:sel]) {
        return @"{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"DebugLocalDispatch.dispatch missing\"}}";
    }
    NSString *(*imp)(id, SEL, NSString *) =
        (NSString *(*)(id, SEL, NSString *))[shared methodForSelector:sel];
    return imp(shared, sel, envelopeJSON) ?: @"";
}

#pragma mark - JSON-RPC invocation

/// Build a JSON-RPC envelope { jsonrpc, id, method, params } and dispatch it
/// in-process. Returns the parsed response dict (with `result` or `error`).
static NSDictionary *_Nullable call_rpc(NSString *method, NSDictionary *params, NSError **outError) {
    NSDictionary *envelope = @{
        @"jsonrpc": @"2.0",
        @"id": @1,
        @"method": method,
        @"params": params ?: @{},
    };
    NSError *encErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&encErr];
    if (!bodyData) {
        if (outError) *outError = encErr;
        return nil;
    }
    NSString *bodyStr = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    NSString *resp = dispatch_local_rpc(bodyStr);

    NSError *parseErr = nil;
    NSData *respData = [resp dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&parseErr];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"WanWoDebugOffload"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"unexpected RPC response: %@", resp]}];
        }
        return nil;
    }
    return (NSDictionary *)parsed;
}

/// Emit either the RPC result or RPC error as a noff envelope.
static int emit_rpc(int stdout_fd, int stderr_fd, NSString *action,
                     NSString *method, NSDictionary *params,
                     BOOL compact, BOOL quiet) {
    NSError *err = nil;
    NSDictionary *resp = call_rpc(method, params, &err);
    if (!resp) {
        NSDictionary *errEnv = noff_json_error(TOOL_NAME, action,
                                                NOFF_ERR_INTERNAL_ERROR,
                                                err.localizedDescription ?: @"RPC dispatch failed");
        noff_emit_json(stdout_fd, errEnv, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    if (resp[@"error"]) {
        NSDictionary *errEnv = noff_json_error(TOOL_NAME, action,
                                                NOFF_ERR_INTERNAL_ERROR,
                                                [NSString stringWithFormat:@"%@", resp[@"error"]]);
        noff_emit_json(stdout_fd, errEnv, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id result = resp[@"result"] ?: @{};
    NSDictionary *env = noff_json_envelope(TOOL_NAME, action, result);
    noff_emit_json(stdout_fd, env, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

#pragma mark - Subcommand dispatch (DEBUG-only, RPC-backed)

static int cmd_discover(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    return emit_rpc(stdout_fd, stderr_fd, @"discover", @"rpc.discover", @{}, compact, quiet);
}

static int cmd_viewTree(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSNumber *md = opt_int(argc, argv, "--maxDepth");
    if (md) params[@"maxDepth"] = md;
    return emit_rpc(stdout_fd, stderr_fd, @"viewTree", @"debug.viewTree", params, compact, quiet);
}

static int cmd_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *kw = second_positional(argc, argv);
    if (!kw) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search", NOFF_ERR_INVALID_ARGS,
                                             @"search requires a keyword. Usage: wanwo-debug search <keyword> [--scope all|text|type]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"keyword": kw} mutableCopy];
    NSString *scope = noff_find_arg(argc, argv, "--scope");
    if (scope) params[@"scope"] = scope;
    return emit_rpc(stdout_fd, stderr_fd, @"search", @"debug.search", params, compact, quiet);
}

static int cmd_inspect(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *addr = second_positional(argc, argv);
    if (!addr) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"inspect", NOFF_ERR_INVALID_ARGS,
                                             @"inspect requires a view address. Usage: wanwo-debug inspect <address>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd, @"inspect", @"debug.inspect", @{@"address": addr}, compact, quiet);
}

static int cmd_highlight(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *addr = second_positional(argc, argv);
    if (!addr) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"highlight", NOFF_ERR_INVALID_ARGS,
                                             @"highlight requires a view address. Usage: wanwo-debug highlight <address>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"address": addr} mutableCopy];
    NSString *color = noff_find_arg(argc, argv, "--color");
    if (color) params[@"color"] = color;
    NSNumber *dur = opt_double(argc, argv, "--duration");
    if (dur) params[@"duration"] = dur;
    return emit_rpc(stdout_fd, stderr_fd, @"highlight", @"debug.highlight", params, compact, quiet);
}

static int cmd_trace(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (noff_has_flag(argc, argv, "--last")) params[@"last"] = @YES;
    return emit_rpc(stdout_fd, stderr_fd, @"trace", @"debug.agentTrace", params, compact, quiet);
}

static int cmd_ls(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (path) params[@"path"] = path;
    if (noff_has_flag(argc, argv, "--recursive")) params[@"recursive"] = @YES;
    NSNumber *md = opt_int(argc, argv, "--maxDepth");
    if (md) params[@"maxDepth"] = md;
    return emit_rpc(stdout_fd, stderr_fd, @"ls", @"debug.ls", params, compact, quiet);
}

static int cmd_read(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    if (!path) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"read", NOFF_ERR_INVALID_ARGS,
                                             @"read requires a path. Usage: wanwo-debug read <path> [--offset N] [--limit N] [--base64]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"path": path} mutableCopy];
    NSNumber *off = opt_int(argc, argv, "--offset");
    if (off) params[@"offset"] = off;
    NSNumber *lim = opt_int(argc, argv, "--limit");
    if (lim) params[@"limit"] = lim;
    if (noff_has_flag(argc, argv, "--base64")) params[@"base64"] = @YES;
    return emit_rpc(stdout_fd, stderr_fd, @"read", @"debug.readFile", params, compact, quiet);
}

static int cmd_write(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *path = second_positional(argc, argv);
    if (!path) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"write", NOFF_ERR_INVALID_ARGS,
                                             @"write requires a path. Usage: wanwo-debug write <path> --content <text> [--encoding utf8|base64] [--mode 0644]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *content = noff_find_arg(argc, argv, "--content");
    if (!content) content = noff_read_stdin(stdin_fd);
    if (!content) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"write", NOFF_ERR_INVALID_ARGS,
                                             @"write requires --content <text> or stdin.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *params = [@{@"path": path, @"content": content} mutableCopy];
    NSString *enc = noff_find_arg(argc, argv, "--encoding");
    if (enc) params[@"encoding"] = enc;
    NSString *mode = noff_find_arg(argc, argv, "--mode");
    if (mode) params[@"mode"] = mode;
    return emit_rpc(stdout_fd, stderr_fd, @"write", @"debug.writeFile", params, compact, quiet);
}

static int cmd_exec(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSArray<NSString *> *pos = noff_positional_args(argc, argv);
    if (pos.count < 2) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"exec", NOFF_ERR_INVALID_ARGS,
                                             @"exec requires a command. Usage: wanwo-debug exec <command...>");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSArray *args = [pos subarrayWithRange:NSMakeRange(1, pos.count - 1)];
    NSString *cmd = [args componentsJoinedByString:@" "];
    return emit_rpc(stdout_fd, stderr_fd, @"exec", @"debug.shellExecute", @{@"command": cmd}, compact, quiet);
}

static int cmd_screenshot(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSNumber *scale = opt_double(argc, argv, "--scale");
    if (scale) params[@"scale"] = scale;
    return emit_rpc(stdout_fd, stderr_fd, @"screenshot", @"debug.screenshot", params, compact, quiet);
}

static int cmd_snapshot(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *sub = second_positional(argc, argv);
    if (!sub) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snapshot", NOFF_ERR_INVALID_ARGS,
                                             @"snapshot requires a subcommand. Usage: wanwo-debug snapshot <list|get|clear|enable|disable> [--type markdown|messageList] [--id X]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *type = noff_find_arg(argc, argv, "--type") ?: @"markdown";
    NSString *base = [type isEqualToString:@"messageList"]
        ? @"debug.messageListSnapshot"
        : @"debug.markdownSnapshot";

    NSString *method = nil;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([sub isEqualToString:@"enable"]) {
        method = [base stringByAppendingString:@".setEnabled"];
        params[@"enabled"] = @YES;
    } else if ([sub isEqualToString:@"disable"]) {
        method = [base stringByAppendingString:@".setEnabled"];
        params[@"enabled"] = @NO;
    } else if ([sub isEqualToString:@"list"]) {
        method = [base stringByAppendingString:@".list"];
    } else if ([sub isEqualToString:@"get"]) {
        method = [base stringByAppendingString:@".get"];
        NSString *sid = noff_find_arg(argc, argv, "--id");
        if (sid) params[@"id"] = sid;
    } else if ([sub isEqualToString:@"clear"]) {
        method = [base stringByAppendingString:@".clear"];
    } else {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"snapshot", NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"unknown snapshot subcommand '%@'. Valid: list|get|clear|enable|disable", sub]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd,
                     [NSString stringWithFormat:@"snapshot.%@", sub],
                     method, params, compact, quiet);
}

static int cmd_overlay(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *sub = second_positional(argc, argv);
    if (!sub) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"overlay", NOFF_ERR_INVALID_ARGS,
                                             @"overlay requires a subcommand. Usage: wanwo-debug overlay <enable|disable|mode> [--mode all|byType|byTypePrefix|byAddress] [--type X] [--address X]");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *method = nil;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([sub isEqualToString:@"enable"]) {
        method = @"debug.debugOverlay.setEnabled";
        params[@"enabled"] = @YES;
    } else if ([sub isEqualToString:@"disable"]) {
        method = @"debug.debugOverlay.setEnabled";
        params[@"enabled"] = @NO;
    } else if ([sub isEqualToString:@"mode"]) {
        method = @"debug.debugOverlay.setMode";
        NSString *mode = noff_find_arg(argc, argv, "--mode");
        if (mode) params[@"mode"] = mode;
        NSString *type = noff_find_arg(argc, argv, "--type");
        if (type) params[@"type"] = type;
        NSString *addr = noff_find_arg(argc, argv, "--address");
        if (addr) params[@"address"] = addr;
    } else {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"overlay", NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"unknown overlay subcommand '%@'. Valid: enable|disable|mode", sub]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    return emit_rpc(stdout_fd, stderr_fd,
                     [NSString stringWithFormat:@"overlay.%@", sub],
                     method, params, compact, quiet);
}

#endif /* DEBUG — RPC-backed subcommands */

#pragma mark - Top-level handler

static int debug_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // logs is Release-safe (in-process OSLogStore read, no RPC).
    if ([subcmd isEqualToString:@"logs"])       return cmd_logs(argc, argv, stdout_fd, stderr_fd, compact, quiet);

#if DEBUG
    if ([subcmd isEqualToString:@"discover"])   return cmd_discover(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"viewTree"])   return cmd_viewTree(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"search"])     return cmd_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"inspect"])    return cmd_inspect(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"highlight"])  return cmd_highlight(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"trace"])      return cmd_trace(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"ls"])         return cmd_ls(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"read"])       return cmd_read(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"write"])      return cmd_write(argc, argv, stdin_fd, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"exec"])       return cmd_exec(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"screenshot"]) return cmd_screenshot(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"snapshot"])   return cmd_snapshot(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"overlay"])    return cmd_overlay(argc, argv, stdout_fd, stderr_fd, compact, quiet);
#else
    // Release build: every RPC-backed subcommand is compiled out. Tell the
    // user which path is available instead of a bare "unknown command".
    {
        static NSString *const kRpcCmds = @"discover viewTree search inspect highlight trace ls read write exec screenshot snapshot overlay";
        if ([kRpcCmds containsString:subcmd]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR,
                [NSString stringWithFormat:@"'%@' requires a Debug build (DebugLocalDispatch is compiled out in Release). Only 'logs' works in Release builds.", subcmd]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
    }
#endif

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Use --help for valid commands.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

#if DEBUG
// [T-ish-offload-signal-forward] Deliberately-wedged offload, for verifying the
// signal-forwarding path without having to wedge a real ffmpeg transcode.
//
// Reproduces the exact failure shape: the handler never returns on its own, so
// the guest task can never reach do_exit() and `kill` has nothing that will
// look at the signal queue. With the abort callback registered, a terminating
// signal releases the wait and the guest process exits — which is the whole
// behaviour under test.
static atomic_bool g_hangtest_abort = ATOMIC_VAR_INIT(false);

static bool hangtest_abort_requested(int sig) {
    atomic_store_explicit(&g_hangtest_abort, true, memory_order_release);
    NSLog(@"[HangTest] abort requested by signal %d", sig);
    return true;
}

static int hangtest_handler(int argc, char **argv,
                            int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)argc; (void)argv; (void)stdin_fd; (void)stderr_fd;
    atomic_store_explicit(&g_hangtest_abort, false, memory_order_release);
    const char *msg = "wanwo-hangtest: wedged; send a signal to abort\n";
    if (stdout_fd >= 0) (void) write(stdout_fd, msg, strlen(msg));
    NSLog(@"[HangTest] handler entered — will block until aborted");

    // Bounded at 10 minutes purely so a forgotten test process cannot pin a
    // guest task forever; the real exit is the abort flag.
    for (int i = 0; i < 600 * 50; i++) {
        if (atomic_load_explicit(&g_hangtest_abort, memory_order_acquire)) {
            NSLog(@"[HangTest] abort observed — returning so the guest task can exit");
            const char *done = "wanwo-hangtest: aborted\n";
            if (stdout_fd >= 0) (void) write(stdout_fd, done, strlen(done));
            return 0;
        }
        usleep(20 * 1000);
    }
    NSLog(@"[HangTest] safety timeout reached without an abort");
    return 1;
}
#endif

void debug_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("wanwo-debug", debug_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/wanwo-debug");
        NSLog(@"WanWoOffload: wanwo-debug handler registered (logs available in all builds; RPC subcommands DEBUG-only)");
    } else {
        NSLog(@"WanWoOffload: failed to register wanwo-debug handler (err=%d)", err);
    }

#if DEBUG
    // 【适配点 2】挂测命令 minis-hangtest → wanwo-hangtest（改名纪律）；
    // 保留原件 native_offload_add_handler 直连——signal-forward 测试桩，
    // 权限门控对其无意义（OpenMinis 原件同款直连）。
    if (native_offload_add_handler("wanwo-hangtest", hangtest_handler) == 0) {
        noff_ensure_guest_stub("/usr/local/bin/wanwo-hangtest");
        native_offload_set_abort_handler("wanwo-hangtest", hangtest_abort_requested);
        NSLog(@"WanWoOffload: wanwo-hangtest handler registered (DEBUG only)");
    }
#endif
}
