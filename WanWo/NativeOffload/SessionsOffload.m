//
//  SessionsOffload.m
//  WanWo
//
//  【WanWo 降级桩 · B1c 批】源=OpenMinis src/ios/NativeOffloads/SessionsOffload.m
//  （全文 449 行）+ SessionsOffloadBridge.swift（全文 537 行）。**未 vendored**，
//  降级裁定（简报 B1c 规则③；原注册名 minis-sessions-cli → wanwo-sessions-cli）：
//
//  原件语义：list/search/messages（跨会话查询）+ send/retry/status/open
//  （跨会话操作/导航）。ObjC handler 自包含，但全部能力在
//  SessionsOffloadBridge，其绑定 OpenMinis ChatStore 会话面。WanWo 侧
//  摸底（简报 ②要求对 WanWo/WanWo/Storage/ 评估）：
//    · 查询半边（list/search/messages）**有形态等价物**：SessionStore
//      （listSessions 摘要）+ JSONL 事件流（JsonlEventLog/SessionWriter）——
//      但消息语义不同（WanWo 事件流为 dsh 风格 message/* 事件 + content
//      blocks），适配需新建事件→CLI 消息投影 + 跨会话关键词扫描面，成本
//      中高（估 1 个独立批次，复用 ConversationProjector 投影层可压缩）；
//    · 操作半边（send/retry）**无等价物**：WanWo 的 AgentLoop per-session
//      挂在会话视图栈上，无全局跨会话派单器——send/retry 需要的"向其他
//      会话派发 prompt"不存在，属调度层立项面；status 可由存储推导，
//      open 需 UI 导航缝（RootSelection 直写可行但 send 不通则价值存疑）。
//  结论：**查询半边可立项适配、操作半边缺宿主**；整命令本批降级，逐子命令
//  可行性已写入 B1c 报告待用户拍板。降级路径照 ffmpeg 先例（B1b 授权）。
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "WanWoOffloadGate.h"   // 【终验补】B1c 桩走 wanwo_offload_register_checked——B1c 漏带门控头（CI 实证 SessionsOffload.m:46 隐式声明错，同族四处一并补）
#include "kernel/native_offload.h"
#include <unistd.h>

// ── WanWo M6.1 增（B1c）：降级 handler（ffmpeg 先例同款形态）──
static int sessions_handler(int argc, char **argv,
                            int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)argc; (void)argv; (void)stdin_fd;
    NSDictionary *err = noff_json_error(@"wanwo-sessions-cli", @"sessions-cli", NOFF_ERR_NOT_AVAILABLE,
        @"wanwo-sessions-cli is unavailable in this build: the cross-session "
        "query/operate bridge has not been ported to WanWo's storage layer yet "
        "(SessionStore projection + cross-session dispatch pending).");
    noff_emit_json(stdout_fd, err, NO, NO);
    return NOFF_EXIT_NOT_AVAILABLE;
}

void sessions_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("wanwo-sessions-cli", sessions_handler);
    if (err == 0) {
        // 降级路径（B1b ffmpeg 先例）：补 guest stub 保 PATH 解析语义。
        noff_ensure_guest_stub("/usr/local/bin/wanwo-sessions-cli");
        NSLog(@"WanWoOffload: wanwo-sessions-cli handler registered (downgrade: storage bridge not ported)");
    } else {
        NSLog(@"WanWoOffload: failed to register wanwo-sessions-cli handler (err=%d)", err);
    }
}
