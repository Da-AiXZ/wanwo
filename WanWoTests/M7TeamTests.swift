//
//  M7TeamTests.swift
//  WanWoTests
//
//  【M7 件 L · F046 单测】dsh Agent Teams 语义移植对拍断言点（语义源
//  experimental/agent-team/src/ 全家 + tool-agent-team/src/index.ts）：
//    - 花名册状态机：spawn provisioning→active（stub 缝内 prompt 已接受）、
//      重启 reconcile（persisted dossier 齐备 → active；缺失 → failed）、
//      投影单向转移（provisioning 起步/不可变字段/name 复用拒）。
//    - 名字规则：MEMBER_NAME 正则（lower-kebab-case/≤64/不叫 "lead"）。
//    - CAS 任务板：create/claim/complete 转移矩阵 + expectedRevision、
//      set_dependencies 建图（自阻塞 cycle/重复/缺失）、delete 依赖人挡、
//      授权（owner/Lead 矩阵、reassign Lead 专用）、ready 判定、
//      writeScopes 咨询性告警（路径组件前缀重叠）、maxTasks 256。
//    - 邮箱：queued 先持久→三分支投递（teammate 缝/Lead steer 缝/失败保持
//      queued）→ delivered 幂等回写；pending<64 帽、65536B 帽、自投递拒、
//      recovery 全量重派（journal 重放等价）。
//    - 投影重建：四事件 journal 重放 == 增量应用；version==2 selector；
//      failure 中毒面；nextTaskNumber 推进。
//    - 九工具 schema 面：名称/必填/描述 + 视图 JSON 编码器字段保真。
//  测试基建：TeamSeams 九闭包测试桩注入（内存 journal + 可配置故障位），
//  不触盘、不依赖 AgentLoop/SubagentRuntime（冻结件经缝隔离验证）。
//

import XCTest
@testable import WanWo

final class M7TeamTests: XCTestCase {

    // MARK: - 测试基建（TeamSeams 内存桩）

    /// 内存会话日志（锁保护；append 契合 SessionWriter 语义：seq 单调自增）。
    private final class TeamJournal: @unchecked Sendable {
        private let lock = NSLock()
        private var logs: [String: [SessionEvent]] = [:]
        private var seqs: [String: Int] = [:]

        func append(_ sessionId: String, payload: SessionEvent.Payload) {
            lock.lock()
            defer { lock.unlock() }
            let next = (seqs[sessionId] ?? 0) + 1
            seqs[sessionId] = next
            // wireType 供 defaultIgnorable 判定（extension 恒 ignorable——
            // SessionEvent.defaultIgnorable :217-226 语义）。
            let probe = SessionEvent(seq: next, timeMs: 0, payload: payload, ignorable: false)
            var event = probe
            event.ignorable = SessionEvent.defaultIgnorable(for: probe.wireType)
            logs[sessionId, default: []].append(event)
        }

        func read(_ sessionId: String) -> [SessionEvent] {
            lock.lock()
            defer { lock.unlock() }
            return logs[sessionId] ?? []
        }

        func ids() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return logs.keys.sorted()
        }

