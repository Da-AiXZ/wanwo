//
//  SubagentRuntime.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 C · F045】出处（packages/subagent/ 逐文件对拍）：
//    - subagent/src/index.ts（SubagentRuntime 语义源：providers 注册表唯一性
//      fail loud + 能力五 bool 校验 + start/seedFor 分派）。
//    - subagent-spawn-in-process/src/index.ts:41-66 —— SpawnInProcessProvider
//      （inheritsParentContext=false，零父上下文，fresh child 无 seed）。
//    - subagent-fork-in-process/src/index.ts:48-92 —— ForkInProcessProvider
//      （completedTurnPrefix 切片：最后一条 turn/end（含）前；无完成回合 =
//      空种子 = 不传 seed；seedFor 创建时一次捕获）。
//    - subagent/src/continuation.ts —— continuation 管理器（activation 注册
//      表 + 每 child 一把锁 + turn 经子 inbox 排队 + 回传双通道）。
//    - tool-subagent:376-378 —— KV-cache 约束（fork 的 inheritsParentContext
//      措辞差异 + 换路由警告——警告随 modelSelection 面缺失登记）。
//
//  万我适配裁定（登记）：
//    - cordis 事件 → 进程内回调/注册表方法（已定适配①）。
//    - 远程面（@Remote browser 用）不做（已定适配②）。
//    - persona/toolFilter 请求字段不接受（已定适配③；descriptor 字段保留
//      往返保真）。
//    - cold resume（continuation.ts:404-454）：依赖 sessionQuery 观察缝——
//      WanWo 无对应缝，M7.2 登记不实现；非驻留子投递报 NOT_RESUMABLE。
//    - 并发：provider 契约允许并发 start；M7.2 只做并发上限计数（冷读上限
//      4）——三级治理（总数/执行槽/LRU）是 M7.3 件。
//    - dsh 每 child 一把锁（continuation.ts:146）→ WanWo 以 actor 化
//      SubagentRuntime 串行化 activation 操作等价承载。
//

import Foundation

// MARK: - 并发上限（M7.2 简版计数）

/// 启动并发闸（AsyncSemaphore 形态；M7.2 仅上限计数，登记见头注）。
final class SubagentStartGate: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        lock.lock()
        if inFlight < limit {
            inFlight += 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
            return
        }
        inFlight -= 1
        lock.unlock()
    }
}

// MARK: - Provider 协议（types.ts:344-390 WanWo 形态）

/// 解析后的启动请求（service 已校验能力 + 解析 descriptor——dsh
/// ResolvedSubagentStartRequest 对应）。
struct SubagentResolvedRequest: Sendable {
    var request: SubagentStartRequest
    var descriptor: SubagentDescriptor.Record
    var childId: String
    /// 子会话深度（resolveChildDepth 结果；SubagentDepth 地板单调语义）。
    var childDepth: Int
}

/// One registered transport for running child agents（dsh SubagentProvider；
/// 万我 in-process 形态——one-shot 路径；continuable 由 runtime 直接编排）。
protocol SubagentProviderProtocol: Sendable {
    var name: String { get }
    var capabilities: SubagentCapabilities { get }
    /// Whether the child sees the parent's completed-turn prefix（描述性——
    /// 模型面措辞由此派生，tool-subagent providerWording）。
    var inheritsParentContext: Bool { get }
    /// Establish a child with the given seed（one-shot 与 continuable 共用
    /// 创建面——dsh types.ts:344-390 start 语义）。
    func start(_ request: SubagentResolvedRequest,
               seed: [SessionEvent]?) async throws -> SubagentRun
    /// continuable-creation 能力：贡献 detached 创建输入的 seed 有无。
    /// 方法在场即能力（dsh :389）；fork 前缀切片在创建时一次捕获（:85-91）。
    func seedFor(_ request: SubagentResolvedRequest,
                 parentLogEvents: [SessionEvent]) -> [SessionEvent]?
}

// MARK: - Spawn（subagent-spawn-in-process 1:1）

