//
//  ChatTurnRunner.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/agent-loop/src/agent.ts（ReactLoopAgent
//  turn()/step()/buildRequest 切片的 M1 子集：无工具、无 inbox、单 step 回合）。
//  关键时序 1:1（10-design §六① / §5.2）：
//    turn/start → step/start → user/message → request/header →【durable 检查点】
//    → LLM.stream → assistant/chunk 逐块落盘 → assistant/message → step/end → turn/end。
//  「延迟构造下游模型流直到完整已记录请求前缀 durable」（dsh
//  session-checkpoint-policy）：append 返回即 fsync，流在全部事件落盘后才创建。
//  重试（dsh llm-retry）：先落盘 llm/retry 再等待，等待结束落盘 llm/retry-started。
//

import Foundation

/// 一回合执行的最终结果。
struct TurnOutcome: Sendable {
    var turn: Int
    var endReason: TurnEndReason
    var assistantText: String
    var usage: TokenUsage?
}

/// M1 最小回合执行器。
struct ChatTurnRunner {
    /// M1 系统提示词（完整 PromptAssembler 随 M2 落地，10-design §5.2）。
    static let m1SystemPrompt = """
    你是万我（WanWo），运行在 iPad 上的 AI 助手。请用与用户相同的语言回答。
    当前版本尚不支持工具调用，仅可进行文本对话。
    """

    /// 执行一个回合（用户消息已由调用方送入 writer 之外的文本参数）。
    /// - Parameters:
    ///   - onLiveChunk: 流式块直通车（后台线程调用；UI 侧 0.2s 节流）。
    ///   - onRetry: 重试通知（后台线程调用）。
    static func runTurn(writer: SessionWriter,
                        adapter: OpenAICompatAdapter,
                        userText: String,
                        retryPolicy: RetryPolicy = RetryPolicy(),
                        onLiveChunk: @escaping @Sendable (StreamChunk) -> Void,
                        onRetry: @escaping @Sendable (Int, Int, String) -> Void) async throws -> TurnOutcome {
        let turn = writer.nextTurn
        try await writer.append(.turnStart(turn: turn))

        do {
            let outcome = try await runStepAndFinish(writer: writer, adapter: adapter,
                                                     turn: turn, userText: userText,
                                                     retryPolicy: retryPolicy,
                                                     onLiveChunk: onLiveChunk,
                                                     onRetry: onRetry)
            return outcome
        } catch {
            // 回合级错误收尾（dsh turn() catch：aborted / 结构化 error，保证 turn 恒有 end；
            // 先按不变量要求收掉开放 step，再收 turn——turn/end 时 step 仍开放是违例）。
            if Task.isCancelled {
                if writer.openTurn == turn {
                    if let openStep = writer.openStep {
                        try? await writer.append(.stepEnd(turn: turn, step: openStep))
                    }
                    try? await writer.append(.turnEnd(turn: turn, reason: .aborted(cause: "user")))
                }
            } else {
                let failure = (error as? LLMError)?.failure
                    ?? LlmFailure(message: String(describing: error), code: "UNKNOWN")
                if writer.openTurn == turn {
                    if let openStep = writer.openStep {
                        try? await writer.append(.stepEnd(turn: turn, step: openStep))
                    }
                    try? await writer.append(.turnEnd(turn: turn, reason: .error(failure)))
                }
            }
            throw error
        }
    }

