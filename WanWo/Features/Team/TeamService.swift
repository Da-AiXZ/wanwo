//
//  TeamService.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 L · F046】出处（experimental/agent-team/src/ 全家 +
//  experimental/tool-agent-team/src/index.ts，逐文件实读本体）：
//    - index.ts TeamService façade（membership/spawnTeammate/sendMessage/
//      createTask/getTask/listTasks/updateTask/waitForChange/interrupt/
//      tryMembership）逐方法 1:1。
//    - journal.ts —— TeamJournal transact（per-Lead promise tail 串行化）+
//      appendAndFlush（append+落盘确认+onCommit 通知）1:1；state() failure
//      面同源。万我 per-root tail → tails dict（Task 链）承载。
//    - roster.ts —— spawn 状态机（provisioning→active|failed）、
//      tryMembership（roster.ts:92-122：header 父子关系+roster 判定，
//      provider-owned 普通 subagent 排除）、memberName 校验、interrupt
//      （Lead 专用+目标非自身）、reconcileProvisioning（:392-434 持久判活）
//      1:1。
//    - mailbox.ts —— send（queued 先持久→三分支投递→delivered 幂等回写）、
//      pending<64 帽、65536B 帽、target-local FIFO 串行派发
//      （serializeDispatch/dispatchThrough 1:1）、deliveryContent 框架行、
//      persistedTargetRecorded（inactive 目标持久回读）逐语义。
//    - task-board.ts —— create/get/list/update（CAS expectedRevision +
//      七 action 授权与转移矩阵）+ taskView（ownerName/ready/
//      writeScopeWarnings）1:1。
//    - activity.ts —— TeamActivity 一次性 waiter（notify 全唤醒/超时
//      timedOut）1:1。
//  已定适配（主理人判定，勿再议）：
//    ①四事件走 extensionEvent（wire version 2 形态照 types.ts:218-234）。
//    ②投递通道三分支：target=Lead→批1 steer 语义缝；teammate 活跃→批1
//      SubagentRuntime.sendMessage 公开缝；inactive→缝内惰性冷恢复后投递；
//      delivered=目标会话记录回读确认（防谎报，幂等去重）。
//    ③per-member 工具面经批2 makeAgentStack toolFilter/teamScope 承载。
//    ④不引入 experimental 标记机制。
//  万我适配（登记）：
//    - dsh durable MessageSource('team-message') → 万我 userMessage 词汇
//      冻结，投递确认以 deliveryContent 框架行内容指纹承载（messageId 唯一
//      ——team-message-<uuid>）。
//    - InboxSource 增 `.teamMessage(senderId:)` case 由主理人合并统一加；
//      当前 lead 分支以 `.subagentMessage(childId:)` 过渡承载（非 directHuman
//      语义等价）——见 leadSteer 装配闭包。
//    - SubagentRuntime.sendMessage 内部 followup 恒 .user（冻结件）——
//      队友分支 directHuman authority 语义差，所需缝：sendMessage 增 source
//      参数（报告呈报）。
//    - WanWo childId 由 SubagentRuntime.startContinuable 分配（dsh 由 roster
//      预生成）→ spawn 顺序 = startContinuable → journal provisioning →
//      checkpoint 初始 prompt → active（dsh = journal → start → checkpoint →
//      active）；startContinuable 失败 = 无 journal 足迹（dsh failed 快照面
//      由简化承接——登记）。
//    - checkpointInitialPrompt 的 messageId 关联 → 初始 prompt userMessage
//      前缀口径轮询（QA-6 P0-1 hasPrefix——有界 10s；超时留守 provisioning——
//      重启 reconcile 同口径承接）。
//    - 投递确认轮询 250ms×有界（dsh session/event 观察缝万我无对应——登记）。
//    - waitForChange 唤醒面 = Team journal commit（member/task/queued/
//      delivered 边）；成员 running↔idle 状态边不唤醒（dsh agent/status
//      订阅面万我无对应缝——登记）。
//    - disposalTimeoutMs/lifecycle 处置编排：服务为 App 生命周期单例无 dispose
//      面，常量保留 1:1 不消费（登记）。
//    - QA-6 修正：P0-1 初始 prompt 判定 hasPrefix 前缀口径（生产 guidance
//      后缀）+ reconcile 同口径（prompt 参照经 member 快照万我扩展字段持久，
//      TeamTypes 登记）；P1-2 spawn 预检（非权威，start 前）+ transact 权威
//      拒绝后 drainChild（closeAgent 缝）——拒绝路径零孤儿活子；P1-4 Lead
//      栈装 team 通信三件（主理人裁决批准——dsh 作用域安装语义）；P1-1
//      TeamLoopDirectory 弱引用 box + 惰性清理（修强持有泄漏）。
//

import Foundation

// MARK: - 缝（AppEnvironment 装配；测试注入桩）

/// TeamService 宿主缝（AgentLoop/SubagentRuntime 冻结件一律经缝调用）。
struct TeamSeams: Sendable {
    /// journal append+落盘（dsh session.append+flush——SessionWriter.append
    /// 返回即持久；extensionEvent 通道）。
    var appendEvent: @Sendable (_ rootId: String, _ kind: String,
                                _ payload: JSONValue) async throws -> Void
    /// 会话日志只读（Lead 投影重建 / 目标回执回读 / 子会话 reconcile）。
    var readEvents: @Sendable (_ sessionId: String) async -> [SessionEvent]?
    /// 全部会话 id（启动恢复扫描面）。
    var allSessionIds: @Sendable () async -> [String]
    /// Lead loop steer（target=Lead 投递分支——批1 steer 语义缝；InboxSource
    /// 新 case 主理人合并后在此闭包内切换）。
    var leadSteer: @Sendable (_ rootId: String, _ text: String,
                              _ senderId: String) async throws -> Void
    /// teammate 投递（SubagentRuntime.sendMessage(from: rootId, ...)——宿主
    /// 仲裁形态 dsh steerHostSubagentPrompt 同族；inactive 目标缝内惰性冷恢复）。
    var deliverToTeammate: @Sendable (_ rootId: String, _ targetId: String,
                                      _ text: String) async throws -> Void
    /// teammate 打断（SubagentRuntime.interrupt 公开缝）。
    var interruptTeammate: @Sendable (_ childId: String,
                                      _ callerSessionId: String) async throws -> Bool
    /// 驻留成员状态快照（SubagentRuntime.listAgents(root, false) 投影）。
    var memberStatuses: @Sendable (_ rootId: String) async -> [String: String]
    /// Lead loop 运行态（TeamLoopDirectory——running/idle；nil=inactive）。
    var leadStatus: @Sendable (_ rootId: String) async -> String?
    /// 会话 cwd（teammate 子会话 cwd 继承供值）。
    var sessionCwd: @Sendable (_ sessionId: String) async -> String?
    /// continuable 子启动（SubagentRuntime.startContinuable 公开缝；
    /// provider = spawn|fork——dsh fresh/forkProvider 配置语义）。
    var startTeammate: @Sendable (_ provider: String,
                                  _ request: SubagentStartRequest) async throws
        -> SubagentRuntime.ContinuableStart
    /// 孤儿活子回收（SubagentRuntime.closeAgent 公开缝——QA-6 P1-2：journal
    /// 权威拒绝后 drain 该子；caller = rootId 满足祖先授权校验）。
    var drainChild: @Sendable (_ childId: String,
                               _ callerSessionId: String) async throws -> Bool
}

