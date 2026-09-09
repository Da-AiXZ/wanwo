//
//  SandboxEscalation.swift
//  WanWo
//
//  【语义移植 · dsh · P1-3 判定矩阵重做】出处（源码原件逐条对位）：
//    - dsh packages/sandbox/sandbox/src/escalation.ts:28-31 —— WIDER_MODES
//      严格加宽表（read-only→[workspace-write,danger-full-access]；
//      workspace-write→[danger-full-access]）。
//    - escalation.ts:41 —— ESCALATION_TARGETS 闭集（schema enum 是全集；
//      严格加宽是执行时 per-call 检查——「schemas are registry-global while
//      the effective mode is per-call truth」，:22-27 注释原文语义）。
//    - escalation.ts:51-61 —— validateEscalationArgs 成对校验，三条错误
//      文案逐字。
//    - escalation.ts:71-73 / :84-86 —— sandboxDenialMarker /
//      escalationHintMarker 模型可见文案逐字。
//    - escalation.ts:157-189 —— approveEscalation 有序 fail-closed：严格加宽
//      检查（:162-164）→ approver 缺失（:165-167）→ agent 缺失（:168-170）→
//      approval.request（:173-179，reason 固定格式）→ 四值结算映射
//      （:183-186）。
//  WanWo 归一（登记）：
//    · approver = 结构闭包（EscalationApprover），闭住 ApprovalCoordinator +
//      审批政策读取（'never' 在 dispatch 之前确定性 rejected——dsh
//      user-approval index.ts:266 语义，WanWo 落在闭包首行）。
//    · dsh :168-170 agent 缺失分支：WanWo 单宿主 agent 身份恒存在，
//      结构性不可达（保留文档，不设死代码）。
//    · dsh 抛错由工具注册表合成 isError 结果；WanWo 抛错由工具体 catch
//      合成（ToolPipeline 统一管线，§十三.2 同向）。
//

import Foundation

// MARK: - 词汇（dsh escalation.ts:28-41）

/// 严格加宽表（dsh WIDER_MODES 1:1；执行时 per-call 检查，非 schema 约束）。
enum SandboxWiderModes {
    static func targets(from mode: SandboxMode) -> [SandboxMode] {
        switch mode {
        case .readOnly: return [.workspaceWrite, .dangerFullAccess]
        case .workspaceWrite: return [.dangerFullAccess]
        case .dangerFullAccess: return []
        }
    }
}

/// 提权目标闭集（dsh ESCALATION_TARGETS 1:1；schema enum 全集——read-only
/// 是地板，没有东西提权到它）。
enum SandboxEscalationTargets {
    static let all: [SandboxMode] = [.workspaceWrite, .dangerFullAccess]
}

// MARK: - 模型可见文案（dsh escalation.ts:71-86 逐字）

/// 拒绝标记（两族统一的策略拒绝词汇）。
func sandboxDenialMarker(_ mode: SandboxMode) -> String {
    "[sandbox: file access denied under \(mode.rawValue) mode]"
}

/// 同回合提权提示（subject：bash='command' / fs='operation'）。
func escalationHintMarker(_ subject: String) -> String {
    "[sandbox: escalation available — retry this exact \(subject) once with "
        + "sandbox_permissions (the narrowest wider mode that suffices) + justification; "
        + "the approval prompt asks the user]"
}

// MARK: - 参数成对校验（dsh escalation.ts:51-61）

/// 提权参数校验错误（message = dsh 逐字文案）。
struct SandboxEscalationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 成对校验（schema 表达不了的约束：两参数同进同出 + 理由非空句）。
func validateEscalationArgs(sandboxPermissions: String?, justification: String?) throws {
    if sandboxPermissions != nil && justification == nil {
        throw SandboxEscalationError(
            message: "invalid escalation: sandbox_permissions requires a justification")
    }
    if justification != nil && sandboxPermissions == nil {
        throw SandboxEscalationError(
            message: "invalid escalation: justification is only valid together with sandbox_permissions")
    }
    if let justification, justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw SandboxEscalationError(
            message: "invalid justification: expected a non-empty sentence")
    }
}

// MARK: - 审批通道（dsh EscalationApprover 结构形状）

/// 提权审批通道（dsh EscalationApprover 的 Swift 结构闭包形态：tool 层闭住
/// ctx.approval 传入，本模块不依赖审批服务类型）。
typealias SandboxEscalationApprover = @Sendable (
    _ toolName: String, _ callId: String?, _ reason: String
) async -> ApprovalOutcome

// MARK: - approveEscalation（dsh escalation.ts:157-189 有序 fail-closed）

enum SandboxEscalation {
    /// 结算一笔提权请求（任何执行发生之前）。返回授予的模式，仅 stamp 发起
    /// 本请求的这一次调用；其余每条路径抛 dsh 逐字文案（工具体 catch 合成
    /// isError 结果——什么都没执行）。
    /// - Parameters:
    ///   - requestedMode: 请求的目标模式（schema enum 钉在闭集内）。
    ///   - justification: 模型的一句话理由（逐字进审计 reason）。
    ///   - effectiveMode: 本调用的生效模式（会话末条 sandbox/mode ?? 部署默认）。
    ///   - subject: 文案名词（bash='command' / fs='operation'）。
    ///   - toolName / callId: 审批请求身份。
    ///   - approver: 审批通道（nil = 无审批服务合成）。
    static func approve(requestedMode: String,
                        justification: String,
                        effectiveMode: SandboxMode,
                        subject: String,
                        toolName: String,
                        callId: String?,
                        approver: SandboxEscalationApprover?) async throws -> SandboxMode {
        let mode = requestedMode
        // 1. 严格加宽（执行时 per-call 检查；非加宽请求绝不惊动真人）。
        guard SandboxWiderModes.targets(from: effectiveMode).rawValues.contains(mode) else {
            throw SandboxEscalationError(message:
                "sandbox escalation to \"\(mode)\" is not strictly wider than "
                + "this call's current \"\(effectiveMode.rawValue)\" mode")
        }
        // 2. 审批服务缺失（fail closed）。
        guard let approver else {
            throw SandboxEscalationError(message:
                "sandbox escalation to \"\(mode)\" requires approval, but no "
                + "approval service is composed")
        }
        // （dsh :168-170 agent 缺失分支：WanWo 单宿主 agent 身份恒存在——
        //   结构性不可达，见文件头注登记。）
        // 3. 审计自包含的固定 reason 格式（dsh :177 逐字模板）。
        let outcome = await approver(toolName, callId,
                                     "escalate sandbox to \(mode): \(justification)")
        // 4. 四值结算映射（dsh :183-186 逐字）。
        switch outcome {
        case .allowedOnce:
            guard let granted = SandboxMode(rawValue: mode) else {
                throw SandboxEscalationError(message:
                    "unreachable sandbox mode: \(mode)")
            }
            return granted
        case .rejected:
            throw SandboxEscalationError(message:
                "the user rejected escalating this \(subject) to \"\(mode)\"")
        case .cancelled:
            throw SandboxEscalationError(message:
                "approval for escalating to \"\(mode)\" was cancelled")
        case .unavailable:
            throw SandboxEscalationError(message:
                "sandbox escalation to \"\(mode)\" requires approval, but no "
                + "approval channel is available")
        }
    }
}

private extension Array where Element == SandboxMode {
    var rawValues: [String] { map(\.rawValue) }
}