    private static func runStepAndFinish(writer: SessionWriter,
                                         adapter: OpenAICompatAdapter,
                                         turn: Int,
                                         userText: String,
                                         retryPolicy: RetryPolicy,
                                         onLiveChunk: @escaping @Sendable (StreamChunk) -> Void,
                                         onRetry: @escaping @Sendable (Int, Int, String) -> Void) async throws -> TurnOutcome {
        let step = 1
        try await writer.append(.stepStart(turn: turn, step: step))
        try await writer.append(.userMessage(text: userText))

        // request/header（dsh buildRequest：config + system；M1 无 tools）。
        let header = EpochHeader(
            config: LlmCallConfig(provider: adapter.providerName,
                                  model: adapter.endpoint.model,
                                  reasoningEffort: adapter.endpoint.reasoningEffort,
                                  maxTokens: nil),
            system: m1SystemPrompt)
        _ = try await writer.logRequestHeaderIfNeeded(header)
        // 到此处 user/message + request/header 已全部 durable（append 即 fsync）
        // ——「先持久化再发请求」检查点满足，此后才构造下游模型流。

        let request = buildLLMRequest(writer: writer, adapter: adapter)
        var attempt = 0
        let retryId = UUID().uuidString

        while true {
            var blocks: [ContentBlock] = []
            var usage: TokenUsage?
            var finish: FinishReason?
            do {
                // 每个 attempt 一个全新流（dsh：重试 = 步内重新进入流消费）。
                let stream = adapter.stream(request)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    // model-visible=logged：每个流块先落盘再驱动 UI。
                    try await writer.append(.assistantChunk(turn: turn, step: step, chunk: chunk))
                    onLiveChunk(chunk)
                    switch chunk {
                    case .blockEnd(_, let block):
                        blocks.append(block)
                    case .usage(let reported):
                        usage = reported
                    case .finish(let reason):
                        finish = reason
                    default:
                        break
                    }
                }
            } catch {
                // 用户取消：按 dsh 语义 finalize 已交付前缀为 interrupted 助手消息。
                if Task.isCancelled {
                    return try await finalizeInterrupted(writer: writer, turn: turn, step: step,
                                                         blocks: blocks, usage: usage,
                                                         adapter: adapter)
                }
                let llmError = (error as? LLMError)
                    ?? LLMError(message: String(describing: error), code: "UNKNOWN")
                // 重试判定（dsh llm-retry recover：白名单 + maxRetries）。
                guard retryPolicy.isRetryable(code: llmError.code),
                      retryPolicy.mode == .normal,
                      attempt < retryPolicy.maxRetries else {
                    try await writer.append(.stepEnd(turn: turn, step: step))
                    throw llmError
                }
                attempt += 1
                let delayMs = retryPolicy.delayMs(retry: attempt,
                                                  providerRetryAfterMs: llmError.providerRetryAfterMs)
                // 先持久化再等待（dsh：每次调度重试在其可取消等待之前先持久化）。
                try await writer.append(.llmRetry(
                    retryId: retryId, turn: turn, step: step,
                    provider: adapter.providerName,
                    mode: retryPolicy.mode.rawValue,
                    policyKey: "normal/\(retryPolicy.maxRetries)",
                    retry: attempt, maxRetries: retryPolicy.maxRetries,
                    delayMs: delayMs, failure: llmError.failure))
                onRetry(attempt, delayMs, llmError.message)
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                try await writer.append(.llmRetryStarted(
                    retryId: retryId, turn: turn, step: step, retry: attempt))
                continue
            }

            // 正常收尾：assistant/message（派生历史从此取用；usage 随消息同行）。
            let message = AssistantMessage(id: UUID().uuidString,
                                           provider: adapter.providerName,
                                           model: adapter.endpoint.model,
                                           content: blocks)
            try await writer.append(.assistantMessage(
                turn: turn, step: step, message: message, usage: usage, interrupted: false))
            try await writer.append(.stepEnd(turn: turn, step: step))

            let endReason: TurnEndReason
            if case .maxTokens = finish {
                endReason = .maxTokens
            } else if case .error(let failure) = finish {
                endReason = .error(failure)
            } else {
                endReason = .completed
            }
            try await writer.append(.turnEnd(turn: turn, reason: endReason))

            let text = blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined()
            return TurnOutcome(turn: turn, endReason: endReason, assistantText: text,
                               usage: usage)
        }
    }

    /// 取消收尾（dsh step() catch aborted 分支：有交付内容才落 interrupted 消息）。
    private static func finalizeInterrupted(writer: SessionWriter,
                                            turn: Int, step: Int,
                                            blocks: [ContentBlock],
                                            usage: TokenUsage?,
                                            adapter: OpenAICompatAdapter) async throws -> TurnOutcome {
        if !blocks.isEmpty {
            let message = AssistantMessage(id: UUID().uuidString,
                                           provider: adapter.providerName,
                                           model: adapter.endpoint.model,
                                           content: blocks)
            try? await writer.append(.assistantMessage(
                turn: turn, step: step, message: message, usage: usage, interrupted: true))
        }
        try? await writer.append(.stepEnd(turn: turn, step: step))
        try? await writer.append(.turnEnd(turn: turn, reason: .aborted(cause: "user")))
        let text = blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined()
        return TurnOutcome(turn: turn, endReason: .aborted(cause: "user"),
                           assistantText: text, usage: usage)
    }

    /// 请求内容完全来自已落盘事件（deriveMessages；model-visible = logged）。
    private static func buildLLMRequest(writer: SessionWriter,
                                        adapter: OpenAICompatAdapter) -> LLMRequest {
        let derived = writer.deriveMessages()
        return LLMRequest(
            baseURL: adapter.endpoint.baseURL,
            apiKey: adapter.apiKey,
            model: adapter.endpoint.model,
            system: derived.system ?? m1SystemPrompt,
            messages: derived.messages,
            maxTokens: nil,
            temperature: nil,
            thinking: adapter.endpoint.thinking,
            reasoningEffort: adapter.endpoint.reasoningEffort,
            purpose: nil)
    }
}
