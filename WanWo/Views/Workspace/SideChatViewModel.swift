//
//  SideChatViewModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 10-design §5.8（M9.7 侧聊设计）/ m6-scope-brief
//  §6.2（codex side.rs 查证版）+ 用户拍板「父会话状态行加」】
//  侧边聊天完整版（M9.7 核销面）：
//    · ephemeral：独立 tmp-dir JsonlEventLog + 真 SessionWriter——事件不进
//      persistentBase 会话桶、不进 GRDB 索引（writer 的 database.touch 对未知
//      id 是 0 行 UPDATE 即 no-op）、不进记忆抽取（记忆面读持久桶）。
//      关闭即弃（tmp 由系统回收）。
//    · fork 快照降级（派单允许的降级路径）：父会话历史不复制——侧聊以
//      「空会话 + 边界系统事件」起步（fork 完整机制面 = 事件流 replay 成
//      initialHistory 需动 SessionWriter/不变量核心，超批且属自创复杂机制
//      禁区；M9.7 届时核销）。边界以 .system 事件落侧聊流（一次性）。
//    · 工具层硬白名单（SideChatToolWhitelist——设计更强的硬约束照做）。
//    · 同一时刻仅一个侧聊（模型单实例挂在页签层；codex :26-27 同语义）。
//    · 父会话状态行：主对话 等输入/等审批（environment.pendingInteraction
//      SessionIDs）/运行中（environment.activeRunSessionIDs）/空闲。
//

import Foundation
import SwiftUI

