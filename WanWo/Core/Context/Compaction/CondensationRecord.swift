//
//  CondensationRecord.swift
//  WanWo
//
//  【M8 批2 · B1 件1】Condensation tombstone 载荷与事件注册（语义移植 · OpenHands
//  software-agent-sdk）：
//    · 压缩 = 追加 tombstone，原始事件永不删（sdk context/condenser/README.md:17-19
//      "similar to tombstones"）；摘要插入点 = forgotten 首条 seq（summaryOffset）；
//    · 事件走 ExtensionEventRegistry（SessionEvent 专用 case 冻结枚举不动）——
//      kind: "condensation/v1"        载荷 {id, forgottenSeqs:[Int64], summary?,
//                                      summaryOffset?, llmResponseID?, tokensBefore?,
//                                      tokensAfter?, createdAtMs}
//      kind: "condensation-request/v1" 载荷 {reason:"overflow"|"manual", requestedAtMs}
//      （冻结契约禁改名；事件 kind 一经落盘永不改）
//    · 注册纪律 = GoalEvents 同款（GoalTypes.swift:200-226）：isRegistered 守卫幂等
//      + 注册表重名 fatal 门；装配期调用（Compactor.init 承接——AppEnvironment 不可
//      改的等价适配，见 b1-report.md §1.2-2）。
//  CondensationRequirement / ContextSummarizer = 冻结契约原文（派单"三路共用"节）。
//

import Foundation

// MARK: - 冻结契约（禁改名）

/// 压缩需求分级（sdk base.py:95-104 CondensationRequirement 1:1）。
enum CondensationRequirement: Equatable, Sendable {
    /// 现在必须压缩，否则无法继续（token 超限 / 显式请求）。
    case hard
    /// 希望压缩但可推迟（事件数超限启发式；失败下步再试）。
    case soft
}

/// 摘要器协议（冻结契约；B2 提供 LLM 结构化摘要器与 basic 兜底两个 conformer，
/// B1 只定义协议+消费）。
protocol ContextSummarizer: Sendable {
    /// serializedEvents = 逐事件序列化文本（B1 掩码/序列化产出，带 seq 标注）；
    /// previousSummary = 最近一次 tombstone 的摘要（增量折叠防摘要的摘要漂移，
    /// Cline agentic-compaction.ts:139-151 语义）。
    /// 返回 = 摘要正文（markdown 渲染后）；nil = 摘要失败（HARD 走 basic 兜底链）。
    func summarize(serializedEvents: [String], previousSummary: String?) async -> String?
}

// MARK: - 事件 kind 与注册（GoalEvents 同款）

/// condensation 域 extensionEvent 注册面（幂等；重名 fatal 由注册表门保）。
enum CondensationEvents {
    /// wire type = "extension/condensation/v1"（tombstone：遗忘集 + 摘要 + 审计指标）。
    static let condensationKind = "condensation/v1"
    /// wire type = "extension/condensation-request/v1"（HARD 触发载体：手动 /
    /// provider 超限；sdk base.py handles_condensation_requests 语义）。
    static let requestKind = "condensation-request/v1"

    static func register() {
        if !ExtensionEventRegistry.shared.isRegistered(condensationKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: condensationKind,
                // 必填：id + forgottenSeqs（其余字段可选——ExtensionFieldSchema
                // 只表达"在场必填"，可选字段不入表，登记表达力边界）。
                requiredFields: [
                    ExtensionFieldSchema("id", .string),
                    ExtensionFieldSchema("forgottenSeqs", .array),
                ],
                // logOnly：tombstone 原始事件不进派生历史/聊天流——模型可见面由
                // CondensationWorkingSet 投影（派生摘要条目）承载（README.md:17-19
                // 非破坏语义；ConversationProjector 诊断页透传可审计）。
                projection: .logOnly))
        }
        if !ExtensionEventRegistry.shared.isRegistered(requestKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: requestKind,
                requiredFields: [
                    ExtensionFieldSchema("reason", .string,
                                         allowedValues: [.string("overflow"),
                                                         .string("manual")]),
                    ExtensionFieldSchema("requestedAtMs", .int),
                ],
                projection: .logOnly))
        }
    }
}

// MARK: - Condensation tombstone 载荷

