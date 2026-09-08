//
//  SessionEvent.swift
//  WanWo
//
//  【语义移植 · dsh 事件词汇 1:1】出处：
//    - dsh packages/core/session/src/types.ts（SessionEvent 信封：type/seq/time/data/ignorable）
//    - dsh packages/core/session/src/known-event-types.ts（KNOWN_SESSION_EVENT_TYPES + ignorable 兼容机制）
//    - dsh packages/session/session-persistence-jsonl/src/format.ts（JSONL 行编码）
//    - 10-design §5.1（Event 词汇 M1 子集 + 扩展位；不变量 model-visible = logged）
//  M1 词汇子集：turn/start|end、step/start|end、user/message、assistant/chunk、
//  assistant/message、request/header（= modelRequest）、llm/retry、llm/retry-started、
//  session/title、system。枚举留扩展位：未识别的 type 若带 ignorable 标记则以
//  .ignored(kind) 透传；不带则拒绝重建（fail closed，dsh SessionEvent.ignorable 语义）。
//
//  M2 扩展（wire 名 1:1 dsh known-event-types）：tool/call、tool/result、
//  compaction/start、compaction/summary、compaction/end、compaction/prune、
//  command/run、command/done、approval/asked、approval/decided（dsh 审计事件对）。
//

import Foundation

// MARK: - TurnEndReason（dsh TurnEndReasonMap 词汇）

enum TurnEndReason: Equatable, Sendable {
    case completed
    case aborted(cause: String)   // 取消原因（M1: "user"）
    case blocked
    case error(LlmFailure)
    case maxTokens
    /// 崩溃/中断孤儿回合的事后收尾（dsh interrupted：live 循环不发射，仅 resume 修复追加）。
    case interrupted
}

extension TurnEndReason: Codable {
    private enum Kind: String, Codable {
        case completed
        case aborted
        case blocked
        case error
        case maxTokens = "max-tokens"
        case interrupted
    }

    private enum Keys: String, CodingKey {
        case kind, reason, failure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .completed: self = .completed
        case .blocked: self = .blocked
        case .maxTokens: self = .maxTokens
        case .interrupted: self = .interrupted
        case .aborted:
            if let reason = try? container.decode([String: String].self, forKey: .reason),
               let cause = reason["kind"] {
                self = .aborted(cause: cause)
            } else {
                self = .aborted(cause: "user")
            }
        case .error:
            self = .error(try container.decode(LlmFailure.self, forKey: .failure))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .completed:
            try container.encode(Kind.completed, forKey: .kind)
        case .aborted(let cause):
            try container.encode(Kind.aborted, forKey: .kind)
            try container.encode(["kind": cause], forKey: .reason)
        case .blocked:
            try container.encode(Kind.blocked, forKey: .kind)
        case .error(let failure):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        case .maxTokens:
            try container.encode(Kind.maxTokens, forKey: .kind)
        case .interrupted:
            try container.encode(Kind.interrupted, forKey: .kind)
        }
    }
}

// MARK: - SessionEvent

/// 会话事件日志的一条不可变记录（dsh SessionEvent 信封：type + seq + time + data + ignorable）。
struct SessionEvent: Equatable, Sendable {
    /// 载荷（dsh SessionEventMap 的 M1 子集；wire type 名一比一）。
    enum Payload: Equatable, Sendable {
        case turnStart(turn: Int)
        case turnEnd(turn: Int, reason: TurnEndReason)
        case stepStart(turn: Int, step: Int)
        case stepEnd(turn: Int, step: Int)
        /// 模型可见面用户消息（M1 纯文本；attachments 随 M2 附件系统扩展）。
        case userMessage(text: String)
        /// 原始流块（token 级 replay 保真；model-visible=logged 的实现根基）。
        case assistantChunk(turn: Int, step: Int, chunk: StreamChunk)
        /// 一步聚合的助手消息（派生历史用）；interrupted 标记取消时已交付前缀。
        case assistantMessage(turn: Int, step: Int, message: AssistantMessage,
                              usage: TokenUsage?, interrupted: Bool)
        /// 发给模型的完整请求头快照（log-only；最新一份可重建请求头）。
        case requestHeader(header: EpochHeader, reason: String)
        /// 重试调度（等待前先落盘——dsh llm-retry「先持久化再等待」）。
        case llmRetry(retryId: String, turn: Int, step: Int, provider: String,
                      mode: String, policyKey: String, retry: Int, maxRetries: Int?,
                      delayMs: Int, failure: LlmFailure)
        /// 重试等待结束、即将重发请求。
        case llmRetryStarted(retryId: String, turn: Int, step: Int, retry: Int)
        /// 会话标题（F004；loss 不影响重建 → ignorable）。
        case sessionTitle(title: String, source: String)
        /// 信息性系统注记（dispatch 要求的 system 词汇；恒 ignorable）。
        case system(note: String)
        // MARK: M2 词汇（wire 名 1:1 dsh）

