//
//  CompositeApprovalSeam.swift
//  WanWo
//
//  【语义移植 · M3 T1 + T2】出处：
//    - m3-scope-brief §二.4 —— CompositeApprovalSeam 四步管线：
//      判定 → allow 直通 / forbidden 拒 / prompt → 挂起或 fail closed。
//    - 06-codex-gap1 §八.1/§八.2 —— 三值判定接 dsh pre-execute 缝：
//      allow→跳过审批、deny（forbidden）→阻断、ask（prompt）→既有
//      user-approval；T2 规则引擎作为缝内高优先级判定入口，未命中走既有
//      waterfall 兜底。
//    - dsh packages/interaction/user-approval/src/index.ts:266 —— 'never' 政策
//      在 dispatch 之前确定性拒绝（每个 ask 恒 'rejected'，注册顺序无关）。
//    - dsh index.ts:207-226 —— 审计对只随 ask 产生：allow 直通与 forbidden
//      拒绝不询问，故不落 approval/asked+decided。
//  T2 管线（gap1 §八.1/§八.3 + §七.3）：
//    ① 会话审批缓存命中 → 直接授予（ApprovedForSession；不落审计对）；
//    ② 规则引擎先行（prefix/network 多层取最严；wrapper 拆段全覆盖才判）→
//       未命中回落矩阵启发式（沙箱档取双旋钮实时值）；
//    ③ allow 直通 / forbidden 确定性拒绝（不落审计对）；
//    ④ prompt：never 政策短路 → 审批协调器挂起；allowedOnce 结算 → 会话缓存
//       登记 +「允许并记住」沉淀（bash 命令导出前缀规则，黑名单/去重把关）。
//  permission = nil 时整段 T2 逻辑旁路（T1 形态——单测与旧装配路径兼容）。
//

import Foundation

/// 组合审批缝（四步管线 + T2 规则引擎先行；makeAgentStack 装配点）。
struct CompositeApprovalSeam: ApprovalSeam {
    /// 判定骨架（矩阵启发式兜底 + 工具效果分类；T2 规则引擎先行，矩阵兜底）。
    let matrix: ApprovalDecisionMatrix
    /// 审批协调器（审计对落盘 + 在途登记 + first answer wins）。
    let coordinator: ApprovalCoordinator
    /// 会话审批政策读取缝（dsh effectivePolicy；生产装配 = knobs.approval 折叠，
    /// approval/policy 事件与 /permission 切换实时生效）。
    let policyProvider: @Sendable () -> ApprovalPolicy
    /// T2 权限协调器（规则引擎 + 会话缓存 + 沉淀 + 双旋钮；nil = T1 形态）。
    var permission: PermissionCoordinator? = nil

    func request(tool: String, args: JSONValue, callId: String?,
                 reason: String?) async -> ApprovalOutcome {
        // ① 会话审批缓存（gap1 §八.3 完备键；命中 = 本会话已批准过同一请求，
        //    不再询问、不落审计对——审计对只随 ask，dsh 语义）。
        if let permission, permission.cachedApproval(tool: tool, args: args) {
            return .allowedOnce
        }

        // ② 判定：规则引擎先行（命中取最严；wrapper 内外层全覆盖才判），
        //    未命中回落矩阵启发式（沙箱档取双旋钮实时值——T2 双旋钮接管）。
        let sandbox = permission?.knobs.sandbox ?? matrix.sandboxMode
        let verdict: ApprovalDecisionVerdict
        let matchedByRules: Bool
        if let rulesVerdict = permission?.rulesVerdict(tool: tool, args: args) {
            verdict = rulesVerdict
            matchedByRules = true
        } else {
            verdict = ApprovalDecisionMatrix(sandboxMode: sandbox,
                                             rows: matrix.rows)
                .decide(tool: tool, args: args)
            matchedByRules = false
        }

        switch verdict {
        case .allow:
            // ③ allow 直通：不询问、不落审计对（审计对只随 ask，dsh 语义）。
            return .allowedOnce

        case .forbidden:
            // ③ forbidden 确定性拒绝：不询问（禁令不可经批准绕过——codex
            //    Forbidden 语义），不落审计对。
            return .rejected

        case .prompt:
            // ④ 政策短路（dsh index.ts:261-266：'never' 在任何 dispatch 之前
            //    拒绝）→ 否则挂起等真人（fail closed：桥关闭/取消/无 answerer
            //    分别归一 cancelled/unavailable，绝无静默放行路径）。
            if policyProvider() == .never {
                return .rejected
            }
            // 「允许并记住」沉淀出口：仅 bash 待批命令且非规则命中路径
            // （规则命中的 prompt 沉淀无意义——多层取最严会吞掉新 allow 规则）。
            let rememberable = tool == "bash" && !matchedByRules && permission != nil
            let resolution = await coordinator.requestWithMemory(
                tool: tool, callId: callId, reason: reason, rememberable: rememberable)
            if resolution.outcome == .allowedOnce {
                // 会话缓存登记（同请求本会话内不再询问）+ 可选沉淀。
                permission?.rememberApproval(tool: tool, args: args)
                if resolution.remembered, let permission,
                   let command = args.field("command")?.stringValue {
                    _ = permission.sedimentPrefixRule(fromCommand: command)
                }
            }
            return resolution.outcome
        }
    }
}
