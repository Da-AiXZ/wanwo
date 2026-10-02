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

/// inbox 条目来源（M7 F006/F045：dsh MessageSource 的 WanWo 形态）。
/// user/message 事件载荷冻结不可改——来源归属走进程内 InboxEntry + 伴随
/// extensionEvent（goal 轮次 admitted = goal/round，见 AgentLoop claim 处）。
enum InboxSource: Equatable, Sendable {
    /// 用户/宿主直接输入（submit/steer/followup 缺省；dsh 缺省 source='user'
    /// 同语义——authority 视为直接人类输入）。
    case user
    /// goal 自动续跑轮（goal-round-driver followup 保留）。
    case goal(goalId: String, revision: Int, round: Int)
    /// 子 agent 结算通知（F045 settle 通道预留；M7.2 经 jobs 完成纸条通道，
    /// 本 case 供后续专用 notice 派发）。
    case subagentSettled(childId: String, stopReason: String)
    /// 宿主/系统注入（QA-2 P1-1：goal wrapup 收尾指令等——绝不计入
    /// directHuman authority，dsh deferContext 来源语义）。
    case system
    /// 子 agent 消息回传（QA-2 P1-2 deliverFromSubagent——dsh agent-message
    /// relay 等价：sender 是子 agent，绝不计入 directHuman authority）。
    case subagentMessage(childId: String)
}