        /// 模型请求的一次工具调用（dsh tool/call：arguments 为模型原始 JSON 文本）。
        case toolCall(turn: Int, step: Int, callId: String, name: String, arguments: String)
        /// 工具调用的模型可见结果（dsh tool/result；error.* 为结构化失败身份；
        /// meta 为工具私有呈现载荷，必须 lossless JSON）。
        case toolResult(turn: Int, step: Int, callId: String, content: String, isError: Bool,
                        errorName: String?, errorCode: String?, meta: JSONValue?)
        /// 压缩开锁（log-only；持有锁直到 compaction/end；turn=nil 为回合外独立事务）。
        case compactionStart(compactionId: String, turn: Int?)
        /// 压缩摘要与影子定价（log-only；后随的 user/message 是面上的替换节点）。
        case compactionSummary(compactionId: String, summary: String,
                               shadowedRangeStart: Int, shadowedRangeEnd: Int,
                               shadowedSeqs: [Int], shadowedTokenCount: Int)
        /// 压缩解锁；error 记录未成功尝试。
        case compactionEnd(compactionId: String, turn: Int?, error: String?)
        /// 模型无关 prune 的影子定价（后随 tool/result 替换节点，协议与 dsh 一致）。
        case compactionPrune(shadowedSeqs: [Int], shadowedTokenCount: Int)
        /// 斜杠命令进入 handler（log-only；commandId 与 command/done 配对）。
        case commandRun(commandId: String, name: String, args: String?)
        /// 斜杠命令落定（kind: success | error）。
        case commandDone(commandId: String, kind: String, text: String?)
        /// 审批请求审计（M2 自动批准占位也记账；F018）。
        case approvalAsked(requestId: String, tool: String, reason: String?)
        /// 审批结论审计（verdict: allow | deny）。
        case approvalDecided(requestId: String, verdict: String)
        /// 外来未来事件（带 ignorable 标记透传；本进程永不主动写入）。
        case ignored(kind: String)
        // MARK: E1 扩展通道（10-design v2.4 修订①；此后专用 case 集合永久冻结，
        // 新事件种类一律走本通道——报批登记后经 ExtensionEventRegistry 注册实现）
        /// 模块内注册表扩展事件（dsh merge-extensible 的 Swift 移植）：
        ///   · wire type "extension/\(kind)"，wire 恒带 ignorable（前向兼容：
        ///     旧构建读新日志透传不崩，defaultIgnorable 承载）；
        ///   · 已注册 kind：解码按注册 schema 逐字段校验，缺字段/类型错/值非法
        ///     → fail closed 拒该条；写侧同规则拒绝（SessionWriter 门）；
        ///   · 未注册 kind：解码透传 + 消费侧跳过 + 扫描计数（SessionLogScanner）。
        case extensionEvent(kind: String, payload: JSONValue)
    }

    var seq: Int
    var timeMs: Int64
    var payload: Payload
    var ignorable: Bool

    init(seq: Int, timeMs: Int64, payload: Payload, ignorable: Bool = false) {
        self.seq = seq
        self.timeMs = timeMs
        self.payload = payload
        self.ignorable = ignorable
    }

