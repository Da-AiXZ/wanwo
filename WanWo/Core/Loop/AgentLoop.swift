//
//  AgentLoop.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/agent-loop/src/agent.ts（ReactLoopAgent：
//  三相 idle/maintenance/running、inbox steer=唤醒/inject=不唤醒/followup=下回合、
//  turn()/step()/preStep 状态机、cancel 三源 abort 融合、wake latch）+ 10-design §5.2
//  （AgentLoop actor F001）+ §六①（一次对话全时序）。
//  移植要点：
//    · 相位词汇一比一；非 idle 期间输入在 inbox 排队（wake latch 语义）
//    · turn：turn/start → step 循环（claim inbox → 上下文注入 → 压力检查 →
//      request/header durable 检查点 → 流 → assistant/message → toolCalls 调度）
//      → turn/end 结构化 reason
//    · max-tokens 粘滞（后续正常 step 不降级回合结局，dsh sticky 语义）
//    · cancel 三源融合（user/parent/hook + disposed）；未启动 toolCall 由调度器
//      补合成错误结果保 replay
//    · maxTurns 熔断可恢复（blocked 收尾；新回合计数重置）
//

import Foundation

/// Agent 循环（F001）。actor：串行化状态机。
actor AgentLoop {
    // MARK: - 词汇

    enum Phase: Equatable, Sendable {
        case idle(lastTurn: Int)
        case maintenance
        case running(turn: Int, step: Int)
    }

    /// 取消原因（dsh AgentCancelCause 词汇）。
    enum CancelCause: Equatable, Sendable {
        case user
        case parent
        case hook(reason: String)
        case disposed
    }

    struct Config: Sendable {
        /// 单回合步数熔断（dsh maxTurns 熔断的 M2 落点：步级防失控；blocked 可恢复）。
        var maxTurns = 32
        /// 并行工具池上限（dsh maxParallelToolCalls 缺省 10；可热更）。
        var maxParallelToolCalls = 10
    }

    /// 一步的结局（dsh step() 返回词汇）。
    enum StepOutcome: Equatable, Sendable {
        /// 无工具调用——回合正常收尾。
        case completed
        /// 触达输出上限（粘滞）。
        case maxTokens
        /// 有工具调用：结果已回注，继续下一步。
        case hasToolCalls
    }

    /// UI/宿主回调（后台线程调用；UI 侧自行跳 MainActor + 节流）。
    struct Callbacks: Sendable {
        var onLiveChunk: @Sendable (StreamChunk) -> Void = { _ in }
        var onShellLine: @Sendable (String, String) -> Void = { _, _ in }
        var onTokenPressure: @Sendable (Compactor.PressureInfo?) -> Void = { _ in }
        var onTurnEnd: @Sendable (TurnEndReason) -> Void = { _ in }
        var onPhaseChange: @Sendable (Phase) -> Void = { _ in }
        /// 工具卡活投影（callId, name, arguments 原文, presentCall detail）——
        /// tool/call 落盘后发射。arguments 原文随行：live 路径据此缓存 callArgs，
        /// 使 presentResult 的纯函数复现与 replay 同形（M3 T1）。
        var onToolCallStarted: @Sendable (String, String, String, String?) -> Void = { _, _, _, _ in }
        /// 工具卡收敛（callId, 结果文本, isError）——tool/result 落盘后发射。
        var onToolCallFinished: @Sendable (String, String, Bool) -> Void = { _, _, _ in }
        /// 用户消息已落盘（P2-⑪ 消息即时上屏：user/message append 后发射，
        /// 文本 = 落盘原文——含注入展开后的最终形态；UI 侧自行过滤标记消息）。
        var onUserMessageAppended: @Sendable (String) -> Void = { _ in }
    }

    // MARK: - 依赖

    struct Dependencies: Sendable {
        let sessionId: String
        let writer: SessionWriter
        let assembler: PromptAssembler
        let registry: ToolRegistry
        let pipeline: ToolPipeline
        let compactor: Compactor
        let spill: SpillStore
        let injector: ContextInjector
        let makeAdapter: @Sendable () async throws -> OpenAICompatAdapter
        let callbacks: Callbacks
        /// P1-3：本调用生效沙箱模式供值缝（PermissionCoordinator.knobs.sandbox
        /// 实时折叠值；四层解析顺序在装配缝注释——approved 显式 > 会话末条
        /// sandbox/mode > 新会话默认源 > 部署默认）。
        let sandboxModeProvider: @Sendable () -> SandboxMode
        /// P1-3：提权审批通道（approval 只由 sandbox_permissions 请求触发；
        /// 'never' 政策在闭包内先短路——dsh user-approval index.ts:266）。
        let escalationApprover: SandboxEscalationApprover?
    }

    // MARK: - 状态

    nonisolated let deps: Dependencies
    nonisolated let config: Config
    private var phase: Phase
    private var nextStepInbox: [String] = []    // steer/inject（本回合内消费）
    private var nextTurnInbox: [String] = []    // followup（独立回合）
    private var cancelCause: CancelCause?
    /// 工具调度取消旗标（cancel 三源融合时置位；调度器子任务只读——
    /// 驱动器唤醒即复位，避免上一轮回合的残留置位污染新回合）。
    private let toolCancelFlag = CancelFlag()
    private var driverTask: Task<Void, Never>?
    private var maxParallelToolCalls: Int
    /// runtime context 快照投影状态（F038' ERR-024；dsh RuntimeContextProjection
    /// 语义移植，见 Core/Context/RuntimeContextProjection.swift）。
    private var runtimeProjection = RuntimeContextProjection()

    private static let logger = AppLogger(category: "AgentLoop")

    // MARK: - ERR-024 缓存取证（临时 · os_log + 内存环形缓冲，不落盘事件，事件词汇零新增）

    // ERR-025②：取证行同步进 CacheForensicsBuffer（诊断页「复制取证」按钮
    // 的数据源）——os_log 在真机上不连 Console 不可见，取证链路不闭环；
    // 缓冲纯内存不落盘事件，事件词汇零新增口径不变。

    /// 取证状态（线程安全；buildLLMRequest 为 static 上下文）。
    private final class ForensicsState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastItems: [String]?
        private var requestIndex = 0

        /// 记录本次请求指纹，返回 (请求序号, 上一请求指纹)。
        func advance(items: [String]) -> (index: Int, previous: [String]?) {
            lock.lock()
            defer { lock.unlock() }
            requestIndex += 1
            let previous = lastItems
            lastItems = items
            return (requestIndex, previous)
        }
    }

    private static let forensics = ForensicsState()

    /// 单条指纹（FNV-1a 64 哈希 + UTF-8 字节长度）。
    private static func fingerprint(_ label: String, _ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "\(label)#\(String(hash, radix: 16))#\(text.utf8.count)"
    }

    /// 相邻两次请求逐项指纹对比（定位 provider 前缀缓存断点确切位置）。
    /// 断点判读：firstDiff < 上一请求 item 数 = 前缀发散（缓存从该 item 起
    /// 全 miss，取证目标）；firstDiff ≥ 上一请求 item 数 = 纯尾部追加（前缀
    /// 稳定，缓存应命中至上一请求全长）。
    private static func logCacheForensics(system: String?,
                                          messages: [ChatMessage],
                                          tools: [ToolSchemaEntry]?) {
        var items: [String] = []
        if let system, !system.isEmpty {
            items.append(fingerprint("system", system))
        }
        if let tools, !tools.isEmpty {
            for tool in tools {
                let paramsJSON = (try? JSONEncoder().encode(tool.parameters))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "<encode-failed>"
                items.append(fingerprint("tool:\(tool.name)",
                                         tool.name + "\u{1}" + tool.description
                                            + "\u{1}" + paramsJSON))
            }
        }
        for (index, message) in messages.enumerated() {
            var text = message.content
            if let calls = message.toolCalls, !calls.isEmpty {
                text += "\u{1}" + calls
                    .map { "\($0.id)\u{2}\($0.name)\u{2}\($0.arguments)" }
                    .joined(separator: "\u{3}")
            }
            items.append(fingerprint("m\(index):\(message.role.rawValue)", text))
        }

        let (requestIndex, previous) = forensics.advance(items: items)
        var firstDiff = -1
        if let previous {
            let common = min(previous.count, items.count)
            for index in 0..<common where previous[index] != items[index] {
                firstDiff = index
                break
            }
            if firstDiff < 0, items.count != previous.count {
                firstDiff = min(previous.count, items.count)
            }
        }
        let prevCount = previous?.count ?? 0
        let prefixStable = previous == nil || firstDiff < 0 || firstDiff >= prevCount
        let summary = "cache-forensics req#\(requestIndex) items=\(items.count) "
            + "system=\(system?.isEmpty == false ? 1 : 0) tools=\(tools?.count ?? 0) "
            + "messages=\(messages.count) firstDiff=\(firstDiff) "
            + "prefixStable=\(prefixStable)"
        Self.logger.info(summary)
        CacheForensicsBuffer.shared.append(summary)
        if let previous, firstDiff >= 0, firstDiff < previous.count {
            let current = firstDiff < items.count ? items[firstDiff] : "<absent>"
            let divergence = "cache-forensics req#\(requestIndex) PREFIX DIVERGENCE "
                + "at item \(firstDiff): prev=\(previous[firstDiff]) cur=\(current)"
            Self.logger.info(divergence)
            CacheForensicsBuffer.shared.append(divergence)
        }
        let dump = "cache-forensics req#\(requestIndex) dump: "
            + items.joined(separator: " | ")
        Self.logger.debug(dump)
        CacheForensicsBuffer.shared.append(dump)
    }

    init(deps: Dependencies, config: Config = Config()) {
        self.deps = deps
        self.config = config
        self.maxParallelToolCalls = config.maxParallelToolCalls
        self.phase = .idle(lastTurn: deps.writer.nextTurn - 1)
    }

    // MARK: - inbox 三级输入

    /// 用户输入（idle → 新回合；非 idle → followup 排队）。
    func submit(_ text: String) {
        nextTurnInbox.append(text)
        wake()
    }

    /// steer：本回合下一步注入 + 唤醒（打断注入；dsh next-step + wakeup）。
    func steer(_ text: String) {
        nextStepInbox.append(text)
        wake()
    }

    /// inject：本回合下一步注入，不唤醒（dsh inject）。
    func inject(_ text: String) {
        nextStepInbox.append(text)
    }

    /// followup：排队独立回合 + 唤醒。
    func followup(_ text: String) {
        nextTurnInbox.append(text)
        wake()
    }

    /// 并行池上限热更（dsh maxParallelToolCalls 可热更）。
    func setMaxParallelToolCalls(_ value: Int) {
        maxParallelToolCalls = max(1, value)
    }

    // MARK: - 取消（三源 abort 融合）

    /// 取消当前活动。三源（UI 停止按钮 / 后台挂起 / 内部治理）融合为 cause；
    /// 未启动 toolCall 的合成错误结果由 ToolCallScheduler 落盘（保 replay）；
    /// guest 进程走 nonisolated 快路杀（防内核 pids_lock 卡死 actor，§5.4）。
    func cancel(cause: CancelCause = .user) {
        cancelCause = cause
        toolCancelFlag.set()
        driverTask?.cancel()
        IshExecutorBridge.stopAllNonisolated(sessionId: deps.sessionId)
    }

    // MARK: - 维护相（/compact 经此串行化）

    /// 空闲期维护（dsh runMaintenance：非 idle 即拒绝）。
    /// - Returns: 维护结果文本（错误以 "Error: " 前缀返回，不抛）。
    func runMaintenance(_ job: @escaping @Sendable () async throws -> String) async -> String {
        guard case .idle = phase else {
            return "Error: agent is busy; compaction requires an idle conversation"
        }
        phase = .maintenance
        deps.callbacks.onPhaseChange(phase)
        defer {
            phase = .idle(lastTurn: deps.writer.nextTurn - 1)
            deps.callbacks.onPhaseChange(phase)
            if !nextTurnInbox.isEmpty || !nextStepInbox.isEmpty {
                wake()
            }
        }
        do {
            return try await job()
        } catch {
            return "Error: \(String(describing: error))"
        }
    }

    // MARK: - 驱动器（dsh wakeDriver/kick）

    /// idle → 启动驱动器（非 idle：输入已在 inbox 排队，收敛时回放——wake latch）。
    private func wake() {
        guard case .idle = phase else { return }
        phase = .running(turn: deps.writer.nextTurn - 1, step: 0)
        deps.callbacks.onPhaseChange(phase)
        toolCancelFlag.reset()
        driverTask = Task { [weak self] in
            await self?.kick()
        }
    }

    /// 驱动循环：消耗队列直到空（dsh kick：while turn()）。
    private func kick() async {
        var keepGoing = true
        while keepGoing && cancelCause == nil {
            keepGoing = (try? await runTurn()) ?? false
        }
        phase = .idle(lastTurn: deps.writer.nextTurn - 1)
        deps.callbacks.onPhaseChange(phase)
        driverTask = nil
        cancelCause = nil
        // 收敛回放：队列仍有 followup → 再唤醒（dsh wakeRequested 回放）。
        if !nextTurnInbox.isEmpty || !nextStepInbox.isEmpty {
            wake()
        }
    }

    // MARK: - 回合（dsh turn()）

    /// 执行一个回合。- Returns: 队列仍有待处理工作时 true（继续下一回合）。
    private func runTurn() async throws -> Bool {
        let turn = deps.writer.nextTurn
        try await deps.writer.append(.turnStart(turn: turn))
        var endReason: TurnEndReason? = nil
        var sawMaxTokens = false
        var stepIndex = 0

        do {
            while true {
                // 三源取消检查（cause 已融合）。
                if let cause = cancelCause {
                    endReason = .aborted(cause: Self.causeKeyword(cause))
                    break
                }
                try Task.checkCancellation()

                // maxTurns 熔断（blocked：可恢复——新回合计数重置）。
                if stepIndex >= config.maxTurns {
                    try? await deps.writer.append(
                        .system(note: "max turns reached (\(config.maxTurns)); "
                            + "send a message to continue"), ignorable: true)
                    endReason = .blocked
                    break
                }

                // claim inbox（dsh preStep：首步 next-turn，其后 next-step）。
                var messages: [String] = []
                if stepIndex == 0 {
                    if !nextTurnInbox.isEmpty {
                        messages = nextTurnInbox
                        nextTurnInbox.removeAll()
                    } else if !nextStepInbox.isEmpty {
                        messages = nextStepInbox
                        nextStepInbox.removeAll()
                    } else {
                        endReason = .completed
                        break
                    }
                } else {
                    // 工具结果步：steer/inject 消息（可为空——模型消费工具结果）。
                    messages = nextStepInbox
                    nextStepInbox.removeAll()
                }

                stepIndex += 1
                let step = stepIndex
                try await deps.writer.append(.stepStart(turn: turn, step: step))

                // 上下文注入（F038/F039/F040）。
                let injected = try await self.injectContexts(messages: messages)
                for text in injected where !text.isEmpty {
                    try await deps.writer.append(.userMessage(text: text))
                    // P2-⑪ 消息即时上屏（落盘即发射；UI 侧过滤标记消息）。
                    deps.callbacks.onUserMessageAppended(text)
                }

                // 压力检查（dsh pre-step 压缩介入点；失败继续回合）。
                await self.checkCompactionPressure()

                // 一步（模型请求 + 工具调度）。
                let outcome = try await runStep(turn: turn, step: step)
                // step 收尾配对校验（ERR-021 防御②）：step/end 落盘前补齐缺失
                // 的 tool/result，结构性保证派生历史的 tool_calls↔tool 配对完整。
                await ensureStepToolResultsPaired(turn: turn, step: step)
                try await deps.writer.append(.stepEnd(turn: turn, step: step))

                // ERR-023：step 收尾窗口的取消置位（step 边界竞态）——dsh 语义：
                // 用户取消恒为 aborted，哪怕取消落在 step 边界（stream 已交付
                // 完毕、事件收尾进行中），也不得以 completed 收尾。
                if let cause = cancelCause {
                    endReason = .aborted(cause: Self.causeKeyword(cause))
                    break
                }

                switch outcome {
                case .completed:
                    endReason = .completed
                case .maxTokens:
                    sawMaxTokens = true
                    endReason = .maxTokens
                case .hasToolCalls:
                    continue
                }
                break
            }
        } catch {
            // 回合级错误收尾（dsh turn() catch：aborted / 结构化 error）。
            if let cause = cancelCause {
                endReason = .aborted(cause: Self.causeKeyword(cause))
            } else if Task.isCancelled {
                endReason = .aborted(cause: "user")
            } else {
                let failure = (error as? LLMError)?.failure
                    ?? LlmFailure(message: String(describing: error), code: "UNKNOWN")
                endReason = .error(failure)
                Self.logger.error("turn \(turn) error: \(failure.message)")
            }
            // 收掉开放 step（不变量：turn/end 时 step 不得开放）。
            if let openStep = deps.writer.openStep, deps.writer.openTurn == turn {
                // 同样先补配对（取消/错误路径的 tool/call 也可能有丢 result）。
                await ensureStepToolResultsPaired(turn: turn, step: openStep)
                try? await deps.writer.append(.stepEnd(turn: turn, step: openStep))
            }
        }

        // max-tokens 粘滞：后续正常收尾不得降级回合结局（dsh sticky）。
        if sawMaxTokens, case .completed = endReason {
            endReason = .maxTokens
        }
        let finalReason = endReason ?? .completed
        try? await deps.writer.append(.turnEnd(turn: turn, reason: finalReason))
        deps.callbacks.onTurnEnd(finalReason)

        // dsh turn() 尾：队列仍 pending → 继续下一回合；aborted 则停（等待新输入）。
        return !nextTurnInbox.isEmpty && !Self.isAborted(finalReason)
    }

    private static func causeKeyword(_ cause: CancelCause) -> String {
        switch cause {
        case .user: return "user"
        case .parent: return "parent"
        case .hook(let reason): return "hook:\(reason)"
        case .disposed: return "disposed"
        }
    }

    private static func isAborted(_ reason: TurnEndReason) -> Bool {
        if case .aborted = reason { return true }
        return false
    }

    // MARK: - step 收尾配对校验（ERR-021 防御②）

    /// step/end 落盘前校验：本 step 已落盘的全部 tool/call 必须有对应 tool/result。
    /// callId 全局唯一（SessionInvariant），结果按 callId 全流匹配。缺失的立即补
    /// 合成 isError result（TOOL_RESULT_LOST）——这是对一切丢 result 路径（并发
    /// append 失败、I/O 故障、未预期异常）的结构性兜底，保证派生历史发给 API 的
    /// tool_calls↔tool 配对永远完整（否则下轮请求 400）。
    private func ensureStepToolResultsPaired(turn: Int, step: Int) async {
        let events = deps.writer.events
        var pending: [String] = []
        for event in events {
            switch event.payload {
            case .toolCall(let t, let s, let callId, _, _) where t == turn && s == step:
                pending.append(callId)
            case .toolResult(_, _, let callId, _, _, _, _, _):
                pending.removeAll { $0 == callId }
            default:
                break
            }
        }
        guard !pending.isEmpty else { return }
        let output = ToolOutput(text: "tool result was lost due to an internal error",
                                isError: true, errorName: "ToolResultLostError",
                                errorCode: "TOOL_RESULT_LOST", meta: nil)
        for callId in pending {
            Self.logger.error("turn \(turn) step \(step): tool result missing for "
                + "\(callId); synthesizing TOOL_RESULT_LOST")
            try? await deps.writer.append(.toolResult(
                turn: turn, step: step, callId: callId,
                content: output.text, isError: output.isError,
                errorName: output.errorName, errorCode: output.errorCode,
                meta: output.meta))
        }
    }

    // MARK: - 上下文注入（F038/F039/F040）

    private func injectContexts(messages: [String]) async throws -> [String] {
        let workspace = AgentLoop.workspaceAccess(sessionId: deps.sessionId)
        var injected: [String] = []

        // F038'：runtime context 快照投影（ERR-024；dsh RuntimeContextProjection
        // 语义）。①每步刷新 retained（归属消息被压缩影子化 → 失效重注入）；
        // ②渲染当前快照（workspace + AGENTS.md；ERR-025① 时间戳已移出——
        // 以 dsh 源码为准：快照只由注册的动态上下文位组成，时间在 dsh 是
        // 独立的 opt-in time-context 通道，与快照无关）；③内容没变就不注入
        // （缓存前缀稳定的关键不变量）；④注入即追加——落盘为 user/message，
        // 旧快照保留在历史。F039 AGENTS.md 增量 reconcile 并入本通道：AGENTS.md
        // 变化即快照文本变化 → 自动重注入（ContextInjector.reconcileAgentsMd
        // API 保留不再被 loop 调用）。
        runtimeProjection.refresh(events: deps.writer.events)
        let snapshot = deps.injector.baselineSnapshot(
            workspace: workspace, workspacePath: WanWoPaths.workspaceLinuxDir)
        if let pending = runtimeProjection.project(snapshot) {
            let event = try await deps.writer.append(.userMessage(text: pending))
            runtimeProjection.commit(text: pending, seq: event.seq)
        }

        // F040：@file 展开（首条用户消息）。
        for (index, text) in messages.enumerated() {
            if index == 0, let expanded = deps.injector.expandFileReferences(
                in: text, workspace: workspace).injected {
                injected.append(expanded)
            }
            injected.append(text)
        }
        return injected
    }

    private func checkCompactionPressure() async {
        let events = deps.writer.events
        let header = deps.writer.recordedRequestHeader
        let model = header?.config.model
        let info = deps.compactor.pressure(events: events, model: model, header: header)
        deps.callbacks.onTokenPressure(info)
        // T2.4 P0-2：触发口径 = estimatedTokens（表面估算）；usedTokens 已是
        // usage 锚点投影（呈现面），不进触发判定——两口径分离（Compactor 头注）。
        guard info.estimatedTokens >= info.thresholdTokens else { return }
        // 压缩失败不抛穿（dsh：继续回合）。
        let appendClosure: (SessionEvent.Payload, Bool) async throws -> Void = {
            [writer = deps.writer] payload, ignorable in
            try await writer.append(payload, ignorable: ignorable)
        }
        _ = await deps.compactor.compactIfNeeded(events: events, model: model,
                                                 append: appendClosure)
        let after = deps.compactor.pressure(events: deps.writer.events, model: model,
                                            header: header)
        deps.callbacks.onTokenPressure(after)
    }

    // MARK: - 一步（dsh step()：模型请求 + 工具执行）

    private func runStep(turn: Int, step: Int) async throws -> StepOutcome {
        let adapter = try await deps.makeAdapter()

        // prompt 组装（严格插值；组装失败按回合错误处理）。
        let assembly: (system: String, contextSnapshot: String, tools: [ToolSchemaEntry])
        do {
            assembly = try deps.assembler.assemble(toolSchemas: deps.registry.schemas())
        } catch {
            throw LLMError(message: String(describing: error), code: "PROMPT_ASSEMBLY")
        }

        // request/header（dsh buildRequest：config + system + tools）。
        let header = EpochHeader(
            config: LlmCallConfig(provider: adapter.providerName,
                                  model: adapter.endpoint.model,
                                  reasoningEffort: adapter.endpoint.reasoningEffort,
                                  maxTokens: nil),
            system: assembly.system,
            tools: assembly.tools.isEmpty ? nil : assembly.tools)
        _ = try await deps.writer.logRequestHeaderIfNeeded(header)
        // durable 检查点到此完成（append 即 fsync）——之后才构造模型流。

        let request = Self.buildLLMRequest(
            writer: deps.writer, adapter: adapter, assembly: assembly)
        let (blocks, usage, finish) = try await streamWithRetry(
            writer: deps.writer, adapter: adapter, request: request,
            turn: turn, step: step)

        // assistant/message（取消时 streamWithRetry 已 finalize interrupted 前缀）。
        // ERR-023：空 blocks（无任何 content/toolCall）的 assistant/message 不落盘。
        let persistable = blocks.persistableBlocks
        if !persistable.isEmpty {
            let message = AssistantMessage(id: UUID().uuidString,
                                           provider: adapter.providerName,
                                           model: adapter.endpoint.model,
                                           content: persistable)
            try await deps.writer.append(.assistantMessage(
                turn: turn, step: step, message: message, usage: usage, interrupted: false))
        }

        // finish error → 回合错误（dsh LlmError 路径）。
        if case .error(let failure) = finish {
            throw LLMError(message: failure.message, code: failure.code)
        }
        if case .maxTokens = finish { return .maxTokens }

        // 工具调用 → 调度（结果按 model order 落盘后继续回合）。
        let toolCalls = blocks.compactMap { block -> ToolCallSpec? in
            if case .toolCall(let id, let name, let arguments) = block {
                return ToolCallSpec(id: id, name: name, arguments: arguments)
            }
            return nil
        }
        if toolCalls.isEmpty { return .completed }

        await ToolCallScheduler.executeToolCalls(
            deps: deps, cancelFlag: toolCancelFlag, turn: turn, step: step,
            toolCalls: toolCalls, maxParallel: maxParallelToolCalls)
        return .hasToolCalls
    }

    // MARK: - 流式消费（dsh step() 流循环 + M1 RetryPolicy 重试语义）

    private func streamWithRetry(writer: SessionWriter,
                                 adapter: OpenAICompatAdapter,
                                 request: LLMRequest,
                                 turn: Int, step: Int) async throws
        -> (blocks: [ContentBlock], usage: TokenUsage?, finish: FinishReason) {
        var attempt = 0
        let retryId = UUID().uuidString
        let retryPolicy = RetryPolicy()

        while true {
            var blocks: [ContentBlock] = []
            var usage: TokenUsage?
            var finish: FinishReason = .stop
            do {
                let stream = adapter.stream(request)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    // model-visible=logged：每块先落盘再驱动 UI。
                    try await writer.append(.assistantChunk(turn: turn, step: step, chunk: chunk))
                    deps.callbacks.onLiveChunk(chunk)
                    switch chunk {
                    case .blockEnd(_, let block): blocks.append(block)
                    case .usage(let reported): usage = reported
                    case .finish(let reason): finish = reason
                    default: break
                    }
                }
            } catch {
                // 取消：finalize 已交付前缀为 interrupted 消息（dsh 语义）。
                if Task.isCancelled || cancelCause != nil {
                    await finalizeInterruptedPrefix(writer: writer, adapter: adapter,
                                                    turn: turn, step: step,
                                                    blocks: blocks, usage: usage)
                    throw CancellationError()
                }
                let llmError = (error as? LLMError)
                    ?? LLMError(message: String(describing: error), code: "UNKNOWN")
                guard retryPolicy.isRetryable(code: llmError.code),
                      retryPolicy.mode == .normal,
                      attempt < retryPolicy.maxRetries else {
                    throw llmError
                }
                attempt += 1
                let delayMs = retryPolicy.delayMs(retry: attempt,
                                                  providerRetryAfterMs: llmError.providerRetryAfterMs)
                // 先持久化再等待（dsh llm-retry）。
                try await writer.append(.llmRetry(
                    retryId: retryId, turn: turn, step: step,
                    provider: adapter.providerName,
                    mode: retryPolicy.mode.rawValue,
                    policyKey: "normal/\(retryPolicy.maxRetries)",
                    retry: attempt, maxRetries: retryPolicy.maxRetries,
                    delayMs: delayMs, failure: llmError.failure))
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                try await writer.append(.llmRetryStarted(
                    retryId: retryId, turn: turn, step: step, retry: attempt))
                continue
            }
            // ERR-023（分类丢失点）：消费方 Task 取消会让 AsyncThrowingStream
            // **正常终止**——next() 返回 nil 而非抛错，上面的 catch 不触发，
            // 流循环带着空/部分 blocks 与默认 .stop 落到正常收尾，取消被当作
            // 正常完成收拢（真机实证：手动停止 → 空 assistant/message +
            // turn/end completed）。此处显式识别：按 dsh 语义 finalize
            // interrupted 前缀并抛取消，让 turn 收尾分类为 aborted。
            if Task.isCancelled || cancelCause != nil {
                await finalizeInterruptedPrefix(writer: writer, adapter: adapter,
                                                turn: turn, step: step,
                                                blocks: blocks, usage: usage)
                throw CancellationError()
            }
            return (blocks, usage, finish)
        }
    }

    /// 已交付前缀的 interrupted finalize（dsh step() catch aborted 分支）：
    /// 有可交付内容才落 interrupted assistant/message（空消息不落盘，ERR-023）。
    /// append 失败静默（取消路径不掩盖 CancellationError 本身）。
    private func finalizeInterruptedPrefix(writer: SessionWriter,
                                           adapter: OpenAICompatAdapter,
                                           turn: Int, step: Int,
                                           blocks: [ContentBlock],
                                           usage: TokenUsage?) async {
        let persistable = blocks.persistableBlocks
        guard !persistable.isEmpty else { return }
        let message = AssistantMessage(id: UUID().uuidString,
                                       provider: adapter.providerName,
                                       model: adapter.endpoint.model,
                                       content: persistable)
        try? await writer.append(.assistantMessage(
            turn: turn, step: step, message: message, usage: usage, interrupted: true))
    }

    // MARK: - 请求构造（内容完全来自已落盘事件）

    /// 请求构造：消息完全来自已落盘事件（deriveMessages 线性折叠），
    /// system 取组装结果（与 request/header 快照一致），tools 透传组装产物
    /// （dsh buildRequest 语义）。
    /// ERR-024：runtime context 快照**不再随请求尾追**——快照以 user/message
    /// 落盘进历史（见 injectContexts 的 RuntimeContextProjection 投影），请求
    /// 消息流 append-only、前缀稳定，provider 前缀缓存才能命中（dsh
    /// runtime-context.ts 语义：快照不进 system、不逐请求重发）。
    private static func buildLLMRequest(writer: SessionWriter,
                                        adapter: OpenAICompatAdapter,
                                        assembly: (system: String,
                                                   contextSnapshot: String,
                                                   tools: [ToolSchemaEntry])) -> LLMRequest {
        let derived = writer.deriveMessages()
        let resolvedSystem = assembly.system.isEmpty ? derived.system : assembly.system
        let request = LLMRequest(
            baseURL: adapter.endpoint.baseURL,
            apiKey: adapter.apiKey,
            model: adapter.endpoint.model,
            system: resolvedSystem,
            messages: derived.messages,
            thinking: adapter.endpoint.thinking,
            reasoningEffort: adapter.endpoint.reasoningEffort,
            tools: assembly.tools.isEmpty ? nil : assembly.tools)
        // ERR-024 取证（临时）：相邻请求逐项指纹对比，定位缓存前缀断点。
        logCacheForensics(system: resolvedSystem,
                          messages: derived.messages,
                          tools: assembly.tools.isEmpty ? nil : assembly.tools)
        return request
    }

    // MARK: - 工作区访问

    nonisolated static func workspaceAccess(sessionId: String) -> WorkspaceFileAccess {
        WorkspaceFileAccess(sessionId: sessionId)
    }
}
