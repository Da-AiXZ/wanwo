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
        /// Identifiable（ForEach/差分用；callId 全局唯一即 id）。
        var id: String { callId }

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
        /// 交互状态行（M3 T1：审批 waiting/结算态、提问 waiting——dsh 流内
        /// toolview 行的 WanWo 形态；琥珀语义行）。
        var statusNote: String?
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
    // MARK: M3 T1 待决交互（composer 接管数据源；dsh 2026-07-23/07-29 笔记）
    /// 待决审批队列（composer 接管显示队首；first answer wins 由协调器保证）。
    @Published private(set) var pendingApprovals: [PendingApprovalPresentation] = []
    /// 待决提问队列（composer 接管显示队首）。
    @Published private(set) var pendingQuestions: [PendingQuestionPresentation] = []
    /// 审批按钮防双击（dsh：answered 后本地禁用，失败 re-arm）。
    @Published private(set) var approvalAnswering = false
    /// 提问提交防双击。
    @Published private(set) var questionBusy = false

    private let environment: AppEnvironment
    private let sessionID: String
    private var writer: SessionWriter?
    private var agentLoop: AgentLoop?
    private var registry: ToolRegistry?
    /// replay 投影用的调用参数缓存（callId → name/args，presentResult 复现用）。
    private var callArgs: [String: (name: String, args: JSONValue)] = [:]
    private var runningTask: Task<Void, Never>?
    private var slashCommands: SlashCommandRegistry?
    // MARK: M3 T1 审批/提问装配引用（answer 路径回传宿主裁决登记处）
    private var approvalCoordinator: ApprovalCoordinator?
    private var questionService: UserQuestionService?

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
                let stack = await self.environment.makeAgentStack(
                    sessionId: self.sessionID,
                    writer: writer,
                    callbacks: self.makeCallbacks(),
                    interactionPresenter: self)
                self.agentLoop = stack.loop
                self.approvalCoordinator = stack.approvalCoordinator
                self.questionService = stack.questionService
                if let loop = stack.loop {
                    self.registry = loop.deps.registry
                    self.slashCommands = SlashCommandRegistry.makeDefault(
                        loop: loop, environment: self.environment)
                } else {
                    // ERR-015/016：装配失败按「未配置模型」降级（原 agentLoop! 强解闪退）；
                    // 横幅带具体失败原因（无端点 / Key 不可读等），不再只有泛化提示。
                    self.registry = nil
                    self.slashCommands = nil
                    self.resumeBanner = "未配置模型：\(stack.failureReason ?? "未知原因") 请到「设置 · Providers」检查"
                }
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
        // M3 T1：桥关闭——在途待决一律 fail closed（审批 .unavailable /
        // 提问 ASK_ABORTED；m3-scope-brief §二.5「桥关闭在途待决一律 unavailable」）。
        approvalCoordinator?.bridgeClosed()
        questionService?.bridgeClosed()
        guard let writer = writer else { return }
        let store = environment.sessionStore
        Task {
            _ = await task?.value
            await store.closeWriter(writer)
        }
    }

    // MARK: - 发送 / 取消

    /// .failed(String) 带关联值不能直接 == 比较（隐式成员查找会落到系统类型）。
    private var canSendFromPhase: Bool {
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // .failed 也允许重发（错误状态条不是死锁——用户改完可直接重试）。
        guard !text.isEmpty, canSendFromPhase, let loop = agentLoop else { return }
        draft = ""

        if SlashCommandRegistry.isCommand(text) {
            runningTask = Task { [weak self] in
                await self?.runSlashCommand(text)
                self?.runningTask = nil
            }
            return
        }
        phase = .streaming
        // AgentLoop 是 actor：submit 需 await（MainActor 上下文经 Task 跳转）。
        Task { await loop.submit(text) }
    }

    func cancel() {
        Task { await agentLoop?.cancel(cause: .user) }
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
            onTurnEnd: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.flushNow()
                    self.reproject()
                    // F060 可观测性最小纪律：错误必须自解释——turn/end error
                    // 把 failure.message 原文（DeepSeek providerMessage）带进
                    // 状态条（截 200 防撑爆），不能只给 code。
                    if case .error(let failure) = reason {
                        self.phase = .failed(Self.failureBanner(failure))
                    } else {
                        self.phase = .idle
                    }
                    self.maybeGenerateTitle()
                }
            },
            onPhaseChange: { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .running = phase { self.phase = .streaming }
                }
            },
            onToolCallStarted: { [weak self] callId, name, arguments, detail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // live 路径同样缓存 callArgs（与 replay 同源；presentResult 复现用）。
                    self.callArgs[callId] = (name, ToolCallScheduler.parseArgs(arguments))
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
                        // presentResult 纯函数复现（live 与 replay 同形；M3 T1：
                        // ask_user_question 的 N/M answered 等结算标题由此更新）。
                        let args = self.callArgs[callId]?.args ?? .null
                        let toolOutput = ToolOutput(text: output, isError: isError,
                                                    errorName: nil, errorCode: nil,
                                                    meta: nil)
                        if let name = self.callArgs[callId]?.name,
                           let intent = self.registry?.get(name)?.presentResult(args, toolOutput) {
                            card.title = intent.title
                            card.detail = intent.detail
                        }
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

    /// 状态条错误文案（F060）：code + message 原文（DeepSeek providerMessage，
    /// 400 场景即其原始抱怨）；换行拍平，截 200 防撑爆状态条。
    private static func failureBanner(_ failure: LlmFailure) -> String {
        let flattened = failure.message.replacingOccurrences(of: "\n", with: " ")
        let body = flattened.count > 200
            ? String(flattened.prefix(200)) + "…"
            : flattened
        return "模型错误 [\(failure.code)] \(body)"
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
                        // replay 结算态：审批未通过（NOT_APPROVED）的琥珀行
                        // （waiting 态是 live 独有状态，重投影后按在途队列重放）。
                        card.statusNote = (isError && errorCode == "NOT_APPROVED")
                            ? "未获批准" : nil
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
        // live 琥珀状态行不在事件流中——重投影后按在途队列重放（M3 T1）。
        if let first = pendingApprovals.first, let callId = first.callId {
            setCardStatus(callId: callId, note: "等待审批")
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

// MARK: - M3 T1 交互呈现缝（SessionInteractionPresenter；dsh composer 接管 +
// 流内 toolview 行 + 侧栏琥珀点镜像，2026-07-23 / 2026-07-29 笔记）

extension ChatViewModel: SessionInteractionPresenter {
    func presentApproval(_ pending: PendingApprovalPresentation) {
        // 配对命令（dsh conversation.approval.detail 槽语义：按 callId 关联
        // 已流式呈现的工具卡，presentCall 复现命令文本，不重复 args JSON）。
        var commandDetail: String?
        if let callId = pending.callId, let entry = callArgs[callId],
           let intent = registry?.get(entry.name)?.presentCall(entry.args) {
            commandDetail = intent.detail
        }
        let enriched = PendingApprovalPresentation(
            id: pending.id, toolName: pending.toolName, callId: pending.callId,
            reason: pending.reason, commandDetail: commandDetail)
        pendingApprovals.append(enriched)
        if let callId = pending.callId {
            setCardStatus(callId: callId, note: "等待审批")
        }
        environment.notePendingInteraction(sessionId: sessionID, active: true)
    }

    func settleApproval(id: String, outcome: ApprovalOutcome) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let presentation = pendingApprovals.remove(at: index)
        approvalAnswering = false
        // 工具卡结算态（琥珀行；allowed-once 后工具继续执行，无琥珀行——
        // dsh：批准后工具卡回到 running 语义）。
        if let callId = presentation.callId {
            let note: String?
            switch outcome {
            case .allowedOnce: note = nil
            case .rejected: note = "未获批准"
            case .cancelled: note = "审批已取消"
            case .unavailable: note = "审批不可用（fail closed）"
            }
            setCardStatus(callId: callId, note: note)
        }
        refreshPendingInteractionMirror()
    }

    func presentQuestion(_ pending: PendingQuestionPresentation) {
        pendingQuestions.append(pending)
        environment.notePendingInteraction(sessionId: sessionID, active: true)
    }

    func settleQuestion(id: String, settlement: QuestionSettlement) {
        guard let index = pendingQuestions.firstIndex(where: { $0.id == id }) else { return }
        let presentation = pendingQuestions.remove(at: index)
        questionBusy = false
        // 工具卡结算态（与 AskUserTool.presentResult 的 N/M answered / cancelled /
        // interrupted 判定同规则——live 与 replay 同形）。
        if let callId = presentation.callId {
            let note: String?
            switch settlement {
            case .answered(let answer):
                let answeredIDs = Set(answer.answers.filter { item in
                    !item.selected.isEmpty || !(item.custom ?? "").isEmpty
                }.map(\.id))
                let answered = presentation.questions.filter { answeredIDs.contains($0.id) }.count
                note = "\(answered)/\(presentation.questions.count) 已回答"
            case .cancelled: note = "已取消"
            case .aborted: note = "已中断"
            }
            setCardStatus(callId: callId, note: note)
        }
        refreshPendingInteractionMirror()
    }

    /// 侧栏琥珀点镜像清退（最后一个待决交互结算时）。
    private func refreshPendingInteractionMirror() {
        if pendingApprovals.isEmpty && pendingQuestions.isEmpty {
            environment.notePendingInteraction(sessionId: sessionID, active: false)
        }
    }

    /// 工具卡琥珀状态行更新。
    private func setCardStatus(callId: String, note: String?) {
        for index in bubbles.indices {
            if case .tool(var card) = bubbles[index].kind, card.callId == callId {
                card.statusNote = note
                bubbles[index].kind = .tool(card)
                return
            }
        }
    }
}

// MARK: - M3 T1 用户裁决入口（composer 接管 → 宿主裁决登记处）

extension ChatViewModel {
    /// 审批裁决（允许一次 / 拒绝）。first answer wins 由协调器保证；本地防双击，
    /// 被拒（已结算/不存在）即 re-arm——dsh 笔记「disable locally, re-arm on failure」。
    func answerApproval(_ pending: PendingApprovalPresentation, allow: Bool) {
        guard !approvalAnswering else { return }
        approvalAnswering = true
        let outcome: ApprovalOutcome = allow ? .allowedOnce : .rejected
        let coordinator = approvalCoordinator
        Task { [weak self] in
            let accepted = coordinator?.answer(requestId: pending.id, outcome: outcome) ?? false
            if !accepted {
                self?.approvalAnswering = false
            }
        }
    }

    /// 提交整组回答（draft 组装在视图层按 dsh submitDrafts 语义完成后回传）。
    func submitQuestionAnswer(_ pending: PendingQuestionPresentation,
                              answer: AskUserQuestionAnswer) {
        guard !questionBusy else { return }
        questionBusy = true
        let service = questionService
        Task { [weak self] in
            let accepted = service?.answer(requestId: pending.id, answer) ?? false
            if !accepted {
                self?.questionBusy = false
            }
        }
    }

    /// 关闭整组提问（dsh composer cancel → ASK_CANCELLED，中性结算态）。
    func cancelQuestion(_ pending: PendingQuestionPresentation) {
        guard !questionBusy else { return }
        questionBusy = true
        let service = questionService
        Task { [weak self] in
            let accepted = service?.dismiss(requestId: pending.id) ?? false
            if !accepted {
                self?.questionBusy = false
            }
        }
    }
}
