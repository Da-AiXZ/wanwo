//
//  ChatViewModel.swift
//  WanWo
//
//  【按设计新写 · M2 重写】出处：10-design §2.1（UI 不持业务状态，只消费投影）、
//  §7.3 交互流 1（发送→流式→工具卡流式输出→完成态卡片收敛→下一轮，顶部状态条
//  实时显示 token 压力 F041）、§5.2（SessionLifecycle resume）。
//  M1 → M2 变化：
//    · 回合驱动从 ChatTurnRunner 切到 AgentLoop（submit/cancel/回调三缝）
//    · 工具卡：tool/call → running 卡（presentCall 意图 + onShellLine 流式）→
//      tool/result 收敛（presentResult 意图 + 结果文本）
//    · 斜杠命令（/compact /new /model /help）：command/run + command/done 落盘
//    · 标记消息过滤：<runtime-context> / <agents-md-update> / <compaction-summary>
//      / <file> 开头的 user 消息不渲染气泡（注入通道，F038/F039/F040）
//    · token 压力三档显示（F041 素净版）
//  UI 投影 = 会话事件流的只读视图；0.2s 节流 flush 沿用 M1 模式。
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
        case failed(String)
    }

    /// 工具卡状态（dsh 工具卡 M2 素净版；正式卡片族 = M9）。
    struct ToolCard: Identifiable, Equatable {
        let callId: String
        var name: String
        var title: String
        var detail: String?
        /// 流式输出（shell 行等）。
        var liveOutput: String = ""
        /// 结果文本（收敛后）。
        var resultText: String?
        var isError: Bool = false
        var isRunning: Bool = true
    }

    struct Bubble: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case assistant(String)
            case reasoning(String)
            case tool(ToolCard)
            case command(kind: String, text: String)
            case note(String)
        }

        let id: String
        var kind: Kind
    }

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var resumeBanner: String?
    @Published private(set) var modelLabel = ""
    @Published private(set) var pressure: Compactor.PressureInfo?
    @Published var draft = ""

    private let environment: AppEnvironment
    private let sessionID: String
    private var writer: SessionWriter?
    private var agentLoop: AgentLoop?
    private var registry: ToolRegistry?
    /// replay 投影用的调用参数缓存（callId → name/args，presentResult 复现用）。
    private var callArgs: [String: (name: String, args: JSONValue)] = [:]
    private var runningTask: Task<Void, Never>?
    private var slashCommands: SlashCommandRegistry?

    // 0.2s 节流（§5.4 OutputSanitizer 节流语义；M1 flush 模式复用）
    private var pendingTextChunks: Deque<String> = []
    private var pendingReasoningChunks: Deque<String> = []
    private var flushTimer: Timer?

    init(environment: AppEnvironment, sessionID: String) {
        self.environment = environment
        self.sessionID = sessionID
    }

    // MARK: - 打开（resume + AgentLoop 装配）

    func open() {
        guard phase == .loading else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (writer, repaired) = try await self.environment.sessionStore.openWriter(id: self.sessionID)
                self.writer = writer
                if repaired > 0 {
                    self.resumeBanner = "已恢复：\(repaired) 个中断收尾已修复"
                }
                if let endpoint = (try? self.environment.makeAdapter())?.1 {
                    self.modelLabel = "\(endpoint.name) · \(endpoint.model)"
                }
                self.agentLoop = self.environment.makeAgentStack(
                    sessionId: self.sessionID,
                    writer: writer,
                    callbacks: self.makeCallbacks())
                self.registry = self.agentLoop?.deps.registry
                self.slashCommands = SlashCommandRegistry.makeDefault(
                    loop: self.agentLoop!, environment: self.environment)
                self.reproject()
                self.phase = .idle
            } catch {
                self.phase = .failed("打开会话失败：\(String(describing: error))")
            }
        }
    }

    // MARK: - 关闭（会话切换 / 视图离场）

    func close() {
        Task { [weak agentLoop] in await agentLoop?.cancel(cause: .disposed) }
        let task = runningTask
        runningTask = nil
        task?.cancel()
        guard let writer = writer else { return }
        let store = environment.sessionStore
        Task {
            _ = await task?.value
            await store.closeWriter(writer)
        }
    }

    // MARK: - 发送 / 取消

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .idle, let loop = agentLoop else { return }
        draft = ""

        if SlashCommandRegistry.isCommand(text) {
            runningTask = Task { [weak self] in
                await self?.runSlashCommand(text)
                self?.runningTask = nil
            }
            return
        }
        phase = .streaming
        loop.submit(text)
    }

    func cancel() {
        agentLoop?.cancel(cause: .user)
    }

    // MARK: - 斜杠命令（command/run → 执行 → command/done）

    private func runSlashCommand(_ text: String) async {
        guard let writer = writer else { return }
        let name = SlashCommandRegistry.commandName(text)
        guard let command = slashCommands?.command(named: name) else {
            let help = slashCommands?.helpText ?? "Unknown command."
            try? await writer.append(.commandRun(commandId: UUID().uuidString,
                                                 name: name, args: nil))
            try? await writer.append(.commandDone(commandId: "", kind: "error",
                                                  text: "Unknown command \"\(name)\".\n\n\(help)"))
            reproject()
            return
        }
        let commandId = UUID().uuidString
        let args = text.count > name.count + 1
            ? String(text.dropFirst(name.count + 2)) : nil
        try? await writer.append(.commandRun(commandId: commandId, name: name, args: args))
        let result = await command.run()
        try? await writer.append(.commandDone(commandId: commandId, kind: "success", text: result))
        reproject()
    }

    // MARK: - AgentLoop 回调（后台线程 → MainActor）

    private func makeCallbacks() -> AgentLoop.Callbacks {
        AgentLoop.Callbacks(
            onLiveChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.handleLiveChunk(chunk) }
            },
            onShellLine: { [weak self] callId, line in
                Task { @MainActor [weak self] in
                    self?.appendToCard(callId: callId, line: line)
                }
            },
            onTokenPressure: { [weak self] info in
                Task { @MainActor [weak self] in self?.pressure = info }
            },
            onTurnEnd: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.flushNow()
                    self.reproject()
                    self.phase = .idle
                    self.maybeGenerateTitle()
                }
            },
            onPhaseChange: { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .running = phase { self.phase = .streaming }
                }
            },
            onToolCallStarted: { [weak self] callId, name, detail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let card = ToolCard(callId: callId, name: name,
                                        title: name, detail: detail)
                    self.bubbles.append(Bubble(id: "tc-live-\(callId)", kind: .tool(card)))
                }
            },
            onToolCallFinished: { [weak self] callId, output, isError in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let index = self.bubbles.lastIndex(where: {
                        if case .tool(let card) = $0.kind { return card.callId == callId }
                        return false
                    }), case .tool(var card) = self.bubbles[index].kind {
                        card.resultText = output
                        card.isError = isError
                        card.isRunning = false
                        self.bubbles[index].kind = .tool(card)
                    }
                }
            })
    }

    private func appendToCard(callId: String, line: String) {
        for index in bubbles.indices {
            if case .tool(var card) = bubbles[index].kind, card.callId == callId {
                card.liveOutput += (card.liveOutput.isEmpty ? "" : "\n") + line
                bubbles[index].kind = .tool(card)
                return
            }
        }
    }

    private func maybeGenerateTitle() {
        guard let writer = writer else { return }
        let firstTurnOfSession = writer.nextTurn <= 2
        guard firstTurnOfSession,
              let adapter = try? environment.makeAdapter().0 else { return }
        let database = environment.database
        let environment = self.environment
        Task { [weak self] in
            await TitleGenerator.generateAndStore(writer: writer, database: database,
                                                  adapter: adapter)
            await MainActor.run { self?.environment.sessionsRevision += 1 }
            _ = environment
        }
    }

    // MARK: - 投影（UI = 事件流的只读视图）

    /// 注入/标记消息前缀（F038/F039/F040 + 压缩摘要呈现；不渲染气泡）。
    private static let markerPrefixes = ["<runtime-context>", "<agents-md-update>",
                                         "<compaction-summary>", "<file>"]

    private func isMarkerMessage(_ text: String) -> Bool {
        Self.markerPrefixes.contains { text.hasPrefix($0) }
    }

    private func reproject() {
        guard let writer = writer else { return }
        var result: [Bubble] = []
        callArgs.removeAll()
        for event in writer.events {
            switch event.payload {
            case .userMessage(let text):
                guard !isMarkerMessage(text) else { continue }
                result.append(Bubble(id: "u\(event.seq)", kind: .user(text)))

            case .assistantMessage(_, _, let message, _, _):
                for block in message.content {
                    switch block {
                    case .text(let t):
                        result.append(Bubble(id: "a\(event.seq)-t\(result.count)",
                                             kind: .assistant(t)))
                    case .reasoning(let t):
                        result.append(Bubble(id: "a\(event.seq)-r\(result.count)",
                                             kind: .reasoning(t)))
                    case .toolCall:
                        break // 工具卡由 tool/call 事件渲染
                    }
                }

            case .toolCall(let turn, let step, let callId, let name, let arguments):
                let args = ToolCallScheduler.parseArgs(arguments)
                callArgs[callId] = (name, args)
                let intent = registry?.get(name)?.presentCall(args)
                    ?? ToolCardIntent(title: name)
                result.append(Bubble(id: "tc\(event.seq)", kind: .tool(ToolCard(
                    callId: callId, name: name,
                    title: intent.title,
                    detail: intent.detail ?? "turn \(turn) · step \(step)"))))

            case .toolResult(_, _, let callId, let content, let isError,
                             let errorName, let errorCode, let meta):
                // 收敛同名 running 卡（replay 投影顺序保证先 call 后 result）。
                if let index = result.lastIndex(where: {
                    if case .tool(let card) = $0.kind { return card.callId == callId }
                    return false
                }) {
                    if case .tool(var card) = result[index].kind {
                        let args = callArgs[callId]?.args ?? .null
                        let output = ToolOutput(text: content, isError: isError,
                                                errorName: errorName, errorCode: errorCode,
                                                meta: meta)
                        if let intent = registry?.get(card.name)?.presentResult(args, output) {
                            card.title = intent.title
                            card.detail = intent.detail
                        }
                        card.resultText = content
                        card.isError = isError
                        card.isRunning = false
                        result[index].kind = .tool(card)
                    }
                }

            case .commandRun(_, let name, _):
                result.append(Bubble(id: "cr\(event.seq)", kind: .command(kind: "run", text: name)))

            case .commandDone(_, let kind, let text):
                result.append(Bubble(id: "cd\(event.seq)",
                                     kind: .command(kind: kind, text: text ?? "")))

            case .compactionSummary(let compactionId, _, _, _, _, _):
                result.append(Bubble(id: "cs\(event.seq)",
                                     kind: .note("上下文已压缩（\(compactionId.prefix(8))）")))

            default:
                break
            }
        }
        bubbles = result
        streamingText = ""
        streamingReasoning = ""
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
