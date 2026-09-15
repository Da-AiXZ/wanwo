//
//  PlayerOffload.m
//  WanWo
//
//  【WanWo 降级桩 · B1c 批】源=OpenMinis src/ios/NativeOffloads/PlayerOffload.m
//  （全文 327 行）+ PlayerOffloadBridge.swift（全文 445 行）。**未 vendored**，
//  降级裁定（简报 B1c 规则③"无等价物或成本大→NOT_AVAILABLE 降级+报告标注
//  待用户拍板是否立项；禁止自创实现"）：
//
//  原件语义：play/pause/resume/seek/status/stop/list 七子命令。ObjC handler
//  本身自包含，但其全部实际能力都在 PlayerOffloadBridge，而该桥深度绑定
//  OpenMinis App 层三件：
//    · GlobalAudioPlayer（音频会话宿主，WanWo 无此组件）；
//    · MinisAudioPreviewView / MinisVideoFullscreenPlayer（SwiftUI 播放视图，
//      play 成功后向用户呈现播放器 UI 的唯一面，WanWo 无等价物）；
//    · BackgroundKeepAliveManager.suspendSilentAudioForMedia/resume…
//      （静音保活挂起面；WanWo 的 BackgroundKeepAlive（m5 B4）无该 API，
//      形态不同）。
//  三个依赖都属 App UI/媒体层立项面——适配它们=自创实现（禁）。评估成本已
//  写进 B1c 报告（需先移植 GlobalAudioPlayer + 两播放视图 + 保活 API 对齐，
//  属独立 UI 批次）。降级路径照 ffmpeg 先例（B1b 授权）：注册真命令名 +
//  guest stub 保 PATH 解析，handler 恒回 NOT_AVAILABLE envelope。
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "WanWoOffloadGate.h"   // 【终验补】B1c 桩走 wanwo_offload_register_checked——B1c 漏带门控头（CI 实证 SessionsOffload.m:46 隐式声明错，同族四处一并补）
#include "kernel/native_offload.h"
#include <unistd.h>

// ── WanWo M6.1 增（B1c）：降级 handler（ffmpeg 先例同款形态）──
// OpenMinis 原件的七子命令分发面本批整体不引入（依赖 App 层播放栈，见头注
// 裁定）。--compact/-q flag 解析从简——无播放栈本就无产物，标准 envelope
// 形态即可。
static int player_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)argc; (void)argv; (void)stdin_fd;
    NSDictionary *err = noff_json_error(@"apple-player", @"player", NOFF_ERR_NOT_AVAILABLE,
        @"apple-player is unavailable in this build: the host playback stack "
        "(GlobalAudioPlayer / player views) has not been ported to WanWo yet.");
    noff_emit_json(stdout_fd, err, NO, NO);
    return NOFF_EXIT_NOT_AVAILABLE;
}

void player_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("apple-player", player_handler);
    if (err == 0) {
        // 降级路径（B1b ffmpeg 先例）：补 guest stub 使 `apple-player` 可被
        // PATH 解析命中（否则 command not found，错误语义劣化），由 handler
        // 回 NOT_AVAILABLE envelope。
        noff_ensure_guest_stub("/usr/local/bin/apple-player");
        NSLog(@"WanWoOffload: apple-player handler registered (downgrade: playback stack not ported)");
    } else {
        NSLog(@"WanWoOffload: failed to register apple-player handler (err=%d)", err);
    }
}
