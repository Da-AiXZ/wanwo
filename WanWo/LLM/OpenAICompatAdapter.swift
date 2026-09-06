//
//  OpenAICompatAdapter.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - dsh packages/llm/llm-deepseek/src/adapter.ts（fetch + SSE；非 2xx 错误体透传 +
//      httpErrorCode；流空闲 5min watchdog；连接事实与凭据同代配对）
//    - dsh packages/llm/llm-deepseek/src/sse.ts（[DONE] 终止；EOF 缺 [DONE] = STREAM_CLOSED）
//    - dsh packages/llm/llm-deepseek/src/translate.ts（wire chunk → StreamChunk 全量移植）
//    - dsh packages/llm/llm-deepseek/src/serialize.ts（wire 请求序列化：stream:true +
//      stream_options.include_usage + thinking/reasoning_effort 扩展字段）
//    - 10-design §5.5 v2.1（09 #16：OpenAI 兼容格式接入，base URL/key/model 用户自填；
//      DeepSeek 经此格式；M1 只做文本流，图片策略后置）
//  传输：URLSession.bytes 逐行解析 SSE（不引第三方 HTTP 库，§2.4）。
//

import Foundation

/// OpenAI 兼容 chat-completions 流式 adapter（transport-only；连接事实随构造冻结，
/// 一次请求内不观察配置变化——dsh streamWithConnection 的单次解析语义）。
struct OpenAICompatAdapter {
    /// 默认流空闲超时（dsh DEFAULT_STREAM_IDLE_TIMEOUT_MS = 300_000）。
    static let defaultStreamIdleTimeout: TimeInterval = 300

    let endpoint: EndpointConfig
    let apiKey: String
    let providerName: String
    let streamIdleTimeout: TimeInterval

    init(endpoint: EndpointConfig, apiKey: String, providerName: String? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.providerName = providerName ?? endpoint.name
        self.streamIdleTimeout = Self.defaultStreamIdleTimeout
    }

    // MARK: - 流式调用

