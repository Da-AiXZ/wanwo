//
//  GoalService.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 B · F006】出处（packages/goal/goal/src/index.ts 全文对拍）：
//    - :172-181      —— Config.defaultMaxGoalRounds 缺省 256。
//    - :199-237      —— resolveMaxGoalRounds / resolveObjective / resolveBlockReason。
//    - :301-317      —— create（仅可替换 complete 旧 goal；armed）。
//    - :327-341      —— edit（至少一个替换字段；保 activation）。
//    - :349-422      —— pause/resume/complete/block 转移矩阵 1:1。
//    - :430-445      —— clear（墓碑 revision+1；clearedAt = max(now, updatedAt)）。
//    - :454-464      —— expectCurrent CAS（nil→GOAL_NOT_FOUND；不匹配→GOAL_STALE_REVISION）。
//    - :584-602      —— commit 的 activation 原子栅栏（pendingActivation{offset}；
//      append 返回 seq==offset 才落 activation，否则回 disarmed）。
//    - :255-267      —— session-start 恒 disarmed（万我：服务实例随会话栈创建，
//      初始 disarmed；resume 即新实例=disarmed——语义等价，登记）。
//  万我形态：
//    - actor 串行化 = dsh 单服务实例方法串行；持久态唯一事实源 = writer.events
//      （GoalFold 每读重算——万我无常驻 projection registry，R2 同族，登记）。
//    - 'goal/changed' cordis 事件 → 进程内 onChange 回调（已定适配①）；
//      listener 失败由调用方 Task 隔离（回调内抛错不外泄）。
//    - authority（tool-goal authority.ts）：dsh 读开放 turn 事件流判 direct
//      human / goal round；万我 user/message 载荷冻结无 source → AgentLoop 在
//      claim/admit 时同步登记 TurnProvenance（进程内，等价 dsh 的进程内
//      agents registry 活性判定；登记）。
//

import Foundation

