//
//  LLMTypes.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - dsh packages/llm/llm-deepseek/src/types.ts（wire 词汇）
//    - dsh packages/llm/llm-deepseek/src/translate.ts（StreamChunk / FinishReason / mapUsage 语义）
//    - dsh packages/core/session/src/types.ts（TokenUsage / EpochHeader / LlmFailure 词汇）
//    - 10-design §5.5（StreamChunk = text|thinking|toolCall|usage|done）
//  M1 子集：文本 + reasoning + usage + finish；tool-call 词汇按 dsh 1:1 保留
//  （translate 逻辑完整移植），工具执行在 M2 接入。
//

import Foundation

// MARK: - TokenUsage

/// 六分格计量的 M1 子集。口径对齐 dsh mapUsage：prompt_tokens 含缓存命中，
/// cacheRead 从 inputTokens 中减出（分桶不重复计数，10-design §5.5）。
struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int?
    var cacheReadTokens: Int?
    var reasoningTokens: Int?

    init(inputTokens: Int,
         outputTokens: Int,
         totalTokens: Int? = nil,
         cacheReadTokens: Int? = nil,
         reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
    }
}

// MARK: - LlmFailure

/// 结构化失败（dsh LlmFailure：message + 稳定 code；turn/end error 载荷）。
struct LlmFailure: Codable, Equatable, Sendable {
    var message: String
    var code: String

    init(message: String, code: String) {
        self.message = message
        self.code = code
    }
}

// MARK: - ContentBlock

/// 助手消息内容块（dsh ContentBlock 词汇：text / reasoning / tool-call）。
enum ContentBlock: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, arguments: String)
}

extension ContentBlock: Codable {
    private enum BlockType: String, Codable {
        case text
        case reasoning
        case toolCall = "tool-call"
    }

