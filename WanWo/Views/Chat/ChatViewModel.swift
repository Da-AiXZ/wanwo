//
//  ChatViewModel.swift
//  WanWo
//
//  【按设计新写】出处：10-design §2.1（UI 不持业务状态，只消费投影；交互意图收敛为
//  对 SessionLifecycle/loop 的方法调用）、§7.3 交互流 1（发送→流式→卡片）、
//  §5.2（SessionLifecycle resume）、复用 M0 OutputSanitizer/ShellTestView 的
//  0.2s 节流 flush 模式。
//  UI 投影 = 会话事件流的只读视图；发送/取消收敛为对 ChatTurnRunner 的调用。
//

import Foundation
import SwiftUI
import Collections

@MainActor
final class ChatViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case idle
        case streaming
        case retrying(attempt: Int, delayMs: Int, message: String)
        case failed(String)
    }

    struct Bubble: Identifiable, Equatable {
        enum Kind: Equatable {
            case user
            case assistant
            case reasoning
            case toolNote
        }

        let id: String
        var kind: Kind
        var text: String
    }

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var resumeBanner: String?
    @Published private(set) var modelLabel = ""
    @Published var draft = ""

    private let environment: AppEnvironment
    private let sessionID: String
    private var writer: SessionWriter?
    private var adapter: OpenAICompatAdapter?
    private var runningTask: Task<Void, Never>?

    // 0.2s 节流（复用 M0 ShellTestView 的 flush 模式；§5.4 OutputSanitizer 节流语义）
    private var pendingTextChunks: Deque<String> = []
    private var pendingReasoningChunks: Deque<String> = []
    private var flushTimer: Timer?

    init(environment: AppEnvironment, sessionID: String) {
        self.environment = environment
        self.sessionID = sessionID
    }

    // MARK: - 打开（resume）

    func open() {
        guard phase == .loading else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (writer, repaired) = try await self.environment.sessionStore.openWriter(id: self.sessionID)
                self.writer = writer
                self.adapter = (try? self.environment.makeAdapter())?.0
                if repaired > 0 {
                    self.resumeBanner = "已恢复：\(repaired) 个中断收尾已修复"
                }
                let derived = writer.deriveMessages()
                if let config = derived.config {
                    self.modelLabel = "\(config.provider) · \(config.model)"
                } else if let endpoint = (try? self.environment.makeAdapter())?.1 {
                    self.modelLabel = "\(endpoint.name) · \(endpoint.model)"
                }
                self.reproject()
                self.phase = .idle
            } catch {
                self.phase = .failed("打开会话失败：\(String(describing: error))")
            }
        }
    }

    // MARK: - 投影（UI = 事件流的只读视图）

    private func reproject() {
        guard let writer = writer else { return }
        var result: [Bubble] = []
        for event in writer.events {
            switch event.payload {
            case .userMessage(let text):
                result.append(Bubble(id: "u\(event.seq)", kind: .user, text: text))
            case .assistantMessage(_, _, let message, _, _):
                for block in message.content {
                    switch block {
                    case .text(let t):
                        result.append(Bubble(id: "a\(event.seq)-t\(result.count)",
                                             kind: .assistant, text: t))
                    case .reasoning(let t):
                        result.append(Bubble(id: "a\(event.seq)-r\(result.count)",
                                             kind: .reasoning, text: t))
                    case .toolCall(let id, let name, _):
                        result.append(Bubble(id: "a\(event.seq)-c\(id)",
                                             kind: .toolNote,
                                             text: "工具调用 \(name)（M2 起执行；本次调用未产生结果）"))
                    }
                }
            default:
                break
            }
        }
        bubbles = result
        streamingText = ""
        streamingReasoning = ""
    }

    // MARK: - 发送 / 取消

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard phase == .idle else { return }
        guard runningTask == nil else { return }
        draft = ""

        runningTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runTurn(userText: text)
            self.runningTask = nil
        }
    }

    func cancel() {
        runningTask?.cancel()
    }

    private func runTurn(userText: String) async {
        do {
            let (adapter, endpoint) = try environment.makeAdapter()
            self.adapter = adapter
            guard let writer = writer else {
                phase = .failed("会话未打开")
                return
            }
            modelLabel = "\(endpoint.name) · \(endpoint.model)"
            phase = .streaming
            let firstTurnOfSession = (writer.eventCount == 0)

            let outcome = try await ChatTurnRunner.runTurn(
                writer: writer,
                adapter: adapter,
                userText: userText,
                onLiveChunk: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.handleLiveChunk(chunk)
                    }
                },
                onRetry: { [weak self] attempt, delayMs, message in
                    Task { @MainActor [weak self] in
                        self?.phase = .retrying(attempt: attempt, delayMs: delayMs, message: message)
                        self?.streamingText = ""
                        self?.streamingReasoning = ""
                    }
                })

            flushNow()
            reproject()
            switch outcome.endReason {
            case .completed:
                phase = .idle
            case .maxTokens:
                phase = .failed("回合达到输出上限")
            case .error(let failure):
                phase = .failed("模型错误 [\(failure.code)]：\(failure.message)")
            case .aborted:
                phase = .idle
            case .blocked, .interrupted:
                phase = .idle
            }

            // F004 标题生成（首轮后；后台执行，不阻塞下一轮）。
            if firstTurnOfSession {
                let environment = self.environment
                let turnOutcome = outcome
                if case .completed = turnOutcome.endReason {
                    Task { [weak self] in
                        await TitleGenerator.generateAndStore(
                            writer: writer, database: environment.database,
                            adapter: adapter)
                        await MainActor.run { self?.environment.sessionsRevision += 1 }
                    }
                }
            }
        } catch {
            flushNow()
            reproject()
            if Task.isCancelled {
                phase = .idle
            } else if let llmError = error as? LLMError {
                phase = .failed("模型错误 [\(llmError.code)]：\(llmError.message)")
            } else {
                phase = .failed(String(describing: error))
            }
        }
    }

    // MARK: - 流式直通车（0.2s 节流 flush）

    private func handleLiveChunk(_ chunk: StreamChunk) {
        switch chunk {
        case .textDelta(_, let text):
            pendingTextChunks.append(text)
        case .reasoningDelta(_, let text):
            pendingReasoningChunks.append(text)
        default:
            break
        }
        flushIfIdle()
    }

    private func flushIfIdle() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushTimer = nil
                self?.flushNow()
            }
        }
    }

    private func flushNow() {
        if !pendingTextChunks.isEmpty {
            while let chunk = pendingTextChunks.popFirst() {
                streamingText += chunk
            }
        }
        if !pendingReasoningChunks.isEmpty {
            while let chunk = pendingReasoningChunks.popFirst() {
                streamingReasoning += chunk
            }
        }
    }
}
