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
    static func normalizing(_ raw: String) -> ApprovalOutcome {
        all.first { $0.rawValue == raw } ?? .unavailable
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

// MARK: - ApprovalSeam（F018 审批缝）

/// 审批缝（F018）。实现方必须 fail closed：任何异常路径都不得产生
/// `.allowedOnce` 之外的授予语义（`.allowedOnce` 是唯一授予）。
protocol ApprovalSeam: Sendable {
    /// 请求审批。
    /// - Parameters:
    ///   - tool: 工具名（呈现与审计）。
    ///   - args: 工具参数（判定矩阵输入）。
    ///   - callId: 关联 tool/call（dsh ApprovalRequest.callId——UI 把审批
    ///     挂到已流式呈现的工具卡上；审计事件词汇暂无 callId 字段（T1 零改动），
    ///     仅用于 live 呈现配对）。
    ///   - reason: 请求方的可读理由（dsh ApprovalRequest.reason）。
    /// - Returns: 四值闭集结论；`.allowedOnce` 是唯一放行。
    func request(tool: String, args: JSONValue, callId: String?,
                 reason: String?) async -> ApprovalOutcome
}

// MARK: - fail-closed 兜底

/// 无 answerer 时的兜底缝（协议契约「缺失 answerer 即 unavailable」的显式形态；
/// dsh index.ts:55-56：with none composed the chain falls through to the
/// fail-closed 'unavailable'）。
struct UnavailableApprovalSeam: ApprovalSeam {
    func request(tool: String, args: JSONValue, callId: String?,
                 reason: String?) async -> ApprovalOutcome {
        .unavailable
    }
}