    private enum Keys: String, CodingKey {
        case type, text, id, name, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(BlockType.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .reasoning:
            self = .reasoning(try container.decode(String.self, forKey: .text))
        case .toolCall:
            self = .toolCall(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                arguments: try container.decode(String.self, forKey: .arguments))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let text):
            try container.encode(BlockType.reasoning, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolCall(let id, let name, let arguments):
            try container.encode(BlockType.toolCall, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

// MARK: - ToolCallSpec / ToolSchemaEntry（M2 扩展）

/// assistant 消息携带的工具调用（OpenAI wire assistant.tool_calls 单元；
/// arguments 为模型原始 JSON 文本，与 tool/call 事件 1:1）。
struct ToolCallSpec: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 发给模型的工具 schema（dsh ToolSchema 词汇：name/description/parameters）。
struct ToolSchemaEntry: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue

    init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - AssistantMessage

/// 一条助手消息（dsh AssistantMessage 词汇；tool-call 块在 M2 由派生历史上映 wire）。
struct AssistantMessage: Codable, Equatable, Sendable {
    var id: String
    var role: String
    var provider: String
    var model: String
    var content: [ContentBlock]

    init(id: String, provider: String, model: String, content: [ContentBlock]) {
        self.id = id
        self.role = "assistant"
        self.provider = provider
        self.model = model
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, provider, model, content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        content = try container.decode([ContentBlock].self, forKey: .content)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(content, forKey: .content)
    }
}

// MARK: - ChatMessage

/// 派生历史消息（dsh Message 词汇；M2 扩展：assistant tool_calls + tool 结果消息，
/// 对应 OpenAI wire 的 assistant.tool_calls / role:"tool" + tool_call_id）。
struct ChatMessage: Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    var role: Role
    var content: String
    /// assistant 角色携带的工具调用（随消息上 wire）。
    var toolCalls: [ToolCallSpec]?
    /// tool 角色消息对应的调用 id（wire tool_call_id）。
    var toolCallID: String?

    init(role: Role,
         content: String,
         toolCalls: [ToolCallSpec]? = nil,
         toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

// MARK: - FinishReason

/// 模型停止原因（dsh FinishReason；未识别 wire 值映射为 error）。
enum FinishReason: Equatable, Sendable {
    case stop
    case toolCalls
    case maxTokens
    case error(LlmFailure)
}

extension FinishReason: Codable {
    private enum Kind: String, Codable {
        case stop
        case toolCalls = "tool-calls"
        case maxTokens = "max-tokens"
        case error
    }

    private enum Keys: String, CodingKey {
        case kind, failure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stop: self = .stop
        case .toolCalls: self = .toolCalls
        case .maxTokens: self = .maxTokens
        case .error:
            self = .error(try container.decode(LlmFailure.self, forKey: .failure))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .stop:
            try container.encode(Kind.stop, forKey: .kind)
        case .toolCalls:
            try container.encode(Kind.toolCalls, forKey: .kind)
        case .maxTokens:
            try container.encode(Kind.maxTokens, forKey: .kind)
        case .error(let failure):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        }
    }
}

// MARK: - StreamChunk

/// 模型流块（dsh StreamChunk 词汇 1:1；finish/usage 延迟到 [DONE] 统一发射，见 translate.ts）。
enum StreamChunk: Equatable, Sendable {
    case blockStart(index: Int, blockType: String)
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case toolCallDelta(index: Int, id: String, name: String?, argumentsDelta: String)
    case blockEnd(index: Int, block: ContentBlock)
    case usage(TokenUsage)
    case finish(FinishReason)
}

extension StreamChunk: Codable {
    private enum Keys: String, CodingKey {
        case type, index, blockType, text, id, name
        case argumentsDelta
        case block, usage, finish
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .type)
        switch kind {
        case "block-start":
            self = .blockStart(
                index: try container.decode(Int.self, forKey: .index),
                blockType: try container.decode(String.self, forKey: .blockType))
        case "text-delta":
            self = .textDelta(
                index: try container.decode(Int.self, forKey: .index),
                text: try container.decode(String.self, forKey: .text))
        case "reasoning-delta":
            self = .reasoningDelta(
                index: try container.decode(Int.self, forKey: .index),
                text: try container.decode(String.self, forKey: .text))
        case "tool-call-delta":
            self = .toolCallDelta(
                index: try container.decode(Int.self, forKey: .index),
                id: try container.decode(String.self, forKey: .id),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                argumentsDelta: try container.decode(String.self, forKey: .argumentsDelta))
        case "block-end":
            self = .blockEnd(
                index: try container.decode(Int.self, forKey: .index),
                block: try container.decode(ContentBlock.self, forKey: .block))
        case "usage":
            self = .usage(try container.decode(TokenUsage.self, forKey: .usage))
        case "finish":
            self = .finish(try container.decode(FinishReason.self, forKey: .finish))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown StreamChunk type \"\(kind)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .blockStart(let index, let blockType):
            try container.encode("block-start", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(blockType, forKey: .blockType)
        case .textDelta(let index, let text):
            try container.encode("text-delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(text, forKey: .text)
        case .reasoningDelta(let index, let text):
            try container.encode("reasoning-delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(text, forKey: .text)
        case .toolCallDelta(let index, let id, let name, let argumentsDelta):
            try container.encode("tool-call-delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(argumentsDelta, forKey: .argumentsDelta)
        case .blockEnd(let index, let block):
            try container.encode("block-end", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(block, forKey: .block)
        case .usage(let usage):
            try container.encode("usage", forKey: .type)
            try container.encode(usage, forKey: .usage)
        case .finish(let reason):
            try container.encode("finish", forKey: .type)
            try container.encode(reason, forKey: .finish)
        }
    }
}

// MARK: - LlmCallConfig / EpochHeader

/// 会话级调用配置（dsh LlmCallConfig 子集）。
struct LlmCallConfig: Codable, Equatable, Sendable {
    var provider: String
    var model: String
    var reasoningEffort: String?
    var maxTokens: Int?

    init(provider: String, model: String, reasoningEffort: String? = nil, maxTokens: Int? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens
    }
}

/// 已记录的请求头快照（dsh EpochHeader：config + system + tools；
/// 「最新一份 request/header 快照可重建整个请求头」（dsh 语义））。
struct EpochHeader: Codable, Equatable, Sendable {
    var config: LlmCallConfig
    var system: String?
    /// 本次请求暴露给模型的工具 schema（M2 起；无工具请求缺省不编码）。
    var tools: [ToolSchemaEntry]?

    init(config: LlmCallConfig, system: String? = nil, tools: [ToolSchemaEntry]? = nil) {
        self.config = config
        self.system = system
        self.tools = tools
    }
}

// MARK: - LLMRequest / LLMError

/// 一次模型调用请求（adapter 层输入；内容由派生历史组装，见 SessionWriter.deriveMessages）。
struct LLMRequest: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var system: String?
    var messages: [ChatMessage]
    var maxTokens: Int?
    var temperature: Double?
    /// DeepSeek 扩展透传（09 #16）：enabled | disabled，可选。
    var thinking: String?
    /// DeepSeek 扩展透传（09 #16）：off | low | high | max，可选。
    var reasoningEffort: String?
    /// 请求用途标记（如 "session-title"，见 dsh serialize resolveThinking）。
    var purpose: String?
    /// M2：随请求暴露的工具 schema（无工具请求缺省不发 tools 字段）。
    var tools: [ToolSchemaEntry]?

    init(baseURL: String,
         apiKey: String,
         model: String,
         system: String? = nil,
         messages: [ChatMessage] = [],
         maxTokens: Int? = nil,
         temperature: Double? = nil,
         thinking: String? = nil,
         reasoningEffort: String? = nil,
         purpose: String? = nil,
         tools: [ToolSchemaEntry]? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.purpose = purpose
        self.tools = tools
    }
}

/// 模型层错误（dsh LlmError 的 Swift 形态：稳定 code + 可选 status/Retry-After + 错误体透传）。
struct LLMError: Error, Equatable, Sendable {
    var message: String
    var code: String
    var status: Int?
    var providerRetryAfterMs: Int?
    var isCallerAbort: Bool
    var causeText: String?

    init(message: String,
         code: String,
         status: Int? = nil,
         providerRetryAfterMs: Int? = nil,
         isCallerAbort: Bool = false,
         causeText: String? = nil) {
        self.message = message
        self.code = code
        self.status = status
        self.providerRetryAfterMs = providerRetryAfterMs
        self.isCallerAbort = isCallerAbort
        self.causeText = causeText
    }

    var failure: LlmFailure {
        LlmFailure(message: message, code: code)
    }
}

// MARK: - HTTP 错误码映射（dsh adapter.ts httpErrorCode 1:1 移植）

/// 非 2xx 状态 + 错误体 → 稳定错误码（dsh httpErrorCode 语义）。
func httpErrorCode(status: Int, errorDetail: String?) -> String {
    if status == 401 || status == 403 { return "AUTH" }
    if status == 413 { return "INVALID_REQUEST" }
    let detail = errorDetail ?? ""
    if detail.range(of: "quota|insufficient balance|insufficient.*quota", options: [.regularExpression, .caseInsensitive]) != nil {
        return "QUOTA_EXCEEDED"
    }
    if status == 429 { return "RATE_LIMIT" }
    if status == 400 {
        if detail.range(of: "context length|maximum context|too many tokens", options: [.regularExpression, .caseInsensitive]) != nil {
            return "CONTEXT_WINDOW_EXCEEDED"
        }
        return "INVALID_REQUEST"
    }
    if status >= 500 { return "SERVER" }
    return "HTTP_\(status)"
}

/// 解析 Retry-After 头（dsh providerRetryAfterMs：秒数或 HTTP 日期）。
func providerRetryAfterMs(fromHeaderValue value: String?) -> Int? {
    guard let value = value, !value.isEmpty else { return nil }
    if let seconds = Int(value), seconds > 0 {
        return seconds * 1_000
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: value) {
        let delay = Int(date.timeIntervalSinceNow * 1000)
        return delay > 0 ? delay : nil
    }
    return nil
}