/// 'goal/changed' listener 锁盒（QA-2 P0-1：nonisolated 计算属性的线程安全
/// 存储——NSLock 自保护，@unchecked Sendable）。
private final class OnChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (GoalChanged) -> Void)?
    var value: (@Sendable (GoalChanged) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// goal 域服务（dsh GoalService 1:1；每会话一实例——AppEnvironment.makeAgentStack 装配）。
actor GoalService {
    /// 进程本地 activation 状态（index.ts:183-190 GoalRuntimeState 1:1）。
    private var activation: GoalActivation = .disarmed
    private var pendingActivation: (expectedSeq: Int, activation: GoalActivation)?

    /// 工具面 authority 供给（authority.ts open-turn 事件判定的进程内等价）。
    struct TurnProvenance: Equatable, Sendable {
        var turn: Int
        var directHuman: Bool
        var goalRound: GoalRef.Round?
    }
    private var turnProvenance: TurnProvenance?
    /// 本会话是否顶层 agent（dsh roots().includes 检查等价；子 agent 会话 false）。
    private let isTopLevel: Bool

    private nonisolated static let logger = AppLogger(category: "goal")

    let writer: SessionWriter
    let defaultMaxGoalRounds: Int

    /// 'goal/changed' 通知（index.ts:601 agentEvents emit 等价；装配期由
    /// makeAgentStack 接线到 AgentLoop.onGoalChanged）。listener 失败不外泄。
    /// QA-2 P0-1：Swift 5.9 禁 nonisolated 存储属性——锁盒承载 + nonisolated
    /// 计算属性（装配侧写 / commit 侧读均跨线程安全）。
    private nonisolated let onChangeBox = OnChangeBox()
    nonisolated var onChange: (@Sendable (GoalChanged) -> Void)? {
        get { onChangeBox.value }
        set { onChangeBox.value = newValue }
    }

    /// 畸形 goal 历史的软失败（index.ts:137-159 applyGoalProjection 的
    /// state.failure 语义：首个非法事件保留；宿主访问拒绝，客户端视图停在
    /// 最后合法 goal）。
    private var failure: String?

    init(writer: SessionWriter,
         defaultMaxGoalRounds: Int = GoalDomain.defaultMaxGoalRounds,
         isTopLevel: Bool = true) {
        self.writer = writer
        self.defaultMaxGoalRounds = defaultMaxGoalRounds
        self.isTopLevel = isTopLevel
    }

    // MARK: - 读取（index.ts:275-278 get + :473-479 state）

    /// 当前持久投影（严格折叠；软失败保留在 failure）。
    private func projection() throws -> (snapshot: GoalSnapshot, roundsStarted: Int,
                                         createdAt: Int64, updatedAt: Int64)? {
        if let failure {
            throw GoalError(message: failure, code: .goalInvalidTransition)
        }
        do {
            let folded = try GoalFold.foldGoal(writer.events)
            guard let goal = folded.goal,
                  let createdAt = folded.createdAt, let updatedAt = folded.updatedAt else {
                return nil
            }
            return (goal, folded.roundsStarted, createdAt, updatedAt)
        } catch {
            // 软捕获：首个非法事件保留进 failure（replay 不断流——index.ts:146-159）。
            if failure == nil { failure = error.localizedDescription }
            throw error
        }
    }

    /// 构建活性视图（index.ts:604-614 view 1:1：durable + roundsStarted +
    /// timestamps + 进程本地 activation）。
    private func view(_ projection: (snapshot: GoalSnapshot, roundsStarted: Int,
                                     createdAt: Int64, updatedAt: Int64)) -> GoalView {
        let s = projection.snapshot
        return GoalView(id: s.id, revision: s.revision, objective: s.objective,
                        phase: s.phase, blockedReason: s.blockedReason,
                        maxGoalRounds: s.maxGoalRounds,
                        roundsStarted: projection.roundsStarted,
                        createdAt: projection.createdAt,
                        updatedAt: projection.updatedAt,
                        activation: activation)
    }

    /// Read the current goal（index.ts:275-278 get 1:1）；无 goal 返回 nil。
    func get() throws -> GoalView? {
        guard let projection = try projection() else { return nil }
        return view(projection)
    }

    /// Remove process-local continuation authority without changing durable
    /// phase or revision（index.ts:287-292 disarm 1:1）。
    func disarm() -> GoalView? {
        activation = .disarmed
        guard let projection = try? projection() else { return nil }
        return view(projection)
    }

    // MARK: - 装配缝（AgentLoop claim/admit 与回合收尾调用）

    /// 登记本回合的输入来源（authority.ts open-turn 事件判定的进程内等价；
    /// AgentLoop 在 claim/admit 后调用）。QA-2 P0-3 复验打回的合并语义：
    ///   ① 同回合合并——step0 claim（用户输入，directHuman=true）后 step1
    ///     claim（工具结果步，injected 通常为空 → directHuman=false）不得抹掉
    ///     人类权威；goalRound 非空才更新（dsh 权威覆盖整个开放 turn）。
    ///   ② stale 跨回合守卫（防御 fence 失效的残留，与合并叠加）——旧回合
    ///     provenance 不得成为新回合权威证据。
    func noteTurnProvenance(turn: Int, directHuman: Bool, goalRound: GoalRef.Round?) {
        if let existing = turnProvenance, existing.turn == turn {
            // 同回合合并：人类权威一旦建立不因后续空 claim 丢失。
            turnProvenance = TurnProvenance(
                turn: turn,
                directHuman: existing.directHuman || directHuman,
                goalRound: goalRound ?? existing.goalRound)
            return
        }
        if turnProvenance != nil, writer.openTurn == turn {
            Self.logger.warning("goal provenance: stale turn record rejected for turn \(turn)")
            return
        }
        turnProvenance = TurnProvenance(turn: turn, directHuman: directHuman, goalRound: goalRound)
    }

    /// 回合收尾清账（AgentLoop turnEnd fence 调用）。
    func clearTurnProvenance() {
        turnProvenance = nil
    }

    // MARK: - 变更（index.ts:301-445 1:1）

    /// Create and arm a goal（index.ts:301-317）。
    func create(objective: String, maxGoalRounds: Int? = nil,
                origin: GoalMutationOrigin = .host) async throws -> GoalView {
        let spec = try Self.resolveCreateGoal(objective: objective,
                                              maxGoalRounds: maxGoalRounds,
                                              defaultMaxGoalRounds: defaultMaxGoalRounds)
        let current = try projection()
        if let current, current.snapshot.phase != .complete {
            throw GoalError(
                message: "goal \"\(current.snapshot.id)\" already exists with phase \"\(current.snapshot.phase.rawValue)\"",
                code: .goalAlreadyExists)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let goal = GoalSnapshot(id: "goal-\(UUID().uuidString)", revision: 1,
                                objective: spec.objective, phase: .active,
                                blockedReason: nil, maxGoalRounds: spec.maxGoalRounds)
        return try await commitSnapshot(.create, goal: goal, roundsStarted: 0,
                                  createdAt: now, updatedAt: now,
                                  activation: .armed, origin: origin)
    }

    /// Edit objective and/or round cap without changing phase（index.ts:327-341）。
    func edit(ref: GoalRef, objective: String?, maxGoalRounds: Int?,
              origin: GoalMutationOrigin = .host) async throws -> GoalView {
        let currentState = try expectCurrent(ref)
        if objective == nil && maxGoalRounds == nil {
            throw GoalError(message: "goal edit requires objective and/or maxGoalRounds",
                            code: .goalInvalidEdit)
        }
        let current = currentState.snapshot
        var resolvedObjective = current.objective
        if let objective { resolvedObjective = try Self.resolveObjective(objective) }
        var resolvedMaxGoalRounds = current.maxGoalRounds
        if let maxGoalRounds { resolvedMaxGoalRounds = try Self.resolveMaxGoalRounds(maxGoalRounds) }
        let goal = GoalSnapshot(
            id: current.id, revision: current.revision + 1,
            objective: resolvedObjective, phase: current.phase,
            blockedReason: current.blockedReason, maxGoalRounds: resolvedMaxGoalRounds)
        return try await commitCurrent(.edit, currentState: currentState, goal: goal,
                                 activation: activation, origin: origin)
    }

    /// Pause an active goal and disarm automatic continuation（index.ts:349-352）。
    func pause(ref: GoalRef, origin: GoalMutationOrigin = .host) async throws -> GoalView {
        try await transition(ref, .pause, allowed: [.active], phase: .paused,
                             activation: .disarmed, origin: origin)
    }

    /// Resume and arm a stopped goal（index.ts:361-380 1:1：resumable 三相/
    /// active+armed 拒绝/roundsStarted ≥ max 拒绝）。
    func resume(ref: GoalRef, origin: GoalMutationOrigin = .host) async throws -> GoalView {
        let currentState = try expectCurrent(ref)
        let current = currentState.snapshot
        let resumable: Set<GoalPhase> = [.active, .paused, .blocked]
        if !resumable.contains(current.phase) {
            throw Self.transitionError(current, .resume, resumable)
        }
        if current.phase == .active && activation == .armed {
            throw GoalError(message: "goal \"\(current.id)\" is already active and armed",
                            code: .goalInvalidTransition)
        }
        if currentState.roundsStarted >= current.maxGoalRounds {
            throw GoalError(
                message: "goal \"\(current.id)\" exhausted \(current.maxGoalRounds) goal rounds; "
                    + "increase maxGoalRounds before resuming",
                code: .goalInvalidTransition)
        }
        return try await commitCurrent(.resume, currentState: currentState,
                                 goal: Self.withPhase(current, .active),
                                 activation: .armed, origin: origin)
    }

    /// Mark a current non-complete goal complete and disarm it（index.ts:388-398）。
    func complete(ref: GoalRef, origin: GoalMutationOrigin = .host) async throws -> GoalView {
        try await transition(ref, .complete, allowed: [.active, .paused, .blocked],
                             phase: .complete, activation: .disarmed, origin: origin)
    }

    /// Mark an active goal blocked and disarm it（index.ts:407-422）。
    func block(ref: GoalRef, reason: GoalBlockReason,
               origin: GoalMutationOrigin = .host) async throws -> GoalView {
        let currentState = try expectCurrent(ref)
        let current = currentState.snapshot
        if current.phase != .active {
            throw Self.transitionError(current, .block, [.active])
        }
        return try await commitCurrent(.block, currentState: currentState,
                                 goal: Self.withPhase(current, .blocked,
                                                      blockedReason: try Self.resolveBlockReason(reason)),
                                 activation: .disarmed, origin: origin)
    }

    /// Clear the current goal while retaining a durable tombstone（index.ts:430-445）。
    func clear(ref: GoalRef, origin: GoalMutationOrigin = .host) async throws -> GoalRef {
        let currentState = try expectCurrent(ref)
        let current = currentState.snapshot
        let tombstone = GoalRef(id: current.id, revision: current.revision + 1)
        let change = GoalChangeMeta.clear(GoalClearChange(
            cleared: tombstone, clearedAt: nextMutationTime(currentState.updatedAt)))
        try await commit(change, activation: .disarmed, origin: origin)
        return tombstone
    }

    // MARK: - authority（tool-goal authority.ts 1:1）

    /// GoalToolAuthority（authority.ts:19-21）。
    enum GoalToolAuthority: Sendable {
        case directHuman
        case goalRound(GoalView)
    }

    /// requireDirectHuman（authority.ts:99-102 1:1：root agent + 开放回合内
    /// 的直接人类输入；万我单宿主 root=非子 agent 会话）。
    func requireDirectHumanAuthority(turn: Int) throws {
        guard isTopLevel else {
            throw GoalToolError(
                message: "this goal operation requires a direct human turn on a top-level agent",
                code: "GOAL_TOOL_AUTHORITY_REQUIRED")
        }
        guard writer.openTurn == turn, let provenance = turnProvenance,
              provenance.turn == turn, provenance.directHuman else {
            throw GoalToolError(
                message: "this goal operation requires a direct human turn on a top-level agent",
                code: "GOAL_TOOL_AUTHORITY_REQUIRED")
        }
    }

    /// completionAuthority（authority.ts:110-117 1:1：直接人类输入或精确已准入轮次）。
    func completionAuthority(turn: Int) throws -> GoalToolAuthority {
        if writer.openTurn == turn, let provenance = turnProvenance,
           provenance.turn == turn, provenance.directHuman {
            return .directHuman
        }
        guard let projection = try projection() else {
            throw GoalToolError(
                message: "complete and blocked require a direct human turn or the current goal round",
                code: "GOAL_TOOL_AUTHORITY_REQUIRED")
        }
        let current = view(projection)
        if writer.openTurn == turn, let provenance = turnProvenance,
           provenance.turn == turn, let round = provenance.goalRound,
           round.goalId == current.id, round.revision == current.revision,
           round.round == current.roundsStarted {
            return .goalRound(current)
        }
        throw GoalToolError(
            message: "complete and blocked require a direct human turn or the current goal round",
            code: "GOAL_TOOL_AUTHORITY_REQUIRED")
    }

    // MARK: - 私有（index.ts:447-602 1:1）

    /// Reject stale or missing current-state refs（index.ts:454-464）。
    private struct CurrentProjection {
        var snapshot: GoalSnapshot
        var roundsStarted: Int
        var createdAt: Int64
        var updatedAt: Int64
    }

    private func expectCurrent(_ ref: GoalRef) throws -> CurrentProjection {
        guard let projection = try projection() else {
            throw GoalError(message: "no current goal", code: .goalNotFound)
        }
        let current = projection.snapshot
        if ref.id != current.id || ref.revision != current.revision {
            throw GoalError(
                message: "stale goal ref \"\(ref.id)\" revision \(ref.revision); "
                    + "current is \"\(current.id)\" revision \(current.revision)",
                code: .goalStaleRevision)
        }
        return CurrentProjection(snapshot: current, roundsStarted: projection.roundsStarted,
                                 createdAt: projection.createdAt, updatedAt: projection.updatedAt)
    }

    /// Shared validated phase transition（index.ts:505-518）。QA-2 P0-2：
    /// commitCurrent 为 async——本函数同链 async throws（原签名 sync throws
    /// 内 try await 编译错误）。
    private func transition(_ ref: GoalRef, _ operation: GoalOperation,
                            allowed: Set<GoalPhase>, phase: GoalPhase,
                            activation newActivation: GoalActivation,
                            origin: GoalMutationOrigin) async throws -> GoalView {
        let currentState = try expectCurrent(ref)
        let current = currentState.snapshot
        if !allowed.contains(current.phase) {
            throw Self.transitionError(current, operation, allowed)
        }
        return try await commitCurrent(operation, currentState: currentState,
                                 goal: Self.withPhase(current, phase),
                                 activation: newActivation, origin: origin)
    }

    private static func transitionError(_ current: GoalSnapshot, _ operation: GoalOperation,
                                        _ allowed: Set<GoalPhase>) -> GoalError {
        let names = allowed.map(\.rawValue).sorted().joined(separator: " or ")
        return GoalError(
            message: "cannot \(operation.rawValue) goal \"\(current.id)\" from phase \"\(current.phase.rawValue)\"; expected \(names)",
            code: .goalInvalidTransition)
    }

    /// Build a new revision with one replacement phase（index.ts:494-502）。
    private static func withPhase(_ current: GoalSnapshot, _ phase: GoalPhase,
                                  blockedReason: GoalBlockReason? = nil) -> GoalSnapshot {
        GoalSnapshot(id: current.id, revision: current.revision + 1,
                     objective: current.objective, phase: phase,
                     blockedReason: blockedReason ?? (phase == .blocked ? current.blockedReason : nil),
                     maxGoalRounds: current.maxGoalRounds)
    }

    /// Commit a mutation that retains the current goal's derived counters/times
    ///（index.ts:529-547）。
    private func commitCurrent(_ operation: GoalOperation,
                               currentState: CurrentProjection,
                               goal: GoalSnapshot,
                               activation newActivation: GoalActivation,
                               origin: GoalMutationOrigin) async throws -> GoalView {
        try await commitSnapshot(operation, goal: goal, roundsStarted: currentState.roundsStarted,
                           createdAt: currentState.createdAt,
                           updatedAt: nextMutationTime(currentState.updatedAt),
                           activation: newActivation, origin: origin)
    }

    /// Clamp a current goal's next timestamp across backward wall-clock movement
    ///（index.ts:550-552）。
    private func nextMutationTime(_ previousUpdatedAt: Int64) -> Int64 {
        max(Int64(Date().timeIntervalSince1970 * 1000), previousUpdatedAt)
    }

    /// Build and commit one full-snapshot mutation（index.ts:555-582）。
    private func commitSnapshot(_ operation: GoalOperation,
                                goal: GoalSnapshot,
                                roundsStarted: Int,
                                createdAt: Int64,
                                updatedAt: Int64,
                                activation newActivation: GoalActivation,
                                origin: GoalMutationOrigin) async throws -> GoalView {
        let change = GoalChangeMeta.snapshot(GoalSnapshotChange(
            operation: operation, goal: goal, roundsStarted: roundsStarted,
            createdAt: createdAt, updatedAt: updatedAt))
        try await commit(change, activation: newActivation, origin: origin)
        return GoalView(id: goal.id, revision: goal.revision, objective: goal.objective,
                        phase: goal.phase, blockedReason: goal.blockedReason,
                        maxGoalRounds: goal.maxGoalRounds, roundsStarted: roundsStarted,
                        createdAt: createdAt, updatedAt: updatedAt, activation: activation)
    }

    /// Commit one mutation into the goal log and live event stream
    ///（index.ts:585-602 commit 1:1——activation 原子栅栏）。
    private func commit(_ change: GoalChangeMeta,
                        activation newActivation: GoalActivation,
                        origin: GoalMutationOrigin) async throws {
        let ref = GoalCodec.ref(of: change)
        let expectedSeq = writer.eventCount
        pendingActivation = (expectedSeq, newActivation)
        defer { pendingActivation = nil }
        let event = try await writer.append(.extensionEvent(
            kind: GoalEvents.changeKind, payload: GoalCodec.encode(change)))
        // 栅栏：append 返回 seq == 预期 offset 才落 activation，否则回 disarmed
        //（并发写入插队的保守兜底——index.ts:591 同语义）。
        if event.seq == expectedSeq {
            activation = newActivation
        } else {
            activation = .disarmed
        }
        // 通知（index.ts:596-601 'goal/changed' 等价；listener 失败不外泄——
        // 回调体自身承载线程纪律，装配侧 Task 隔离）。
        let projection = try? projection()
        let current = projection.map { view($0) }
        let notification = GoalChanged(operation: change.operation, ref: ref,
                                       goal: current, origin: origin)
        onChange?(notification)
    }

    // MARK: - 入参校验（index.ts:199-237 1:1）

    static func resolveMaxGoalRounds(_ value: Int) throws -> Int {
        guard value >= 1 else {
            throw GoalError(message: "maxGoalRounds must be a positive safe integer",
                            code: .goalInvalidMaxRounds)
        }
        return value
    }

    static func resolveObjective(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GoalError(message: "goal objective must be a non-empty string",
                            code: .goalInvalidObjective)
        }
        return trimmed
    }

    private static func resolveCreateGoal(objective: String, maxGoalRounds: Int?,
                                          defaultMaxGoalRounds: Int) throws -> (objective: String, maxGoalRounds: Int) {
        let resolvedObjective = try resolveObjective(objective)
        let rounds = try resolveMaxGoalRounds(maxGoalRounds ?? defaultMaxGoalRounds)
        return (resolvedObjective, rounds)
    }

    /// Validate and detach one policy-owned blocker explanation（index.ts:223-237）。
    /// QA-2 顺带：非法 reason 补 throw（GOAL_INVALID_BLOCK_REASON）——原实现
    /// guard 分支注释 fail loud 却静默返回原值。
    static func resolveBlockReason(_ reason: GoalBlockReason) throws -> GoalBlockReason {
        let code = reason.code
        let valid = code.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
        let message = reason.message.trimmingCharacters(in: .whitespaces)
        guard valid, !message.isEmpty else {
            throw GoalError(
                message: "blocked reason must carry a kebab-case code and a non-empty message",
                code: .goalInvalidBlockReason)
        }
        return GoalBlockReason(code: code, message: message)
    }
}

// MARK: - 回合续跑提示词（goal-round-driver prompt.ts 全文 1:1）

/// Model-visible continuation prompt for one same-session goal round。
enum GoalRoundPrompt {
    /// renderGoalRoundPrompt（prompt.ts:12-26 逐字；objective JSON.stringify 等价）。
    static func render(goal: GoalView, round: Int) -> String {
        let objectiveJSON = (try? JSONEncoder().encode(goal.objective))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(goal.objective)\""
        return "<goal_round>\n"
            + "Objective: \(objectiveJSON)\n"
            + "Round: \(round)/\(goal.maxGoalRounds)\n\n"
            + "Continue working toward the objective in this same session. Treat the current workspace, "
            + "tool results, and durable session state as authoritative; inspect them instead of assuming "
            + "earlier narration is still current. Make concrete progress and verify the result. Before "
            + "claiming completion, gather evidence that the whole objective is achieved, read the current "
            + "goal, and mark it complete. If work remains, leave the goal active for the next round. Follow "
            + "the configured goal-tool policy before reporting a blocker.\n"
            + "</goal_round>"
    }
}

// MARK: - 收尾指令（tool-goal wrapup.ts 全文 1:1）

/// Model-visible wrap-up instruction for a terminal autonomous goal update。
enum GoalWrapup {
    private static let grounding = "Report only what earlier rounds and tool results in this session actually establish; "
        + "when a detail is not in the session, say so instead of inventing it. "

    /// renderWrapupContext（wrapup.ts:17-41 逐字；WanWo 经 AgentLoop.inject
    /// 注入下一步——dsh deferContext 的下一步等价承载，登记）。
    static func render(objective: String, blockedReason: String? = nil) -> String {
        let objectiveJSON = (try? JSONEncoder().encode(objective))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(objective)\""
        let heading = "Objective: \(objectiveJSON)\n"
        if let blockedReason {
            let reasonJSON = (try? JSONEncoder().encode(blockedReason))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(blockedReason)\""
            return "<goal_blocked>\n"
                + heading
                + "Blocked: \(reasonJSON)\n"
                + "The goal is marked blocked and this autonomous run is ending. Write the closing "
                + "message to the user now: state what has been completed so far, describe the concrete "
                + "blocking condition and what you tried, and say exactly what you need from the user to "
                + "continue. "
                + grounding
                + "Address the user directly. Do not call any more tools in this run; further work "
                + "waits for the user's next instruction.\n"
                + "</goal_blocked>"
        }
        return "<goal_complete>\n"
            + heading
            + "The goal is marked complete and this autonomous run is ending. Write the closing "
            + "message to the user now: state the outcome, summarize what was done and how it was "
            + "verified, and point to the concrete results (files, commits, or other artifacts). "
            + grounding
            + "Note anything the user should review or do next. Address the user directly. Do not "
            + "call any more tools in this run; further work waits for the user's next instruction.\n"
            + "</goal_complete>"
    }
}