        /// journal 重放投影（TeamProjection.rebuildFromEvents 等价面）。
        func projection(_ rootId: String) -> TeamState {
            TeamProjection.rebuildFromEvents(rootId: rootId, events: read(rootId))
        }
    }

    /// 缝桩束：可配置故障位 + 调用记录（全部锁保护——TeamService actor 与
    /// transact Task 并发访问）。
    private final class TeamHarness: @unchecked Sendable {
        let journal = TeamJournal()
        private let lock = NSLock()
        private var nextChildCounter = 0
        private var leadSteerCallsStorage: [(rootId: String, text: String, senderId: String)] = []
        private var deliverCallsStorage: [(rootId: String, targetId: String, text: String)] = []
        private var interruptCallsStorage: [String] = []
        private var statusesStorage: [String: String] = [:]
        private var leadStatusStorage: String? = "idle"
        private var failLeadSteerFlag = false
        private var failDeliverFlag = false
        private var acceptPromptFlag = true
        private var seedDossierFlag = true
        /// QA-6 P0-1 回归：true = startTeammate 按 withContinuableReturnGuidance
        /// 包装初始 prompt 落盘（复刻生产链 SubagentRuntime :398-422）。
        private var wrapGuidanceFlag = false
        private var drainCallsStorage: [String] = []

        // MARK: 可配置故障位

        var failLeadSteer: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failLeadSteerFlag }
            set { lock.lock(); failLeadSteerFlag = newValue; lock.unlock() }
        }

        var failDeliver: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failDeliverFlag }
            set { lock.lock(); failDeliverFlag = newValue; lock.unlock() }
        }

        /// false = startTeammate 不落初始 prompt userMessage（provisioning 留守）。
        var acceptPrompt: Bool {
            get { lock.lock(); defer { lock.unlock() }; return acceptPromptFlag }
            set { lock.lock(); acceptPromptFlag = newValue; lock.unlock() }
        }

        /// false = 子日志不含 lineage/descriptor（reconcile 判 failed 面）。
        var seedDossier: Bool {
            get { lock.lock(); defer { lock.unlock() }; return seedDossierFlag }
            set { lock.lock(); seedDossierFlag = newValue; lock.unlock() }
        }

        /// QA-6 P0-1：true = 初始 prompt 按 guidance 后缀包装落盘。
        var wrapGuidance: Bool {
            get { lock.lock(); defer { lock.unlock() }; return wrapGuidanceFlag }
            set { lock.lock(); wrapGuidanceFlag = newValue; lock.unlock() }
        }

        /// QA-6 P1-2：drainChild 缝调用记录（权威拒绝路径回收面）。
        var drainCalls: [String] {
            lock.lock(); defer { lock.unlock() }; return drainCallsStorage
        }

        /// 已创建子会话数（预检孤儿面断言用）。
        var childCount: Int {
            lock.lock(); defer { lock.unlock() }; return nextChildCounter
        }

        var statuses: [String: String] {
            get { lock.lock(); defer { lock.unlock() }; return statusesStorage }
            set { lock.lock(); statusesStorage = newValue; lock.unlock() }
        }

        // MARK: 调用记录

        var leadSteerCalls: [(rootId: String, text: String, senderId: String)] {
            lock.lock(); defer { lock.unlock() }; return leadSteerCallsStorage
        }

        var deliverCalls: [(rootId: String, targetId: String, text: String)] {
            lock.lock(); defer { lock.unlock() }; return deliverCallsStorage
        }

        var interruptCalls: [String] {
            lock.lock(); defer { lock.unlock() }; return interruptCallsStorage
        }

        func makeService() -> TeamService {
            let harness = self
            let seams = TeamSeams(
                appendEvent: { sessionId, kind, payload in
                    harness.journal.append(
                        sessionId, payload: .extensionEvent(kind: kind, payload: payload))
                },
                readEvents: { harness.journal.read($0) },
                allSessionIds: { harness.journal.ids() },
                leadSteer: { rootId, text, senderId in
                    if harness.failLeadSteer {
                        throw TeamError("no loop registered", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
                    }
                    harness.lock.lock()
                    harness.leadSteerCallsStorage.append((rootId, text, senderId))
                    harness.lock.unlock()
                    // steer 后 Lead 日志落投递文本（waitForFraming 确认面）。
                    harness.journal.append(rootId, payload: .userMessage(text: text))
                },
                deliverToTeammate: { rootId, targetId, text in
                    if harness.failDeliver {
                        throw TeamError("cold resume failed", code: "TEAM_LEAD_SESSION_UNAVAILABLE")
                    }
                    harness.lock.lock()
                    harness.deliverCallsStorage.append((rootId, targetId, text))
                    harness.lock.unlock()
                    harness.journal.append(targetId, payload: .userMessage(text: text))
                },
                interruptTeammate: { childId, _ in
                    harness.lock.lock()
                    harness.interruptCallsStorage.append(childId)
                    harness.lock.unlock()
                    return true
                },
                memberStatuses: { _ in harness.statuses },
                leadStatus: { _ in "idle" },
                sessionCwd: { _ in "/var/wanwo/workspace" },
                startTeammate: { provider, request in
                    harness.lock.lock()
                    harness.nextChildCounter += 1
                    let childId = "child-\(harness.nextChildCounter)"
                    let acceptPrompt = harness.acceptPromptFlag
                    let seedDossier = harness.seedDossierFlag
                    let wrapGuidance = harness.wrapGuidanceFlag
                    harness.lock.unlock()
                    if seedDossier {
                        harness.journal.append(childId, payload: .extensionEvent(
                            kind: SubagentLineage.eventKind,
                            payload: SubagentLineage.payload(for: SubagentLineage.Record(
                                parentSession: request.parentSessionId,
                                delegationDepth: 0, seeded: false, agentPath: nil))))
                        harness.journal.append(childId, payload: .extensionEvent(
                            kind: SubagentDescriptor.eventKind,
                            payload: SubagentDescriptor.payload(for: SubagentDescriptor.Record(
                                mode: .continuable, provider: provider,
                                label: request.label, agentProvider: nil, agentModel: nil,
                                agentReasoningEffort: nil, persona: nil, toolFilter: nil))))
                    }
                    if acceptPrompt {
                        // QA-6 P0-1：wrapGuidance = 复刻生产链（guidance 后缀
                        // 追加——withContinuableReturnGuidance 原文包装）。
                        let text = wrapGuidance
                            ? SubagentRuntime.withContinuableReturnGuidance(
                                parentId: request.parentSessionId, prompt: request.prompt)
                            : request.prompt
                        harness.journal.append(childId, payload: .userMessage(text: text))
                    }
                    return SubagentRuntime.ContinuableStart(
                        childId: childId, messageId: "msg-\(childId)")
                },
                drainChild: { childId, _ in
                    harness.lock.lock()
                    harness.drainCallsStorage.append(childId)
                    harness.lock.unlock()
                    return true
                })
            return TeamService(seams: seams)
        }
    }

    // MARK: - 断言助手

    /// TeamError 稳定码断言（非 TeamError / 不抛 / 他码一律失败）。
    private func expectTeamError(code expected: String,
                                 _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected TeamError code \(expected), but no error thrown")
        } catch let error as TeamError {
            XCTAssertEqual(error.code, expected, "message: \(error.message)")
        } catch {
            XCTFail("expected TeamError \(expected), got: \(error)")
        }
    }

    /// 生成一个 active 队友（stub 缝内 prompt 已接受 → provisioning 立即 settle；
    /// promptAcceptTimeoutMs 注入快值——acceptPrompt=false 用例不等满 10s）。
    private func spawnActive(_ service: TeamService, rootId: String,
                             name: String) async throws -> TeamMemberView {
        await service.setPromptAcceptTimeoutForTesting(200)
        return try await service.spawnTeammate(
            callerSessionId: rootId, name: name, description: "worker \(name)",
            prompt: "initial prompt for \(name)", context: "fresh")
    }

    // MARK: - 名字规则（roster.ts :26 MEMBER_NAME 1:1）

    func testMemberNameValidation() {
        XCTAssertTrue(TeamValidation.isValidMemberName("researcher"))
        XCTAssertTrue(TeamValidation.isValidMemberName("code-reviewer"))
        XCTAssertTrue(TeamValidation.isValidMemberName("a"))
        XCTAssertTrue(TeamValidation.isValidMemberName(String(repeating: "a", count: 64)))
        // 拒：大写 / 前后连字符 / 连续连字符 / 下划线 / 空 / 超长 / "lead"。
        XCTAssertFalse(TeamValidation.isValidMemberName("Researcher"))
        XCTAssertFalse(TeamValidation.isValidMemberName("-lead-"))
        XCTAssertFalse(TeamValidation.isValidMemberName("a--b"))
        XCTAssertFalse(TeamValidation.isValidMemberName("code_reviewer"))
        XCTAssertFalse(TeamValidation.isValidMemberName(""))
        XCTAssertFalse(TeamValidation.isValidMemberName(String(repeating: "a", count: 65)))
        XCTAssertFalse(TeamValidation.isValidMemberName("lead"))
    }

    // MARK: - writeScope 归一化（validation.ts :26-34 1:1）

    func testWriteScopeNormalization() throws {
        XCTAssertEqual(try TeamValidation.writeScope("src/api"), "src/api")
        XCTAssertEqual(try TeamValidation.writeScope("./src/api"), "src/api")
        XCTAssertEqual(try TeamValidation.writeScope("src/api/"), "src/api")
        XCTAssertEqual(try TeamValidation.writeScope("src\\api"), "src/api")
        XCTAssertThrowsError(try TeamValidation.writeScope("/abs/path"))
        XCTAssertThrowsError(try TeamValidation.writeScope(""))
        XCTAssertThrowsError(try TeamValidation.writeScope("../escape"))
        XCTAssertThrowsError(try TeamValidation.writeScope("src//api"))
        XCTAssertThrowsError(try TeamValidation.writeScope("C:/data"))
        // 重叠：相等 / 组件前缀。
        XCTAssertTrue(TeamValidation.scopesOverlap("src/api", "src/api"))
        XCTAssertTrue(TeamValidation.scopesOverlap("src", "src/api"))
        XCTAssertTrue(TeamValidation.scopesOverlap("src/api", "src/api/auth"))
        XCTAssertFalse(TeamValidation.scopesOverlap("src/api", "src/api2"))
        XCTAssertFalse(TeamValidation.scopesOverlap("docs", "src"))
    }

    // MARK: - spawn 花名册（roster.ts spawn 状态机）

    func testSpawnProvisionsActiveMember() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        let view = try await spawnActive(service, rootId: rootId, name: "worker")
        XCTAssertEqual(view.name, "worker")
        XCTAssertEqual(view.role, "teammate")
        XCTAssertEqual(view.status, "inactive")   // active + statusMap 缺省 → inactive
        XCTAssertEqual(view.provider, "spawn")
        XCTAssertEqual(view.context, "fresh")

        // 花名册：Lead 伪行 + teammate 行（创建序）。
        let roster = try await service.listMembers(rootId)
        XCTAssertEqual(roster.count, 2)
        XCTAssertEqual(roster.first?.role, "lead")
        XCTAssertEqual(roster.last?.name, "worker")

        // 投影：provisioning→active 已 settle（journal 重放等价）。
        let state = harness.journal.projection(rootId)
        XCTAssertEqual(state.members.count, 1)
        XCTAssertEqual(state.members.first?.phase, .active)
        XCTAssertEqual(state.members.first?.id, view.id)

        // teammate 身份解析（lineage 父子 + roster active → teammate）。
        let membership = try await service.membership(view.id)
        XCTAssertEqual(membership.role, "teammate")
        XCTAssertEqual(membership.rootId, rootId)
        XCTAssertEqual(membership.name, "worker")

        // 顶层会话 = 隐式 Team 根（types.ts :7）——陌生顶层 id 解析为 lead，
        // 非 nil；无 lineage 的子 id 亦按顶层承载（dsh :107/:115 语义）。
        let stranger = try await service.tryMembership("stranger")
        XCTAssertEqual(stranger?.role, "lead")
        XCTAssertEqual(stranger?.rootId, "stranger")
    }

    func testSpawnNameRulesAndDuplicate() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        // 名字规则（TeamError.invalidMemberName）。
        await expectTeamError(code: TeamError.invalidMemberName) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "Big Bird", description: "d",
                prompt: "p", context: "fresh")
        }
        // "lead" 保留名。
        await expectTeamError(code: TeamError.invalidMemberName) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "lead", description: "d",
                prompt: "p", context: "fresh")
        }
        // 复用拒（TEAM_MEMBER_NAME_TAKEN）。
        _ = try await spawnActive(service, rootId: rootId, name: "worker")
        await expectTeamError(code: TeamError.memberNameTaken) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "worker", description: "d",
                prompt: "p", context: "fresh")
        }
    }

    func testSpawnTeammateCallerRejected() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        // teammate 调 spawn_teammate → TEAM_LEAD_REQUIRED。
        await expectTeamError(code: TeamError.leadRequired) {
            _ = try await service.spawnTeammate(
                callerSessionId: member.id, name: "nested", description: "d",
                prompt: "p", context: "fresh")
        }
    }

    // MARK: - QA-6 P0-1：guidance 后缀生产形态回归 + P1-2 预检孤儿

    /// 生产缝链复刻：startTeammate 以 withContinuableReturnGuidance 包装初始
    /// prompt 落盘（SubagentRuntime :398-422 逐字）——hasPrefix 口径下 accepted。
    func testGuidanceSuffixedPromptAccepted() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        harness.wrapGuidance = true

        let view = try await spawnActive(service, rootId: rootId, name: "worker")
        // 等值判定（旧口径）必漏——hasPrefix 口径 accepted → active settle。
        XCTAssertNotEqual(view.status, "provisioning")
        XCTAssertEqual(harness.journal.projection(rootId).members.first?.phase, .active)

        // reconcile 同口径：prompt 参照随 member 事件持久——重启重放判活。
        let fresh = harness.makeService()
        await fresh.recoverAll()
        XCTAssertEqual(harness.journal.projection(rootId).members.first?.phase, .active)
    }

    /// 非权威预检：name 复用拒绝发生在 startTeammate 之前——无孤儿活子
    ///（childCount 不变、无 drain 调用）。
    func testPrecheckPreventsOrphanChild() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        _ = try await spawnActive(service, rootId: rootId, name: "worker")

        await expectTeamError(code: TeamError.memberNameTaken) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "worker", description: "d",
                prompt: "p", context: "fresh")
        }
        XCTAssertEqual(harness.childCount, 1)   // 预检先于 start——未创建子
        XCTAssertEqual(harness.drainCalls, [])
        // maxMembers 预检同面：填满后再 spawn → 预检拒绝、未创建子。
        for index in 1..<TeamConstants.maxMembers {
            _ = try await spawnActive(service, rootId: rootId, name: "m\(index)")
        }
        await expectTeamError(code: TeamError.memberLimit) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "overflow", description: "d",
                prompt: "p", context: "fresh")
        }
        XCTAssertEqual(harness.childCount, TeamConstants.maxMembers)
        XCTAssertEqual(harness.drainCalls, [])
    }

    // MARK: - QA-6 P1-4：Lead 栈 team 通信三件 + 非 team 栈批1 版保留

    func testLeadStackInstallsTeamCommunicationTools() throws {
        let harness = TeamHarness()
        let service = harness.makeService()

        // Lead 栈：team 版 send_message/interrupt_agent/list_agents 生效
        //（dsh 作用域安装语义——描述指纹区分 team 版与批1 版）。
        let leadRegistry = ToolRegistry(presentationMode: .both)
        TeamTools.registerAll(into: leadRegistry, assembler: PromptAssembler(),
                              service: service,
                              scope: TeamTools.ScopeContext(
                                role: .lead, name: "lead", teamId: "root-1"))
        XCTAssertTrue(leadRegistry.get("send_message")?.description
            .contains("cold-resumes") ?? false)
        XCTAssertNotNil(leadRegistry.get("interrupt_agent"))
        XCTAssertNotNil(leadRegistry.get("list_agents"))
        XCTAssertTrue(leadRegistry.get("spawn_teammate")?.description
            .contains("Only the Team Lead may call") ?? false)
        XCTAssertNotNil(leadRegistry.get("team_task_update"))

        // 非 team 会话（scope nil）：TeamTools 不注册任何件——批1 同名四件
        // 由 SubagentTools.registerAll 照常生效（普通子代理栈面）。
        let plainRegistry = ToolRegistry(presentationMode: .both)
        TeamTools.registerAll(into: plainRegistry, assembler: PromptAssembler(),
                              service: service, scope: nil)
        XCTAssertNil(plainRegistry.get("send_message"))
        XCTAssertNil(plainRegistry.get("list_agents"))
        XCTAssertNil(plainRegistry.get("interrupt_agent"))
        XCTAssertNil(plainRegistry.get("spawn_teammate"))
    }

    // MARK: - QA-6 P2-1：listAgents "ready" 档词汇收敛

    func testReadyStatusNormalizesToInactive() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        harness.statuses = [member.id: "ready"]
        let roster = try await service.listMembers(rootId)
        XCTAssertEqual(roster.last?.status, "inactive")
        // 他词汇原样透传（running 不受收敛影响）。
        harness.statuses = [member.id: "running"]
        let running = try await service.listMembers(rootId)
        XCTAssertEqual(running.last?.status, "running")
    }

    func testMaxMembersCap() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        for index in 0..<TeamConstants.maxMembers {
            _ = try await spawnActive(service, rootId: rootId, name: "m\(index)")
        }
        await expectTeamError(code: TeamError.memberLimit) {
            _ = try await spawnActive(service, rootId: rootId, name: "overflow")
        }
    }

    // MARK: - 重启 reconcile（roster.ts reconcileProvisioning :392-434 1:1）

    /// 直接 seed 一行 provisioning 成员（M7-Fix E1b 后 spawn 确认超时即时
    /// failed 落账——留守行只可能来自进程崩溃窗，即 reconcile 的对象形态）。
    private func seedProvisioningMember(_ harness: TeamHarness, rootId: String,
                                        memberId: String, name: String) {
        harness.journal.append(rootId, payload: .extensionEvent(
            kind: TeamEvents.memberKind,
            payload: TeamEvents.memberPayload(teamId: rootId, member: TeamMemberSnapshot(
                id: memberId, name: name, description: "worker \(name)",
                provider: "spawn", context: "fresh", phase: .provisioning,
                error: nil, prompt: nil))))
    }

    func testReconcileResolvesProvisioningMember() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        // 崩溃窗留守行（直接 seed）+ 持久面补齐：初始 prompt userMessage
        // 事后落账（子日志已含 lineage+descriptor dossier）→ reconcile 判活。
        // CI修23：dossier 必须真种（原测试只落 userMessage——reconcile 四要件
        // lineage.parentSession==rootId + continuable descriptor + provider 匹配
        // + prompt 前缀缺前三件，恒判 failed 与注释自相矛盾）。
        let memberId = "child-stuck"
        seedProvisioningMember(harness, rootId: rootId, memberId: memberId, name: "worker")
        harness.journal.append(memberId, payload: .extensionEvent(
            kind: SubagentLineage.eventKind,
            payload: SubagentLineage.payload(for: SubagentLineage.Record(
                parentSession: rootId, delegationDepth: 0, seeded: false, agentPath: nil))))
        harness.journal.append(memberId, payload: .extensionEvent(
            kind: SubagentDescriptor.eventKind,
            payload: SubagentDescriptor.payload(for: SubagentDescriptor.Record(
                mode: .continuable, provider: "spawn", label: "team-worker",
                agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
                persona: nil, toolFilter: nil))))
        harness.journal.append(memberId,
                               payload: .userMessage(text: "initial prompt for worker"))
        await service.recoverAll()
        XCTAssertEqual(harness.journal.projection(rootId).members.first?.phase, .active)
    }

    func testReconcileFailsUnresolvableChild() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        // 崩溃窗留守行（直接 seed）；子日志无 lineage/descriptor dossier
        // → 持久判活失败 → failed 快照。
        let memberId = "child-bare"
        seedProvisioningMember(harness, rootId: rootId, memberId: memberId, name: "worker")
        harness.journal.append(memberId,
                               payload: .userMessage(text: "initial prompt for worker"))
        await service.recoverAll()
        let member = harness.journal.projection(rootId).members.first
        XCTAssertEqual(member?.phase, .failed)
        XCTAssertNotNil(member?.error)
        let roster = try await service.listMembers(rootId)
        XCTAssertEqual(roster.last?.status, "failed")
        XCTAssertEqual(roster.last?.diagnostics.isEmpty, false)
    }

    // MARK: - M7-Fix E1b：spawn 确认超时即时 failed 快照（roster.ts:289-313）

    func testSpawnPromptTimeoutJournalsFailedImmediately() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        // 确认超时窗（stub 不落初始 prompt）→ 立即 failed，不靠重启 reconcile。
        harness.acceptPrompt = false
        let view = try await spawnActive(service, rootId: rootId, name: "worker")
        XCTAssertEqual(view.status, "failed")
        let member = harness.journal.projection(rootId).members.first
        XCTAssertEqual(member?.phase, .failed)
        XCTAssertNotNil(member?.error)
        // dsh stopTeammates 等价：失败快照后 drain 活子。
        XCTAssertEqual(harness.drainCalls, [view.id])
        // 花名册渲染 failed + 诊断。
        let roster = try await service.listMembers(rootId)
        XCTAssertEqual(roster.last?.status, "failed")
        XCTAssertEqual(roster.last?.diagnostics.isEmpty, false)
    }

    // MARK: - 邮箱（mailbox.ts 三分支 + delivered 幂等 + 帽）

    func testMailboxTeammateDeliveryAccepted() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        let result = try await service.sendMessage(
            callerSessionId: rootId, target: "worker", message: "please review")
        XCTAssertEqual(result.status, "accepted")
        XCTAssertEqual(harness.deliverCalls.count, 1)
        XCTAssertEqual(harness.deliverCalls.first?.targetId, member.id)
        // 框架行（deliveryContent :309-314 逐字）。
        XCTAssertTrue(harness.deliverCalls.first!.text.hasPrefix(
            "Team message \(result.messageId) from lead:"))
        // delivered 已回写且幂等（投影重放 delivered 去重面）。
        let state = harness.journal.projection(rootId)
        XCTAssertEqual(state.delivered, [result.messageId])
        XCTAssertEqual(state.messages.count, 1)
    }

    func testMailboxLeadDeliveryAccepted() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        // teammate → lead（resolveActiveMember 'lead' 伪行 → steer 缝分支）。
        let result = try await service.sendMessage(
            callerSessionId: member.id, target: "lead", message: "task done")
        XCTAssertEqual(result.status, "accepted")
        XCTAssertEqual(harness.leadSteerCalls.count, 1)
        XCTAssertEqual(harness.leadSteerCalls.first?.senderId, member.id)
        XCTAssertTrue(harness.journal.projection(rootId).delivered.contains(result.messageId))
    }

    func testMailboxQueuedPersistsAndRecoveryRedelivers() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        _ = try await spawnActive(service, rootId: rootId, name: "worker")

        // 投递失败 → status queued（但已持久——勿重发语义）。
        harness.failDeliver = true
        var ids: [String] = []
        for index in 0..<3 {
            let result = try await service.sendMessage(
                callerSessionId: rootId, target: "worker", message: "msg \(index)")
            XCTAssertEqual(result.status, "queued")
            ids.append(result.messageId)
        }
        XCTAssertEqual(harness.journal.projection(rootId).messages.count, 3)
        XCTAssertEqual(harness.journal.projection(rootId).delivered, [])

        // 进程重启形态：全新 service 实例（缓存空 → journal 重放）+ 恢复缝修复。
        harness.failDeliver = false
        let recovered = harness.makeService()
        await recovered.recoverAll()
        let state = harness.journal.projection(rootId)
        XCTAssertEqual(state.delivered.count, 3)
        XCTAssertEqual(Set(state.delivered), Set(ids))
    }

    func testMailboxPendingCap() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        _ = try await spawnActive(service, rootId: rootId, name: "worker")

        harness.failDeliver = true
        for index in 0..<TeamConstants.maxPendingMessagesPerMember {
            _ = try await service.sendMessage(
                callerSessionId: rootId, target: "worker", message: "n\(index)")
        }
        await expectTeamError(code: TeamError.mailboxFull) {
            _ = try await service.sendMessage(
                callerSessionId: rootId, target: "worker", message: "overflow")
        }
    }

    func testMailboxMessageTooLarge() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        _ = try await spawnActive(service, rootId: rootId, name: "worker")

        let oversized = String(repeating: "a", count: TeamConstants.maxMessageBytes)
        await expectTeamError(code: TeamError.messageTooLarge) {
            _ = try await service.sendMessage(
                callerSessionId: rootId, target: "worker", message: oversized)
        }
    }

    func testMailboxSelfAndUnknownTargetRejected() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        // 自投递拒。
        await expectTeamError(code: TeamError.selfMessage) {
            _ = try await service.sendMessage(
                callerSessionId: rootId, target: "lead", message: "to myself")
        }
        // 未知目标 / 非 active 成员拒。
        await expectTeamError(code: TeamError.memberNotFound) {
            _ = try await service.sendMessage(
                callerSessionId: rootId, target: "ghost", message: "m")
        }
        // 静态解析面（provisioning 成员不可解析——resolveActiveMember :43-55）。
        let emptyState = TeamState.empty(rootId: rootId)
        XCTAssertThrowsError(try TeamService.resolveActiveMember(
            rootId: rootId, state: emptyState, rawName: "worker"))
    }

    // MARK: - CAS 任务板（task-board.ts 七 action 授权与转移矩阵）

    func testTaskLifecycleWithCAS() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        // create → task-1，revision 1，unowned pending ready。
        let created = try await service.createTask(
            callerSessionId: rootId, subject: "review pr", description: "detail",
            blockedBy: [], writeScopes: [])
        XCTAssertEqual(created.id, "task-1")
        XCTAssertEqual(created.revision, 1)
        XCTAssertEqual(created.status, .pending)
        XCTAssertEqual(created.ready, true)
        XCTAssertNil(created.ownerName)

        // 他人目标 stale revision → TEAM_TASK_STALE_REVISION。
        await expectTeamError(code: TeamError.taskStaleRevision) {
            _ = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
                taskId: "task-1", expectedRevision: 99, action: .claim,
                subject: nil, description: nil, blockedBy: nil,
                writeScopes: nil, owner: nil))
        }
        // claim（CAS revision 1）→ in_progress + owner。
        let claimed = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
            taskId: "task-1", expectedRevision: 1, action: .claim,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        XCTAssertEqual(claimed.status, .inProgress)
        XCTAssertEqual(claimed.revision, 2)
        XCTAssertEqual(claimed.ownerName, "worker")

        // 已被他人持有 → TEAM_TASK_ALREADY_CLAIMED。
        await expectTeamError(code: TeamError.taskAlreadyClaimed) {
            _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
                taskId: "task-1", expectedRevision: 2, action: .claim,
                subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        }
        // 非 owner 且非 Lead 的 edit 拒 → TEAM_TASK_UNAUTHORIZED（同队第二成员
        // helper——CAS revision 2 已达，仅授权面拦截）。
        let helper = try await spawnActive(service, rootId: rootId, name: "helper")
        await expectTeamError(code: TeamError.taskUnauthorized) {
            _ = try await service.updateTask(callerSessionId: helper.id, request: UpdateTeamTaskRequest(
                taskId: "task-1", expectedRevision: 2, action: .edit,
                subject: "x", description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        }
        // complete → completed；reopen → pending（owner 释放）。
        let completed = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
            taskId: "task-1", expectedRevision: 2, action: .complete,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        XCTAssertEqual(completed.status, .completed)
        let reopened = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
            taskId: "task-1", expectedRevision: 3, action: .reopen,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        XCTAssertEqual(reopened.status, .pending)
        XCTAssertNil(reopened.ownerName)
    }

    func testTaskDependenciesAndReadiness() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")

        let first = try await service.createTask(
            callerSessionId: rootId, subject: "a", description: "a", blockedBy: [],
            writeScopes: [])
        // blocked 任务 ready=false。
        let second = try await service.createTask(
            callerSessionId: rootId, subject: "b", description: "b",
            blockedBy: [first.id], writeScopes: [])
        XCTAssertEqual(second.ready, false)
        XCTAssertEqual(second.blockedBy, [first.id])

        // 依赖完成任务 → ready 翻转。
        _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: first.id, expectedRevision: 1, action: .claim,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: first.id, expectedRevision: 2, action: .complete,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        let ready = try await service.getTask(callerSessionId: rootId, taskId: second.id)
        XCTAssertEqual(ready.ready, true)

        // set_dependencies 自阻塞 → cycle；缺失 → not found。
        await expectTeamError(code: TeamError.taskDependencyCycle) {
            _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
                taskId: second.id, expectedRevision: 1, action: .setDependencies,
                subject: nil, description: nil, blockedBy: [second.id],
                writeScopes: nil, owner: nil))
        }
        await expectTeamError(code: TeamError.taskNotFound) {
            _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
                taskId: second.id, expectedRevision: 1, action: .setDependencies,
                subject: nil, description: nil, blockedBy: ["task-999"],
                writeScopes: nil, owner: nil))
        }
        // 有依赖人的任务不可删 → TEAM_TASK_HAS_DEPENDENTS。
        await expectTeamError(code: TeamError.taskHasDependents) {
            _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
                taskId: first.id, expectedRevision: 3, action: .delete,
                subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        }
        // 已删任务再变更加载 → TEAM_TASK_DELETED。
        _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: second.id, expectedRevision: 1, action: .delete,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        await expectTeamError(code: TeamError.taskDeleted) {
            _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
                taskId: second.id, expectedRevision: 2, action: .edit,
                subject: "x", description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        }
    }

    func testTaskAuthorizationAndReassign() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")
        let task = try await service.createTask(
            callerSessionId: rootId, subject: "t", description: "t",
            blockedBy: [], writeScopes: [])

        // reassign Lead 专用 → teammate 调用拒。
        await expectTeamError(code: TeamError.leadRequired) {
            _ = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
                taskId: task.id, expectedRevision: 1, action: .reassign,
                subject: nil, description: nil, blockedBy: nil, writeScopes: nil,
                owner: "worker"))
        }
        // Lead reassign → owner = worker（resolveActiveMember by name）。
        let assigned = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: task.id, expectedRevision: 1, action: .reassign,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: "worker"))
        XCTAssertEqual(assigned.status, .inProgress)
        XCTAssertEqual(assigned.ownerName, "worker")
        // Lead reassign 空 owner → unassign 回 pending。
        let unassigned = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: task.id, expectedRevision: 2, action: .reassign,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: ""))
        XCTAssertEqual(unassigned.status, .pending)
        XCTAssertNil(unassigned.ownerName)
    }

    func testWriteScopeWarnings() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        _ = try await spawnActive(service, rootId: rootId, name: "worker")

        // 两个 in_progress 任务写作用域重叠（组件前缀）→ 咨询性告警。
        let left = try await service.createTask(
            callerSessionId: rootId, subject: "l", description: "l",
            blockedBy: [], writeScopes: ["src/api"])
        _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: left.id, expectedRevision: 1, action: .claim,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        let right = try await service.createTask(
            callerSessionId: rootId, subject: "r", description: "r",
            blockedBy: [], writeScopes: ["src/api/auth"])
        _ = try await service.updateTask(callerSessionId: rootId, request: UpdateTeamTaskRequest(
            taskId: right.id, expectedRevision: 1, action: .claim,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        let view = try await service.getTask(callerSessionId: rootId, taskId: right.id)
        XCTAssertEqual(view.writeScopeWarnings, ["write scopes overlap with \(left.id)"])
        // 不重叠 → 无告警。
        let third = try await service.createTask(
            callerSessionId: rootId, subject: "x", description: "x",
            blockedBy: [], writeScopes: ["docs"])
        let thirdView = try await service.getTask(callerSessionId: rootId, taskId: third.id)
        XCTAssertTrue(thirdView.writeScopeWarnings.isEmpty)
    }

    func testMaxTasksCap() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        for index in 0..<TeamConstants.maxTasks {
            _ = try await service.createTask(
                callerSessionId: rootId, subject: "t\(index)", description: "d",
                blockedBy: [], writeScopes: [])
        }
        await expectTeamError(code: TeamError.taskLimit) {
            _ = try await service.createTask(
                callerSessionId: rootId, subject: "overflow", description: "d",
                blockedBy: [], writeScopes: [])
        }
    }

    // MARK: - wait / interrupt（index.ts :213-226 + roster.interrupt）

    func testWaitForChangeTimeoutValidation() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))

        await expectTeamError(code: TeamError.invalidTimeout) {
            _ = try await service.waitForChange(callerSessionId: rootId, timeoutMs: 9_999)
        }
        await expectTeamError(code: TeamError.invalidTimeout) {
            _ = try await service.waitForChange(callerSessionId: rootId,
                                                timeoutMs: TeamConstants.maxWaitTimeoutMs + 1)
        }
    }

    func testInterruptRules() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")
        harness.statuses = [member.id: "running"]

        // teammate 调 interrupt → TEAM_LEAD_REQUIRED。
        await expectTeamError(code: TeamError.leadRequired) {
            _ = try await service.interrupt(callerSessionId: member.id, targetName: "worker")
        }
        // Lead 自打断拒。
        await expectTeamError(code: TeamError.invalidTarget) {
            _ = try await service.interrupt(callerSessionId: rootId, targetName: "lead")
        }
        // Lead 打断队友 → 返回打断前状态。
        let previous = try await service.interrupt(callerSessionId: rootId, targetName: "worker")
        XCTAssertEqual(previous, "running")
        XCTAssertEqual(harness.interruptCalls, [member.id])
    }

    // MARK: - 投影重建（projection.ts 四事件规则 journal 重放）

    func testProjectionRebuildFromJournalReplay() async throws {
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        let member = try await spawnActive(service, rootId: rootId, name: "worker")
        _ = try await service.createTask(
            callerSessionId: rootId, subject: "t", description: "d",
            blockedBy: [], writeScopes: ["src"])
        _ = try await service.updateTask(callerSessionId: member.id, request: UpdateTeamTaskRequest(
            taskId: "task-1", expectedRevision: 1, action: .claim,
            subject: nil, description: nil, blockedBy: nil, writeScopes: nil, owner: nil))
        _ = try await service.sendMessage(
            callerSessionId: rootId, target: "worker", message: "hello")

        // journal 重放（全新重建）== 增量缓存态：members/tasks/messages/delivered。
        let state = harness.journal.projection(rootId)
        XCTAssertEqual(state.id, rootId)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.members.map(\.phase), [.active])
        XCTAssertEqual(state.tasks.map(\.status), [.inProgress])
        XCTAssertEqual(state.tasks.map(\.ownerId), [member.id])
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.delivered.count, 1)
        // nextTaskNumber 推进（task-1 → 2）。
        XCTAssertEqual(state.nextTaskNumber, 2)
        // 混入非 Team 事件不投影、他 teamId 事件跳过。
        var mixed = harness.journal.read(rootId)
        mixed.append(SessionEvent(seq: 9_999, timeMs: 0,
                                  payload: .extensionEvent(
                                    kind: TeamEvents.memberKind,
                                    payload: .object([
                                        "version": .int(2),
                                        "teamId": .string("other-team"),
                                        "member": TeamMemberSnapshot(
                                            id: "x", name: "x", description: "x",
                                            provider: "spawn", context: "fresh",
                                            phase: .provisioning, error: nil).encoded(),
                                    ])),
                                  ignorable: true))
        let remixed = TeamProjection.rebuildFromEvents(rootId: rootId, events: mixed)
        XCTAssertEqual(remixed.members.count, 1)
    }

    func testProjectionRejectsInvalidTransitions() {
        let rootId = "root-1"
        let member = TeamMemberSnapshot(id: "c1", name: "worker", description: "d",
                                        provider: "spawn", context: "fresh",
                                        phase: .provisioning, error: nil)
        let memberEvent = { (snapshot: TeamMemberSnapshot) in
            SessionEvent(seq: 1, timeMs: 0, payload: .extensionEvent(
                kind: TeamEvents.memberKind,
                payload: TeamEvents.memberPayload(teamId: rootId, member: snapshot)),
                ignorable: true)
        }

        // 非 provisioning 起步拒。
        var state = TeamState.empty(rootId: rootId)
        TeamProjection.apply(&state, payload: memberEvent(
            TeamMemberSnapshot(id: "c1", name: "worker", description: "d",
                               provider: "spawn", context: "fresh",
                               phase: .active, error: nil)).payload)
        XCTAssertNotNil(state.failure)

        // 不可变字段变更拒（provider 改写）。
        state = TeamState.empty(rootId: rootId)
        TeamProjection.apply(&state, payload: memberEvent(member).payload)
        XCTAssertNil(state.failure)
        TeamProjection.apply(&state, payload: memberEvent(
            TeamMemberSnapshot(id: "c1", name: "worker", description: "d",
                               provider: "fork", context: "fresh",
                               phase: .active, error: nil)).payload)
        XCTAssertNotNil(state.failure)

        // provisioning→provisioning 非法转移拒。
        state = TeamState.empty(rootId: rootId)
        TeamProjection.apply(&state, payload: memberEvent(member).payload)
        TeamProjection.apply(&state, payload: memberEvent(member).payload)
        XCTAssertNotNil(state.failure)

        // task revision 必须连续；version!=2 拒；failure 中毒后不再应用。
        state = TeamState.empty(rootId: rootId)
        let task = TeamTaskSnapshot(id: "task-1", revision: 2, subject: "s",
                                    description: "d", status: .pending, ownerId: nil,
                                    blockedBy: [], writeScopes: [])
        TeamProjection.apply(&state, payload: SessionEvent(
            seq: 1, timeMs: 0, payload: .extensionEvent(
                kind: TeamEvents.taskKind,
                payload: TeamEvents.taskPayload(teamId: rootId, task: task)),
            ignorable: true).payload)
        XCTAssertNotNil(state.failure)
        let before = state.tasks.count
        TeamProjection.apply(&state, payload: memberEvent(member).payload)
        XCTAssertEqual(state.tasks.count, before)
    }

    // MARK: - 九工具 schema 面（tool-agent-team 逐字对拍点）

    func testToolSurface() {
        let harness = TeamHarness()
        let service = harness.makeService()
        let teammateTools: [any AgentTool] = [
            TeamSpawnTeammateTool(service: service),
            TeamSendMessageTool(service: service),
            TeamListAgentsTool(service: service),
            TeamInterruptAgentTool(service: service),
            TeamTaskCreateTool(service: service),
            TeamTaskListTool(service: service),
            TeamTaskGetTool(service: service),
            TeamTaskUpdateTool(service: service),
        ]
        XCTAssertEqual(teammateTools.map(\.name), [
            "spawn_teammate", "send_message", "list_agents", "interrupt_agent",
            "team_task_create", "team_task_list", "team_task_get", "team_task_update",
        ])
        // 必填参数面（required 数组逐字）。
        func required(_ tool: any AgentTool) -> [String] {
            tool.parameters.field("required")?.arrayItems?.compactMap(\.stringValue) ?? []
        }
        XCTAssertEqual(required(teammateTools[0]), ["name", "description", "prompt"])
        XCTAssertEqual(required(teammateTools[1]), ["target", "message"])
        XCTAssertEqual(required(teammateTools[2]), [])
        XCTAssertEqual(required(teammateTools[3]), ["target"])
        XCTAssertEqual(required(teammateTools[4]), ["subject", "description"])
        XCTAssertEqual(required(teammateTools[5]), [])
        XCTAssertEqual(required(teammateTools[6]), ["task_id"])
        XCTAssertEqual(required(teammateTools[7]), ["task_id", "expected_revision", "action"])
        // 描述面非空 + dsh 关键措辞。
        XCTAssertTrue(teammateTools[0].description.contains("Only the Team Lead may call"))
        XCTAssertTrue(teammateTools[1].description.contains("cold-resumes"))
        XCTAssertTrue(teammateTools[7].description.contains("Compare-and-set"))

        // Lead 栈八件 = teammate 同一面（QA-6 P1-4 裁决：team 通信三件随行，
        // 批1 四件同名对 Lead 被遮蔽是正确的——注册序承载）。
        let leadTools: [any AgentTool] = [
            TeamSpawnTeammateTool(service: service),
            TeamSendMessageTool(service: service),
            TeamListAgentsTool(service: service),
            TeamInterruptAgentTool(service: service),
            TeamTaskCreateTool(service: service),
            TeamTaskListTool(service: service),
            TeamTaskGetTool(service: service),
            TeamTaskUpdateTool(service: service),
        ]
        XCTAssertEqual(leadTools.map(\.name), [
            "spawn_teammate", "send_message", "list_agents", "interrupt_agent",
            "team_task_create", "team_task_list", "team_task_get", "team_task_update",
        ])
    }

    // MARK: - M7-Fix E1b：schema 枚举补齐（tool-agent-team index.ts 对拍逐字）

    func testToolSchemaEnums() {
        let harness = TeamHarness()
        let service = harness.makeService()

        // spawn_teammate.context enum ['fresh','fork']（index.ts:180-183）。
        let contextEnum = TeamSpawnTeammateTool(service: service)
            .parameters.field("properties")?.field("context")?
            .field("enum")?.arrayItems?.compactMap(\.stringValue)
        XCTAssertEqual(contextEnum, ["fresh", "fork"])

        // team_task_list.status enum（index.ts:306-309——无 deleted）。
        let statusEnum = TeamTaskListTool(service: service)
            .parameters.field("properties")?.field("status")?
            .field("enum")?.arrayItems?.compactMap(\.stringValue)
        XCTAssertEqual(statusEnum, ["pending", "in_progress", "completed"])

        // team_task_update.action enum 八值逐字（index.ts:355-359）。
        let actionEnum = TeamTaskUpdateTool(service: service)
            .parameters.field("properties")?.field("action")?
            .field("enum")?.arrayItems?.compactMap(\.stringValue)
        XCTAssertEqual(actionEnum, [
            "claim", "release", "edit", "set_dependencies",
            "complete", "reopen", "reassign", "delete",
        ])
    }

    func testSpawnRejectsUnknownContext() async throws {
        // M7-Fix E1b：context 静默收敛 fresh → 显式拒绝（dsh schema 校验层
        // 等价拒绝语义）；拒绝发生在 start 之前——无孤儿活子。
        let harness = TeamHarness()
        let service = harness.makeService()
        let rootId = "root-1"
        harness.journal.append(rootId, payload: .system(note: "seed"))
        await expectTeamError(code: TeamError.invalidArgument) {
            _ = try await service.spawnTeammate(
                callerSessionId: rootId, name: "worker",
                description: "worker", prompt: "p", context: "clone")
        }
        XCTAssertEqual(harness.childCount, 0, "拒绝必须发生在 start 之前")
    }

    func testViewEncodersAndConstants() throws {
        // 视图 JSON 编码器字段保真（nil 字段省略——additionalProperties:false 面）。
        let memberJSON = teamMemberViewJSON(TeamMemberView(
            id: "c1", name: "worker", role: "teammate", status: "idle",
            description: "d", provider: "spawn", context: "fresh", model: nil,
            diagnostics: []))
        XCTAssertEqual(memberJSON.field("name")?.stringValue, "worker")
        XCTAssertEqual(memberJSON.field("role")?.stringValue, "teammate")
        XCTAssertNil(memberJSON.field("model"))
        XCTAssertEqual(memberJSON.field("diagnostics")?.arrayItems?.count, 0)

        let taskJSON = teamTaskViewJSON(TeamTaskView(
            id: "task-1", revision: 2, subject: "s", description: "d",
            status: .inProgress, blockedBy: ["task-0"], writeScopes: ["src"],
            ownerName: "worker", ready: false,
            writeScopeWarnings: ["write scopes overlap with task-0"]))
        XCTAssertEqual(taskJSON.field("status")?.stringValue, "in_progress")
        XCTAssertEqual(taskJSON.field("ownerName")?.stringValue, "worker")
        XCTAssertEqual(taskJSON.field("ready")?.boolValue, false)
        XCTAssertEqual(taskJSON.field("writeScopeWarnings")?.arrayItems?.count, 1)

        // 常量与框架行逐字（mailbox deliveryContent :309-314）。
        XCTAssertEqual(TeamConstants.maxMembers, 8)
        XCTAssertEqual(TeamConstants.maxTasks, 256)
        XCTAssertEqual(TeamConstants.maxPendingMessagesPerMember, 64)
        XCTAssertEqual(TeamConstants.maxMessageBytes, 65_536)
        XCTAssertEqual(TeamConstants.minWaitTimeoutMs, 10_000)
        XCTAssertEqual(TeamConstants.maxWaitTimeoutMs, 3_600_000)
        XCTAssertEqual(TeamConstants.memberLabelPrefix, "team-member:")
        let message = TeamMessageSnapshot(id: "team-message-abc", senderId: "root-1",
                                          senderName: "lead", targetId: "c1",
                                          content: "body")
        XCTAssertEqual(TeamConstants.deliveryFrame(messageId: message.id,
                                                   senderName: message.senderName),
                       "Team message team-message-abc from lead:")
        XCTAssertEqual(TeamService.deliveryContent(message),
                       "Team message team-message-abc from lead:\nbody")
        XCTAssertTrue(TeamService.targetRecorded(
            events: [SessionEvent(seq: 1, timeMs: 0,
                                  payload: .userMessage(
                                    text: "Team message team-message-abc from lead:\nbody"),
                                  ignorable: false)],
            message: message))
        // numericTaskNumber（projection.ts :26 正则语义）。
        XCTAssertEqual(TeamProjection.numericTaskNumber("task-41"), 41)
        XCTAssertNil(TeamProjection.numericTaskNumber("task-x"))
        XCTAssertNil(TeamProjection.numericTaskNumber("other-1"))
    }
}
