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
//  传输：URLSession uploadTask 显式上传 body + URLSessionDataDelegate 流式逐块接收
//  （← OpenMinis OAuthHTTPClient.swift:1426-1454 同款模式；不引第三方 HTTP 库，§2.4）。
//  注意：URLSession.upload(for:from:delegate:) async 版返回 (Data, URLResponse)，
//  是非流式 API——SSE 场景必须走 delegate 回调逐块接收（Apple 文档核实口径）。
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
        let (urlRequest, bodyData) = try buildURLRequest(request)

        // 2. 传输层修法 ← OpenMinis OAuthHTTPClient.swift:1426-1454（dataTask can
        //    lose httpBody + delegate 流式逐块接收）：
        //    - uploadTask(with:from:) 显式上传 body（httpBody 已在 buildURLRequest 置空，
        //      URLSession 按实际上传 body 重算 Content-Length）
        //    - URLSessionDataDelegate.didReceive data 逐块喂 AsyncThrowingStream<UInt8>
        //    - didReceive response 经 CheckedContinuation 交出 HTTPURLResponse，
        //      状态码判定在消费侧进行（非 2xx 错误体透传逻辑保持 dsh 语义）
        //    - didCompleteWithError 收尾（错误 → finish(throwing:)；EOF → finish()）
        let delegate = StreamedUploadDelegate(tracker: tracker)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let uploadTask = session.uploadTask(with: urlRequest, from: bodyData)
        // 取消桥接 ← OpenMinis stopLoading（OAuthHTTPClient.swift:1434-1438）：
        // 消费侧停止（Task 取消 / 流终止 / 正常收尾）→ task.cancel() +
        // session.invalidateAndCancel()，防 session/delegate 泄漏。
        delegate.setOnTermination { _ in
            uploadTask.cancel()
            session.invalidateAndCancel()
        }
        uploadTask.resume()

        // 3. 等响应头（可取消；响应头前传输失败 → TRANSPORT 分类，dsh 初始 fetch 口径）
        let http: HTTPURLResponse
        do {
            http = try await delegate.waitForResponse()
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw LLMError(message: "request to \(endpoint.baseURL) failed: \(error.localizedDescription)",
                           code: "TRANSPORT", causeText: String(describing: error))
        }

        // 非 2xx：错误体透传（dsh：HTTP status 权威，body 原样带在 causeText）。
        // delegate 把剩余 body 逐块喂入字节流，此处读完再抛 LLMError（分类照旧）。
        if !(200..<300).contains(http.statusCode) {
            var bodyBytes: [UInt8] = []
            for try await byte in delegate.bytes {
                bodyBytes.append(byte)
                tracker.pulse()
            }
            let body = String(decoding: bodyBytes, as: UTF8.self)
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

        // 4. SSE 行装配 → wire chunk 翻译（translate.ts 全量语义）。
        //    字节流 → LineSplitter 按行切分（等价 AsyncBytes.lines：\n 分隔、
        //    去行尾 \r、EOF 残段 flush）→ SSEAssembler 按行输入契约不变。
        var assembler = SSEAssembler()
        var translator = ChunkTranslator()
        // STREAM_CLOSED 诊断事实（一次性给足：行数 / 载荷数 / 最后载荷前 200 字符 /
        // Content-Type 响应头 / 最后 3 行原始行各前 200 字符），服务端「200 + 错误
        // JSON 载荷 + 关流」或对空 body 请求直接关流时用户下次重跑即可看到真实返回。
        var lineCount = 0
        var payloadCount = 0
        var lastPayload: String?
        var lastRawLines: [String] = []

        /// 消费一行 SSE：返回 true 表示 [DONE] 终止（dsh parseSse 顺序）。
        func handleLine(_ line: String) throws -> Bool {
            lineCount += 1
            tracker.pulse()
            lastRawLines.append(line)
            if lastRawLines.count > 3 {
                lastRawLines.removeFirst()
            }
            switch assembler.consume(line: line) {
            case .payload(let payload):
                payloadCount += 1
                lastPayload = payload
                // [DONE] 是流终止哨兵，不是模型载荷——先判后喂（dsh parseSse 顺序），
                // 绝不进入 translator（喂入会被当 JSON 解析并误抛 MALFORMED_RESPONSE）。
                if payload == SSE.done {
                    return true // dsh parseSse：[DONE] 即正常终止
                }
                let chunks = try translator.consume(payload: payload)
                for chunk in chunks {
                    yield(chunk)
                }
            case .activity, .none:
                break
            }
            return false
        }

        var splitter = LineSplitter()
        for try await byte in delegate.bytes {
            if let line = splitter.feed(byte) {
                if try handleLine(line) {
                    return
                }
            }
        }
        if let line = splitter.flush() {
            if try handleLine(line) {
                return
            }
        }
        // EOF 前未见 [DONE]：截断响应，不可信（dsh STREAM_CLOSED）。
        // 诊断载荷：last 为空说明服务端一个 data: 都没发（如对不存在模型直接关流）；
        // last 非 JSON 说明服务端发了错误对象（典型：已下线模型名 / 鉴权失败）。
        let lastSummary = lastPayload.map { String($0.prefix(200)) } ?? "∅"
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "nil"
        let rawLinesSummary = lastRawLines.isEmpty
            ? "∅"
            : lastRawLines.map { String($0.prefix(200)) }.joined(separator: " | ")
        throw LLMError(
            message: "SSE stream ended without [DONE] "
                + "(lines=\(lineCount), payloads=\(payloadCount), last=\(lastSummary), "
                + "content-type=\(contentType), lastRawLines=[\(rawLinesSummary)])",
            code: "STREAM_CLOSED")
    }

    // MARK: - wire 序列化（serialize.ts requestWithMessages 语义）

    /// 返回 (请求, body 数据)。body 不放进 httpBody——由调用方走 uploadTask 显式上传
    /// （传输层修法 ← OpenMinis OAuthHTTPClient.swift:1426，dataTask can lose httpBody）。
    private func buildURLRequest(_ request: LLMRequest) throws -> (URLRequest, Data) {
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
        // 清理旧 Content-Length —— URLSession 会按实际上传的 body 重算
        // （← OpenMinis OAuthHTTPClient.swift:1405 同款）。
        urlRequest.setValue(nil, forHTTPHeaderField: "Content-Length")
        let bodyData = try JSONEncoder().encode(wire)
        return (urlRequest, bodyData)
    }
}

