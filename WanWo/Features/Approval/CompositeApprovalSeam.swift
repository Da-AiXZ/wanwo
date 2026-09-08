//
//  CompositeApprovalSeam.swift
//  WanWo
//
//  【语义移植 · M3 T1】出处：
//    - m3-scope-brief §二.4 —— CompositeApprovalSeam 四步管线：
//      判定 → allow 直通 / forbidden 拒 / prompt → 挂起或 fail closed。
//    - 06-codex-gap1 §八.1/§八.2 —— 三值判定接 dsh pre-execute 缝：
//      allow→跳过审批、deny（forbidden）→阻断、ask（prompt）→既有 user-approval。
//    - dsh packages/interaction/user-approval/src/index.ts:266 —— 'never' 政策
//      在 dispatch 之前确定性拒绝（每个 ask 恒 'rejected'，注册顺序无关）。
//    - dsh index.ts:207-226 —— 审计对只随 ask 产生：allow 直通与 forbidden
//      拒绝不询问，故不落 approval/asked+decided（dsh 审计对语义：ask 的
//      持久半记录；M2「每笔调用都记账」占位行为随本件废止）。
//

import Foundation

/// 组合审批缝（四步管线；makeAgentStack 装配点）。
struct CompositeApprovalSeam: ApprovalSeam {
    /// 判定骨架（workspace-write 最简矩阵 + 效果分类静态表；T2 规则引擎接管）。
    let matrix: ApprovalDecisionMatrix
    /// 审批协调器（审计对落盘 + 在途登记 + first answer wins）。
    let coordinator: ApprovalCoordinator
    /// 会话审批政策读取缝（dsh effectivePolicy；T1 恒 .ask——T2 接
    /// approval/policy 会话事件折叠与 /permission 双旋钮）。
    let policyProvider: @Sendable () -> ApprovalPolicy

    func request(tool: String, args: JSONValue, callId: String?,
                 reason: String?) async -> ApprovalOutcome {
        // ① 判定（三值；多条规则行命中取最严已在矩阵内完成）。
        switch matrix.decide(tool: tool, args: args) {
        case .allow:
            // ② allow 直通：不询问、不落审计对（审计对只随 ask，dsh 语义）。
            return .allowedOnce

        case .forbidden:
            // ③ forbidden 确定性拒绝：不询问（组织级禁令不可经批准绕过——
            // codex Forbidden 语义），不落审计对。
            return .rejected

        case .prompt:
            // ④ 政策短路（dsh index.ts:261-266：'never' 在任何 dispatch 之前
            // 拒绝）→ 否则挂起等真人（fail closed：桥关闭/取消/无 answerer
            // 分别归一 cancelled/unavailable，绝无静默放行路径）。
            if policyProvider() == .never {
                return .rejected
            }
            return await coordinator.request(tool: tool, callId: callId, reason: reason)
        }
    }
}
