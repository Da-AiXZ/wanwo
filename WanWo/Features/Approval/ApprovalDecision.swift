//
//  ApprovalDecision.swift
//  WanWo
//
//  【P1-3 临场最小版】三值判定词汇（allow/prompt/forbidden + 取最严）。
//  P1-3 审批缝重做已移除判定矩阵与工具效果分类表（ApprovalDecisionMatrix /
//  ToolEffectTable——审批只由沙箱提权请求触发，dsh escalation.ts:173）；本
//  枚举暂由 PermissionRulesEngine（F022 规则引擎，P1-4 砍除）引用。P1-4 随
//  规则引擎一并删除本文件——三值判定与 interaction/readOnly 两类保留语义的
//  归宿：审批触发面结构性收窄到携带 sandbox_permissions schema 的四工具
//  （bash/write/edit/str_replace_editor），ask_user_question/exit_plan_mode/
//  只读工具无提权 schema，结构上不可能触发审批（死锁/放行语义天然保住）。
//

import Foundation

/// 规则/矩阵判定的三值结论（codex Decision 词汇；P1-4 移除）。
enum ApprovalDecisionVerdict: Equatable, Sendable {
    case allow
    case prompt
    case forbidden

    /// 取最严（多条命中取 max，只增不减）。严格度序：allow < prompt < forbidden。
    static func strictest(_ a: ApprovalDecisionVerdict, _ b: ApprovalDecisionVerdict)
        -> ApprovalDecisionVerdict {
        switch (a, b) {
        case (.forbidden, _), (_, .forbidden): return .forbidden
        case (.prompt, _), (_, .prompt): return .prompt
        default: return .allow
        }
    }
}
