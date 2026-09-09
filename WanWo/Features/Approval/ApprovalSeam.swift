//
//  ApprovalSeam.swift
//  WanWo
//
//  【语义移植 · dsh · M3 T1 重做】出处（源码原件逐条对位）：
//    - dsh packages/interaction/user-approval/src/types.ts:32 —— ApprovalOutcome
//      四值闭集 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'；
//      callers fail closed on 'unavailable'（types.ts:30-31 注释原文语义）。
//    - dsh packages/interaction/user-approval/src/index.ts:48 —— OUTCOMES 全集
//      运行时归一化；:279 rogue（非词汇）answerer 返回值归一为 'unavailable'；
//      :281-283 throwing answerer fail the QUESTION closed（→ 'unavailable'）。
//    - dsh packages/interaction/user-approval/src/index.ts:60/63 —— ApprovalPolicy
//      'ask' | 'never' 闭集与 APPROVAL_POLICIES 全集。
//    - dsh packages/interaction/user-approval/src/index.ts:207-226 —— request()：
//      turn-enclosed 前置（:209-215，审计对必须被回合封闭）→ 追加 approval/asked →
//      decide → 追加 approval/decided；'allowed-once' 是唯一授予（:203）。
//    - dsh packages/interaction/user-approval/src/index.ts:266 —— 'never' 政策在
//      dispatch 之前确定性拒绝（每 ask 恒 'rejected'）。
//    - dsh packages/client/ui-approval/src/client/contract/slots.ts:64 ——
//      ApprovalDecision：交互呈现层只回 'allowed-once' | 'rejected' 二值。
//  M3 T1：AutoApprovalSeam 占位删除（attempt1 回滚纪律：不复刻旧实现）；
//  审计事件词汇仍为既有 approval/asked + approval/decided（SessionEvent 零改动红线），
//  approval/decided 的 verdict 字段从 M2 的 "allow|deny" 双值改为四值闭集原文
//  （字段名不变，值为 dsh types.ts:32 闭集字符串 1:1）。
//

import Foundation

// MARK: - ApprovalOutcome（四值闭集 · dsh types.ts:32）

/// 审批结论闭集（dsh ApprovalOutcome 1:1）。`allowed-once` 是唯一授予；
/// 其余三值一律 fail closed：
///   · rejected   —— 仅指用户主动拒绝（M2 旧 "deny" 把用户拒绝与 fail-closed
///                   混为一态，即 attempt1 回滚根因之一，严禁回归）；
///   · cancelled  —— 请求被撤销（turn 取消 / abort 信号）；
///   · unavailable —— fail-closed 归一化：answerer 缺失、rogue 返回值、
///                   桥关闭时的在途待决。
enum ApprovalOutcome: String, Equatable, Sendable, Codable {
    case allowedOnce = "allowed-once"
    case rejected
    case cancelled
    case unavailable

    /// dsh index.ts:48 OUTCOMES 全集（运行时归一化的判定基准）。
    static let all: [ApprovalOutcome] = [.allowedOnce, .rejected, .cancelled, .unavailable]

    /// dsh index.ts:279 语义：rogue（非词汇）返回值归一为 fail-closed 的
    /// `unavailable`，绝不把未知值泄漏进调用方的闭集 switch。
    /// E1 追加（v2.4 备忘答复，已批）：M2 台账兼容——旧日志 approval/decided
    /// 的 verdict 为 "allow"/"deny" 双值，重放映射 allow→allowed-once（M2 语义
    /// = 授予一次）、deny→rejected（M2 语义 = 用户主动拒绝）；其余非词汇值
    /// 仍归一 unavailable（dsh rogue 语义不变）。
    static func normalizing(_ raw: String) -> ApprovalOutcome {
        if let exact = all.first(where: { $0.rawValue == raw }) {
            return exact
        }
        switch raw {
        case "allow": return .allowedOnce
        case "deny": return .rejected
        default: return .unavailable
        }
    }
}

// MARK: - ApprovalPolicy（dsh index.ts:60）

/// 会话审批政策（dsh ApprovalPolicy 1:1）：
///   · ask   —— 缺省：交给 answerer 链；无 answerer 即 fail closed 'unavailable'。
///   · never —— 无人被询问：每个 ask 确定性 'rejected'（dsh index.ts:266，
///              在 dispatch 之前短路——注册顺序无关的硬保证）。
/// T1 落点：政策读取缝 + never 短路；approval/policy 会话事件（走 E1 通道）
/// 与 /permission 双旋钮为 T2 件（m3-scope-brief §三.3）。
enum ApprovalPolicy: String, Equatable, Sendable, Codable {
    case ask
    case never

    /// dsh index.ts:63 APPROVAL_POLICIES 全集。
    static let all: [ApprovalPolicy] = [.ask, .never]
}

// MARK: - ApprovalDecision（交互呈现层二值 · dsh slots.ts:64）

/// 交互 UI 能做出的决定（dsh ApprovalDecision 1:1）：一次性授予或拒绝；
/// cancelled/unavailable 不是用户输入，是系统归一化结果。
enum ApprovalDecision: String, Equatable, Sendable {
    case allowedOnce = "allowed-once"
    case rejected
}

// MARK: - fail-closed 词汇（P1-3 审批缝重做后保留的闭集与政策类型）
//
// P1-3：主动审批缝（F018 protocol ApprovalSeam + UnavailableApprovalSeam）
// 随判定矩阵一并移除——审批只由沙箱提权请求触发（dsh escalation.ts:173，
// approveEscalation → approval.request），通道见 SandboxEscalation.swift 的
// SandboxEscalationApprover 结构闭包。本文件保留 Outcome/Policy/Decision
// 三组类型（审计对与交互呈现仍在用）。