/// Fresh child：own session / own system prompt / zero parent context。
struct SpawnInProcessProvider: SubagentProviderProtocol {
    let name: String
    let capabilities = SubagentCapabilities.inProcess
    /// Context contract: a spawned child starts fresh。
    let inheritsParentContext = false
    let childFactory: SubagentChildFactory

    func start(_ request: SubagentResolvedRequest, seed: [SessionEvent]?) async throws -> SubagentRun {
        // Fresh child: no seed（:54-58）。
        return try await childFactory(request, nil)
    }

    /// A spawned child starts fresh——no seed（:61-65）。
    func seedFor(_ request: SubagentResolvedRequest,
                 parentLogEvents: [SessionEvent]) -> [SessionEvent]? {
        nil
    }
}

// MARK: - Fork（subagent-fork-in-process 1:1）

/// Child SEEDED with a prefix of the parent's log——inherits the parent's
/// conversation context instead of starting fresh。
struct ForkInProcessProvider: SubagentProviderProtocol {
    let name: String
    let capabilities = SubagentCapabilities.inProcess
    /// Context contract: a forked child IS seeded with the completed-turn prefix。
    let inheritsParentContext = true
    let childFactory: SubagentChildFactory

    /// The balanced completed-turn prefix（fork-in-process :48-55 逐语义）：
    /// every event up to and including the last turn/end；in-flight turn
    /// excluded；无完成回合 = 空；seq === array index（append 契约）。
    static func completedTurnPrefix(_ events: [SessionEvent]) -> [SessionEvent] {
        guard let lastEnd = events.last(where: { event in
            if case .turnEnd = event.payload { return true }
            return false
        }) else { return [] }
        return Array(events.prefix(lastEnd.seq + 1))
    }

    func start(_ request: SubagentResolvedRequest, seed: [SessionEvent]?) async throws -> SubagentRun {
        // Only pass a seed when there's a completed turn to inherit（:80-82）。
        return try await childFactory(request, (seed?.isEmpty == false) ? seed : nil)
    }

    /// The fork prefix is captured ONCE, at creation（:85-91）。
    func seedFor(_ request: SubagentResolvedRequest,
                 parentLogEvents: [SessionEvent]) -> [SessionEvent]? {
        Self.completedTurnPrefix(parentLogEvents)
    }
}

/// 子 agent 工厂缝（AppEnvironment 装配——创建子会话 + 组装栈 + 一次性驱动）。
typealias SubagentChildFactory = @Sendable (
    _ resolved: SubagentResolvedRequest,
    _ seed: [SessionEvent]?
) async throws -> SubagentRun

// MARK: - Continuable 激活（continuation.ts WanWo 形态）

/// One continuable child's process-local residency（dsh Activation 子集：
/// durable childId + live loop + epoch）。
final class SubagentActivation: @unchecked Sendable {
    let childId: String
    let parentSessionId: String
    let provider: String
    let label: String
    /// Live child loop（驻留期间持有；dispose 置空）。
    private let lock = NSLock()
    private var storedLoop: AgentLoop?
    /// Activation 生命周期 epoch（dsh lifecycle.ts 每 epoch 发 start/end——
    /// 万我 M7.2 epoch 观察面登记不实现，仅计数保真）。
    private(set) var epoch = 1
    /// 初始 prompt 已入 inbox（dsh announced）。
    var announced = false

    init(childId: String, parentSessionId: String, provider: String,
         label: String, loop: AgentLoop) {
        self.childId = childId
        self.parentSessionId = parentSessionId
        self.provider = provider
        self.label = label
        self.storedLoop = loop
    }

    var loop: AgentLoop? {
        lock.lock()
        defer { lock.unlock() }
        return storedLoop
    }

    func close() {
        lock.lock()
        storedLoop = nil
        lock.unlock()
    }
}

// MARK: - Runtime

