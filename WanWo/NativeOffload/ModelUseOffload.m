//
//  ModelUseOffload.m
//  WanWo
//
//  【WanWo 降级桩 · B1c 批】源=OpenMinis src/ios/NativeOffloads/ModelUseOffload.m
//  （全文 598 行）+ ModelUseOffloadBridge.swift（全文 2172 行）。**未 vendored**，
//  降级裁定（简报 B1c 规则③；原注册名 minis-model-use → wanwo-model-use）：
//
//  原件语义：list/search/run 三子命令——list/search 枚举、过滤可调模型；
//  run 以 OpenAI Chat Completions 形态向选中模型发起子调用（含 system 注入、
//  streaming、图片/音频模态、generation_config、passthrough 裸透传、文件
//  I/O）。ObjC handler 的参数解析面自包含，但全部实际能力在
//  ModelUseOffloadBridge，其依赖 OpenMinis Provider 层的完整面：
//    · ProviderConfigStore / ProviderConfigDB（多 provider 实例注册表 +
//      entry_id/model_id 寻址 + instance_label 消歧——WanWo LLM 层只有单一
//      活动端点 EndpointStore.activeEndpoint + OpenAICompatAdapter，无多
//      实例注册表、无 ModelEntry/ModelModality 元数据，见 WanWo/LLM/）；
//    · LLMMessage / 流式管线 / 图片与音频附件路径 / 媒体转码
//      （OpenAICompatAdapter 仅覆盖会话主链 chat 面，无 run 子调用所需的
//      endpoint 覆写、passthrough、generation_config→wire 转换）；
//    · 2172 行桥中约 2/3 为图片生成/媒体落盘/格式转换（无对应物）。
//  摸底结论（简报 B1c ②要求先摸清 WanWo LLM Providers 层）：**无等价物，
//  适配成本=在 WanWo 侧新建模型注册表+子调用协议层，属立项面**——按规则降级
//  而非硬编。是否立项待用户拍板（B1c 报告单列）。
//  降级路径照 ffmpeg 先例（B1b 授权）：注册真命令名 + guest stub 保 PATH
//  解析，handler 恒回 NOT_AVAILABLE envelope。
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

// ── WanWo M6.1 增（B1c）：降级 handler（ffmpeg 先例同款形态）──
static int model_use_handler(int argc, char **argv,
                             int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)argc; (void)argv; (void)stdin_fd;
    NSDictionary *err = noff_json_error(@"wanwo-model-use", @"model-use", NOFF_ERR_NOT_AVAILABLE,
        @"wanwo-model-use is unavailable in this build: WanWo has no "
        "multi-provider model registry to back the list/search/run surface yet "
        "(OpenMinis ProviderConfigStore equivalent not ported).");
    noff_emit_json(stdout_fd, err, NO, NO);
    return NOFF_EXIT_NOT_AVAILABLE;
}

void model_use_offload_register(void) {
    // 万我 M6.1 增：native_offload_add_handler → wanwo_offload_register_checked
    // （权限门控 trampoline，10-design:818 v2；OpenMinis 原件直连内核注册）。
    int err = wanwo_offload_register_checked("wanwo-model-use", model_use_handler);
    if (err == 0) {
        // 降级路径（B1b ffmpeg 先例）：补 guest stub 保 PATH 解析语义。
        noff_ensure_guest_stub("/usr/local/bin/wanwo-model-use");
        NSLog(@"WanWoOffload: wanwo-model-use handler registered (downgrade: provider registry not ported)");
    } else {
        NSLog(@"WanWoOffload: failed to register wanwo-model-use handler (err=%d)", err);
    }
}