    /// 流式生成 StreamChunk。取消传播：消费方取消 Task → ABORTED；空闲 5min → TIMEOUT。
    /// 结构化实现（等价 dsh AbortSignal.any 融合）：消费子任务与看门狗子任务同组，
    /// 任一先结束即取消全组；错误按 tracker.didTimeout / 取消状态分类。
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let tracker = ActivityTracker()
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await Self.watchdog(tracker: tracker, interval: self.streamIdleTimeout)
                        }
                        group.addTask {
                            try await self.runChunks(request, tracker: tracker) { chunk in
                                continuation.yield(chunk)
                            }
                        }
                        try await group.next()
                        group.cancelAll()
                        _ = try? await group.next() // 等另一子任务收尾
                    }
                    continuation.finish()
                } catch {
                    if tracker.didTimeout {
                        continuation.finish(throwing: LLMError(
                            message: "stream idle timeout after \(Int(self.streamIdleTimeout))s",
                            code: "TIMEOUT"))
                    } else if Task.isCancelled, !(error is LLMError) {
                        continuation.finish(throwing: LLMError(
                            message: "request aborted by caller", code: "ABORTED",
                            isCallerAbort: true))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 看门狗子任务：空闲超 interval 即标记并抛 TIMEOUT（触发组取消 → 读终止）。
    private static func watchdog(tracker: ActivityTracker, interval: TimeInterval) async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            if tracker.idleSeconds() >= interval {
                tracker.markTimeout()
                throw LLMError(message: "stream idle timeout", code: "TIMEOUT")
            }
        }
    }

    private func runChunks(_ request: LLMRequest,
                           tracker: ActivityTracker,
                           _ yield: (StreamChunk) -> Void) async throws {
        // 1. wire 请求序列化（serialize.ts 语义：可选字段缺省不发 null）
        let urlRequest = try buildURLRequest(request)

        // 2. 初始 fetch（dsh：初始 fetch 与 body 读共用一个信号；TRANSPORT 分类）
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw LLMError(message: "request to \(endpoint.baseURL) failed: \(error.localizedDescription)",
                           code: "TRANSPORT", causeText: String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(message: "non-HTTP response", code: "TRANSPORT")
        }

        // 3. 非 2xx：错误体透传（dsh：HTTP status 权威，body 原样带在 causeText）
        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await byteChunk in bytes {
                body += String(decoding: [byteChunk], as: UTF8.self)
                tracker.pulse()
            }
            var providerMessage = "API error (HTTP \(http.statusCode))"
            var providerDetail: String?
            if let parsed = try? JSONDecoder().decode(WireErrorBody.self, from: Data(body.utf8)),
               let errorMessage = parsed.error?.message {
                providerMessage = errorMessage
                providerDetail = [parsed.error?.code, parsed.error?.type, parsed.error?.message]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            throw LLMError(
                message: providerMessage,
                code: httpErrorCode(status: http.statusCode, errorDetail: providerDetail),
                status: http.statusCode,
                providerRetryAfterMs: providerRetryAfterMs(
                    fromHeaderValue: http.value(forHTTPHeaderField: "Retry-After")),
                causeText: body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }

        // 4. SSE 行装配 → wire chunk 翻译（translate.ts 全量语义）
        var assembler = SSEAssembler()
        var translator = ChunkTranslator()
        // STREAM_CLOSED 诊断事实（一次性给足：行数 / 载荷数 / 最后载荷前 200 字符），
        // 服务端「200 + 错误 JSON 载荷 + 关流」时用户下次重跑即可看到真实载荷。
        var lineCount = 0
        var payloadCount = 0
        var lastPayload: String?
        for try await line in bytes.lines {
            lineCount += 1
            tracker.pulse()
            switch assembler.consume(line: line) {
            case .payload(let payload):
                payloadCount += 1
                lastPayload = payload
                // [DONE] 是流终止哨兵，不是模型载荷——先判后喂（dsh parseSse 顺序），
                // 绝不进入 translator（喂入会被当 JSON 解析并误抛 MALFORMED_RESPONSE）。
                if payload == SSE.done {
                    return // dsh parseSse：[DONE] 即正常终止
                }
                let chunks = try translator.consume(payload: payload)
                for chunk in chunks {
                    yield(chunk)
                }
            case .activity, .none:
                break
            }
        }
        // EOF 前未见 [DONE]：截断响应，不可信（dsh STREAM_CLOSED）。
        // 诊断载荷：last 为空说明服务端一个 data: 都没发（如对不存在模型直接关流）；
        // last 非 JSON 说明服务端发了错误对象（典型：已下线模型名 / 鉴权失败）。
        let lastSummary = lastPayload.map { String($0.prefix(200)) } ?? "∅"
        throw LLMError(
            message: "SSE stream ended without [DONE] "
                + "(lines=\(lineCount), payloads=\(payloadCount), last=\(lastSummary))",
            code: "STREAM_CLOSED")
    }

    // MARK: - wire 序列化（serialize.ts requestWithMessages 语义）

    private func buildURLRequest(_ request: LLMRequest) throws -> URLRequest {
        var wireMessages: [WireMessage] = []
        if let system = request.system, !system.isEmpty {
            wireMessages.append(WireMessage(role: "system", content: system))
        }
        for message in request.messages {
            // M1 文本流：assistant/tool 内容拍平为字符串文本（tool 消息 M2 起扩展）。
            wireMessages.append(WireMessage(role: message.role.rawValue, content: message.content))
        }

        // resolveThinking（serialize.ts）：session-title 强制关闭思考；effort off → disabled。
        var thinkingType: String?
        var wireEffort: String?
        if request.purpose == "session-title" {
            thinkingType = "disabled"
        } else if let effort = request.reasoningEffort {
            if effort == "off" {
                thinkingType = "disabled"
            } else {
                thinkingType = "enabled"
                wireEffort = effort
            }
        } else if let thinking = request.thinking {
            thinkingType = thinking
        }

        let wire = WireRequest(
            model: request.model,
            messages: wireMessages,
            stream: true,
            stream_options: WireStreamOptions(include_usage: true),
            thinking: thinkingType.map { WireThinking(type: $0) },
            reasoning_effort: wireEffort,
            temperature: request.temperature,
            max_tokens: request.maxTokens)

        var url = URL(string: endpoint.baseURL) ?? URL(string: "https://localhost")!
        if endpoint.baseURL.hasSuffix("/") {
            url.appendPathComponent("chat/completions")
        } else {
            url.append(path: "chat/completions")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(wire)
        return urlRequest
    }
}

// MARK: - wire 类型（dsh types.ts 词汇）

struct WireMessage: Codable {
    var role: String
    var content: String
}

struct WireThinking: Codable {
    var type: String
}

struct WireStreamOptions: Codable {
    var include_usage: Bool
}

struct WireRequest: Codable {
    var model: String
    var messages: [WireMessage]
    var stream: Bool
    var stream_options: WireStreamOptions
    var thinking: WireThinking?
    var reasoning_effort: String?
    var temperature: Double?
    var max_tokens: Int?
}

/// 非 2xx 错误体（dsh WireError：{error: {message, code, type}}）。
struct WireErrorBody: Decodable {
    struct WireErrorDetail: Decodable {
        var message: String?
        var code: String?
        var type: String?
    }
    var error: WireErrorDetail?
}

/// SSE 数据载荷形状（dsh types.ts WireChunk）。
struct WireChunk: Decodable {
    struct WireDeltaToolCall: Decodable {
        var index: Int?
        var id: String?
        var function: WireFunctionDelta?
    }
    struct WireFunctionDelta: Decodable {
        var name: String?
        var arguments: String?
    }
    struct WireDelta: Decodable {
        var content: String?
        var reasoning_content: String?
        var tool_calls: [WireDeltaToolCall]?
    }
    struct WireChoice: Decodable {
        var delta: WireDelta?
        var finish_reason: String?
    }
    struct WireUsageDetails: Decodable {
        var cached_tokens: Int?
        var reasoning_tokens: Int?
    }
    struct WireUsage: Decodable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var total_tokens: Int?
        var prompt_cache_hit_tokens: Int?
        var prompt_tokens_details: WireUsageDetails?
        var completion_tokens_details: WireUsageDetails?
    }

    var choices: [WireChoice]?
    var usage: WireUsage?
}