@MainActor
final class SideChatViewModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case idle
        case streaming
        case failed(String)
    }

    /// 父会话状态行（codex SideParentStatus 词汇的 WanWo 折算；用户拍板加）。
    enum ParentStatus: Equatable {
        case noParent          // 未选主会话
        case needsInput        // 等输入 / 等审批（琥珀——可行动）
        case running           // 运行中
        case idle              // 空闲
    }

    typealias Bubble = ConversationProjector.Bubble

    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var boundaryNote: String?
    @Published var draft = ""
    /// 侧聊待决审批/提问（白名单下理论不现；呈现缝保留 fail closed 完整性）。
    @Published private(set) var pendingApprovals: [PendingApprovalPresentation] = []
    @Published private(set) var pendingQuestions: [PendingQuestionPresentation] = []

    private let environment: AppEnvironment
    private let parentSessionID: String?
    private var sideSessionID: String?
    private var writer: SessionWriter?
    private var agentLoop: AgentLoop?
    private var registry: ToolRegistry?
    private var approvalCoordinator: ApprovalCoordinator?
    private var questionService: UserQuestionService?
    private var callArgs: [String: (name: String, args: JSONValue)] = [:]
    private var opened = false

    /// 0.2s 节流（主对话同钟）。
    private var pendingTextChunks: Deque<String> = []
    private var pendingReasoningChunks: Deque<String> = []
    private var flushTimer: Timer?
    private static let logger = AppLogger(category: "side-chat")

    init(environment: AppEnvironment, parentSessionID: String?) {
        self.environment = environment
        self.parentSessionID = parentSessionID
    }

    // MARK: - 父会话状态行

    func parentStatus() -> ParentStatus {
        guard let parentSessionID else { return .noParent }
        if environment.pendingInteractionSessionIDs.contains(parentSessionID) {
            return .needsInput
        }
        if environment.activeRunSessionIDs.contains(parentSessionID) {
            return .running
        }
        return .idle
    }

    // MARK: - 打开（ephemeral 会话 + 白名单装配）

    func open() {
        guard !opened else { return }
        opened = true
        Task { [weak self] in
            await self?.assemble()
        }
    }

    private func assemble() async {
        let sideID = "side-" + UUID().uuidString
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-side-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir,
                                                 withIntermediateDirectories: true)
        let logURL = tmpDir.appendingPathComponent("\(sideID).jsonl")
        let header = SessionHeader(
            id: sideID,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            cwd: nil)
        do {
            let log = try JsonlEventLog.create(header: header, at: logURL)
            // 真 SessionWriter（不变量校验/派生历史全复用）；database.touch
            // 对未知 id 为 0 行 UPDATE——不进 GRDB 索引。
            let writer = try await SessionWriter(id: sideID, header: header,
                                                 log: log,
                                                 database: environment.database)
            self.sideSessionID = sideID
            self.writer = writer
            // 边界系统事件（一次性；fork 快照降级见文件头）。
            try? await writer.append(.system(note: Self.boundaryText))
            boundaryNote = Self.boundaryText
            // 复用主对话 Agent 栈装配（模型选择随父会话 holder 继承）。
            let modelSelection = environment.modelSelection(for: parentSessionID
                                                                ?? sideID)
            let stack = await environment.makeAgentStack(
                sessionId: sideID,
                writer: writer,
                callbacks: makeCallbacks(),
                interactionPresenter: self,
                modelSelection: modelSelection)
            guard let loop = stack.loop else {
                phase = .failed("未配置模型：\(stack.failureReason ?? "未知原因")")
                return
            }
            self.agentLoop = loop
            self.approvalCoordinator = stack.approvalCoordinator
            self.questionService = stack.questionService
            // 工具层硬白名单（注销 + fail closed guard；模型可见面即时收窄）。
            let registry = loop.deps.registry
            self.registry = registry
            SideChatToolWhitelist.apply(to: registry)
            reproject()
            phase = .idle
        } catch {
            phase = .failed("侧边聊天初始化失败：\(String(describing: error))")
        }
    }

    /// 边界提示（codex 两段隐藏提示词的 WanWo 折算：继承语境仅供理解 /
    /// 只读探索定位；机制面 = 工具硬白名单，文案为软约束补充）。
    static let boundaryText =
        "你正在侧边聊天中：这是一个只读的临时探索会话，关闭应用后即消失。"
        + "你只拥有只读工具（read/glob/grep/read_image/web_search/web_fetch），"
        + "不能写入、执行或产生任何变更。回答应聚焦于解答与探索；"
        + "如用户要求实际变更，请提示其回到主对话。"

    // MARK: - 关闭（ephemeral 弃置）

    func close() {
        Task { [weak agentLoop] in await agentLoop?.cancel(cause: .disposed) }
        approvalCoordinator?.bridgeClosed()
        questionService?.bridgeClosed()
        guard let writer else { return }
        // MainActor 域内先取出依赖（跨 Task 引用不触 @MainActor 属性隔离）。
        let store = environment.sessionStore
        let sideID = sideSessionID
        Task {
            await store.closeWriter(writer)
            if let sideID {
                // tmp 日志文件即时清理（ephemeral 语义）。
                try? FileManager.default.removeItem(
                    at: FileManager.default.temporaryDirectory
                        .appendingPathComponent("wanwo-side-sessions/\(sideID).jsonl"))
            }
        }
        writer.close()
        self.writer = nil
        sideSessionID = nil
        opened = false
        phase = .loading
        bubbles = []
        streamingText = ""
        streamingReasoning = ""
    }

    // MARK: - 发送 / 取消

    func send() {
        guard canSend, let loop = agentLoop else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        phase = .streaming
        Task { [loop] in
            await loop.submit(text)
        }
    }

    func cancel() {
        Task { await agentLoop?.cancel(cause: .user) }
    }

    var canSend: Bool {
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    // MARK: - AgentLoop 回调（主对话同构；0.2s 节流）

    private func makeCallbacks() -> AgentLoop.Callbacks {
        AgentLoop.Callbacks(
            onLiveChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in
                    switch chunk {
                    case .textDelta(_, let text):
                        self?.pendingTextChunks.append(text)
                    case .reasoningDelta(_, let text):
                        self?.pendingReasoningChunks.append(text)
                    default:
                        break
                    }
                    self?.flushIfIdle()
                }
            },
            onTokenPressure: { _ in },
            onTurnEnd: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.flushNow()
                    self.reproject()
                    if case .error(let failure) = reason {
                        self.phase = .failed(failure.message)
                    } else {
                        self.phase = .idle
                    }
                }
            },
            onPhaseChange: { [weak self] loopPhase in
                Task { @MainActor [weak self] in
                    if case .running = loopPhase { self?.phase = .streaming }
                }
            },
            onToolCallStarted: { [weak self] _, _, _, _ in
                Task { @MainActor [weak self] in
                    self?.reproject()
                }
            },
            onToolCallFinished: { [weak self] callId, output, isError in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let index = self.bubbles.lastIndex(where: {
                        if case .tool(let card) = $0.kind { return card.callId == callId }
                        return false
                    }), case .tool(var card) = self.bubbles[index].kind {
                        let toolOutput = ToolOutput(text: output, isError: isError,
                                                    errorName: nil, errorCode: nil,
                                                    meta: nil)
                        if let name = self.callArgs[callId]?.name,
                           let intent = self.registry?.get(name)?
                               .presentResult(self.callArgs[callId]!.args, toolOutput) {
                            card.title = intent.title
                            card.detail = intent.detail
                        }
                        card.resultText = output
                        card.isError = isError
                        card.isRunning = false
                        self.bubbles[index].kind = .tool(card)
                    } else {
                        self.reproject()
                    }
                }
            },
            onUserMessageAppended: { [weak self] text, _ in
                Task { @MainActor [weak self] in
                    guard let self, !ConversationProjector.isMarkerMessage(text) else { return }
                    self.bubbles.append(Bubble(id: "side-live-\(UUID().uuidString)",
                                               kind: .user(text, [])))
                }
            })
    }

    // MARK: - 投影（事件流只读视图；主对话同一折叠规则）

    private func reproject() {
        guard let writer else { return }
        let projected = ConversationProjector.project(
            events: writer.events, registry: registry, callArgs: &callArgs)
        bubbles = projected
        streamingText = ""
        streamingReasoning = ""
        pendingTextChunks.removeAll()
        pendingReasoningChunks.removeAll()
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
        while let chunk = pendingTextChunks.popFirst() { streamingText += chunk }
        while let chunk = pendingReasoningChunks.popFirst() { streamingReasoning += chunk }
    }
}

// MARK: - 交互呈现缝（白名单下不现审批/提问；缝保留——完整性 + fail closed）

extension SideChatViewModel: SessionInteractionPresenter {
    func presentApproval(_ pending: PendingApprovalPresentation) {
        pendingApprovals.append(pending)
    }

    func settleApproval(id: String, outcome: ApprovalOutcome) {
        pendingApprovals.removeAll { $0.id == id }
    }

    func presentQuestion(_ pending: PendingQuestionPresentation) {
        pendingQuestions = PendingQuestionMirror.upsert(pendingQuestions, pending)
    }

    func settleQuestion(id: String, settlement: QuestionSettlement) {
        pendingQuestions.removeAll { $0.id == id }
    }
}