/// 压缩 tombstone（sdk event/condenser.py Condensation 事件 + CondensationSummaryEvent
/// 摘要派生条的 WanWo 承载；派生摘要条目不入事件库、由投影在 summaryOffset 生成）。
struct CondensationRecord: Equatable, Sendable {
    /// tombstone id（确定性派生摘要条目 id 的锚——sdk event/condenser.py:51-76
    /// "{condensation_id}-summary" 的 WanWo 等价：投影合成条目 compactionId 复用本 id）。
    var id: String
    /// 被遗忘的事件 seq 全集（原始事件仍在日志，投影过滤）。
    var forgottenSeqs: [Int]
    /// 摘要正文（B2 ContextSummarizer 产出，markdown 渲染后；nil = 无摘要遗忘）。
    var summary: String?
    /// 摘要插入点 = forgotten 首条 seq（sdk summary_offset 语义）。
    var summaryOffset: Int?
    /// 摘要 LLM response id（审计；万我 ContextSummarizer 协议不回 response id——
    /// 冻结契约禁改名，恒 nil 登记，可审计缺口呈报 b1-report.md）。
    var llmResponseID: String?
    /// 压缩前工作集 token 估算（同源 M2 估计器）。
    var tokensBefore: Int?
    /// 压缩后工作集 token 估算。
    var tokensAfter: Int?
    var createdAtMs: Int64

    // MARK: 编解码（读写两侧闭环——GoalCodec 同款纪律）

    var payload: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "forgottenSeqs": .array(forgottenSeqs.map { .int($0) }),
        ]
        if let summary {
            object["summary"] = .string(summary)
        }
        if let summaryOffset {
            object["summaryOffset"] = .int(summaryOffset)
        }
        if let llmResponseID {
            object["llmResponseID"] = .string(llmResponseID)
        }
        if let tokensBefore {
            object["tokensBefore"] = .int(tokensBefore)
        }
        if let tokensAfter {
            object["tokensAfter"] = .int(tokensAfter)
        }
        object["createdAtMs"] = .int(Int(createdAtMs))
        return .object(object)
    }

    static func decode(_ payload: JSONValue) -> CondensationRecord? {
        guard case .object(let fields) = payload,
              case .string(let id) = fields["id"],
              case .array(let seqValues) = fields["forgottenSeqs"]
        else { return nil }
        var seqs: [Int] = []
        for value in seqValues {
            guard case .int(let seq) = value else { return nil }
            seqs.append(seq)
        }
        var summary: String?
        if case .string(let text) = fields["summary"] { summary = text }
        var summaryOffset: Int?
        if case .int(let offset) = fields["summaryOffset"] { summaryOffset = offset }
        var llmResponseID: String?
        if case .string(let responseID) = fields["llmResponseID"] { llmResponseID = responseID }
        var tokensBefore: Int?
        if case .int(let before) = fields["tokensBefore"] { tokensBefore = before }
        var tokensAfter: Int?
        if case .int(let after) = fields["tokensAfter"] { tokensAfter = after }
        var createdAtMs: Int64 = 0
        if case .int(let ms) = fields["createdAtMs"] { createdAtMs = Int64(ms) }
        return CondensationRecord(id: id, forgottenSeqs: seqs, summary: summary,
                                  summaryOffset: summaryOffset,
                                  llmResponseID: llmResponseID,
                                  tokensBefore: tokensBefore, tokensAfter: tokensAfter,
                                  createdAtMs: createdAtMs)
    }
}

// MARK: - CondensationRequest 载荷

/// 压缩请求（sdk CondensationRequest 事件；未处理的 request = HARD 触发源，
/// tombstone 落地即清位——view.unhandled_condensation_request 语义）。
struct CondensationRequestMeta: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        /// provider 上下文超限 / 历史畸形恢复（catch-condense-retry）。
        case overflow
        /// 用户手动（/compact）。
        case manual
    }

    var reason: Reason
    var requestedAtMs: Int64

    var payload: JSONValue {
        .object([
            "reason": .string(reason.rawValue),
            "requestedAtMs": .int(Int(requestedAtMs)),
        ])
    }

    static func decode(_ payload: JSONValue) -> CondensationRequestMeta? {
        guard case .object(let fields) = payload,
              case .string(let reasonRaw) = fields["reason"],
              let reason = Reason(rawValue: reasonRaw)
        else { return nil }
        var requestedAtMs: Int64 = 0
        if case .int(let ms) = fields["requestedAtMs"] { requestedAtMs = Int64(ms) }
        return CondensationRequestMeta(reason: reason, requestedAtMs: requestedAtMs)
    }
}