// MARK: - ChunkTranslator（dsh translate.ts 1:1 语义移植）

/// 有状态翻译器：SSE 载荷 → StreamChunk；finish/usage 延迟到 [DONE] 统一发射。
/// 每个内容/推理/工具调用 index 一个开放块（dsh OpenBlock）。
struct ChunkTranslator {
    private struct OpenBlock {
        var kind: String
        var text: String
        var callId: String?
        var name: String?
    }

    private var nextIndex = 0
    private var blocks: [OpenBlock] = []
    private var textIndex: Int?
    private var reasoningIndex: Int?
    /// wire tool-call index → 开放块 index（dsh toolBlocks）。
    private var toolBlocks: [Int: Int] = [:]
    private var pendingFinish: FinishReason?
    private var pendingUsage: TokenUsage?

    /// dsh mapFinishReason：未识别值 → error finish（大写化 code）。
    private static func mapFinishReason(_ reason: String) -> FinishReason {
        switch reason {
        case "stop": return .stop
        case "tool_calls": return .toolCalls
        case "length": return .maxTokens
        default:
            return .error(LlmFailure(message: "model stopped: \(reason)",
                                     code: reason.uppercased()))
        }
    }

    /// dsh mapUsage：DeepSeek prompt_tokens 含缓存命中 → 减出（分桶不重复计数）。
    private static func mapUsage(_ usage: WireChunk.WireUsage) -> TokenUsage {
        let cacheRead = usage.prompt_tokens_details?.cached_tokens
            ?? usage.prompt_cache_hit_tokens
        let reasoning = usage.completion_tokens_details?.reasoning_tokens
        let prompt = usage.prompt_tokens ?? 0
        let completion = usage.completion_tokens ?? 0
        let combined = prompt + completion
        let hasExactTotal = usage.prompt_tokens != nil
            && prompt >= 0 && completion >= 0
            && (usage.total_tokens == nil || usage.total_tokens == combined)
        return TokenUsage(
            inputTokens: prompt - (cacheRead ?? 0),
            outputTokens: completion,
            totalTokens: hasExactTotal ? combined : nil,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning)
    }

    /// dsh acceptIdentity：id/name 是身份不是累积；空串或 null = 不更新（绝不"清空"）。
    private static func acceptIdentity(current: String?, incoming: String?) -> String? {
        if let incoming = incoming, !incoming.isEmpty { return incoming }
        return current
    }

