//
//  WanWoOffloadGate.h
//  WanWo
//
//  【万我 M6.1 增 · 设计强制新文件】出处：analysis/10-design.md:818 §8.1
//  "权限门控（v2 改进）——检查移进内核分发点（native_offload 分发处），
//  封堵 sh -c/env 间接调用绕过"。OpenMinis 原件无此文件（其自述
//  OffloadPermissionManager.swift:205-209 shell 侧检查覆盖不到间接调用）。
//
//  实现形态（内核 vendored C 零改动）：门控以宿主侧 trampoline 实现
//  （Platform/ISHKernel.m）。本函数向内核 native_offload_add_handler()
//  递交 trampoline 而非真 handler；trampoline 调真 handler 前经 C→Swift
//  门控块（WanWoOffloadPermissionGate，ISHKernel.h）同步做权限检查：
//   - allow → 调真 handler，返回值原样透传；
//   - deny  → noff_json_error(..., AUTHORIZATION_DENIED, ...) 经 stdout
//             回流 + return NOFF_EXIT_AUTH_DENIED(3)。
//

#ifndef WanWoOffloadGate_h
#define WanWoOffloadGate_h

#include "kernel/native_offload.h"

/// 带权限门控的 in-process handler 注册（简报 B1a ③）。
/// OpenMinis *_offload_register() 内 native_offload_add_handler(name, handler)
/// 调用的 WanWo 等价物；B1b/B1c 其余命令一律改走本入口。
///
/// @param guest_name   guest 命令 basename（如 "apple-device"；与内核
///                     native_offload_lookup 的 basename 匹配规则一致）
/// @param real_handler OpenMinis 原件语义的真 handler
/// @return 0 成功；-1 注册表满（NATIVE_OFFLOAD_MAX=32）/ 参数非法
int wanwo_offload_register_checked(const char *guest_name,
                                   native_handler_func real_handler);

#endif /* WanWoOffloadGate_h */