/// SubagentRuntime（dsh `ctx.subagents` 的 WanWo 形态：providers 注册表 +
/// 能力校验 + 一次性启动分派 + continuable 编排；actor 串行化 activation 面）。
actor SubagentRuntime {
    /// M7.2 冷读并发上限（简报拍板：只做并发上限计数）。
    static let concurrencyLimit = 4

    private var providers: [String: any SubagentProviderProtocol] = [:]
    private var activations: [String: SubagentActivation] = [:]
    private let startGate = SubagentStartGate(limit: SubagentRuntime.concurrencyLimit)

    // MARK: 子栈物化缝（dsh agents.create 创建事务的装配承载）

    /// 子栈物化缝（dsh agents.create 创建事务的装配承载）：continuable 路径
    /// 需要 writer 以在 settle 时读子日志 closing message（QA-3 P1-4）。
    typealias ChildMaterializer = @Sendable (
        _ resolved: SubagentResolvedRequest,
        _ seed: [SessionEvent]?,
        _ onTurnEnd: @escaping @Sendable (TurnEndReason) -> Void
    ) async throws -> (loop: AgentLoop, writer: SessionWriter)

    private var childMaterializer: ChildMaterializer?

    /// 装配期注册（幂等覆写；一次注册终身有效）。
    func registerChildMaterializer(_ materializer: @escaping ChildMaterializer) {
        childMaterializer = materializer
    }

    /// 注册 provider；重名即 fatal（dsh NamedEntries 唯一性——装配期 fail loud）。
    func registerProvider(_ provider: any SubagentProviderProtocol) {
        if providers[provider.name] != nil {
            fatalError("subagent provider \"\(provider.name)\" is already registered")
        }
        providers[provider.name] = provider
    }

    func getProvider(_ name: String) -> (any SubagentProviderProtocol)? {
        providers[name]
    }

    // MARK: one-shot 启动（types.ts start 语义 + 能力 fail loud）

    /// 能力校验（fail loud——dsh "a request that needs a capability the chosen
    /// provider lacks is rejected with a typed error"）。
    private func validate(_ provider: any SubagentProviderProtocol,
                          _ request: SubagentStartRequest) throws {
        if request.maxDepth != nil && !provider.capabilities.depthLimit {
            throw SubagentError(
                message: "provider \"\(provider.name)\" cannot enforce maxDepth (no depthLimit capability)")
        }
        if !provider.capabilities.outputSchema {
            throw SubagentError(
                message: "provider \"\(provider.name)\" does not support outputSchema")
        }
    }

    /// Start one ONE-SHOT subagent（深度解析 + descriptor 解析 + 并发闸 +
    /// provider 分派）。
    func start(provider providerName: String,
               request: SubagentStartRequest,
               parentLogEvents: [SessionEvent] = []) async throws -> SubagentRun {
        guard let provider = providers[providerName] else {
            throw SubagentError(message: "subagent provider \"\(providerName)\" is not registered",
                                code: "PROVIDER_NOT_FOUND")
        }
        try validate(provider, request)
        try SubagentDepth.assertSubagentMaxDepth(request.maxDepth)
        let childDepth = try SubagentDepth.resolveChildDepth(
            parentDepth: request.parentDepth, maxDepth: request.maxDepth)
        let descriptor = SubagentDescriptor.Record(
            mode: .oneShot, provider: providerName, label: request.label,
            agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
            persona: nil, toolFilter: nil)
        let childId = UUID().uuidString
        let resolved = SubagentResolvedRequest(
            request: request, descriptor: descriptor, childId: childId,
            childDepth: childDepth)
        // 种子由 provider 决定有无（fork: completedTurnPrefix 切片；spawn: nil）。
        let seed = provider.seedFor(resolved, parentLogEvents: parentLogEvents)
        await startGate.acquire()
        defer { startGate.release() }
        return try await provider.start(resolved, seed: seed)
    }

    // MARK: continuable（continuation.ts startContinuable 万我面）

    struct ContinuableStart: Sendable {
        var childId: String
        var messageId: String
    }

    /// Start one continuable background child：创建子会话（fork 携带创建时
    /// 一次捕获的 seed）→ 注册 activation → 初始 prompt 入子 inbox（followup）
    /// → 返回 durable child id（dsh :102-190 语义；cold resume 不实现，登记）。
    func startContinuable(provider providerName: String,
                          request: SubagentStartRequest,
                          parentLogEvents: [SessionEvent] = [])
        async throws -> ContinuableStart {
        guard let materializer = childMaterializer else {
            throw SubagentError(
                message: "no child stack materializer registered for continuable starts",
                code: "PROVIDER_NOT_FOUND")
        }
        guard let provider = providers[providerName] else {
            throw SubagentError(message: "subagent provider \"\(providerName)\" is not registered",
                                code: "PROVIDER_NOT_FOUND")
        }
        try validate(provider, request)
        try SubagentDepth.assertSubagentMaxDepth(request.maxDepth)
        let childDepth = try SubagentDepth.resolveChildDepth(
            parentDepth: request.parentDepth, maxDepth: request.maxDepth)
        let descriptor = SubagentDescriptor.Record(
            mode: .continuable, provider: providerName, label: request.label ?? "",
            agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
            persona: nil, toolFilter: nil)
        let childId = UUID().uuidString
        let resolved = SubagentResolvedRequest(
            request: request, descriptor: descriptor, childId: childId,
            childDepth: childDepth)
        // 种子由 provider 决定有无（fork 前缀在创建时一次捕获，:85-91）。
        let seed = provider.seedFor(resolved, parentLogEvents: parentLogEvents)
        // settle 通知钩（回传双通道②：settle 时给父发 notice——WanWo 以
        // followup(.subagentSettled) 承载，见 noticeSettled）。
        let runtime = self
        let callback: @Sendable (TurnEndReason) -> Void = { reason in
            Task {
                await runtime.noticeSettled(
                    childId: childId,
                    stopReason: SubagentStopReason(turnEndReason: reason))
            }
        }
        await startGate.acquire()
        defer { startGate.release() }
        let materializerReturn = try await materializer(resolved, (seed?.isEmpty == false) ? seed : nil, callback)
        let loop = materializerReturn.loop
        // QA-3 P1-4：settle 时按 boundary 读子日志 closing message
        //（createSettlementMessage :135-154 的 terminal.output 等价——boundary
        // 取 materializer 返回时的 eventCount，自有事件起点，同 driver P0-2 修正；
        // 先于 activation 注册，settle 回调不早于该点被 actor 串行化消费）。
        registerSettlementBoundary(childId: childId,
                                   boundary: materializerReturn.writer.eventCount,
                                   writer: materializerReturn.writer)
        let activation = SubagentActivation(
            childId: childId, parentSessionId: request.parentSessionId,
            provider: providerName, label: request.label ?? "", loop: loop)
        activations[childId] = activation
        // 初始 prompt 排队（独立回合；dsh delivery 'queue'）+ 相邻 Agent 回传
        // 指引（QA-3 P1-3：continuation-messages.ts:81-97
        // withContinuableReturnGuidance 逐字）。
        await loop.followup(Self.withContinuableReturnGuidance(
            parentId: request.parentSessionId, prompt: request.prompt), source: .user)
        activation.announced = true
        let messageId = UUID().uuidString
        return ContinuableStart(childId: childId, messageId: messageId)
    }

    /// Append adjacent-Agent return guidance to a continuable child's initial
    /// task（continuation-messages.ts:81-97 withContinuableReturnGuidance 逐字；
    /// parentId 经 JSON.stringify 等价编码）。
    static func withContinuableReturnGuidance(parentId: String, prompt: String) -> String {
        let encodedParentId = "\"\(parentId)\""
        return prompt
            + "\n\nYour parent agent id is \(encodedParentId). Before you finish, send your result to that agent with "
            + "send_message({ agent_id: \(encodedParentId), message: \"<self-contained result>\" }). The parent shares "
            + "your workspace but does not automatically receive your transcript, tool output, or reasoning. Send "
            + "earlier messages as well when a finding changes what the parent should do next; sending a message "
            + "does not end your turn."
    }

    /// settle 面收账（childId → boundary + 子 writer；startContinuable 在
    /// materializer 返回后立即注册——QA-3 P1-4 closing message 读取面）。
    private var settlementBoundaries: [String: (boundary: Int, writer: SessionWriter)] = [:]

    private func registerSettlementBoundary(childId: String, boundary: Int,
                                            writer: SessionWriter) {
        settlementBoundaries[childId] = (boundary, writer)
    }

    /// settlementSummary（continuation-messages.ts:106-127 逐字——父侧任务
    /// 词汇的一行终局叙述）。
    private static func settlementSummary(childId: String,
                                          stopReason: SubagentStopReason) -> String {
        let subject = "Background subagent \(childId)"
        switch stopReason {
        case .completed:
            return "\(subject) finished and will do no further work unless you send it more."
        case .aborted:
            return "\(subject) was stopped before it finished."
        case .maxTokens:
            return "\(subject) ran out of room before it finished."
        // A pre-step rejection — a hook deny, a policy plugin — discarded input
        // the child had claimed, so the parent must not treat the task as done.
        case .refusal:
            return "\(subject) declined the task."
        case .error:
            return "\(subject) failed before it finished."
        // Merge-extensible：不可名状的终局按未完成上报，绝不静默当成功。
        case .unknown(let raw):
            return "\(subject) ended abnormally (\(raw)) before it finished."
        }
    }

    /// 激活结算通知（dsh continuation-messages.ts:135-154 createSettlementMessage
    /// 等价——summary + closing message；QA-3 P1-4：工具文案承诺的 "containing
    /// its outcome and any final assistant message" 由此兑现）。父 followup 携
    /// InboxSource.subagentSettled。
    func noticeSettled(childId: String, stopReason: SubagentStopReason) async {
        guard let activation = activations[childId], let parentLoop = parentLoop(of: activation)
        else { return }
        var text = "【系统通知】" + Self.settlementSummary(childId: childId, stopReason: stopReason)
        // terminal.output 等价：自有事件（boundary 后）的最终 assistant 文本；
        // 无 → "It left no closing message."（:143-145 逐字）。
        if let settled = settlementBoundaries.removeValue(forKey: childId) {
            let own = Array(settled.writer.events.dropFirst(settled.boundary))
            if let closing = SubagentOutput.finalAssistantOutput(own) {
                text += "\nIts closing message:\n\(closing)"
            } else {
                text += "\nIt left no closing message."
            }
        }
        await parentLoop.followup(text, source: .subagentSettled(
            childId: childId, stopReason: stopReason.wireName))
    }

    /// 父 loop 解析（WanWo 单宿主形态：父 loop 由装配侧以 parentLoops 注册；
    /// M7.2 简版——注册表找不到时通知静默，登记）。
    private func parentLoop(of activation: SubagentActivation) -> AgentLoop? {
        parentLoops[activation.parentSessionId]
    }

    /// 父会话 loop 注册表（装配期登记——process-local 回传通道承载）。
    var parentLoops: [String: AgentLoop] = [:]

    func registerParentLoop(sessionId: String, loop: AgentLoop) {
        parentLoops[sessionId] = loop
    }

    // MARK: 消息路由（continuation.ts sendMessage 万我面）

    /// 模型面消息投递（dsh sendMessage :202-232 语义子集）：目标为直接
    /// continuable 子 → 运行中 steer 最近步边界 / 空闲 followup 新回合；
    /// 非驻留子 → NOT_RESUMABLE（cold resume 登记不实现）。
    /// - Returns: 接受的消息 id。
    func sendMessage(from senderSessionId: String, to targetId: String,
                     text: String) async throws -> String {
        guard let activation = activations[targetId] else {
            throw SubagentError(
                message: "subagent \"\(targetId)\" has no supported continuation state and cannot be resumed; choose a different target",
                code: "NOT_RESUMABLE")
        }
        guard activation.parentSessionId == senderSessionId else {
            throw SubagentError(
                message: "message delivery requires the exact live sender agent",
                code: "UNAUTHORIZED")
        }
        guard let loop = activation.loop else {
            throw SubagentError(message: "subagent activation is being disposed; the message was not delivered",
                                code: "ACTIVATION_CLOSING")
        }
        // WanMo loop 无运行态查询缝（actor 相位私有）——统一 followup 新回合
        // 排队（steer 运行中最近步边界需 phase 查询，登记）。
        await loop.followup(text, source: .user)
        return UUID().uuidString
    }

    /// 驻留子向直接父回传（dsh sendToParent :337-360 等价；QA-2 P1-2：经
    /// deliverFromSubagent 投递——agent-message relay 文案 + source 非 user，
    /// 绝不计入父侧 directHuman authority；原 steer 缺省 .user 已修）。
    func sendToParent(from childId: String, text: String) async throws -> String {
        guard let activation = activations[childId] else {
            throw SubagentError(message: "sender is not a resident continuable child",
                                code: "UNAUTHORIZED")
        }
        guard let parentLoop = parentLoop(of: activation) else {
            throw SubagentError(message: "direct parent is not live; the message was not delivered",
                                code: "PARENT_UNAVAILABLE")
        }
        await parentLoop.deliverFromSubagent(text, from: childId)
        return UUID().uuidString
    }

    // MARK: interrupt（tool-subagent-control interrupt_agent 语义）

    /// Interrupt one live continuable child's current turn（dsh
    /// continuation.ts:332-334 + control :76-116 语义：祖先授权校验；只停当前
    /// turn（inbox 保留）；已完成 = no-op 返回 accepted）。
    func interrupt(childId: String, callerSessionId: String) async throws -> Bool {
        guard let activation = activations[childId] else {
            // 已完成/未知目标 = accepted no-op。
            return true
        }
        // 祖先授权：M7.2 校验直接父（transitive lineage 校验登记 M7.3）。
        guard activation.parentSessionId == callerSessionId else {
            throw SubagentError(message: "interrupt requires ancestor authority",
                                code: "UNAUTHORIZED")
        }
        guard let loop = activation.loop else { return true }
        await loop.cancel(cause: .parent)
        return true
    }

    // MARK: listing（tool-subagent-control list-agents 语义）

    /// 列出驻留 continuable 子（dsh list-agents：仅列 continuable；scope
    /// children|descendants——M7.2 深度展开=children 直系）。
    struct AgentListing: Sendable, Equatable {
        var subagentId: String
        var label: String
        var provider: String
        var depth: Int
    }

    func listAgents(callerSessionId: String, includeDescendants: Bool) -> [AgentListing] {
        var out: [AgentListing] = []
        for (childId, activation) in activations where activation.parentSessionId == callerSessionId {
            out.append(AgentListing(subagentId: childId, label: activation.label,
                                    provider: activation.provider, depth: 1))
        }
        if includeDescendants {
            // descendants：广度展开（M7.2 简版——按 lineage 链逐层收集）。
            var frontier = out.map(\.subagentId)
            var depth = 2
            while !frontier.isEmpty {
                let next = activations.values.filter { frontier.contains($0.parentSessionId) }
                for item in next {
                    out.append(AgentListing(subagentId: item.childId, label: item.label,
                                            provider: item.provider, depth: depth))
                }
                frontier = next.map(\.childId)
                depth += 1
            }
        }
        return out.sorted { $0.subagentId < $1.subagentId }
    }

    /// 释放驻留激活（drain 子集：精确 children；dispose 幂等）。
    func drainChildren(of parentId: String) async {
        let targets = activations.values.filter { $0.parentSessionId == parentId }
        for activation in targets {
            if let loop = activation.loop {
                await loop.cancel(cause: .parent)
            }
            activation.close()
            activations.removeValue(forKey: activation.childId)
            settlementBoundaries.removeValue(forKey: activation.childId)
        }
    }
}
