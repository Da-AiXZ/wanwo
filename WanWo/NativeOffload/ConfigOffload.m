//
//  ConfigOffload.m
//  WanWo
//
//  【WanWo 降级桩 · B1c 批】源=OpenMinis src/ios/NativeOffloads/ConfigOffload.m
//  （全文 460 行）+ ConfigOffloadBridge.swift（全文 1100 行）。**未 vendored**，
//  降级裁定（简报 B1c 规则③；原注册名 minis-config → wanwo-config）：
//
//  原件语义：list-topics/topic-help/get/set/set-batch/add/audit-list/
//  audit-get/audit-revert 九子命令——经 ConfigRegistry（topic→field schema、
//  点路径读写、确认卡、审计日志与回滚）读写 App 设置。摸底（简报 ②"摸清
//  设置面在哪"）：WanWo 的设置面是**散点 store 族**，无统一注册表——
//    · EndpointStore（config/providers.json）、PermissionDefaultStore
//      （config/permission-default.json）、SkillSettingsStore
//      （config/skills-settings.json）、MCPServerStore（config/mcp-servers/
//      servers.json）——各自文件各自 schema（见 WanWo/App/AppEnvironment
//      init 装配段）；
//    · 无 ConfigRegistry 等价物：无 topic/field schema 层、无点路径寻址、
//      无统一审计日志/回滚面、无写入确认卡（MCP server config 工具的
//      审批缝是单点特例）。
//  适配 ConfigOffloadBridge=在 WanWo 新建统一设置注册表 + 审计回滚系统，
//  成本大且涉及设置面架构决策（哪些 store 入表、schema 形态）——属立项面，
//  按规则降级而非硬编。待用户拍板（B1c 报告单列）。降级路径照 ffmpeg 先例
//  （B1b 授权）。
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

// ── WanWo M6.1 增（B1c）：降级 handler（ffmpeg 先例同款形态）──
static int config_handler(int argc, char **argv,
                          int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)argc; (void)argv; (void)stdin_fd;
    NSDictionary *err = noff_json_error(@"wanwo-config", @"config", NOFF_ERR_NOT_AVAILABLE,
        @"wanwo-config is unavailable in this build: WanWo has no unified "
        "settings registry (ConfigRegistry equivalent) yet — settings live in "
        "per-feature stores without a topic/field schema or audit surface.");
    noff_emit_json(stdout_fd, err, NO, NO);
    return NOFF_EXIT_NOT_AVAILABLE;
}

void config_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("wanwo-config", config_handler);
    if (err == 0) {
        // 降级路径（B1b ffmpeg 先例）：补 guest stub 保 PATH 解析语义。
        noff_ensure_guest_stub("/usr/local/bin/wanwo-config");
        NSLog(@"WanWoOffload: wanwo-config handler registered (downgrade: no unified settings registry)");
    } else {
        NSLog(@"WanWoOffload: failed to register wanwo-config handler (err=%d)", err);
    }
}
