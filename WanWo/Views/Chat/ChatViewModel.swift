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
//  M3 E2（live/replay 统一投影）：
//    · 气泡/工具卡类型与事件→气泡折叠下沉到 ConversationProjector（唯一规则；
//      dsh assembler 语义：live append 与 replay replaceWindow 同一 matchInput，
//      节点位置=起始事件 seq），live 不再按到达序自行追加工具卡
//    · toolCallStarted 即重投影（此刻 assistant/message + tool/call 已落盘），
//      流式缓冲=刚提交消息 → 由事件流渲染并清空（思考/回复按块分立）
//    · shell 行进 0.2s 节流缓冲（§7.3 shell 卡 0.2s 节流；与文本 chunk 同钟）
//    · 工具卡 id 锚定 callId、气泡 id 锚定 seq+块下标——重投影身份稳定
//    · live 流式输出环形窗口封顶（长文本渲染优化）
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

    // MARK: E2：气泡/工具卡类型下沉到 ConversationProjector（live/replay 共用
    // 折叠的产物类型）；旧嵌套名以 typealias 保稳（ChatView 等引用不变）。
    typealias ToolCard = ConversationProjector.ToolCard
    typealias Bubble = ConversationProjector.Bubble

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
    // MARK: M3 T2.2 派生状态
    /// 计划模式生效（Plan chip 显示位；PlanModeController.isActive 折叠镜像）。
    @Published private(set) var planActive = false
    /// 状态条整行（SessionStatsFold；composer dock）。
    @Published private(set) var statsLine: String?
    /// /permission danger-full-access 前置确认（A4；非 nil = 待确认命令行原文）。
    @Published var pendingPermissionConfirmation: String?
    /// 当前权限预设名（P2-⑪ 即时刷新：由计算属性改存储镜像——命令路径外的
    /// @Published 变化不触发重算，改镜像于 reproject 统一落位，保证
    /// composer 权限挡位标签即时跟随；nil = 权限系统未装配）。
    @Published private(set) var currentPermissionPreset: String?

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
    /// M3 T2 权限协调器（/permission 命令装配输入）。
    private var permission: PermissionCoordinator?
    /// M3 T3 计划模式协调器（/plan 命令装配输入）。
    private var plan: PlanModeController?

    // 0.2s 节流（§5.4 OutputSanitizer 节流语义；M1 flush 模式复用）
    private var pendingTextChunks: Deque<String> = []
    private var pendingReasoningChunks: Deque<String> = []
    /// shell 行节流缓冲（E2：§7.3 shell 卡 0.2s 节流——原逐行直改 bubbles，
    /// 高频 bash 输出每行一次全表差分；现与文本 chunk 同一 flush 时钟）。
    private var pendingShellLines: [String: [String]] = [:]
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
                self.permission = stack.permission
                self.plan = stack.plan
                if let loop = stack.loop {
                    self.registry = loop.deps.registry
                    self.slashCommands = SlashCommandRegistry.makeDefault(
                        loop: loop, environment: self.environment,
                        permission: self.permission, plan: self.plan)
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

    // MARK: - M3 T2.2 GUI 命令通道（与手输同路）

    /// GUI 通道的命令提交（dsh「both surfaces write through one path」——
    /// composer 权限挡位下拉 / Plan chip 与手输命令同一 command/run → run →
    /// command/done 落盘路径）。phase 纪律与 send() 一致。
    /// confirmed = 入口自带的确认已通过（P2-⑪ 双弹修复：dsh 确认缝归入口所有
    /// ——PermissionSelect.tsx:129-133 下拉内 RiskConfirmation 确认后直达提交；
    /// 手输 /permission danger-full-access 仍走命令门控确认）。
    func runCommandLine(_ line: String, confirmed: Bool = false) {
        guard SlashCommandRegistry.isCommand(line), canSendFromPhase else { return }
        runningTask = Task { [weak self] in
            await self?.runSlashCommand(line, confirmed: confirmed)
            self?.runningTask = nil
        }
    }

    /// Full access 前置确认（A4）：仅 /permission danger-full-access 需门控
    /// （dsh popupSelect confirming gate + PermissionSelect.tsx:129-133 特判）；
    /// 带参直达语义对其他预设保留。nonisolated 纯函数（单测直呼）。
    nonisolated static func isFullAccessCommand(name: String, args: String?) -> Bool {
        name == "permission"
            && args?.trimmingCharacters(in: .whitespacesAndNewlines) == "danger-full-access"
    }

    /// 确认执行待确认的 Full access 命令（绕过门控直达执行器——确认即放行，
    /// 否则门控会再次拦截形成回环）。
    func confirmPendingPermission() {
        guard let line = pendingPermissionConfirmation else { return }
        pendingPermissionConfirmation = nil
        runningTask = Task { [weak self] in
            await self?.executeSlashCommand(line)
            self?.runningTask = nil
        }
    }

    /// 取消 Full access 确认（fail closed：不执行、不留痕迹）。
    func cancelPendingPermission() {
        pendingPermissionConfirmation = nil
    }

    /// 模型挡位提交（ModelSelectView 回传；下一请求即用新端点）。
    func selectModel(_ endpoint: EndpointConfig) {
        environment.endpointStore.setActive(endpoint)
        modelLabel = "\(endpoint.name) · \(endpoint.model)"
    }

    /// 推理等级提交（P2-⑧：ModelSelectView effort 子菜单回传——写入活动端点
    /// 的 reasoningEffort（nil = provider default 不透传）；下一请求即生效
    /// （AgentLoop makeAdapter 按调用时 activeEndpoint 取用）。
    func selectEffort(_ effort: String?) {
        guard var endpoint = environment.endpointStore.activeEndpoint() else { return }
        endpoint.reasoningEffort = effort
        environment.endpointStore.update(endpoint)
    }

    /// 模型挡位数据源（ModelSelectView @ObservedObject 接线）。
    var endpointStore: EndpointStore { environment.endpointStore }

    /// 命令列表（slash 菜单数据源；按名称排序——dsh helpText 同序）。
    var slashCommandList: [SlashCommandRegistry.Command] {
        (slashCommands?.commands.values.sorted { $0.name < $1.name }) ?? []
    }

    /// 幽灵提示（dsh InputBar.tsx:335-353 claim hint：args 为空时显示命令
    /// hint；dsh 词典仅 hint.plan/goal，WanWo 无 goal → 仅 /plan）。
    var commandHint: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed == "/plan" || trimmed.hasPrefix("/plan "),
              trimmed.dropFirst("/plan".count).trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        // hint.plan zh 原文（ui-conversation locales.ts:7 = placeholder.plan 同值）。
        return "描述你的任务以生成计划"
    }

    /// 草稿是否为空（主按钮状态机入参）。
    var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发送就绪（idle/failed 可发——.failed 重试口径不变）。
    var canSend: Bool { canSendFromPhase }

    /// 命令任务在途（GUI 命令通道 busy；PermissionSelectView 禁用入参）。
    var isCommandRunning: Bool { runningTask != nil }

    /// 主按钮状态机（dsh InputBar.tsx:313-326 primaryStops：运行中且无草稿 →
    /// 主按钮同位变停止；有草稿 → 发送（Queue 语义随 M7，本构建禁用）。
    /// nonisolated 纯函数（单测不经 MainActor 直呼）。
    nonisolated static func primaryStops(running: Bool, draftEmpty: Bool) -> Bool {
        running && draftEmpty
    }

    // MARK: - 斜杠命令（command/run → 执行 → command/done）

    /// 门控入口：未经入口确认的 Full access 命令先行拦截（确认前零副作用——
    /// 不落 command/run、不执行），其余直入执行器。
    private func runSlashCommand(_ text: String, confirmed: Bool = false) async {
        let name = SlashCommandRegistry.commandName(text)
        let rawArgs = text.count > name.count + 1
            ? String(text.dropFirst(name.count + 2)) : nil
        if !confirmed, Self.isFullAccessCommand(name: name, args: rawArgs) {
            pendingPermissionConfirmation = text
            return
        }
        await executeSlashCommand(text)
    }

    /// 执行器（command/run → run → command/done → 重投影；无门控——确认
    /// 放行路径与普通命令共用）。
    private func executeSlashCommand(_ text: String) async {
        guard let writer = writer else { return }
        let name = SlashCommandRegistry.commandName(text)
        let rawArgs = text.count > name.count + 1
            ? String(text.dropFirst(name.count + 2)) : nil
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
        let args = rawArgs
        try? await writer.append(.commandRun(commandId: commandId, name: name, args: args))
        let result = await command.run(args)
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
                    guard let self else { return }
                    // E2：shell 行进节流缓冲（§7.3 shell 卡 0.2s 节流），
                    // flushNow 统一落卡。
                    self.pendingShellLines[callId, default: []].append(line)
                    self.flushIfIdle()
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
            onToolCallStarted: { [weak self] _, _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // E2 统一投影：tool/call 已落盘（ToolCallScheduler 契约：
                    // started 在落盘后发射），卡片位置由事件流折叠给出（dsh
                    // assembler：append 与 replaceWindow 同一 matchInput，节点
                    // 位置=起始事件 seq）。此刻本步 assistant/message 亦已落盘
                    // （AgentLoop runStep：先 append 消息再调度工具）——重投影
                    // 自事件流渲染思考/回复块并清空流式缓冲（按块分立），live
                    // 不再按到达序自行 append 卡片（原 live/replay 分叉点）。
                    self.reproject()
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
                    } else {
                        // 卡不在场兜底（理论不发生：started 已重投影；防御
                        // 回调乱序/漏发——直接按事件流重建）。
                        self.reproject()
                    }
                }
            },
            onUserMessageAppended: { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // P2-⑪ 消息即时上屏：user/message 落盘即入流（乐观气泡），
                    // 不等首个工具卡/回合尾重投影。标记消息（runtime snapshot
                    // 等）与投影层同一过滤纪律，不渲染；下一轮 reproject 以
                    // 事件流折叠产物整体替换（身份/文本同源收敛）。
                    guard !ConversationProjector.isMarkerMessage(text) else { return }
                    self.bubbles.append(ChatViewModel.Bubble(
                        id: "live-user-\(UUID().uuidString)", kind: .user(text)))
                }
            })
    }

    private func appendToCard(callId: String, line: String) {
        for index in bubbles.indices {
            if case .tool(var card) = bubbles[index].kind, card.callId == callId {
                card.liveOutput = Self.appendingLiveLine(card.liveOutput, line)
                bubbles[index].kind = .tool(card)
                return
            }
        }
    }

    // MARK: - 长文本渲染优化（E2）

    /// live 流式输出环形窗口封顶：卡片只保留尾部 N 字符（完整原文在事件流，
    /// 卡片只为可读性——dsh toolview 为虚拟化列表，WanWo M9 前以窗口兜底，
    /// 防 bash 高频输出的无界 Text 布局）。
    static let maxLiveOutputCharacters = 3_000
    static let liveOutputTruncationMarker = "…（前文已截断）"

    static func appendingLiveLine(_ current: String, _ line: String) -> String {
        var updated = current.isEmpty ? line : current + "\n" + line
        if updated.count > maxLiveOutputCharacters {
            let body = String(updated.suffix(maxLiveOutputCharacters))
            updated = body.hasPrefix(liveOutputTruncationMarker)
                ? body
                : liveOutputTruncationMarker + "\n" + body
        }
        return updated
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

    // MARK: - 投影（UI = 事件流的只读视图；E2 起折叠在 ConversationProjector）

    private func reproject() {
        guard let writer = writer else { return }
        // 瞬态续接（dsh current map 语义）：在途卡片的 liveOutput（含尚未
        // flush 的 shell 行）与 statusNote 按 callId 带入新投影——只重建
        // 「dirty」内容，未变节点保状态。
        var carried = Self.toolCards(in: bubbles)
        for (callId, lines) in pendingShellLines {
            guard var card = carried[callId] else { continue }
            for line in lines {
                card.liveOutput = Self.appendingLiveLine(card.liveOutput, line)
            }
            carried[callId] = card
        }
        pendingShellLines.removeAll()
        var callArgsSnapshot = callArgs
        let projected = ConversationProjector.project(
            events: writer.events, registry: registry,
            callArgs: &callArgsSnapshot, previousCards: carried)
        callArgs = callArgsSnapshot
        bubbles = projected
        streamingText = ""
        streamingReasoning = ""
        // T2.2 派生状态刷新（plan chip 镜像 + 状态条折叠 + 权限挡位镜像）。
        planActive = plan?.isActive ?? false
        currentPermissionPreset = permission?.knobs.currentPresetName()
        statsLine = SessionStatsFold.line(for: SessionStatsFold.fold(events: writer.events))
        // live 琥珀状态行不在事件流中——重投影后按在途队列重放（M3 T1）。
        if let first = pendingApprovals.first, let callId = first.callId {
            setCardStatus(callId: callId, note: "等待审批")
        }
    }

    /// 现存工具卡快照（callId → 卡），供投影续接瞬态字段。
    private static func toolCards(in bubbles: [Bubble]) -> [String: ToolCard] {
        var cards: [String: ToolCard] = [:]
        for bubble in bubbles {
            if case .tool(let card) = bubble.kind { cards[card.callId] = card }
        }
        return cards
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
        // E2：缓冲的 shell 行统一落卡（0.2s 节流；§7.3）。
        if !pendingShellLines.isEmpty {
            let buffered = pendingShellLines
            pendingShellLines.removeAll()
            for (callId, lines) in buffered {
                for line in lines {
                    appendToCard(callId: callId, line: line)
                }
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
        // T2.3 P0 第二道防线：同 id 重放副本替换不叠加（dsh 笔记 :19
        // "replaces replay duplicates"；根因修复在 UserQuestionService.ask
        // 的双重呈现——本防线防未来调用方回归）。
        pendingQuestions = PendingQuestionMirror.upsert(pendingQuestions, pending)
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
    /// 审批裁决（允许一次 / 拒绝）。first answer wins 由协调器保证；本地防
    /// 双击，被拒（已结算/不存在）即 re-arm——dsh 笔记「disable locally,
    /// re-arm on failure」。P1-4：remember 沉淀出口随 F022 砍除。
    func answerApproval(_ pending: PendingApprovalPresentation, allow: Bool) {
        guard !approvalAnswering else { return }
        approvalAnswering = true
        let outcome: ApprovalOutcome = allow ? .allowedOnce : .rejected
        let coordinator = approvalCoordinator
        Task { [weak self] in
            let accepted = coordinator?.answer(requestId: pending.id,
                                               outcome: outcome) ?? false
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

// MARK: - M3 T2.2 A1 composer 路由（提问先于审批）

/// composer 座位路由（纯函数，单测断言位）。
enum ComposerSeatRoute: Equatable {
    case question
    case approval
    case input

    /// dsh 笔记 2026-07-23-web-permission-and-approval.md:19 原文
    /// 「presents the first pending question ahead of concurrent approvals to
    /// match composer routing」：提问（ui-user-questions）先于审批（
    /// ApprovalPanel）接管 composer——T2.2 A1（原 WanWo 审批优先为反序）。
    static func route(hasPendingQuestion: Bool,
                      hasPendingApproval: Bool) -> ComposerSeatRoute {
        if hasPendingQuestion { return .question }
        if hasPendingApproval { return .approval }
        return .input
    }
}