/// Team 默认缝（宿主断言失败 fail closed）。
extension TeamSeams {
    static let missing = TeamSeams(
        appendEvent: { _, _, _ in
            throw TeamError("team journal unavailable", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
        },
        readEvents: { _ in nil },
        allSessionIds: { [] },
        leadSteer: { _, _, _ in
            throw TeamError("team journal unavailable", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
        },
        deliverToTeammate: { _, _, _ in
            throw TeamError("team journal unavailable", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
        },
        interruptTeammate: { _, _ in false },
        memberStatuses: { _ in [:] },
        leadStatus: { _ in nil },
        sessionCwd: { _ in nil },
        startTeammate: { _, _ in
            throw TeamError("team journal unavailable", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
        },
        drainChild: { _, _ in false })
}

// MARK: - 成员身份（roster.ts TeamMembership 1:1）

/// Caller identity inside one implicit Team（roster.ts :29-34 1:1）。
struct TeamMembership: Equatable, Sendable {
    var rootId: String
    var id: String        // TeamId = 根会话 id
    var role: String      // 'lead' | 'teammate'
    var name: String
}

/// 投影只读面（types.ts TeamView 1:1；UI/remoteView 消费）。
struct TeamView: Equatable, Sendable {
    var members: [TeamMemberView]
    var tasks: [TeamTaskView]
}

// MARK: - 一次性结果盒（journal transact / activity wait 承载）

/// 恰好一次结算盒（checked continuation + 先到先存竞态承接）。
final class TeamOnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func fulfill(_ value: T) { settle(.success(value)) }
    func reject(_ error: Error) { settle(.failure(error)) }

    private func settle(_ result: Result<T, Error>) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        stored = result
        lock.unlock()
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<T, Error>) in
            lock.lock()
            if let stored = self.stored {
                self.stored = nil
                lock.unlock()
                continuation.resume(with: stored)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

// MARK: - 服务（actor——journal/roster/mailbox/task-board/activity 全宿主）

/// Agent Teams 服务（dsh TeamService façade + journal + roster + mailbox +
/// task-board + activity 的 WanWo 单 actor 承载；mutation 面全部经 transact
/// per-root 串行——journal.ts:42-52 语义）。
actor TeamService {
    /// nonisolated(unsafe)：init 尾 configure 一次性写入（两阶段初始化纪律
    /// ——写入先于 recoverAll Task 与任何 agent 栈装配，此后只读；
    /// AppEnvironment.writerRegistryLock nonisolated(unsafe) 同款）。
    nonisolated(unsafe) private var seams: TeamSeams
    /// 投影缓存（rootId → TeamState；懒重建——dsh sessionProjections 等价）。
    private var states: [String: TeamState] = [:]
    /// per-root mutation 串行尾（journal.ts tails Map 1:1）。
    private var tails: [String: Task<Void, Never>] = [:]
    /// 派发单飞（mailbox inFlightMessages 1:1）。
    private var inFlightMessages: Set<String> = []
    /// lineage 父会话缓存（membership 判定读日志成本摊销）。
    private var lineageParents: [String: String?] = [:]
    /// 活动唤醒（activity.ts waiters Map 1:1）。
    private var waiters: [String: [UUID: TeamOnceBox<Bool>]] = [:]

    private static let logger = AppLogger(category: "team")

    init(seams: TeamSeams) {
        self.seams = seams
    }

    /// 缝延迟绑定（AppEnvironment init 尾——两阶段初始化纪律；批2
    /// MemoryPhase2.configure 同款）。nonisolated：AppEnvironment 同步 init
    /// 内调用（init 不可 await——actor 隔离方法跨隔离调用需 await 语义；
    /// 写入先于 init 尾 recoverAll Task，无并发窗口）。
    nonisolated func configure(seams: TeamSeams) {
        self.seams = seams
    }

    // MARK: - Journal（journal.ts 1:1）

    /// 权威 Team 状态（journal.state :29-34 1:1：failure 抛出；懒重建）。
    private func state(_ rootId: String) async throws -> TeamState {
        if let cached = states[rootId] {
            if let failure = cached.failure {
                throw TeamError(failure, code: TeamError.invalidArgument)
            }
            return cached
        }
        let events = await seams.readEvents(rootId) ?? []
        let rebuilt = TeamProjection.rebuildFromEvents(rootId: rootId, events: events)
        states[rootId] = rebuilt
        if let failure = rebuilt.failure {
            throw TeamError(failure, code: TeamError.invalidArgument)
        }
        return rebuilt
    }

    /// per-root mutation 串行（transact :42-52 1:1——prior tail 吸收 rejection，
    /// 本 op 完整 read-check-append 后释放）。
    private func transact<T: Sendable>(_ rootId: String,
                                       _ operation: @escaping @Sendable () async throws -> T)
        async throws -> T {
        let box = TeamOnceBox<T>()
        let prior = tails[rootId]
        let run = Task { [prior] in
            if let prior { _ = try? await prior.value }
            do { box.fulfill(try await operation()) }
            catch { box.reject(error) }
        }
        tails[rootId] = run
        Task { [weak self] in
            _ = await run.value
            await self?.clearTailIfCurrent(run, rootId: rootId)
        }
        return try await box.wait()
    }

    private func clearTailIfCurrent(_ run: Task<Void, Never>, rootId: String) {
        if tails[rootId] == run { tails.removeValue(forKey: rootId) }
    }

    /// append+落盘+投影增量+提交通知（appendAndFlush :60-72 1:1——append 先于
    /// 应用；append 抛错投影不动）。
    private func appendAndFlush(_ rootId: String, kind: String, payload: JSONValue) async throws {
        try await seams.appendEvent(rootId, kind, payload)
        if var cached = states[rootId] {
            TeamProjection.apply(&cached, payload: .extensionEvent(kind: kind, payload: payload))
            states[rootId] = cached
        }
        activityNotify(rootId)
    }

    // MARK: - Activity（activity.ts 1:1）

    /// 等待下一个 Team 域变更（wait :22-66 1:1：timeout 校验在 waitForChange；
    /// notify 全唤醒；超时 timedOut=true）。
    private func activityWait(_ teamId: String, timeoutMs: Int) async -> Bool {
        let box = TeamOnceBox<Bool>()
        let token = UUID()
        waiters[teamId, default: [:]][token] = box
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            await self?.activityCancel(teamId: teamId, token: token, changed: false)
        }
        return (try? await box.wait()) ?? false
    }

    /// 提交通知全唤醒（notify :72-77 1:1）。
    private func activityNotify(_ teamId: String) {
        guard let current = waiters[teamId] else { return }
        waiters.removeValue(forKey: teamId)
        for box in current.values { box.fulfill(true) }
    }

    private func activityCancel(teamId: String, token: UUID, changed: Bool) {
        guard var current = waiters[teamId], let box = current.removeValue(forKey: token)
        else { return }
        if current.isEmpty { waiters.removeValue(forKey: teamId) } else {
            waiters[teamId] = current
        }
        if changed { box.fulfill(true) } else { box.fulfill(false) }
    }

    // MARK: - Membership（roster.ts tryMembership :92-122 1:1）

    /// 无抛解析（scoped 安装与观察面；malformed 日志不 veto——:116-121 catch
    /// 返回 undefined 同语义）。
    func tryMembership(_ callerSessionId: String) async -> TeamMembership? {
        let parent = await lineageParent(of: callerSessionId)
        if let parent {
            // 直接子：roster 成员（active|provisioning）→ teammate；否则
            // provider-owned subagent（有 lineage descriptor）→ 非 Team 成员。
            guard let rootState = try? await state(parent) else { return nil }
            if let member = rootState.members.first(where: { $0.id == callerSessionId }),
               member.phase == .active || member.phase == .provisioning {
                return TeamMembership(rootId: parent, id: parent,
                                      role: "teammate", name: member.name)
            }
            return nil
        }
        // 顶层会话 = 隐式 Team 根（types.ts :7 TeamId 语义；roster.ts :107/:115）。
        return TeamMembership(rootId: callerSessionId, id: callerSessionId,
                              role: "lead", name: "lead")
    }

    /// 授权凭据解析（membership :79-85 1:1）。
    func membership(_ callerSessionId: String) async throws -> TeamMembership {
        guard let membership = await tryMembership(callerSessionId) else {
            throw TeamError("agent \"\(callerSessionId)\" is not a member of an active Agent Team",
                            code: TeamError.notMember)
        }
        return membership
    }

    /// lineage 父会话（读一次缓存；SubagentLineage 首条权威——dsh
    /// session.header.parentSession 的万我 extensionEvent 承载）。
    private func lineageParent(of sessionId: String) async -> String? {
        if let cached = lineageParents[sessionId] { return cached }
        let events = await seams.readEvents(sessionId)
        let parent = events.flatMap { SubagentLineage.read(events: $0)?.parentSession }
        lineageParents[sessionId] = parent
        return parent
    }

    /// 驻留状态词汇收敛（QA-6 P2-1：SubagentRuntime.listAgents "ready" 档
    /// ——恢复登记未重挂——映射为 "inactive"，万我 status 词汇五档面收敛；
    /// statusMap 全部消费点经此）。
    private static func normalizeStatus(_ raw: String) -> String {
        raw == "ready" ? "inactive" : raw
    }

    // MARK: - Spawn（roster.ts spawn/spawnAdmitted :168-337 1:1·顺序适配登记）

    /// 创建 named durable teammate（Lead 专用）。
    func spawnTeammate(callerSessionId: String, name: String, description: String,
                       prompt: String, context: String) async throws -> TeamMemberView {
        let membership = try await membership(callerSessionId)
        guard membership.role == "lead" else {
            throw TeamError("only the Team Lead can create teammates",
                            code: TeamError.leadRequired)
        }
        guard TeamValidation.isValidMemberName(name) else {
            throw TeamError(
                "teammate name must be lower-kebab-case, at most 64 characters, and not \"lead\"",
                code: TeamError.invalidMemberName)
        }
        let cleanDescription = try TeamValidation.requiredText(
            description, field: "description", maxLength: TeamConstants.taskSubjectMaxLength)
        // dsh config freshProvider 'spawn' / forkProvider 'fork'（tool-agent-team
        // :25-28 + :181-182 schema enum ['fresh','fork'] 1:1）。M7-Fix E1b：
        // schema 枚举在 WanMo 工具面不保证强校验——未知 context 显式拒绝
        //（原静默收敛 fresh 属语义偷渡，dsh 校验层等价拒绝）。
        guard context == "fresh" || context == "fork" else {
            throw TeamError(
                "context must be \"fresh\" or \"fork\"",
                code: TeamError.invalidArgument)
        }
        let provider = context == "fork" ? "fork" : "spawn"
        let rootId = membership.rootId

        // 1a. 非权威预检（QA-6 P1-2：拒绝路径不产生孤儿活子——start 前先查
        //     名复用/成员帽，避免先启动子再拒绝；权威检查仍在 transact，
        //     两窗间竞态由权威拒绝 + drain 兜底）。
        let preState = try await state(rootId)
        if preState.members.contains(where: { $0.name == name }) {
            throw TeamError("teammate name \"\(name)\" was already used in this Team",
                            code: TeamError.memberNameTaken)
        }
        if preState.members.count >= TeamConstants.maxMembers {
            throw TeamError("Team member limit \(TeamConstants.maxMembers) reached",
                            code: TeamError.memberLimit)
        }

        // 1b. startContinuable（childId 由 runtime 分配——顺序适配登记）。
        let started: SubagentRuntime.ContinuableStart
        do {
            started = try await seams.startTeammate(provider, SubagentStartRequest(
                label: TeamConstants.memberLabelPrefix + name,
                prompt: prompt, parentSessionId: rootId,
                parentCwd: await seams.sessionCwd(rootId),
                parentDepth: 0, maxDepth: nil,
                sandboxModeOverride: nil, modelSelection: nil))
        } catch {
            throw error   // start 失败 = 无 journal 足迹（登记）。
        }
        let childId = started.childId
        let member = TeamMemberSnapshot(
            id: childId, name: name, description: cleanDescription,
            provider: provider, context: context, phase: .provisioning, error: nil,
            prompt: prompt)

        // 2. journal provisioning（name 复用/maxMembers 权威检查 + append；
        //    QA-6 P1-2：权威拒绝后 drain 孤儿活子——closeAgent 停回合+摘登记
        //    +置边 Closed，drain 失败不掩盖原拒绝原因）。
        do {
            try await transact(rootId) { [weak self] in
                guard let self else {
                    throw TeamError("team service released",
                                    code: "TEAM_LEAD_SESSION_UNAVAILABLE")
                }
                let state = try await self.state(rootId)
                if state.members.contains(where: { $0.name == name }) {
                    throw TeamError("teammate name \"\(name)\" was already used in this Team",
                                    code: TeamError.memberNameTaken)
                }
                if state.members.count >= TeamConstants.maxMembers {
                    throw TeamError("Team member limit \(TeamConstants.maxMembers) reached",
                                    code: TeamError.memberLimit)
                }
                try await self.appendAndFlush(
                    rootId, kind: TeamEvents.memberKind,
                    payload: TeamEvents.memberPayload(teamId: rootId, member: member))
            }
        } catch {
            try? await seams.drainChild(childId, rootId)
            throw error
        }

        // 3. checkpoint 初始 prompt（checkpointInitialPrompt :340-389 语义——
        //    万我 prompt 前缀口径轮询（QA-6 P0-1），有界 10s）。
        //    M7-Fix E1b（dsh roster.ts:289-313 catch 语义）：确认超时 = 创建方
        //    观测到的故障窗——立即 journal member failed 快照 + drain 活子，
        //    不再留守 provisioning 等重启 reconcile（dsh checkpointInitialPrompt
        //    抛错走同一 failed 落账 + stopTeammates 路径）。
        let accepted = await waitForPromptAccepted(
            childId: childId, prompt: prompt, timeoutMs: promptAcceptTimeoutMs)
        var settled = member
        if accepted {
            settled.phase = .active
            try await settleProvisioning(rootId: rootId, terminal: settled)
        } else {
            var failed = member
            failed.phase = .failed
            failed.error = "initial prompt acceptance timed out"
            do {
                try await settleProvisioning(rootId: rootId, terminal: failed)
            } catch {
                // 落账失败不掩盖清理——先 drain 再上抛（dsh recordError 面等价）。
                try? await seams.drainChild(childId, rootId)
                throw error
            }
            try? await seams.drainChild(childId, rootId)
        }
        let statusMap = await seams.memberStatuses(rootId)
        return TeamMemberView(
            id: settled.id, name: settled.name, role: "teammate",
            status: settled.phase == .failed
                ? "failed"
                : settled.phase == .provisioning
                    ? "provisioning"
                    : Self.normalizeStatus(statusMap[settled.id] ?? "inactive"),
            description: settled.description, provider: settled.provider,
            context: settled.context, model: nil, diagnostics: [])
    }

    /// 初始 prompt 接受确认超时毫秒（checkpointInitialPrompt :340-389 有界面；
    /// var 供单测注入快值——生产保持 10s，登记：可测性旋钮不进缝）。
    var promptAcceptTimeoutMs = 10_000

    /// 测试注入口（actor 隔离写面——跨 actor 属性赋值的显式方法承载）。
    func setPromptAcceptTimeoutForTesting(_ ms: Int) {
        promptAcceptTimeoutMs = ms
    }

    /// 初始 prompt 接受确认（QA-6 P0-1：hasPrefix 前缀口径——生产缝
    /// withContinuableReturnGuidance 在 prompt 后追加回传指引后缀
    ///（SubagentRuntime :398-422），等值判定必漏；messageId 关联的万我内容
    /// 指纹承载登记）。
    private func waitForPromptAccepted(childId: String, prompt: String,
                                       timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let events = await seams.readEvents(childId),
               events.contains(where: {
                   if case .userMessage(let text) = $0.payload {
                       return text.hasPrefix(prompt)
                   }
                   return false
               }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// 终态落账（settleProvisioning :464-482 1:1——仅 provisioning 可终态）。
    private func settleProvisioning(rootId: String, terminal: TeamMemberSnapshot) async throws {
        try await transact(rootId) { [weak self] in
            guard let self else {
                throw TeamError("team service released", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
            }
            let state = try await self.state(rootId)
            guard let current = state.members.first(where: { $0.id == terminal.id }) else {
                throw TeamError("provisioned teammate \"\(terminal.id)\" disappeared",
                                code: TeamError.provisioningConflict)
            }
            guard current.phase == .provisioning else { return }
            try await self.appendAndFlush(
                rootId, kind: TeamEvents.memberKind,
                payload: TeamEvents.memberPayload(teamId: rootId, member: terminal))
        }
    }

    // MARK: - 花名册视图（roster.ts list :129-160 1:1）

    /// Lead + teammate 行（创建序；运行时增强）。
    func listMembers(_ callerSessionId: String) async throws -> [TeamMemberView] {
        let membership = try await membership(callerSessionId)
        let rootId = membership.rootId
        let state = try await state(rootId)
        let leadStatus = await seams.leadStatus(rootId) ?? "inactive"
        var result = [TeamMemberView(
            id: rootId, name: "lead", role: "lead", status: leadStatus,
            description: nil, provider: nil, context: nil, model: nil,
            diagnostics: [])]
        let statusMap = await seams.memberStatuses(rootId)
        for member in state.members {
            result.append(TeamMemberView(
                id: member.id, name: member.name, role: "teammate",
                status: member.phase == .failed
                    ? "failed"
                    : (member.phase == .provisioning
                        ? "provisioning"
                        : Self.normalizeStatus(statusMap[member.id] ?? "inactive")),
                description: member.description, provider: member.provider,
                context: member.context, model: nil,
                diagnostics: member.error.map { [$0] } ?? []))
        }
        return result
    }

    // MARK: - 邮箱（mailbox.ts send/sendAdmitted/tryDispatch/dispatchOnce 1:1）

    /// 发送 durable 邻message（send :55-62 → sendAdmitted :109-151 1:1：
    /// queued 先持久；返回 status=accepted 仅当即时投递确认）。
    func sendMessage(callerSessionId: String, target: String,
                     message: String) async throws -> SendTeamMessageResult {
        let membership = try await membership(callerSessionId)
        let rootId = membership.rootId
        let callerId = callerSessionId
        let callerName = membership.name
        let queued: TeamMessageSnapshot = try await transact(rootId) { [weak self] in
            guard let self else {
                throw TeamError("team service released", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
            }
            let state = try await self.state(rootId)
            let resolved = try Self.resolveActiveMember(rootId: rootId, state: state,
                                                        rawName: target)
            if resolved.id == callerId {
                throw TeamError("a Team member cannot message itself",
                                code: TeamError.selfMessage)
            }
            let pendingForTarget = state.messages.filter { candidate in
                candidate.targetId == resolved.id && !state.delivered.contains(candidate.id)
            }.count
            if pendingForTarget >= TeamConstants.maxPendingMessagesPerMember {
                throw TeamError(
                    "teammate \"\(resolved.name)\" has \(pendingForTarget) pending messages",
                    code: TeamError.mailboxFull)
            }
            let queued = TeamMessageSnapshot(
                id: TeamConstants.newMessageId(), senderId: callerId,
                senderName: callerName, targetId: resolved.id, content: message)
            let framed = Self.deliveryContent(queued)
            if framed.utf8.count > TeamConstants.maxMessageBytes {
                throw TeamError(
                    "team message exceeds \(TeamConstants.maxMessageBytes) bytes",
                    code: TeamError.messageTooLarge)
            }
            try await self.appendAndFlush(
                rootId, kind: TeamEvents.messageQueuedKind,
                payload: TeamEvents.queuedPayload(teamId: rootId, message: queued))
            return queued
        }
        // 即时投递尝试（单飞 + target-local FIFO 串行——tryDispatch/
        // serializeDispatch 1:1）。
        let accepted = await tryDispatch(rootId: rootId, message: queued)
        return SendTeamMessageResult(
            messageId: queued.id,
            status: accepted ? "accepted" : "queued")
    }

    /// 解析活跃成员（roster.ts resolveActiveMember :43-55 1:1——'lead' 伪行 +
    /// active 成员名匹配）。
    static func resolveActiveMember(rootId: String, state: TeamState,
                                    rawName: String) throws -> (id: String, name: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "lead" { return (rootId, name) }
        guard let member = state.members.first(where: { $0.name == name }),
              member.phase == .active else {
            throw TeamError("active teammate \"\(name)\" not found",
                            code: TeamError.memberNotFound)
        }
        return (member.id, member.name)
    }

    /// 模型面投递文本（deliveryContent :309-314 1:1——框架行 + 正文）。
    static func deliveryContent(_ message: TeamMessageSnapshot) -> String {
        TeamConstants.deliveryFrame(messageId: message.id, senderName: message.senderName)
            + "\n" + message.content
    }

    /// 单飞尝试一次派发（tryDispatch :154-170 1:1：in-flight 去重）。
    private func tryDispatch(rootId: String, message: TeamMessageSnapshot) async -> Bool {
        guard !inFlightMessages.contains(message.id) else { return false }
        inFlightMessages.insert(message.id)
        defer { inFlightMessages.remove(message.id) }
        // target-local FIFO 串行（serializeDispatch :193-209——per-target tail）。
        return (try? await transact("dispatch:\(message.targetId)") { [weak self] in
            guard let self else { return false }
            return await self.dispatchThrough(rootId: rootId, message: message)
        }) ?? false
    }

    /// 按持久队列序投递到指定消息为止（dispatchThrough :212-232 1:1）。
    private func dispatchThrough(rootId: String, message: TeamMessageSnapshot) async -> Bool {
        guard let state = try? await state(rootId) else { return false }
        let pending = state.messages.filter { candidate in
            candidate.targetId == message.targetId
                && !state.delivered.contains(candidate.id)
        }
        guard let requested = pending.firstIndex(where: { $0.id == message.id }) else {
            return state.delivered.contains(message.id)
        }
        for candidate in pending[0...requested] {
            if await dispatchOnce(rootId: rootId, message: candidate) == false {
                return false
            }
        }
        return true
    }

    /// 单条派发三分支（dispatchOnce :235-270 + 已定适配②）。
    private func dispatchOnce(rootId: String, message: TeamMessageSnapshot) async -> Bool {
        // 分支0：目标已记录（回执回读——防谎报幂等确认）。
        if let events = await seams.readEvents(message.targetId),
           Self.targetRecorded(events: events, message: message) {
            return await markDelivered(rootId: rootId, messageId: message.id,
                                       targetId: message.targetId)
        }
        let text = Self.deliveryContent(message)
        // 分支1：target=Lead → 批1 steer 语义缝（AgentLoop.steer；InboxSource
        // 新 case 主理人合并收口——TeamSeams.leadSteer 装配闭包承载）。
        if message.targetId == rootId {
            do {
                try await seams.leadSteer(rootId, text, message.senderId)
                if await waitForFraming(sessionId: rootId, message: message,
                                        timeoutMs: 8_000) {
                    return await markDelivered(rootId: rootId, messageId: message.id,
                                               targetId: message.targetId)
                }
                return false
            } catch {
                Self.logger.warning("team message \"\(message.id)\" remains queued: "
                                    + "\(String(describing: error))")
                return false
            }
        }
        // 分支2/3：teammate 活跃 steer/新回合 + inactive 惰性冷恢复
        // （SubagentRuntime.sendMessage 公开缝——批1 恢复缝 remountIfNeeded 在缝内）。
        do {
            try await seams.deliverToTeammate(rootId, message.targetId, text)
            if await waitForFraming(sessionId: message.targetId, message: message,
                                    timeoutMs: 8_000) {
                return await markDelivered(rootId: rootId, messageId: message.id,
                                           targetId: message.targetId)
            }
            return false
        } catch {
            // 冷恢复失败/不可恢复目标：持久回读（persistedTargetRecorded
            // :317-331 1:1——不确定 = 保持 queued）。
            if let events = await seams.readEvents(message.targetId),
               Self.targetRecorded(events: events, message: message) {
                return await markDelivered(rootId: rootId, messageId: message.id,
                                           targetId: message.targetId)
            }
            Self.logger.warning("team message \"\(message.id)\" remains queued: "
                                + "\(String(describing: error))")
            return false
        }
    }

    /// delivered 回写幂等（markDelivered :285-298 1:1）。
    private func markDelivered(rootId: String, messageId: String,
                               targetId: String) async -> Bool {
        do {
            try await transact(rootId) { [weak self] in
                guard let self else { return }
                let state = try await self.state(rootId)
                if state.delivered.contains(messageId) { return }
                guard let queued = state.messages.first(where: { $0.id == messageId }),
                      queued.targetId == targetId else { return }
                try await self.appendAndFlush(
                    rootId, kind: TeamEvents.messageDeliveredKind,
                    payload: TeamEvents.deliveredPayload(
                        teamId: rootId, messageId: messageId, targetId: targetId))
            }
            return true
        } catch {
            return false
        }
    }

    /// 目标记录判定（targetRecorded :301-306 1:1——万我 userMessage 词汇冻结，
    /// 以框架行前缀内容指纹承载 messageId 身份，登记）。
    static func targetRecorded(events: [SessionEvent], message: TeamMessageSnapshot) -> Bool {
        let frame = TeamConstants.deliveryFrame(messageId: message.id,
                                                senderName: message.senderName)
        return events.contains { event in
            if case .userMessage(let text) = event.payload {
                return text.hasPrefix(frame)
            }
            return false
        }
    }

    /// 投递确认轮询（dsh session/event 观察缝的万我有界轮询承载，登记）。
    private func waitForFraming(sessionId: String, message: TeamMessageSnapshot,
                                timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let events = await seams.readEvents(sessionId),
               Self.targetRecorded(events: events, message: message) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    // MARK: - 任务板（task-board.ts create/get/list/update 1:1）

    /// 创建 unowned pending 任务（create :48-73 1:1）。
    func createTask(callerSessionId: String, subject: String, description: String,
                    blockedBy: [String], writeScopes: [String]) async throws -> TeamTaskView {
        let membership = try await membership(callerSessionId)
        let rootId = membership.rootId
        let callerId = callerSessionId
        return try await transact(rootId) { [weak self] in
            guard let self else {
                throw TeamError("team service released", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
            }
            var state = try await self.state(rootId)
            let active = state.tasks.filter { $0.status != .deleted }.count
            if active >= TeamConstants.maxTasks {
                throw TeamError("Team task limit \(TeamConstants.maxTasks) reached",
                                code: TeamError.taskLimit)
            }
            let id = TeamConstants.taskId(state.nextTaskNumber)
            if state.tasks.contains(where: { $0.id == id }) {
                throw TeamError("Team task id space exhausted", code: TeamError.taskLimit)
            }
            let task = TeamTaskSnapshot(
                id: id, revision: 1,
                subject: try TeamValidation.requiredText(
                    subject, field: "subject",
                    maxLength: TeamConstants.taskSubjectMaxLength),
                description: try TeamValidation.requiredText(
                    description, field: "description",
                    maxLength: TeamConstants.taskDescriptionMaxLength),
                status: .pending, ownerId: nil,
                blockedBy: try Self.dependencies(blockedBy, state: state),
                writeScopes: try Self.writeScopes(writeScopes))
            try TeamTaskGraph.assertCandidate(current: state.tasks, candidate: task)
            try await self.appendAndFlush(
                rootId, kind: TeamEvents.taskKind,
                payload: TeamEvents.taskPayload(teamId: rootId, task: task))
            state = try await self.state(rootId)
            return Self.taskView(rootId: rootId, state: state, task: task)
        }
    }

    /// 单任务读取（get :81-87 1:1——deleted 墓碑可读）。
    func getTask(callerSessionId: String, taskId: String) async throws -> TeamTaskView {
        let membership = try await membership(callerSessionId)
        let state = try await state(membership.rootId)
        guard let task = state.tasks.first(where: { $0.id == taskId }) else {
            throw TeamError("team task \"\(taskId)\" not found", code: TeamError.taskNotFound)
        }
        return Self.taskView(rootId: membership.rootId, state: state, task: task)
    }

    /// 未删除任务列表（list :94-100 1:1——数值创建序）。
    func listTasks(_ callerSessionId: String) async throws -> [TeamTaskView] {
        let membership = try await membership(callerSessionId)
        let state = try await state(membership.rootId)
        return state.tasks
            .filter { $0.status != .deleted }
            .map { Self.taskView(rootId: membership.rootId, state: state, task: $0) }
    }

    /// CAS 变更（update :109-215 七 action 授权与转移矩阵 1:1）。
    func updateTask(callerSessionId: String, request: UpdateTeamTaskRequest) async throws
        -> TeamTaskView {
        let membership = try await membership(callerSessionId)
        let rootId = membership.rootId
        let callerId = callerSessionId
        let lead = membership.role == "lead"
        return try await transact(rootId) { [weak self] in
            guard let self else {
                throw TeamError("team service released", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
            }
            var state = try await self.state(rootId)
            guard let current = state.tasks.first(where: { $0.id == request.taskId }) else {
                throw TeamError("team task \"\(request.taskId)\" not found",
                                code: TeamError.taskNotFound)
            }
            if current.revision != request.expectedRevision {
                throw TeamError(
                    "stale team task \"\(current.id)\" revision \(request.expectedRevision); "
                        + "current revision is \(current.revision)",
                    code: TeamError.taskStaleRevision)
            }
            if current.status == .deleted {
                throw TeamError("team task \"\(current.id)\" is deleted",
                                code: TeamError.taskDeleted)
            }
            let owner = current.ownerId == callerId
            func authorizeOwner() throws {
                if !lead && !owner {
                    throw TeamError("task mutation requires its owner or Team Lead",
                                    code: TeamError.taskUnauthorized)
                }
            }
            var next = current
            switch request.action {
            case .claim:
                if let ownerId = current.ownerId, ownerId != callerId {
                    throw TeamError("team task \"\(current.id)\" is owned by another member",
                                    code: TeamError.taskAlreadyClaimed)
                }
                if current.status != .pending
                    || !Self.taskReady(state: state, task: current) {
                    throw TeamError("team task \"\(current.id)\" is not ready to claim",
                                    code: TeamError.taskBlocked)
                }
                next.status = .inProgress
                next.ownerId = callerId
            case .release:
                try authorizeOwner()
                guard current.status == .inProgress else {
                    throw TeamError("only an in-progress task can be released",
                                    code: TeamError.taskInvalidTransition)
                }
                next.status = .pending
                next.ownerId = nil
            case .edit:
                try authorizeOwner()
                if request.subject == nil && request.description == nil
                    && request.writeScopes == nil {
                    throw TeamError("task edit requires subject, description, or write_scopes",
                                    code: TeamError.invalidArgument)
                }
                if let subject = request.subject {
                    next.subject = try TeamValidation.requiredText(
                        subject, field: "subject",
                        maxLength: TeamConstants.taskSubjectMaxLength)
                }
                if let description = request.description {
                    next.description = try TeamValidation.requiredText(
                        description, field: "description",
                        maxLength: TeamConstants.taskDescriptionMaxLength)
                }
                if let writeScopes = request.writeScopes {
                    next.writeScopes = try Self.writeScopes(writeScopes)
                }
            case .setDependencies:
                try authorizeOwner()
                guard let blockedBy = request.blockedBy else {
                    throw TeamError("set_dependencies requires blocked_by",
                                    code: TeamError.invalidArgument)
                }
                next.blockedBy = try Self.dependencies(blockedBy, state: state, selfId: current.id)
            case .complete:
                try authorizeOwner()
                guard current.status == .inProgress else {
                    throw TeamError("only an in-progress task can complete",
                                    code: TeamError.taskInvalidTransition)
                }
                next.status = .completed
            case .reopen:
                try authorizeOwner()
                guard current.status == .completed else {
                    throw TeamError("only a completed task can reopen",
                                    code: TeamError.taskInvalidTransition)
                }
                next.status = .pending
                next.ownerId = nil
            case .reassign:
                guard lead else {
                    throw TeamError("only the Team Lead can reassign tasks",
                                    code: TeamError.leadRequired)
                }
                guard current.status == .pending || current.status == .inProgress else {
                    throw TeamError("only a pending or in-progress task can be reassigned",
                                    code: TeamError.taskInvalidTransition)
                }
                if request.owner == nil || request.owner?.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty == true {
                    next.status = .pending
                    next.ownerId = nil
                } else {
                    guard Self.taskReady(state: state, task: current) else {
                        throw TeamError("team task \"\(current.id)\" is blocked",
                                        code: TeamError.taskBlocked)
                    }
                    let assignee = try Self.resolveActiveMember(
                        rootId: rootId, state: state, rawName: request.owner!)
                    next.status = .inProgress
                    next.ownerId = assignee.id
                }
            case .delete:
                try authorizeOwner()
                if let dependent = state.tasks.first(where: { other in
                    other.status != .deleted && other.id != current.id
                        && other.blockedBy.contains(current.id)
                }) {
                    throw TeamError(
                        "team task \"\(current.id)\" still blocks \"\(dependent.id)\"",
                        code: TeamError.taskHasDependents)
                }
                next.status = .deleted
            }
            next.revision = current.revision + 1
            try TeamTaskGraph.assertCandidate(current: state.tasks, candidate: next)
            try await self.appendAndFlush(
                rootId, kind: TeamEvents.taskKind,
                payload: TeamEvents.taskPayload(teamId: rootId, task: next))
            state = try await self.state(rootId)
            return Self.taskView(rootId: rootId, state: state, task: next)
        }
    }

    /// 依赖校验（dependencies :218-236 1:1：自阻塞=cycle/重复=invalid/缺失=not found）。
    static func dependencies(_ values: [String], state: TeamState,
                             selfId: String? = nil) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in values {
            if id == selfId {
                throw TeamError("a team task cannot block itself",
                                code: TeamError.taskDependencyCycle)
            }
            if seen.contains(id) {
                throw TeamError("duplicate blocker \"\(id)\"",
                                code: TeamError.invalidArgument)
            }
            guard let task = state.tasks.first(where: { $0.id == id }),
                  task.status != .deleted else {
                throw TeamError("blocker task \"\(id)\" not found",
                                code: TeamError.taskNotFound)
            }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    /// write scopes 归一化去重（writeScopes :239-241 1:1）。
    static func writeScopes(_ values: [String]) throws -> [String] {
        var out: [String] = []
        for value in values {
            let normalized = try TeamValidation.writeScope(value)
            if !out.contains(normalized) { out.append(normalized) }
        }
        return out
    }

    /// blockers 全 completed（taskReady :255-257 1:1）。
    static func taskReady(state: TeamState, task: TeamTaskSnapshot) -> Bool {
        task.blockedBy.allSatisfy { blockerId in
            state.tasks.first(where: { $0.id == blockerId })?.status == .completed
        }
    }

    /// 任务视图（taskView :271-296 1:1：ownerName/ready/writeScopeWarnings）。
    static func taskView(rootId: String, state: TeamState,
                         task: TeamTaskSnapshot) -> TeamTaskView {
        let ownerName = task.ownerId.map { ownerId in
            ownerId == rootId
                ? "lead"
                : state.members.first(where: { $0.id == ownerId })?.name
        }
        var warnings = Set<String>()
        for other in state.tasks {
            if other.id == task.id || other.status != .inProgress { continue }
            if task.writeScopes.contains(where: { left in
                other.writeScopes.contains { TeamValidation.scopesOverlap(left, $0) }
            }) {
                warnings.insert("write scopes overlap with \(other.id)")
            }
        }
        return TeamTaskView(
            id: task.id, revision: task.revision, subject: task.subject,
            description: task.description, status: task.status,
            blockedBy: task.blockedBy, writeScopes: task.writeScopes,
            ownerName: ownerName ?? nil,
            ready: task.status == .pending && taskReady(state: state, task: task),
            writeScopeWarnings: Array(warnings).sorted())
    }

    // MARK: - wait_agent / interrupt（index.ts :213-226 1:1）

    /// 等待 Team 变更（waitForChange :213-216 1:1：timeout 校验权威先行）。
    func waitForChange(callerSessionId: String, timeoutMs: Int) async throws -> TeamWaitResult {
        let membership = try await membership(callerSessionId)
        guard timeoutMs >= TeamConstants.minWaitTimeoutMs,
              timeoutMs <= TeamConstants.maxWaitTimeoutMs else {
            throw TeamError("timeoutMs must be an integer from 10000 through 3600000",
                            code: TeamError.invalidTimeout)
        }
        let changed = await activityWait(membership.id, timeoutMs: timeoutMs)
        return TeamWaitResult(timedOut: !changed)
    }

    /// 打断队友当前回合（roster.interrupt :204-215 1:1：Lead 专用 + 非自身；
    /// inbox 保留）。
    func interrupt(callerSessionId: String, targetName: String) async throws -> String {
        let membership = try await membership(callerSessionId)
        guard membership.role == "lead" else {
            throw TeamError("only the Team Lead can interrupt teammates",
                            code: TeamError.leadRequired)
        }
        let state = try await state(membership.rootId)
        let target = try Self.resolveActiveMember(rootId: membership.rootId,
                                                  state: state, rawName: targetName)
        if target.id == membership.rootId {
            throw TeamError("the Team Lead cannot interrupt itself",
                            code: TeamError.invalidTarget)
        }
        let statusMap = await seams.memberStatuses(membership.rootId)
        let previousStatus = Self.normalizeStatus(statusMap[target.id] ?? "inactive")
        _ = try await seams.interruptTeammate(target.id, membership.rootId)
        return previousStatus
    }

    // MARK: - 只读面（index.ts remoteView :242-248 1:1；UI 消费）

    /// 花名册+任务板投影（UI 最小呈现）。
    func teamView(_ callerSessionId: String) async throws -> TeamView {
        TeamView(members: try await listMembers(callerSessionId),
                 tasks: try await listTasks(callerSessionId))
    }

    // MARK: - 恢复（index.ts recoverFor :300-303 + roster.reconcileProvisioning 1:1）

    /// 启动恢复：全量会话扫描 → 含 Team 事件的根 → reconcile provisioning →
    /// 重试 pending 邮箱（scheduleRecovery/recoverFor :289-303 承载）。
    func recoverAll() async {
        let sessionIds = await seams.allSessionIds()
        for sessionId in sessionIds {
            guard let events = await seams.readEvents(sessionId),
                  events.contains(where: { TeamProjection.isTeamEvent($0.payload) }) else {
                continue
            }
            states[sessionId] = TeamProjection.rebuildFromEvents(rootId: sessionId,
                                                                 events: events)
            await reconcileProvisioning(rootId: sessionId)
            await retryPendingMessages(rootId: sessionId)
        }
    }

    /// provisioning 持久判活（reconcileProvisioning :392-434 1:1：lineage 父子
    /// + continuable descriptor + provider 匹配 + 初始 prompt 已接受 → active，
    /// 否则 failed 快照）。
    private func reconcileProvisioning(rootId: String) async {
        guard let rootState = try? await state(rootId) else { return }
        for member in rootState.members where member.phase == .provisioning {
            var phase: TeamMemberPhase = .failed
            var failure = "provisioning did not leave a resumable child Session"
            if let events = await seams.readEvents(member.id) {
                let lineage = SubagentLineage.read(events: events)
                let descriptor = SubagentDescriptor.fold(events: events)
                // QA-6 P0-1：与 waitForPromptAccepted 同口径（hasPrefix 前缀）
                // ——生产子日志初始 userMessage = prompt + guidance 后缀。
                // prompt 参照经 provisioning member 事件持久携带（万我扩展
                // 字段，登记）；旧日志缺 prompt 字段 → 宽松回退（任一
                // userMessage——升级窗口兼容，登记）。
                let acceptedInitialPrompt = events.contains { event in
                    if case .userMessage(let text) = event.payload {
                        guard let expected = member.prompt else { return true }
                        return text.hasPrefix(expected)
                    }
                    return false
                }
                if lineage?.parentSession == rootId
                    && descriptor?.mode == .continuable
                    && descriptor?.provider == member.provider
                    && acceptedInitialPrompt {
                    phase = .active
                } else {
                    failure = "persisted child Session does not match the provisioned continuation"
                }
            }
            var terminal = member
            terminal.phase = phase
            if phase == .failed { terminal.error = failure }
            try? await settleProvisioning(rootId: rootId, terminal: terminal)
        }
    }

    /// pending 邮箱重试（mailbox.recoverFor :86-98 1:1——未 delivered 全量按
    /// 持久序重派发）。
    private func retryPendingMessages(rootId: String) async {
        guard let rootState = try? await state(rootId) else { return }
        let pending = rootState.messages.filter { !rootState.delivered.contains($0.id) }
        for message in pending {
            _ = await tryDispatch(rootId: rootId, message: message)
        }
    }
}

// MARK: - Loop 目录（Lead loop 运行态供值；AppEnvironment.makeAgentStack 登记）

/// 会话 loop 弱引用目录（NSLock + 弱引用 box 数组——loop 释放即弱引用归
/// nil，get/register 路径惰性清理失效项；QA-6 P1-1：修原强持有字典泄漏——
/// 会话关闭后 loop 不被本目录滞留。TeamSeams.leadStatus 装配消费——
/// AgentLoop 冻结件不经此处改动静音，仅 currentPhase 公开缝读取）。
final class TeamLoopDirectory: @unchecked Sendable {
    private struct WeakBox {
        weak var loop: AgentLoop?
    }

    private let lock = NSLock()
    private var entries: [(key: String, box: WeakBox)] = []

    func register(_ sessionId: String, _ loop: AgentLoop) {
        lock.lock()
        defer { lock.unlock() }
        // 同 id 重注册（重装配路径）= 原位替换。
        if let index = entries.firstIndex(where: { $0.key == sessionId }) {
            entries[index].box.loop = loop
        } else {
            entries.append((sessionId, WeakBox(loop: loop)))
        }
        purgeLocked()
    }

    func get(_ sessionId: String) -> AgentLoop? {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked()
        return entries.first(where: { $0.key == sessionId })?.box.loop
    }

    /// 失效项惰性清理（弱引用归 nil 的 box 即摘除——无定时器/无注销面）。
    private func purgeLocked() {
        entries.removeAll { $0.box.loop == nil }
    }
}
