//
//  ApprovalSeam.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/user-approval（serviceAsk：ask 判定 →
//  审批服务，缺失 answerer 即拒绝）+ 10-design §5.3（ApprovalSeam F018 fail closed、
//  allow-once、审计走 approval 事件）。
//  ⚠️ M2 边界：审批缝只留接口，不做 UI。M2 阶段用「自动批准 answerer」占位
//  （AutoApprovalSeam，显式标注"仅 M2"），照记 approval/asked + approval/decided
//  事件保审计与 replay；M3 换真审批卡 answerer。fail-closed 语义在协议注释内固定：
//  answerer 缺失或抛错 → 一律 deny。
//

import Foundation

/// 审批结论（dsh approval verdict 词汇）。
enum ApprovalVerdict: String, Sendable {
    case allow
    case deny
}

/// 审批缝（F018）。实现方必须 fail closed：任何异常路径都不得产生 .allow。
protocol ApprovalSeam: Sendable {
    /// 请求审批。M3 起由审批卡实现（阻塞等待用户，fail closed）；
    /// answerer 缺失/抛错/取消 → .deny。
    func request(tool: String, args: JSONValue, reason: String?,
                 sessionId: String, turn: Int, step: Int) async -> ApprovalVerdict
}

/// 【仅 M2 占位】自动批准 answerer。
/// - 每次请求照记 approval/asked + approval/decided(allow) 事件（审计留存，F018；
///   M3 换真审批后这两个事件继续由真 answerer 写，词汇不变）。
/// - 不沉淀规则（PermissionRuleStore 属 M3）。
struct AutoApprovalSeam: ApprovalSeam {
    let writer: SessionWriter

    func request(tool: String, args: JSONValue, reason: String?,
                 sessionId: String, turn: Int, step: Int) async -> ApprovalVerdict {
        let requestId = "apr-\(UUID().uuidString)"
        // 审计事件失败不阻断工具执行（信息性记录；ignorable）。
        try? await writer.append(
            .approvalAsked(requestId: requestId, tool: tool, reason: reason),
            ignorable: true)
        // 【仅 M2】自动批准。M3：此处阻塞等待 ApprovalCard verdict。
        try? await writer.append(
            .approvalDecided(requestId: requestId, verdict: ApprovalVerdict.allow.rawValue),
            ignorable: true)
        return .allow
    }
}

/// fail-closed 兜底：无 answerer 时使用（协议契约「缺失 answerer 即拒绝」的显式形态）。
struct DenyAllApprovalSeam: ApprovalSeam {
    func request(tool: String, args: JSONValue, reason: String?,
                 sessionId: String, turn: Int, step: Int) async -> ApprovalVerdict {
        .deny
    }
}