    private mutating func open(kind: String) -> Int {
        let index = nextIndex
        nextIndex += 1
        blocks.append(OpenBlock(kind: kind, text: "", callId: nil, name: nil))
        return index
    }

    private func closeBlock(_ block: OpenBlock) -> ContentBlock {
        switch block.kind {
        case "text": return .text(block.text)
        case "reasoning": return .reasoning(block.text)
        default: return .toolCall(id: block.callId ?? "", name: block.name ?? "",
                                  arguments: block.text)
        }
    }

    /// 消费一个 SSE 载荷，返回应发射的 StreamChunk 序列。
    /// 载荷为 [DONE] 时返回收尾序列（block-end × n + usage? + finish）。
    mutating func consume(payload: String) throws -> [StreamChunk] {
        if payload == SSE.done {
            return finishChunks()
        }
        let chunk: WireChunk
        do {
            chunk = try JSONDecoder().decode(WireChunk.self, from: Data(payload.utf8))
        } catch {
            throw LLMError(
                message: "malformed SSE payload: \(String(payload.prefix(120)))",
                code: "MALFORMED_RESPONSE")
        }

        var out: [StreamChunk] = []
        for choice in chunk.choices ?? [] {
            let delta = choice.delta

            // reasoning 先于 text（thinking 模式交错在前；空首块不开 block）。
            if let reasoning = delta?.reasoning_content, !reasoning.isEmpty {
                if reasoningIndex == nil {
                    let index = open(kind: "reasoning")
                    reasoningIndex = index
                    out.append(.blockStart(index: index, blockType: "reasoning"))
                }
                blocks[reasoningIndex!].text += reasoning
                out.append(.reasoningDelta(index: reasoningIndex!, text: reasoning))
            }

            if let content = delta?.content, !content.isEmpty {
                if textIndex == nil {
                    let index = open(kind: "text")
                    textIndex = index
                    out.append(.blockStart(index: index, blockType: "text"))
                }
                blocks[textIndex!].text += content
                out.append(.textDelta(index: textIndex!, text: content))
            }

            for call in delta?.tool_calls ?? [] {
                let wireIndex = call.index ?? blocks.count
                let blockIndex: Int
                if let existing = toolBlocks[wireIndex] {
                    blockIndex = existing
                } else {
                    blockIndex = open(kind: "tool-call")
                    toolBlocks[wireIndex] = blockIndex
                    out.append(.blockStart(index: blockIndex, blockType: "tool-call"))
                }
                // id/name 是身份，不是累积（dsh acceptIdentity）。
                blocks[blockIndex].callId = Self.acceptIdentity(
                    current: blocks[blockIndex].callId, incoming: call.id)
                blocks[blockIndex].name = Self.acceptIdentity(
                    current: blocks[blockIndex].name, incoming: call.function?.name)
                let fragment = call.function?.arguments ?? ""
                blocks[blockIndex].text += fragment
                out.append(.toolCallDelta(
                    index: blockIndex,
                    id: blocks[blockIndex].callId ?? "",
                    name: blocks[blockIndex].name,
                    argumentsDelta: fragment))
            }

            if let reason = choice.finish_reason {
                pendingFinish = Self.mapFinishReason(reason)
            }
        }

        // usage 可挂在 finish chunk 上，也可随尾随 usage-only chunk —— 保留最新。
        if let usage = chunk.usage {
            pendingUsage = Self.mapUsage(usage)
        }
        return out
    }

    /// [DONE]：全部 block 收尾 + usage + finish（dsh：stop 且零块 → EMPTY_RESPONSE）。
    private func finishChunks() -> [StreamChunk] {
        var out: [StreamChunk] = []
        for (index, block) in blocks.enumerated() {
            out.append(.blockEnd(index: index, block: closeBlock(block)))
        }
        if let usage = pendingUsage {
            out.append(.usage(usage))
        }
        let reason = pendingFinish ?? FinishReason.stop
        let finalReason: FinishReason
        if case .stop = reason, blocks.isEmpty {
            finalReason = .error(LlmFailure(
                message: "model returned a completed response with no content",
                code: "EMPTY_RESPONSE"))
        } else {
            finalReason = reason
        }
        out.append(.finish(finalReason))
        return out
    }
}