// MARK: - 传输层 delegate（← OpenMinis OAuthHTTPClient.swift:1426-1454 同款模式）

/// uploadTask 流式响应 delegate：
/// - didReceive response：经 CheckedContinuation 把 HTTPURLResponse 交给消费侧判
///   状态码（delegate 回调非 async，不能直接抛错；非 2xx 的错误体读取与 LLMError
///   分类保持在 async 消费侧，dsh 语义零改动）。
/// - didReceive data：逐字节喂 AsyncThrowingStream<UInt8>（流式；同时喂 watchdog）。
/// - didCompleteWithError：错误 → finish(throwing:)；EOF → finish()。
///
/// 线程模型：session 的 delegateQueue（nil → 内部串行队列）串行回调；
/// 状态快照 + lock 保护，waitForResponse 可被消费侧 Task 取消。
private final class StreamedUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let byteStream: AsyncThrowingStream<UInt8, Error>
    private let byteContinuation: AsyncThrowingStream<UInt8, Error>.Continuation
    private let tracker: ActivityTracker

    private let lock = NSLock()
    private var httpResponse: HTTPURLResponse?
    private var responseFailure: Error?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    init(tracker: ActivityTracker) {
        self.tracker = tracker
        var continuation: AsyncThrowingStream<UInt8, Error>.Continuation!
        self.byteStream = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.byteContinuation = continuation
        super.init()
    }

    /// 响应体字节流（单次消费；onTermination 由调用方设置取消桥接）。
    var bytes: AsyncThrowingStream<UInt8, Error> { byteStream }

    /// 消费侧停止（Task 取消 / 流终止 / 正常收尾）时触发。
    func setOnTermination(_ handler: @escaping @Sendable (Error?) -> Void) {
        byteContinuation.onTermination = handler
    }

    /// 挂起等待响应头。didReceive response 必先于 didReceive data（delegate 串行
    /// 队列），但可能晚于 resume()——先查状态快照再登记 continuation，无竞态；
    /// Task 取消时以 CancellationError 恢复。
    func waitForResponse() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                self.lock.lock()
                if let http = self.httpResponse {
                    self.lock.unlock()
                    cont.resume(returning: http)
                    return
                }
                if let failure = self.responseFailure {
                    self.lock.unlock()
                    cont.resume(throwing: failure)
                    return
                }
                // 先登记再查取消：若取消发生在登记与检查之间，由 cancelWait 兜底。
                self.responseContinuation = cont
                let cancelled = Task.isCancelled
                self.lock.unlock()
                if cancelled {
                    self.cancelWait()
                }
            }
        } onCancel: {
            self.cancelWait()
        }
    }

    /// 取消挂起的响应等待（幂等：lock 下取出并置空，绝不二次 resume）。
    private func cancelWait() {
        lock.lock()
        let pending = responseContinuation
        responseContinuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let pending = responseContinuation
        responseContinuation = nil
        lock.unlock()
        guard let http = response as? HTTPURLResponse else {
            let failure = LLMError(message: "non-HTTP response", code: "TRANSPORT")
            lock.lock()
            responseFailure = failure
            lock.unlock()
            pending?.resume(throwing: failure)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        httpResponse = http
        lock.unlock()
        pending?.resume(returning: http)
        // 非 2xx 也放行：错误体经 didReceive data 读入，由消费侧抛 LLMError。
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        tracker.pulse()
        for byte in data {
            byteContinuation.yield(byte)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = responseContinuation
        responseContinuation = nil
        lock.unlock()
        if let error {
            if pending != nil {
                // 响应头未到即失败（连接失败 / 超时 / 被取消）——经 responseFailure
                // 交给 waitForResponse（消费侧按 TRANSPORT / 取消分类）。
                lock.lock()
                responseFailure = error
                lock.unlock()
                pending?.resume(throwing: error)
            }
            byteContinuation.finish(throwing: error)
        } else {
            // EOF 而无响应头：理论不可达（didReceive response 必先于 didComplete），
            // 兜底给 TRANSPORT 而非永久挂起。
            pending?.resume(throwing: LLMError(message: "non-HTTP response", code: "TRANSPORT"))
            byteContinuation.finish()
        }
    }
}

// MARK: - 行切分（等价 URLSession.AsyncBytes.lines）

/// 字节流按行切分（等价 AsyncBytes.lines 行为：\n 分隔、去行尾 \r、EOF 残段
/// flush 为末行）。SSEAssembler 的按行输入契约保持不变，管线其余零改动。
/// 行只在 \n 处切分，UTF-8 多字节序列不会跨行截断——按行整体解码安全。
private struct LineSplitter {
    private var buffer: [UInt8] = []

    /// 喂入一个字节；遇 \n 返回完成的行（可能为空行），否则返回 nil。
    mutating func feed(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        return takeLine()
    }

    /// EOF flush：残段非空时作为最后一行返回。
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        var line = buffer
        buffer.removeAll(keepingCapacity: true)
        if line.last == 0x0D {
            line.removeLast()
        }
        return String(decoding: line, as: UTF8.self)
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