    /// wire type 名（dsh 事件名一比一）。
    var wireType: String {
        switch payload {
        case .turnStart: return "turn/start"
        case .turnEnd: return "turn/end"
        case .stepStart: return "step/start"
        case .stepEnd: return "step/end"
        case .userMessage: return "user/message"
        case .assistantChunk: return "assistant/chunk"
        case .assistantMessage: return "assistant/message"
        case .requestHeader: return "request/header"
        case .llmRetry: return "llm/retry"
        case .llmRetryStarted: return "llm/retry-started"
        case .sessionTitle: return "session/title"
        case .system: return "system"
        case .toolCall: return "tool/call"
        case .toolResult: return "tool/result"
        case .compactionStart: return "compaction/start"
        case .compactionSummary: return "compaction/summary"
        case .compactionEnd: return "compaction/end"
        case .compactionPrune: return "compaction/prune"
        case .commandRun: return "command/run"
        case .commandDone: return "command/done"
        case .approvalAsked: return "approval/asked"
        case .approvalDecided: return "approval/decided"
        case .extensionEvent(let kind, _): return "extension/\(kind)"
        case .ignored(let kind): return kind
        }
    }

    /// 本进程已知的事件类型集合（dsh known-event-types 语义：known 之外必须 ignorable）。
    /// E1：extension 通道的 kind 是动态集合（ExtensionEventRegistry 注册表驱动），
    /// wire 以 "extension/" 前缀恒定可辨且 defaultIgnorable 恒 true，不入本静态集合。
    static let knownTypes: Set<String> = [
        "turn/start", "turn/end", "step/start", "step/end",
        "user/message", "assistant/chunk", "assistant/message",
        "request/header", "llm/retry", "llm/retry-started",
        "session/title", "system",
        "tool/call", "tool/result",
        "compaction/start", "compaction/summary", "compaction/end", "compaction/prune",
        "command/run", "command/done",
        "approval/asked", "approval/decided",
    ]

    /// 默认 ignorable 值（信息性记录可安全跳过；核心结构事件缺省 required）。
    /// dsh 口径：command/*、approval/* 为呈现/审计记录（不影响重建）→ ignorable；
    /// tool/*、compaction/* 参与重建 → required。
    /// E1：extension 通道恒 ignorable——v2.4 修订①「旧版本读新日志不崩」的
    /// wire 承载（旧构建遇到未知 "extension/\(kind)" 类型按 ignorable 透传）。
    static func defaultIgnorable(for wireType: String) -> Bool {
        switch wireType {
        case "session/title", "system",
             "command/run", "command/done",
             "approval/asked", "approval/decided":
            return true
        default:
            return wireType.hasPrefix("extension/")
        }
    }
}

// MARK: - Codable（dsh 行格式：{"type","seq","time","ignorable"?,"data"}）

extension SessionEvent: Codable {
    private enum Keys: String, CodingKey {
        case type, seq, time, ignorable, data
    }

    // data 载荷结构（与 dsh 各事件 data 形状对应）
    private struct TurnStartData: Codable { var turn: Int }
    private struct TurnEndData: Codable { var turn: Int; var reason: TurnEndReason }
    private struct StepData: Codable { var turn: Int; var step: Int }
    private struct UserMessageData: Codable { var text: String }
    private struct AssistantChunkData: Codable {
        var turn: Int
        var step: Int
        var chunk: StreamChunk
    }
    private struct AssistantMessageData: Codable {
        var turn: Int
        var step: Int
        var message: AssistantMessage
        var usage: TokenUsage?
        var interrupted: Bool?
    }
    private struct RequestHeaderData: Codable {
        var header: EpochHeader
        var reason: String
    }
    private struct LlmRetryData: Codable {
        var retryId: String
        var turn: Int
        var step: Int
        var provider: String
        var mode: String
        var policyKey: String
        var retry: Int
        var maxRetries: Int?
        var delayMs: Int
        var failure: LlmFailure
    }
    private struct LlmRetryStartedData: Codable {
        var retryId: String
        var turn: Int
        var step: Int
        var retry: Int
    }
    private struct SessionTitleData: Codable { var title: String; var source: String }
    private struct SystemNoteData: Codable { var note: String }
    // MARK: M2 载荷结构（wire 字段 1:1 dsh）
    private struct ToolCallData: Codable {
        var turn: Int; var step: Int; var callId: String; var name: String; var arguments: String
    }
    private struct ToolResultData: Codable {
        var turn: Int; var step: Int; var callId: String
        var content: String; var isError: Bool
        var error: ToolResultError?
        var meta: JSONValue?
    }
    private struct ToolResultError: Codable {
        var name: String; var code: String
    }
    private struct CompactionStartData: Codable {
        var compactionId: String; var turn: Int?
    }
    private struct CompactionSummaryData: Codable {
        var compactionId: String; var summary: String
        var shadowedRange: ShadowedRange
        var shadowedSeqs: [Int]
        var shadowedTokenCount: Int
    }
    private struct ShadowedRange: Codable {
        var start: Int; var end: Int
    }
    private struct CompactionEndData: Codable {
        var compactionId: String; var turn: Int?; var error: String?
    }
    private struct CompactionPruneData: Codable {
        var shadowedRange: ShadowedRange
        var shadowedSeqs: [Int]
        var shadowedTokenCount: Int
    }
    private struct CommandRunData: Codable {
        var commandId: String; var name: String; var args: String?
    }
    private struct CommandDoneData: Codable {
        var commandId: String; var kind: String; var text: String?
    }
    private struct ApprovalAskedData: Codable {
        var requestId: String; var tool: String; var reason: String?
    }
    private struct ApprovalDecidedData: Codable {
        var requestId: String; var verdict: String
    }
    // MARK: E1 扩展通道载荷（data = {kind, payload}；wire type = "extension/\(kind)"）
    private struct ExtensionEventData: Codable {
        var kind: String
        var payload: JSONValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        seq = try container.decode(Int.self, forKey: .seq)
        timeMs = try container.decode(Int64.self, forKey: .time)
        ignorable = try container.decodeIfPresent(Bool.self, forKey: .ignorable) ?? false

