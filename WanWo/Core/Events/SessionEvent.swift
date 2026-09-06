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
        /// 外来未来事件（带 ignorable 标记透传；本进程永不主动写入）。
        case ignored(kind: String)
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
        case .ignored(let kind): return kind
        }
    }

    /// 本进程已知的事件类型集合（dsh known-event-types 语义：known 之外必须 ignorable）。
    static let knownTypes: Set<String> = [
        "turn/start", "turn/end", "step/start", "step/end",
        "user/message", "assistant/chunk", "assistant/message",
        "request/header", "llm/retry", "llm/retry-started",
        "session/title", "system",
    ]

    /// 默认 ignorable 值（信息性记录可安全跳过；核心结构事件缺省 required）。
    static func defaultIgnorable(for wireType: String) -> Bool {
        switch wireType {
        case "session/title", "system": return true
        default: return false
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
        default:
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