/// 回合收尾观察缝载荷（M8 批2 件8；B3 常驻笔记的消费输入——turnEnd 事实 +
/// 会话身份；不含正文转录，笔记侧按需经 writer 自取，缝保持窄面）。
struct TurnObservation: Sendable {
    let sessionId: String
    let turn: Int
    let reason: TurnEndReason
    let endedAtMs: Int64
}

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
        /// T2.6 件6：增第二参 = 随行图片引用（E1 attachment/images 落盘后
        /// 发射；空数组 = 纯文本消息——live 乐观气泡据此带图上屏）。
        var onUserMessageAppended: @Sendable (String, [ImageAttachmentRef]) -> Void = { _, _ in }
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
        /// M4-C2：tool_search 组装步宿主（存在 deferred 工具 ⇒ 注册/刷新
        /// tool_search；nil = 不组装——既有调用面/测试不受扰）。
        var toolSearchAssembly: ToolSearchAssembly? = nil
        /// M4-D D2：技能注册表宿主（每步组装前 refresh 装载快照 + write-edit
        /// 失效判定消费方；nil = 不启用——既有调用面/测试不受扰）。
        var skillRegistry: SkillRegistry? = nil
        /// M4-E E5：hooks 五挂点编排器（UserPromptSubmit + Stop 由 loop 直挂；
        /// Pre/PostToolUse 经 pipeline 注入；nil = 不启用——既有调用面/测试
        /// 不受扰，skillRegistry 同款默认值纪律）。
        var hookPoints: HookPointRunner? = nil
        /// 真机批 B 全方位诊断：写进会话事件流的诊断通道（diag/trace，
        /// logOnly 不进模型上下文）——通知/调度/引擎各面的打点经此入
        /// 事件流导出，用户一个窗口看全貌。缺省静默。
        var diagTrace: @Sendable (String) -> Void = { _ in }
        /// 【工作区模型修正】会话 header cwd（writer.header.cwd 注入）——
        /// 文件工具直读根（workspaceAccess cwd 缝）+ shell 执行起跑目录的
        /// 单一事实源。nil = legacy 缺省语义（/var/wanwo/workspace 兜底）。
        /// 带默认值纪律同 skillRegistry/hookPoints：既有调用面/测试不受扰。
        var sessionCwd: String? = nil
        /// 【M7 件 B · F006】goal 域服务（goal-round-driver 宿主；nil = 不
        /// 启用——既有调用面/测试不受扰）。装配见 AppEnvironment.makeAgentStack。
        var goalService: GoalService? = nil
        /// 【M7Fix · citation 缝】assistant 消息落盘收尾缝（MemoryCitations
        /// 生产接线的公开缝——只缝不接线，接线由主理人在 AppEnvironment
        /// 合并）。入参 = 落盘前正文（text 块按 \n 合并）+ 会话 id + turn/step；
        /// 返回 = 剥离 citation 标记后的文本；返回与原文不同则用剥离后文本
        /// 落盘（codex citations.rs 语义：可见文本剥离、citation 条目持久
        /// 保留——载荷提取/usage 回写由接线侧在闭包内自行消费）。nil 缝 =
        /// 原样落盘（skillRegistry/hookPoints 同款默认值纪律，既有调用面/
        /// 测试不受扰）。
        var onAssistantMessageSealed:
            (@Sendable (String, String, Int, Int) async -> String)? = nil
        /// 【M8 批2 · B1 件8 · 回合收尾观察缝】turnEnd 落盘后发射（常驻笔记
        /// B3 消费——只缝不接线，接线由主理人在 AppEnvironment 合并）。
        /// 缝签名：TurnObservation{sessionId, turn, reason, endedAtMs}；
        /// nil 缝 = 零开销跳过（citation 缝同款默认值纪律，既有调用面/测试
        /// 不受扰）。
        var onTurnSettled: (@Sendable (TurnObservation) async -> Void)? = nil
    }

    // MARK: - 状态

    nonisolated let deps: Dependencies
    nonisolated let config: Config
    private var phase: Phase
    /// F042：inbox 条目（文本 + 可选图片引用——仅 submit 通道携带图片；
    /// steer/inject/followup 纯文本）。M7：source = 条目来源（InboxSource）。
    struct InboxEntry: Sendable {
        var text: String
        var images: [ImageAttachmentRef] = []
        var source: InboxSource = .user
    }

    private var nextStepInbox: [InboxEntry] = []    // steer/inject（本回合内消费）
    private var nextTurnInbox: [InboxEntry] = []    // followup（独立回合）
    private var cancelCause: CancelCause?
    /// 工具调度取消旗标（cancel 三源融合时置位；调度器子任务只读——
    /// 驱动器唤醒即复位，避免上一轮回合的残留置位污染新回合）。
    private let toolCancelFlag = CancelFlag()
    private var driverTask: Task<Void, Never>?
    /// 在飞工具批次（调度期间置位——中断收敛的 turn/step 真相源；
    /// 真机转圈批 A：合成 result 必须落在正确的 turn/step 才保配对不变量）。
    private var activeToolBatch: (turn: Int, step: Int)?
    private var maxParallelToolCalls: Int
    /// 【M8 批2 · B1 件4】本轮是否已做过溢出恢复（catch-condense-retry 每
    /// 回合一次——Cline overflowRecoveryAttempted 语义）；runTurn 开头复位。
    private var overflowRecoveryAttempted = false
    /// runtime context 快照投影状态（F038' ERR-024；dsh RuntimeContextProjection
    /// 语义移植，见 Core/Context/RuntimeContextProjection.swift）。
    private var runtimeProjection = RuntimeContextProjection()

    // MARK: goal-round-driver 状态（M7 件 B；dsh DriverState 的 WanWo 承载）

    /// goal 自动续跑保留（dsh RoundAttempt 1:1；actor 内串行化——dsh 进程级
    /// 驱动器状态收进本 actor，登记）。
    struct GoalRoundAttempt: Equatable {
        enum Phase: Equatable { case queued, claimed, admitted }
        var goalId: String
        var revision: Int
        var round: Int
        var text: String
        var phase: Phase
        var cancelled: Bool
        var stale: Bool
    }

    private var goalAttempt: GoalRoundAttempt?
    /// 有竞争性 prompt 排队（真实用户输入等）时禁止自动续跑（dsh
    /// competingQueued 1:1）。
    private var goalCompetingQueued = false

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
            // M7Fix2-A2：reasoning_content 已上 wire——取证指纹必须覆盖，
            // 否则该字段引发的前缀发散对本工具不可见（历史轮 reasoning 来自
            // 已落盘事件、逐请求稳定 → 正常恒为纯尾部追加）。
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                text += "\u{4}" + reasoning
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

    /// 用户输入（idle → 新回合；非 idle → followup 排队）。F042：images =
    /// 随本条消息发送的已准入图片引用（AttachmentStore.saveImages 产物；
    /// AgentLoop 不做准入——准入归 composer 提交路径，loop 只落盘引用）。
    func submit(_ text: String, images: [ImageAttachmentRef] = []) {
        let entry = InboxEntry(text: text, images: images, source: .user)
        nextTurnInbox.append(entry)
        goalNoteNextTurnInsert(entry)
        wake()
        notifyActivity(.mailbox)
    }

    /// steer：本回合下一步注入 + 唤醒（打断注入；dsh next-step + wakeup）。
    func steer(_ text: String, source: InboxSource = .user) {
        nextStepInbox.append(InboxEntry(text: text, source: source))
        wake()
        notifyActivity(.steer)
    }

    /// inject：本回合下一步注入，不唤醒（dsh inject）。
    func inject(_ text: String, source: InboxSource = .user) {
        nextStepInbox.append(InboxEntry(text: text, source: source))
        notifyActivity(.steer)
    }

    /// followup：排队独立回合 + 唤醒。
    func followup(_ text: String, source: InboxSource = .user) {
        let entry = InboxEntry(text: text, source: source)
        nextTurnInbox.append(entry)
        goalNoteNextTurnInsert(entry)
        wake()
        notifyActivity(.mailbox)
    }

    /// 子 agent 消息回传投递（QA-2 P1-2 deliverFromSubagent——dsh
    /// createAgentMessage :62-73 逐字文案前缀 + sendWaking(parent,'steer')
    /// 收敛排队形态；source=.subagentMessage 绝不计入 directHuman authority）。
    func deliverFromSubagent(_ text: String, from childId: String) {
        let entry = InboxEntry(
            text: "Agent \(childId) sent a message: \(text)",
            source: .subagentMessage(childId: childId))
        nextStepInbox.append(entry)
        wake()
        notifyActivity(.steer)
    }

    // MARK: goal-round-driver（M7 件 B；dsh goal-round-driver/src/index.ts 语义）

    /// next-turn 插入的竞争围栏（dsh agent/inbox/inserted 分支 1:1）：
    /// 非本驱动器保留的插入 → competingQueued 置位；保留仍在 queued → stale。
    private func goalNoteNextTurnInsert(_ entry: InboxEntry) {
        if case .goal(let goalId, let revision, let round) = entry.source,
           let attempt = goalAttempt,
           attempt.goalId == goalId, attempt.revision == revision, attempt.round == round,
           attempt.text == entry.text {
            // 自驱保留（sameQueued 深相等）——不算竞争。
            return
        }
        guard goalAttempt != nil else { return }
        goalCompetingQueued = true
        if goalAttempt?.phase == .queued {
            goalAttempt?.stale = true
        }
    }

    /// goal 保留是否仍有效（dsh validReservation :346-359 1:1——claimed 非瘦
    /// stale + 排队内容深相等 + goal 当前 revision + armed + round ===
    /// roundsStarted+1；WanWo 活性由本 actor 内联判定，登记）。
    private func goalReservationValid(_ service: GoalService,
                                      _ entry: InboxEntry,
                                      _ source: GoalRef.Round) async -> Bool {
        guard let attempt = goalAttempt, attempt.phase == .claimed, !attempt.stale,
              attempt.goalId == source.goalId, attempt.revision == source.revision,
              attempt.round == source.round, attempt.text == entry.text else {
            return false
        }
        guard let goal = try? await service.get() else { return false }
        return goal.id == source.goalId && goal.revision == source.revision
            && goal.phase == .active && goal.activation == .armed
            && source.round == goal.roundsStarted + 1
    }

    /// 条目是否 goal 自动续跑来源。
    private static func isGoalSource(_ entry: InboxEntry) -> Bool {
        if case .goal = entry.source { return true }
        return false
    }

    /// claim 批内的 goal 保留判定（标记 claimed + 逐条 validReservation）。
    private func validateGoalClaims(_ service: GoalService,
                                    _ entries: [InboxEntry]) async -> Bool {
        var valid = true
        for entry in entries where Self.isGoalSource(entry) {
            guard case .goal(let goalId, let revision, let round) = entry.source else { continue }
            if let attempt = goalAttempt, attempt.phase == .queued,
               attempt.goalId == goalId, attempt.revision == revision,
               attempt.round == round, attempt.text == entry.text {
                goalAttempt?.phase = .claimed
            }
            let source = GoalRef.Round(goalId: goalId, revision: revision, round: round)
            if !(await goalReservationValid(service, entry, source)) {
                valid = false
            }
        }
        return valid
    }

    /// 消费已结算的 attempt 并驱动下一轮（dsh drive :138-205 + agent/status
    /// idle 分支 :259-281 的合并 WanWo 形态：取消/未接纳的 attempt 收敛回
    /// idle → 精确 ref 围栏内 pause 该 goal；attempt 结算消费 → armed+active
    /// 才保留下一轮；roundsStarted ≥ max → block(code:"round-limit")）。
    /// 仅在收敛 idle 后调用（readyToDrive 等价）。
    private func goalDrive() async {
        guard let service = deps.goalService else { return }
        // dsh :264-279：cancelled/queued/claimed 的 attempt 收敛回 idle →
        // pause（围栏到该 attempt 的精确 ref——resume 已 bump revision 的
        // goal 不受误伤）。
        if let attempt = goalAttempt,
           attempt.phase == .queued || attempt.phase == .claimed || attempt.cancelled {
            let current: GoalView? = (try? await service.get()) ?? nil
            if let goal = current, goal.phase == .active, goal.activation == .armed,
               attempt.goalId == goal.id, attempt.revision == goal.revision {
                goalAttempt = nil
                _ = try? await service.pause(ref: goal.ref, origin: .host)
                // M7Fix 呈现：自动 pause 落大白话注记（照 :683「步数上限」
                // 先例——ignorable .system，投影器渲染；用户实测"对话突然
                // 暂停无解释"病根）。
                try? await deps.writer.append(
                    .system(note: "目标已自动暂停（续轮条件在回合结束时未满足），回复「继续」可恢复"),
                    ignorable: true)
                return
            }
        }
        // attempt 结算消费（dsh :156-162；checkpoint 语义：万我 append 即
        // fsync，无独立 flush 缝——needsCheckpoint 略，登记）。
        if goalAttempt != nil {
            goalAttempt = nil
        }
        goalCompetingQueued = false
        let current: GoalView? = (try? await service.get()) ?? nil
        guard let goal = current else { return }
        guard goal.phase == .active, goal.activation == .armed else { return }
        if goal.roundsStarted >= goal.maxGoalRounds {
            _ = try? await service.block(
                ref: goal.ref,
                reason: GoalBlockReason(
                    code: "round-limit",
                    message: "Goal reached its configured limit of \(goal.maxGoalRounds) rounds."),
                origin: .host)
            // M7Fix 呈现：round-limit block 落大白话注记（同 pause 分支先例）。
            try? await deps.writer.append(
                .system(note: "目标已到轮次上限（\(goal.maxGoalRounds) 轮），已自动标记为 blocked"),
                ignorable: true)
            return
        }
        let round = goal.roundsStarted + 1
        let text = GoalRoundPrompt.render(goal: goal, round: round)
        goalAttempt = GoalRoundAttempt(goalId: goal.id, revision: goal.revision,
                                       round: round, text: text, phase: .queued,
                                       cancelled: false, stale: false)
        followup(text, source: .goal(goalId: goal.id, revision: goal.revision, round: round))
        // queue-failed block（dsh :193-204）不适用：WanWo followup 为内存
        // append 无失败路径，登记。
    }

    /// goal/changed 通知入口（dsh 'goal/changed' 分支 :283-294 1:1）：
    /// 宿主 pause 在运行中 → 取消当前回合（inbox 保留）；idle 即驱动。
    func onGoalChanged(_ change: GoalChanged) async {
        guard deps.goalService != nil else { return }
        if change.operation == .pause, change.origin == .host, case .running = phase {
            // dsh agent.cancel({kind:'user'}, {keepInbox:true})：WanWo cancel
            // 不清 inbox（kick 收敛回放）——keepInbox 语义天然成立。
            cancel(cause: .user)
        }
        if case .idle = phase {
            await goalDrive()
        }
    }

    /// 回合收尾 goal 围栏（dsh session/event 'turn/end' 分支 :329-339 1:1）。
    private func goalTurnEndFence(_ reason: TurnEndReason) async {
        guard let service = deps.goalService else { return }
        await service.clearTurnProvenance()
        switch reason {
        case .maxTokens:
            // max-tokens → disarm（dsh :330-333）。
            goalAttempt = nil
            _ = await service.disarm()
        case .aborted:
            // M7Fix（dsh 对齐 · goal-round-driver index.ts:374-383）：本 fence
            // 收窄为只处理 attempt 存在（claimed/admitted）场景——置 cancelled，
            // 交 goalDrive 的精确围栏收敛。无 attempt 的 aborted（保留失守
            // reject 收尾：pre-step/post-decision reject 已置 goalAttempt=nil）
            // 不再 disarm——goal 保持 armed，回合收尾后由既有 idle→goalDrive()
            // 自动重新预约同一轮（dsh reject 后 restoreOtherClaimed +
            // requestDrive，goal 不掉臂）。
            // 登记偏差：dsh index.ts:329-339 的 aborted→disarm 原文覆盖
            // 「无保留的纯取消」场景；WanWo reject 收尾复用 .aborted 词汇，
            // 无法在该 fence 区分两源，故按派单一律不 disarm——纯取消时
            // armed goal 由 goalDrive 的 revision 围栏与 competingQueued
            // 竞争位承接（误续跑面 = goalDrive 只在无竞争时预约同一轮）。
            if let attempt = goalAttempt,
               attempt.phase == .claimed || attempt.phase == .admitted {
                goalAttempt?.cancelled = true
            }
        default:
            break
        }
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
        // 真机转圈批 A：在飞工具立即收敛（合成 error result + 工具卡回调
        // 停转）——协作式旗标对不检查点的在飞调用（如 run_code 挂在续体
        // 上）永远不生效，收敛必须有确定载体。turn/step 用真实批次值
        // （phase 推算的 step=0 会破坏 result 配对不变量）。
        if let batch = activeToolBatch {
            ToolCallScheduler.convergeInflightOnInterrupt(
                deps: deps, turn: batch.turn, step: batch.step)
        }
        // 真机批 A 补充：中断后 UI 立即解锁（发送键恢复）——真实 phase 仍
        // 由驱动器收敛后自然回 idle（挂着的 pipeline.run 返回时收尾）；
        // 此处仅假发 idle 给 UI（用户可发消息入 inbox，收敛后 kick 消费）。
        deps.callbacks.onPhaseChange(.idle(lastTurn: deps.writer.nextTurn - 1))
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
        notifyIdle()
        // 收敛回放：队列仍有 followup → 再唤醒（dsh wakeRequested 回放）。
        if !nextTurnInbox.isEmpty || !nextStepInbox.isEmpty {
            wake()
        } else {
            // M7 件 B：idle 驱动（dsh agent/status idle → requestDrive）——
            // armed+active 时保留下一轮；attempt 收敛 pause 围栏同位。
            await goalDrive()
        }
    }

    // MARK: - whenIdle（dsh agent.whenIdle 等价——M7 件 C 子驱动器消费缝）

    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// 等待收敛 idle：已在 idle 立即返回；否则挂起至驱动循环收敛。
    /// 子 agent 驱动器（SubagentInProcessDriver）据此等待 one-shot 回合结束。
    func whenIdle() async {
        if case .idle = phase { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleWaiters.append(cont)
        }
    }

    /// 收敛 idle 时唤醒全部等待者（kick 独占调用点）。
    private func notifyIdle() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// phase 查询缝（M7.3 件 H：list_agents running/idle 判定 + wait 面测试
    /// 观察用；只读不扰核心循环——派单"改动仅限新增查询/等待缝"）。
    func currentPhase() -> Phase {
        phase
    }

    // MARK: - inbox 活动等待缝（M7.3 件 H · wait_agent 底座）

    /// inbox 活动类别（codex InputQueueActivity 1:1——wait.rs:180-185
    /// WaitOutcome 的来源通道）。
    enum InboxActivity: Equatable, Sendable {
        /// next-turn 条目到达（followup——子结算通知/新回合输入排队）。
        case mailbox
        /// 本回合步边界条目到达（steer/inject/deliverFromSubagent——新输入
        /// 打断等待）。
        case steer
    }

    /// 活动等待者（一次一续体；activity 与 timeout 双端竞争，先到先 resume，
    /// 后到按 id 摘除不再 resume——续体单次恢复纪律）。
    private struct ActivityWaiter {
        let id = UUID()
        let continuation: CheckedContinuation<InboxActivity?, Never>
    }

    private var activityWaiters: [ActivityWaiter] = []

    /// 等待 inbox 活动（wait.rs:187-205 wait_for_activity 的 watch 通道语义
    /// 等价——挂起至活动到达或超时，**不轮询状态**）。
    /// pending 语义（wait.rs:190-197）：调用时已有排队条目（steer 面优先，
    /// 与条目消费序一致）→ 立即返回，不等待。
    /// - Returns: 活动类别；nil = 超时（WaitOutcome::TimedOut）。
    func waitForInboxActivity(timeoutMs: Int64) async -> InboxActivity? {
        if !nextStepInbox.isEmpty { return .steer }
        if !nextTurnInbox.isEmpty { return .mailbox }
        return await registerActivityWaiter(timeoutMs: timeoutMs)
    }

    /// 等待"下一次" inbox 活动（M7-Fix 批5 W1 · dsh tool-agent-team
    /// wait_agent 语义对拍：只观察本调用开始**之后**的变化——调用时已排队
    /// 的条目不唤醒等待者，index.ts:37 "observes only changes after that
    /// call starts, never wakes a member"）。turn21 实证根因修复：父 inbox
    /// 积压（settle 通知等）曾使 pending 短路把 wait_agent 变成立返。
    /// 与 waitForInboxActivity 的唯一差异：**不做 pending 短路**。事件机制
    /// 零改动——完全复用既有 activityWaiters/notifyActivity/超时哨兵基建。
    /// actor 串行化保证登记是单一同步段——登记之后任何 enqueue 的
    /// notifyActivity 必达；登记之前入队的边（含积压）只留待新边。
    /// - Returns: 活动类别；nil = 超时。
    func waitForNextInboxActivity(timeoutMs: Int64) async -> InboxActivity? {
        return await registerActivityWaiter(timeoutMs: timeoutMs)
    }

    /// 活动等待者登记（一次一续体；activity 与 timeout 双端竞争，先到先
    /// resume，后到按 id 摘除不再 resume——续体单次恢复纪律）。
    /// withCheckedContinuation 体在 actor 同步段内同步执行（不让出），
    /// 保证登记与 notify 之间无丢失窗口。
    private func registerActivityWaiter(timeoutMs: Int64) async -> InboxActivity? {
        return await withCheckedContinuation { (cont: CheckedContinuation<InboxActivity?, Never>) in
            let waiter = ActivityWaiter(continuation: cont)
            activityWaiters.append(waiter)
            let waiterID = waiter.id
            let nanoseconds = UInt64(max(0, timeoutMs)) * 1_000_000
            // 超时哨兵：到期摘除自身并 resume nil；若活动先到，waiter 已被
            // notifyActivity 摘除，本任务到期后摘除 no-op（firstIndex 为 nil）。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                await self?.finishActivityWait(id: waiterID, result: nil)
            }
        }
    }

    /// 按摘除并恢复（活动端/超时端共用；续体单次恢复由摘除唯一性保证）。
    private func finishActivityWait(id: UUID, result: InboxActivity?) {
        guard let index = activityWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = activityWaiters.remove(at: index)
        waiter.continuation.resume(returning: result)
    }

    /// 活动发射（条目入列点独占调用——先入列后发射，等待者恢复时快照已含条目）。
    private func notifyActivity(_ activity: InboxActivity) {
        let waiters = activityWaiters
        activityWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: activity)
        }
    }

    // MARK: - 回合（dsh turn()）

    /// 执行一个回合。- Returns: 队列仍有待处理工作时 true（继续下一回合）。
    private func runTurn() async throws -> Bool {
        let turn = deps.writer.nextTurn
        overflowRecoveryAttempted = false
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
                // 批12+右栏批2 前置：文案中文化+投影器 .system 分支补齐后
                // 用户可见（此前落盘不显示="对话突然中断"无解释，用户实测）。
                if stepIndex >= config.maxTurns {
                    try? await deps.writer.append(
                        .system(note: "本回合已达步数上限（\(config.maxTurns) 步防失控护栏），已暂停——回复「继续」接着跑"),
                        ignorable: true)
                    endReason = .blocked
                    break
                }

                // claim inbox（dsh preStep：首步 next-turn，其后 next-step）。
                var entries: [InboxEntry] = []
                if stepIndex == 0 {
                    if !nextTurnInbox.isEmpty {
                        entries = nextTurnInbox
                        nextTurnInbox.removeAll()
                    } else if !nextStepInbox.isEmpty {
                        entries = nextStepInbox
                        nextStepInbox.removeAll()
                    } else {
                        endReason = .completed
                        break
                    }
                } else {
                    // 工具结果步：steer/inject 消息（可为空——模型消费工具结果）。
                    entries = nextStepInbox
                    nextStepInbox.removeAll()
                }

                // M7 件 B：goal 轮 pre-step 权威门（dsh agent/pre-step
                // validReservation :346-383 1:1）。失守 → reject：goal 条目丢弃、
                // 其余 claimed 条目回队列（restoreOtherClaimed 等价）、balanced
                // 收尾回合（此处 stepStart 未落盘——无 step 需闭合）。
                if let service = deps.goalService, entries.contains(where: Self.isGoalSource) {
                    let valid = await self.validateGoalClaims(service, entries)
                    if !valid {
                        if let attempt = goalAttempt, attempt.phase == .claimed {
                            goalAttempt?.stale = true
                        }
                        goalAttempt = nil
                        let retained = entries.filter { !Self.isGoalSource($0) }
                        nextTurnInbox.insert(contentsOf: retained, at: 0)
                        endReason = .aborted(cause: "goal round reservation invalid")
                        break
                    }
                }

                stepIndex += 1
                let step = stepIndex
                try await deps.writer.append(.stepStart(turn: turn, step: step))

                // 上下文注入（F038/F039/F040）。
                let injected = try await self.injectContexts(entries: entries)

                // M4-E E5：UserPromptSubmit 挂点（CC index.ts:219-235 / codex
                // :199-222——dsh agent/pre-step 位）。有 prompt 才挂（dsh
                // messages.length===0 → next() 同语义）；matchQuery 恒 ""。
                var upsContexts: [String] = []
                let upsPrompt = injected.map(\.text)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if let hookPoints = deps.hookPoints, !upsPrompt.isEmpty {
                    let merged = await hookPoints.userPromptSubmit(
                        turn: turn, prompt: upsPrompt)
                    if merged.decision == .deny {
                        // 拍板⑥：丢弃该消息 + turnEnd aborted(cause:)（CC
                        // reject 语义=无 model-visible 消息落盘）。stepStart
                        // 已落盘 → 先闭合 step 再 break（turn/end 前不得有
                        // 开放 step——SessionInvariant）。
                        // M7 件 B：goal 轮被下游 reject → block（dsh
                        // prompt-rejected :400-410——仅当 goal 仍为该保留身份
                        // 且 active+armed）。
                        if let service = deps.goalService, goalAttempt?.phase == .claimed {
                            let current: GoalView? = (try? await service.get()) ?? nil
                            if let goal = current, goal.phase == .active, goal.activation == .armed,
                               goalAttempt?.goalId == goal.id, goalAttempt?.revision == goal.revision {
                                _ = try? await service.block(
                                    ref: goal.ref,
                                    reason: GoalBlockReason(
                                        code: "prompt-rejected",
                                        message: "Goal round was rejected before entering its step."),
                                    origin: .host)
                            }
                        }
                        goalAttempt = nil
                        try? await deps.writer.append(
                            .stepEnd(turn: turn, step: step))
                        endReason = .aborted(
                            cause: "blocked by UserPromptSubmit hook")
                        break
                    }
                    // context-only 不否决：注入后照常 enter（delegate 语义）。
                    upsContexts = merged.additionalContext
                }

                // M7 件 B：post-decision 复核（dsh :412-424——UPS await 期间
                // goal 状态可能变化；失守同 reject 路径，此时 stepStart 已落盘
                // → 先闭合 step）。
                if let service = deps.goalService,
                   (entries + injected).contains(where: Self.isGoalSource) {
                    let valid = await self.validateGoalClaims(
                        service, injected.isEmpty ? entries : injected)
                    if !valid {
                        goalAttempt = nil
                        let retained = injected.filter { !Self.isGoalSource($0) }
                        nextTurnInbox.insert(contentsOf: retained, at: 0)
                        try? await deps.writer.append(.stepEnd(turn: turn, step: step))
                        endReason = .aborted(cause: "goal round reservation invalid")
                        break
                    }
                }

                // M7Fix2-A1（真机 bug1 前半）：纯图消息不得整条被吞——dsh
                // InputBar 允许 image-only（F042 同源），text 为空但 images
                // 非空的条目必须照常落盘（userMessage + E1 attachment/images
                // + onUserMessageAppended），否则 UI 无泡、模型收空轮次。
                // 空文本落盘安全：SessionInvariant 对 user/message 无约束；
                // DeriveFold 折叠为 content:"" + images 的 ChatMessage，
                // OpenAICompatAdapter 序列化为仅 image_url parts（合法 OpenAI
                // vision 形态）。同函数内其余 text-only 假设核对（登记）：
                //   · goal admitted 记录（下方 if case .goal）——goal 来源
                //     条目恒无图，行为不变；
                //   · authority directHuman（noteTurnProvenance 处）——按
                //     source 判定、与文本无关，纯图用户消息正确计入；
                //   · UPS 挂点（upsPrompt）——纯图轮 prompt 为空不挂 hook
                //     （dsh messages.length===0 → next() 同语义，登记）。
                for entry in injected where !entry.text.isEmpty || !entry.images.isEmpty {
                    let event = try await deps.writer.append(.userMessage(text: entry.text))
                    // F042：附件引用随归属 userMessage 紧随落 E1 通道
                    // （SessionEvent 专用 case 冻结——E1 纪律；载荷声明归属
                    // seq，DeriveFold/ConversationProjector 按序挂接回消息）。
                    if !entry.images.isEmpty,
                       let payload = AttachmentStore.refsJSONPayload(
                            seq: event.seq, refs: entry.images) {
                        _ = try await deps.writer.append(.extensionEvent(
                            kind: AttachmentStore.imagesEventKind, payload: payload))
                    }
                    // 【批3 A3】模型可见附件 URL 清单（"截图已不可用"根因
                    // 修复）：带图条目紧随 attachment/images 注入
                    // `<attachment-refs>` userMessage——模型获得真实可解析
                    // 地址，防编造 wanwo:// 附件名（见
                    // AttachmentStore.modelReferenceNote 头注）。UI 侧走
                    // marker 过滤恒隐藏（ConversationProjector.markerPrefixes）；
                    // 注入失败不抛穿（UPS/R5 同族纪律）。
                    if !entry.images.isEmpty,
                       let note = AttachmentStore.modelReferenceNote(refs: entry.images) {
                        do {
                            _ = try await deps.writer.append(.userMessage(text: note))
                        } catch {
                            Self.logger.error("attachment-refs note append "
                                              + "failed: \(error)")
                        }
                    }
                    // M7 件 B：goal 轮 admitted 记录（dsh user/message
                    // MessageSource 的伴随事件等价——载荷冻结定案；fold 据此
                    // 推进 roundsStarted，GoalFold.applyGoalEvent）。
                    if case .goal(let goalId, let revision, let round) = entry.source {
                        _ = try await deps.writer.append(.extensionEvent(
                            kind: GoalEvents.roundKind,
                            payload: .object(["goalId": .string(goalId),
                                              "revision": .int(revision),
                                              "round": .int(round)])))
                        if let attempt = goalAttempt,
                           attempt.goalId == goalId, attempt.revision == revision,
                           attempt.round == round, attempt.text == entry.text {
                            goalAttempt?.phase = .admitted
                        }
                    }
                    // P2-⑪ 消息即时上屏（落盘即发射；UI 侧过滤标记消息）。
                    // T2.6 件6：引用事件已落盘后才发射（见上）——随行图片引用
                    // 供 live 乐观气泡带图上屏（用户 #22 前半）。
                    deps.callbacks.onUserMessageAppended(entry.text, entry.images)
                }

                // M7 件 B：authority provenance 登记（GoalService 工具面权威
                // 判定的进程内证据——dsh open-turn 事件流判定的等价承载；
                // claim 条目来源，工具侧按 ctx.turn 校验）。
                if let service = deps.goalService {
                    let directHuman = injected.contains { $0.source == .user }
                    let goalRound: GoalRef.Round? = injected.compactMap { entry -> GoalRef.Round? in
                        if case .goal(let goalId, let revision, let round) = entry.source {
                            return GoalRef.Round(goalId: goalId, revision: revision, round: round)
                        }
                        return nil
                    }.first
                    await service.noteTurnProvenance(turn: turn, directHuman: directHuman,
                                                     goalRound: goalRound)
                }

                // M4-E E5：UPS 上下文注入（CC index.ts:226-235——context-only
                // 不否决，随 prompt 之后、模型请求之前；SkillCatalogInjector
                // 同款 userMessage 通道）。注入失败不抛穿（R5 同族）。
                for text in upsContexts {
                    do {
                        try await deps.writer.append(.userMessage(text: text))
                    } catch {
                        Self.logger.error("UserPromptSubmit context injection "
                            + "failed: \(String(describing: error))")
                    }
                }

                // 压力检查（dsh pre-step 压缩介入点；失败继续回合）。
                await self.checkCompactionPressure()

                // 一步（模型请求 + 工具调度）+ LLM 超限 catch-condense-retry
                //（M8 批2 件4：CONTEXT_WINDOW_EXCEEDED / 历史畸形 → 落
                // condensation-request(overflow) + 立即 HARD 压缩 + 重试一次；
                // 重试请求必须确实变小否则终态报错）。
                let outcome: StepOutcome
                do {
                    outcome = try await runStep(turn: turn, step: step)
                } catch {
                    guard !overflowRecoveryAttempted,
                          Self.isContextOverflowLike(error) else { throw error }
                    overflowRecoveryAttempted = true
                    outcome = try await recoverFromContextOverflow(
                        turn: turn, step: step)
                }
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

        // 真机批 B4：回合收尾清理过时纸条（JobCompletionNotice 前缀）——
        // 纸条 = "作业完成去取结果"的中间提醒；回合已结束时 AI 多经 job_output
        // wait 直接拿到结果，纸条已过时（滞留会在后续回合被 claim 出现旧闻）。
        // 按前缀过滤（非全清）：Stop hook 的 steer 文本同住 nextStepInbox，
        // 须跨回合存活（强制续步语义），不得误伤。清理位先于 Stop 挂点。
        nextStepInbox.removeAll { $0.text.hasPrefix("【系统通知】") }

        // M4-E E5：Stop 挂点（CC index.ts:270-277 / codex :260-270——dsh
        // agent/turn-stopping 位，turnEnd 落盘前）。仅自然完成边界触发
        // （aborted/error/blocked/maxTokens 非 stopping boundary 语义——取消
        // 或失败回合强制续步违背用户意图，裁定呈报）。deny → steer 强制续步
        //（AgentLoop.steer:247 现成；kick() 收敛回放 nextStepInbox 非空再
        // 唤醒——AgentLoop.kick:328——turn N 以 completed 收尾、steer 文本
        // 作为 turn N+1 首步 claim 消费，强制续步达成）。
        if let hookPoints = deps.hookPoints, case .completed = finalReason {
            let merged = await hookPoints.stop(turn: turn)
            if merged.decision == .deny {
                let text = merged.reason ?? "continue: blocked by Stop hook"
                self.steer(text)
            }
        }

        try? await deps.writer.append(.turnEnd(turn: turn, reason: finalReason))
        deps.callbacks.onTurnEnd(finalReason)

        // M8 批2 件8：回合收尾观察缝（turnEnd 落盘后发射；B3 常驻笔记消费
        // ——只缝不接线，接线由主理人在 AppEnvironment 合并；nil 缝零开销）。
        if let seam = deps.onTurnSettled {
            let observation = TurnObservation(
                sessionId: deps.sessionId, turn: turn, reason: finalReason,
                endedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
            await seam(observation)
        }

        // M7 件 B：回合收尾 goal 围栏（dsh session/event turn/end 分支——
        // maxTokens→disarm；aborted→claimed/admitted 置 cancelled，否则 disarm；
        // 并清 authority provenance）。
        await goalTurnEndFence(finalReason)

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

    private func injectContexts(entries: [InboxEntry]) async throws -> [InboxEntry] {
        // 验收修复 C-1（2026-09-27）：workspaceAccess 补 cwd 注入。原调用缺
        // cwd → WorkspaceFileAccess 恒 legacy 会话桶解析——项目模式（cwd 落
        // projects 根）会话里 @ 引用任何文件都解析不到、静默失败（F040 建于
        // legacy 单一桶时代，项目模式铺开后语义脱节；批2-3 真机实证 @ 引用
        // 图片零注入的一半真凶，文本文件引用同样受害）。
        let workspace = AgentLoop.workspaceAccess(sessionId: deps.sessionId,
                                                  cwd: deps.sessionCwd)

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
            workspace: workspace,
            workspacePath: deps.sessionCwd ?? WanWoPaths.workspaceLinuxDir)
        if let pending = runtimeProjection.project(snapshot) {
            let event = try await deps.writer.append(.userMessage(text: pending))
            runtimeProjection.commit(text: pending, seq: event.seq)
        }

        // F040：@file 展开（首条用户消息）；F042：图片引用只归属首条真实
        // 用户消息（后续条目均为注入/steer 词汇，无图）。
        // 【验收修复 P0-1 2026-09-28】双消息方案：文件内容块先独立落盘一条
        // user/message（markerPrefixes 过滤不渲染），用户原话保留为真实消息
        // ——旧实现 `text = injected` 把原话整体替换成 <file> 块（批A-F 验收
        // ③真机实证：用户"引用+提问"发出后问题被吞，AI 只收到文件内容反问
        // "想让我做什么"）。C-1 修复让项目模式 @ 引用真正解析到文件后，此
        // F040 原始缺陷首次显形。cleaned == 原话（expandFileReferences 不改写）。
        var expanded: [InboxEntry] = []
        for (index, entry) in entries.enumerated() {
            var text = entry.text
            if index == 0 {
                let refs = deps.injector.expandFileReferences(
                    in: text, workspace: workspace)
                if let injected = refs.injected {
                    _ = try await deps.writer.append(.userMessage(text: injected))
                    text = refs.cleaned
                }
            }
            // M7Fix（根因修复 · 真机+事件流实证）：source 必须原样带入——
            // 旧实现缺 source 参数（memberwise 缺省 .user），goal 轮次注入
            // 消息落盘后 source 退化为 .user → 下游 goal/round admitted
            // extensionEvent 永不写入（:806 判定）→ roundsStarted 恒 0 →
            // goalAttempt 卡 .claimed → goalDrive 误 pause + directHuman
            // authority 污染（:828 恒真）。
            expanded.append(InboxEntry(text: text,
                                       images: index == 0 ? entry.images : [],
                                       source: entry.source))
        }
        return expanded
    }

    private func checkCompactionPressure() async {
        let events = deps.writer.events
        let header = deps.writer.recordedRequestHeader
        let model = header?.config.model
        let info = deps.compactor.pressure(events: events, model: model, header: header)
        deps.callbacks.onTokenPressure(info)
        // M8 批2 件3：触发三源评估在 Compactor.compactIfNeeded 内完成（token
        // 超限→HARD 预算=窗口解析分母×0.9 / 事件数超 240→SOFT / 未处理
        // condensation-request→HARD；多原因取最严遗忘集）+ 熔断停自动压缩。
        // T2.4 P0-2：触发口径 = 工作集 token 估算（M8 批2 起含 tombstone 过滤
        // 与掩码变换，与请求构造同一折叠）；呈现面 usedTokens 分离不变。
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

    // MARK: - LLM 超限 catch-condense-retry（M8 批2 件4）

    /// 溢出恢复（sdk agent/agent.py:813-854 的 WanWo 回合内等价 + Cline
    /// overflow_recovery 同形态，登记 b1-report.md §1.2-3）：
    /// ① 重建工作集（投影纯函数即时重算——万我无增量 view 缓存态可坏，
    ///   rebuild_view 语义等价）；
    /// ② 落 condensation-request/v1(overflow)（HARD 触发载体 + 审计）；
    /// ③ 立即执行一次 HARD 压缩；
    /// ④ 重试请求必须确实变小（Cline agent-runtime.ts:2205-2228），否则终态
    ///   报错不空转（CONTEXT_OVERFLOW_NOTHING_TO_COMPACT）；
    /// ⑤ 同 step 重试一次（assistantChunk 不进派生历史——DeriveFold 忽略
    ///   chunk，重放安全）。
    private func recoverFromContextOverflow(turn: Int, step: Int) async throws -> StepOutcome {
        Self.logger.warning("turn \(turn) step \(step): context overflow detected, "
            + "starting catch-condense-retry")
        let tokensBefore = Compactor.estimateSession(deps.writer.events)
        let request = CondensationRequestMeta(
            reason: .overflow, requestedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        try? await deps.writer.append(.extensionEvent(
            kind: CondensationEvents.requestKind, payload: request.payload))
        let appendClosure: (SessionEvent.Payload, Bool) async throws -> Void = {
            [writer = deps.writer] payload, ignorable in
            try await writer.append(payload, ignorable: ignorable)
        }
        let condensed = await deps.compactor.condensePendingRequest(
            events: deps.writer.events,
            model: deps.writer.recordedRequestHeader?.config.model,
            append: appendClosure)
        let tokensAfter = Compactor.estimateSession(deps.writer.events)
        guard condensed, tokensAfter < tokensBefore else {
            throw LLMError(
                message: "context overflow recovery failed: working set did not shrink "
                    + "(before \(tokensBefore), after \(tokensAfter), condensed=\(condensed))",
                code: "CONTEXT_OVERFLOW_NOTHING_TO_COMPACT")
        }
        Self.logger.info("catch-condense-retry: working set \(tokensBefore)→\(tokensAfter), "
            + "retrying step once")
        return try await runStep(turn: turn, step: step)
    }

    /// 溢出/历史畸形判定（sdk LLMContextWindowExceedError +
    /// LLMMalformedConversationHistoryError 的 WanWo 等价——WanWo 错误码面：
    /// CONTEXT_WINDOW_EXCEEDED 直判；历史畸形 = provider 400 的 tool 配对类
    /// 抱怨，保守白名单匹配，登记）。
    nonisolated static func isContextOverflowLike(_ error: Error) -> Bool {
        guard let llmError = error as? LLMError else { return false }
        if llmError.code == "CONTEXT_WINDOW_EXCEEDED" { return true }
        if llmError.code == "INVALID_REQUEST" {
            let message = llmError.message.lowercased()
            let historyPatterns = ["messages with role 'tool'", "tool_calls",
                                   "tool call id", "preceding message",
                                   "tool message must follow"]
            return historyPatterns.contains { message.contains($0) }
        }
        return false
    }

    // MARK: - 一步（dsh step()：模型请求 + 工具执行）

    private func runStep(turn: Int, step: Int) async throws -> StepOutcome {
        let adapter = try await deps.makeAdapter()

        // M4-C2 组装步（codex spec_plan.rs:371-406 finalize_tool_router 的
        // tool_search 注册面同构）：存在 deferred 工具 ⇒ 注册/刷新 tool_search；
        // 零 deferred ⇒ 注销（幂等；MCP 工具世代换手后由此收敛注册态，逐步
        // 执行对齐 codex per-turn finalize 的 WanWo 等价）。
        deps.toolSearchAssembly?.refresh()

        // M4-D D2：技能装载快照组装期刷新（失效三通道①——C2 ToolSearchAssembly
        // 同位模式：脏才重扫，幂等低成本；消费面 D4 目录注入接线）。
        deps.skillRegistry?.refresh()

        // M4-D D4：技能目录注入（渐进一级，dsh skills.md:229-235）——组装期从
        // 派生视角取基线（DeriveFold 产物最后一个含 <available_skills> 的
        // user/message；影子化=基线丢失→快照自动重建），与当前快照渲染文本
        // 全等对比；变化即追加全量替换 user/message（append-only，model-visible
        // =logged；R2 零新事件词汇）。无状态投影：基线每步重导，零 AgentLoop 态。
        // 注入失败不抛穿（fail open 记日志——目录缺失下一快照周期重建，R5 同族）。
        if let skillRegistry = deps.skillRegistry,
           let pending = SkillCatalogInjector.project(
            snapshot: skillRegistry.snapshot(), events: deps.writer.events) {
            do {
                try await deps.writer.append(.userMessage(text: pending))
            } catch {
                Self.logger.error("skill catalog injection failed: "
                                  + "\(String(describing: error))")
            }
        }

        // M4-D D6：显式触发（$name 提及 → 正文注入）——派生面真用户消息逐条
        // 提取（mentions.rs 逐式：链接形态+裸名+env 排除）→ snapshot 精确匹配
        // （重名/不存在跳过=歧义保护）→ 位置去重（派生面已有 <skill name="X">
        // 且晚于该消息则跳过——无状态幂等，每步全量重扫与 D4 同模式）。注入
        // 消息 user/message（R2 零新词汇）+ 投影层 `<skill ` 前缀过滤不渲染。
        // user-only 技能显式提及照常注入（用户调用通道，dsh 四象限语义）。
        // fail open：追加失败记日志不抛穿（下一快照周期重扫重建）。
        if let skillRegistry = deps.skillRegistry,
           let mentionInjection = SkillMentionInjector.project(
            snapshot: skillRegistry.snapshot(), events: deps.writer.events) {
            do {
                try await deps.writer.append(.userMessage(text: mentionInjection))
            } catch {
                Self.logger.error("skill mention injection failed: "
                                  + "\(String(describing: error))")
            }
        }

        // prompt 组装（严格插值；组装失败按回合错误处理）。
        var assembly: (system: String, contextSnapshot: String, tools: [ToolSchemaEntry])
        do {
            assembly = try deps.assembler.assemble(
                toolSchemas: deps.registry.schemas(),
                // M4-C6：toolOrder 校验名集 = registry.knownNames 全集（含
                // deferred/hidden）——收窄集会把 toolOrder 合法列出的 MCP
                // deferred 工具名误判为未注册（fatalError 回归防线）。
                knownNames: deps.registry.knownNames)
        } catch {
            throw LLMError(message: String(describing: error), code: "PROMPT_ASSEMBLY")
        }

        // M4-C5 激活面（codex models.rs:845/:1060/:1136 协议项的 chat completions
        // 等价——gap11 §八.2）：tool_search 命中 spec 注入下一请求 tools 数组。
        // 推导纯函数消费 writer.events（JSONL replay 快照）⇒ resume 免费恢复
        // （零新存储零新事件词汇，R2）；注入 = Direct 集原样 + 激活集尾部首见序
        // append-only（拍板项 5）；model-visible=logged：注入内容全部来源于已
        // 落盘的 tool/result ✓。
        assembly.tools = ToolSearchActivation.inject(into: assembly.tools,
                                                     events: deps.writer.events)

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
            // M7Fix：citation 剥离缝应用（MemoryCitations 生产接线缝——只缝
            // 不接线）。缝返回与原文不同 = 剥离后文本落盘；nil 缝 = 原样
            // （见 Dependencies.onAssistantMessageSealed 注）。
            let sealed = await Self.applyAssistantSeal(
                deps.onAssistantMessageSealed, blocks: persistable,
                sessionId: deps.sessionId, turn: turn, step: step)
            let message = AssistantMessage(id: UUID().uuidString,
                                           provider: adapter.providerName,
                                           model: adapter.endpoint.model,
                                           content: sealed)
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

        activeToolBatch = (turn, step)
        defer { activeToolBatch = nil }
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
            // 批C7：在途前缀账（dsh assembler.interruptedBlocks 语义）——blockEnd
            // 仅在 [DONE] 收尾批发射，中断落在流中段时 blocks 恒空，屏面已渲染
            // 的思考/文字前缀必须由 delta 增量合成落盘。tool-call 在途不合成
            // （不完整调用进派生历史会破坏请求语义）；重试新 attempt 开新账。
            var inFlightText: [Int: String] = [:]
            var inFlightReasoning: [Int: String] = [:]
            do {
                let stream = adapter.stream(request)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    // model-visible=logged：每块先落盘再驱动 UI。
                    try await writer.append(.assistantChunk(turn: turn, step: step, chunk: chunk))
                    deps.callbacks.onLiveChunk(chunk)
                    switch chunk {
                    case .blockEnd(let index, let block):
                        blocks.append(block)
                        // 批C7：块闭合 → 移出在途账（防 [DONE] 后合并重复计）。
                        inFlightText.removeValue(forKey: index)
                        inFlightReasoning.removeValue(forKey: index)
                    case .textDelta(let index, let text):
                        inFlightText[index, default: ""] += text
                    case .reasoningDelta(let index, let text):
                        inFlightReasoning[index, default: ""] += text
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
                                                    blocks: blocks,
                                                    inFlightText: inFlightText,
                                                    inFlightReasoning: inFlightReasoning,
                                                    usage: usage)
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
                                                blocks: blocks,
                                                inFlightText: inFlightText,
                                                inFlightReasoning: inFlightReasoning,
                                                usage: usage)
                throw CancellationError()
            }
            return (blocks, usage, finish)
        }
    }

    /// 已交付前缀的 interrupted finalize（dsh step() catch aborted 分支）。
    /// 批C7：落盘内容 = 已闭合块 + 在途前缀（text/reasoning delta 合成，index
    /// 序）——「屏面已有的所有内容块」不蒸发（思考期中断病根：blockEnd 只在
    /// [DONE] 批发射，旧实现流中段中断恒空 blocks=零落盘）。persistableBlocks
    /// 既有判定承担全空过滤（ERR-023：空消息不落盘）。append 失败静默（取消
    /// 路径不掩盖 CancellationError 本身）。
    private func finalizeInterruptedPrefix(writer: SessionWriter,
                                           adapter: OpenAICompatAdapter,
                                           turn: Int, step: Int,
                                           blocks: [ContentBlock],
                                           inFlightText: [Int: String],
                                           inFlightReasoning: [Int: String],
                                           usage: TokenUsage?) async {
        let inFlight: [ContentBlock] = (
            inFlightReasoning.map { ($0.key, ContentBlock.reasoning($0.value)) }
            + inFlightText.map { ($0.key, ContentBlock.text($0.value)) }
        )
        .sorted { $0.0 < $1.0 }
        .map { $0.1 }
        let persistable = (blocks + inFlight).persistableBlocks
        guard !persistable.isEmpty else { return }
        let message = AssistantMessage(id: UUID().uuidString,
                                       provider: adapter.providerName,
                                       model: adapter.endpoint.model,
                                       content: persistable)
        try? await writer.append(.assistantMessage(
            turn: turn, step: step, message: message, usage: usage, interrupted: true))
    }

    // MARK: - assistant 落盘 citation 剥离缝（M7Fix · 只缝不接线）

    /// 应用 onAssistantMessageSealed 缝（runStep 落盘前唯一调用点 + 单测面）。
    /// 变换规则：text 块按 \n 合并为"落盘前正文"过缝；返回与原文不同 → 以
    /// 单一 text 块（剥离后文本）原位替换全部 text 块；reasoning/toolCall
    /// 块原样保留（citation 只作用于可见正文——codex citations.rs 语义）。
    /// 缝为 nil 或返回原文 → blocks 原样返回（零扰动）。
    nonisolated static func applyAssistantSeal(
        _ seal: (@Sendable (String, String, Int, Int) async -> String)?,
        blocks: [ContentBlock],
        sessionId: String, turn: Int, step: Int) async -> [ContentBlock] {
        guard let seal else { return blocks }
        let joined = blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
        guard !joined.isEmpty else { return blocks }
        let stripped = await seal(joined, sessionId, turn, step)
        guard stripped != joined else { return blocks }
        var sealed: [ContentBlock] = []
        var replaced = false
        for block in blocks {
            if case .text = block {
                if !replaced {
                    sealed.append(.text(stripped))
                    replaced = true
                }
            } else {
                sealed.append(block)
            }
        }
        return sealed
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

    nonisolated static func workspaceAccess(sessionId: String,
                                            cwd: String? = nil) -> WorkspaceFileAccess {
        WorkspaceFileAccess(sessionId: sessionId, workspaceCwd: cwd)
    }
}