        func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(T.self, forKey: .data)
        }

        switch type {
        case "turn/start":
            let d = try decodePayload(TurnStartData.self)
            payload = .turnStart(turn: d.turn)
        case "turn/end":
            let d = try decodePayload(TurnEndData.self)
            payload = .turnEnd(turn: d.turn, reason: d.reason)
        case "step/start":
            let d = try decodePayload(StepData.self)
            payload = .stepStart(turn: d.turn, step: d.step)
        case "step/end":
            let d = try decodePayload(StepData.self)
            payload = .stepEnd(turn: d.turn, step: d.step)
        case "user/message":
            let d = try decodePayload(UserMessageData.self)
            payload = .userMessage(text: d.text)
        case "assistant/chunk":
            let d = try decodePayload(AssistantChunkData.self)
            payload = .assistantChunk(turn: d.turn, step: d.step, chunk: d.chunk)
        case "assistant/message":
            let d = try decodePayload(AssistantMessageData.self)
            payload = .assistantMessage(turn: d.turn, step: d.step, message: d.message,
                                        usage: d.usage, interrupted: d.interrupted ?? false)
        case "request/header":
            let d = try decodePayload(RequestHeaderData.self)
            payload = .requestHeader(header: d.header, reason: d.reason)
        case "llm/retry":
            let d = try decodePayload(LlmRetryData.self)
            payload = .llmRetry(retryId: d.retryId, turn: d.turn, step: d.step,
                                provider: d.provider, mode: d.mode, policyKey: d.policyKey,
                                retry: d.retry, maxRetries: d.maxRetries, delayMs: d.delayMs,
                                failure: d.failure)
        case "llm/retry-started":
            let d = try decodePayload(LlmRetryStartedData.self)
            payload = .llmRetryStarted(retryId: d.retryId, turn: d.turn, step: d.step, retry: d.retry)
        case "session/title":
            let d = try decodePayload(SessionTitleData.self)
            payload = .sessionTitle(title: d.title, source: d.source)
        case "system":
            let d = try decodePayload(SystemNoteData.self)
            payload = .system(note: d.note)
        case "tool/call":
            let d = try decodePayload(ToolCallData.self)
            payload = .toolCall(turn: d.turn, step: d.step, callId: d.callId,
                                name: d.name, arguments: d.arguments)
        case "tool/result":
            let d = try decodePayload(ToolResultData.self)
            payload = .toolResult(turn: d.turn, step: d.step, callId: d.callId,
                                  content: d.content, isError: d.isError,
                                  errorName: d.error?.name, errorCode: d.error?.code,
                                  meta: d.meta)
        case "compaction/start":
            let d = try decodePayload(CompactionStartData.self)
            payload = .compactionStart(compactionId: d.compactionId, turn: d.turn)
        case "compaction/summary":
            let d = try decodePayload(CompactionSummaryData.self)
            payload = .compactionSummary(compactionId: d.compactionId, summary: d.summary,
                                         shadowedRangeStart: d.shadowedRange.start,
                                         shadowedRangeEnd: d.shadowedRange.end,
                                         shadowedSeqs: d.shadowedSeqs,
                                         shadowedTokenCount: d.shadowedTokenCount)
        case "compaction/end":
            let d = try decodePayload(CompactionEndData.self)
            payload = .compactionEnd(compactionId: d.compactionId, turn: d.turn, error: d.error)
        case "compaction/prune":
            let d = try decodePayload(CompactionPruneData.self)
            payload = .compactionPrune(shadowedSeqs: d.shadowedSeqs,
                                       shadowedTokenCount: d.shadowedTokenCount)
        case "command/run":
            let d = try decodePayload(CommandRunData.self)
            payload = .commandRun(commandId: d.commandId, name: d.name, args: d.args)
        case "command/done":
            let d = try decodePayload(CommandDoneData.self)
            payload = .commandDone(commandId: d.commandId, kind: d.kind, text: d.text)
        case "approval/asked":
            let d = try decodePayload(ApprovalAskedData.self)
            payload = .approvalAsked(requestId: d.requestId, tool: d.tool, reason: d.reason)
        case "approval/decided":
            let d = try decodePayload(ApprovalDecidedData.self)
            payload = .approvalDecided(requestId: d.requestId, verdict: d.verdict)
        default:
            // E1 扩展通道：wire type "extension/\(kind)"（kind 归注册表管）。
            if type.hasPrefix("extension/") {
                let kindFromType = String(type.dropFirst("extension/".count))
                let d = try decodePayload(ExtensionEventData.self)
                // wire/data kind 一致性（fail closed：拼错的行不可静默读入）。
                guard !d.kind.isEmpty, d.kind == kindFromType else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container,
                        debugDescription: "extension event kind mismatch: type \"\(type)\" vs data.kind \"\(d.kind)\"")
                }
                // 已注册 kind：schema 逐字段校验，缺字段/类型错/值非法
                // → fail closed 拒该条（v2.4 修订①）。未注册 kind：透传
                // （消费侧跳过 + SessionLogScanner 计数）。
                if let reason = ExtensionEventRegistry.shared.validationReason(
                    kind: d.kind, payload: d.payload) {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container,
                        debugDescription: "extension event \"\(d.kind)\" failed schema validation: \(reason)")
                }
                payload = .extensionEvent(kind: d.kind, payload: d.payload)
            } else {
                // 未识别类型：ignorable → 透传；否则拒绝重建（dsh 语义：静默跳过
                // 必需事件可能把会话读错，宁可拒绝）。
                guard ignorable else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container,
                        debugDescription: "unknown required session event type \"\(type)\"; refusing to reconstruct session")
                }
                payload = .ignored(kind: type)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(wireType, forKey: .type)
        try container.encode(seq, forKey: .seq)
        try container.encode(timeMs, forKey: .time)
        if ignorable {
            try container.encode(true, forKey: .ignorable)
        }
        switch payload {
        case .turnStart(let turn):
            try container.encode(TurnStartData(turn: turn), forKey: .data)
        case .turnEnd(let turn, let reason):
            try container.encode(TurnEndData(turn: turn, reason: reason), forKey: .data)
        case .stepStart(let turn, let step):
            try container.encode(StepData(turn: turn, step: step), forKey: .data)
        case .stepEnd(let turn, let step):
            try container.encode(StepData(turn: turn, step: step), forKey: .data)
        case .userMessage(let text):
            try container.encode(UserMessageData(text: text), forKey: .data)
        case .assistantChunk(let turn, let step, let chunk):
            try container.encode(AssistantChunkData(turn: turn, step: step, chunk: chunk), forKey: .data)
        case .assistantMessage(let turn, let step, let message, let usage, let interrupted):
            try container.encode(
                AssistantMessageData(turn: turn, step: step, message: message,
                                     usage: usage, interrupted: interrupted ? true : nil),
                forKey: .data)
        case .requestHeader(let header, let reason):
            try container.encode(RequestHeaderData(header: header, reason: reason), forKey: .data)
        case .llmRetry(let retryId, let turn, let step, let provider, let mode,
                       let policyKey, let retry, let maxRetries, let delayMs, let failure):
            try container.encode(
                LlmRetryData(retryId: retryId, turn: turn, step: step, provider: provider,
                             mode: mode, policyKey: policyKey, retry: retry,
                             maxRetries: maxRetries, delayMs: delayMs, failure: failure),
                forKey: .data)
        case .llmRetryStarted(let retryId, let turn, let step, let retry):
            try container.encode(
                LlmRetryStartedData(retryId: retryId, turn: turn, step: step, retry: retry),
                forKey: .data)
        case .sessionTitle(let title, let source):
            try container.encode(SessionTitleData(title: title, source: source), forKey: .data)
        case .system(let note):
            try container.encode(SystemNoteData(note: note), forKey: .data)
        case .toolCall(let turn, let step, let callId, let name, let arguments):
            try container.encode(
                ToolCallData(turn: turn, step: step, callId: callId, name: name,
                             arguments: arguments),
                forKey: .data)
        case .toolResult(let turn, let step, let callId, let content, let isError,
                         let errorName, let errorCode, let meta):
            let error: ToolResultError?
            if let errorName, let errorCode {
                error = ToolResultError(name: errorName, code: errorCode)
            } else {
                error = nil
            }
            try container.encode(
                ToolResultData(turn: turn, step: step, callId: callId, content: content,
                               isError: isError, error: error, meta: meta),
                forKey: .data)
        case .compactionStart(let compactionId, let turn):
            try container.encode(CompactionStartData(compactionId: compactionId, turn: turn),
                                 forKey: .data)
        case .compactionSummary(let compactionId, let summary, let rangeStart, let rangeEnd,
                                let seqs, let tokens):
            try container.encode(
                CompactionSummaryData(compactionId: compactionId, summary: summary,
                                      shadowedRange: ShadowedRange(start: rangeStart, end: rangeEnd),
                                      shadowedSeqs: seqs, shadowedTokenCount: tokens),
                forKey: .data)
        case .compactionEnd(let compactionId, let turn, let error):
            try container.encode(
                CompactionEndData(compactionId: compactionId, turn: turn, error: error),
                forKey: .data)
        case .compactionPrune(let seqs, let tokens):
            // shadowedRange 单点语义照 dsh pruner（start==end 为单节点 prune）。
            let range = ShadowedRange(start: seqs.first ?? 0, end: seqs.last ?? 0)
            try container.encode(
                CompactionPruneData(shadowedRange: range, shadowedSeqs: seqs,
                                    shadowedTokenCount: tokens),
                forKey: .data)
        case .commandRun(let commandId, let name, let args):
            try container.encode(CommandRunData(commandId: commandId, name: name, args: args),
                                 forKey: .data)
        case .commandDone(let commandId, let kind, let text):
            try container.encode(CommandDoneData(commandId: commandId, kind: kind, text: text),
                                 forKey: .data)
        case .approvalAsked(let requestId, let tool, let reason):
            try container.encode(
                ApprovalAskedData(requestId: requestId, tool: tool, reason: reason),
                forKey: .data)
        case .approvalDecided(let requestId, let verdict):
            try container.encode(ApprovalDecidedData(requestId: requestId, verdict: verdict),
                                 forKey: .data)
        case .extensionEvent(let kind, let payload):
            try container.encode(ExtensionEventData(kind: kind, payload: payload),
                                 forKey: .data)
        case .ignored:
            // 外来事件不回写；防御性编码为仅类型标记。
            try container.encode([String: String](), forKey: .data)
        }
    }
}

// MARK: - SessionHeader（JSONL 首行；dsh SessionHeader 子集）

/// 会话头（存储元数据，不入事件流；dsh format.ts HeaderLine 词汇）。
struct SessionHeader: Codable, Equatable, Sendable {
    /// 磁盘格式版本（dsh SESSION_FORMAT_VERSION 语义：不兼容日志拒绝加载，不做迁移）。
    var version: Int
    var id: String
    var createdAtMs: Int64
    /// 会话工作目录（M1 恒为 /var/wanwo/workspace）。
    var cwd: String?

    static let currentVersion = 0

    init(id: String, createdAtMs: Int64, cwd: String?) {
        self.version = SessionHeader.currentVersion
        self.id = id
        self.createdAtMs = createdAtMs
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, createdAt, cwd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAt)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(createdAtMs, forKey: .createdAt)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
}

/// 会话摘要（GRDB 会话索引投影行 + 列表 UI 数据源）。
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    var title: String?
    var createdAt: Date
    var updatedAt: Date
    var eventCount: Int
}
