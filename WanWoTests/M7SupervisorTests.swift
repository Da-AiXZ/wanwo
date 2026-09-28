//
//  M7SupervisorTests.swift
//  WanWoTests
//
//  【M7.3 件 H · F050 单测】Supervisor 治理+持久化+恢复层（派单落点⑦断言面）：
//    - 边表 upsert/status 流转（local.rs:158-245 对拍：status 过滤 + 缺 child
//      no-op + child 至多一父）。
//    - 恢复树重建（Open 边；local.rs:248-343 对拍：BFS 逐层 + 层内升序 +
//      过滤作用于沿途每条边）。
//    - path 解析（agent_path.rs tests 对拍：合法 join/resolve、禁 ..、非法名）。
//    - 上限 CAS 拒绝（registry.rs AgentLimitReached 等价——第 4 个驻留子拒绝；
//      失败启动回收 / close_agent 回收后可再启）。
//    - 执行槽占用-释放（SubagentStartGate 收编信号量）。
//    - close_agent 置 Closed / 会话正常关闭（drain）不置 Closed
//     （legacy.rs:5-7 崩溃恢复依据）。
//    - 恢复树重建 + 惰性重挂（cold resume 台账偿还；listAgents ready/idle）。
//    - wait 超时/活动唤醒（wait.rs from_outcome 语义 + AgentLoop 等待缝）。
//

import XCTest
@testable import WanWo

final class M7SupervisorTests: XCTestCase {

    /// Sendable harness 盒（@Sendable 闭包只捕获它，不捕获 XCTestCase）。
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var dirs: [URL] = []

        func addDir(_ url: URL) {
            lock.lock(); dirs.append(url); lock.unlock()
        }

        func allDirs() -> [URL] {
            lock.lock(); defer { lock.unlock() }; return dirs
        }

        /// 最小 writer（M7 族同款 harness）。
        func makeWriter(id: String) async throws -> (SessionWriter, URL) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-m7sup-\(id)-\(UUID().uuidString)",
                                         isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            addDir(dir)
            let header = SessionHeader(
                id: id,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                cwd: nil)
            let log = try JsonlEventLog.create(
                header: header, at: dir.appendingPathComponent("session.jsonl"))
            let database = try SessionDatabase(
                path: dir.appendingPathComponent("index.sqlite3").path)
            let writer = try await SessionWriter(id: header.id, header: header,
                                                 log: log, database: database)
            return (writer, dir)
        }

        /// 最小 AgentLoop（依赖面全为测试构造；makeAdapter 恒抛 = 回合快速失败）。
        func makeLoop(sessionId: String, writer: SessionWriter) -> AgentLoop {
            let registry = ToolRegistry()
            let pipeline = ToolPipeline(registry: registry,
                                        repeatAdviser: RepeatCallAdviser())
            return AgentLoop(deps: AgentLoop.Dependencies(
                sessionId: sessionId,
                writer: writer,
                assembler: PromptAssembler(),
                registry: registry,
                pipeline: pipeline,
                compactor: Compactor(policy: .init()) {
                    throw LLMError(message: "unused", code: "TEST")
                },
                spill: SpillStore(root: FileManager.default.temporaryDirectory),
                injector: ContextInjector(),
                makeAdapter: { throw LLMError(message: "unused", code: "TEST") },
                callbacks: .init(),
                sandboxModeProvider: { .workspaceWrite },
                escalationApprover: nil))
        }

        /// 临时 GRDB 边表库。
        func makeEdgeDatabase() throws -> SessionDatabase {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-m7sup-db-\(UUID().uuidString)",
                                         isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            addDir(dir)
            return try SessionDatabase(
                path: dir.appendingPathComponent("index.sqlite3").path)
        }

        /// continuable 启动 ×N 的 materializer（每子一份独立 writer+loop）。
        func makeMaterializer() -> SubagentRuntime.ChildMaterializer {
            return { resolved, _, _ in
                let (writer, _) = try await self.makeWriter(id: resolved.childId)
                let loop = self.makeLoop(sessionId: resolved.childId, writer: writer)
                return (loop, writer)
            }
        }

        /// startContinuable 用 provider（QA-4 P0-2：startContinuable 的
        /// provider guard 先于上限/path 检查，缺注册即 PROVIDER_NOT_FOUND；
        /// continuable 路径不调 childFactory，seedFor 对空父日志返回 nil 种子
        /// ——工厂恒返 unused run 即可，照 M7SubagentTests.swift:240 形态）。
        func makeForkProvider() -> ForkInProcessProvider {
            return ForkInProcessProvider(name: "fork", childFactory: { resolved, _ in
                SubagentRun(id: resolved.childId,
                            result: Task<SubagentResult, Error> {
                    SubagentResult(output: "unused", structured: nil,
                                   diagnostic: nil, stopReason: .completed)
                }) {}
            })
        }

        /// 可控闸（QA-4 P1-2 占跑构造）：open 前 hold 挂起并置 held 旗标。
        /// 适配器阻塞点在 runTurn 首步 claim inbox **之后**，故 held == true
        /// 即为"nextTurnInbox 已被驱动器 claim 清空"的确定性信号。
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuations: [CheckedContinuation<Void, Never>] = []
            private var opened = false
            private var held = false

            var isHeld: Bool {
                lock.lock(); defer { lock.unlock() }; return held
            }

            func hold() async {
                await withCheckedContinuation {
                    (cont: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if opened {
                        lock.unlock()
                        cont.resume()
                        return
                    }
                    held = true
                    continuations.append(cont)
                    lock.unlock()
                }
            }

            func open() {
                lock.lock(); opened = true
                let resumed = continuations
                continuations = []
                lock.unlock()
                for cont in resumed { cont.resume() }
            }
        }

        /// 占跑 loop（QA-4 P1-2"不经 wake 的构造"）：驱动器卡在 gated 适配器
        /// 处（phase = .running）——此后 followup/submit 的 wake() 命中
        /// `guard case .idle`（AgentLoop.swift:545）为 no-op，条目仅排队 +
        /// notifyActivity 发射，pending 检查确定性立返（wait.rs:190-197）。
        func makeGatedLoop(sessionId: String, writer: SessionWriter)
            -> (loop: AgentLoop, gate: Gate) {
            let gate = Gate()
            let registry = ToolRegistry()
            let pipeline = ToolPipeline(registry: registry,
                                        repeatAdviser: RepeatCallAdviser())
            let loop = AgentLoop(deps: AgentLoop.Dependencies(
                sessionId: sessionId,
                writer: writer,
                assembler: PromptAssembler(),
                registry: registry,
                pipeline: pipeline,
                compactor: Compactor(policy: .init()) {
                    throw LLMError(message: "unused", code: "TEST")
                },
                spill: SpillStore(root: FileManager.default.temporaryDirectory),
                injector: ContextInjector(),
                makeAdapter: {
                    await gate.hold()
                    throw LLMError(message: "gated adapter released", code: "TEST")
                },
                callbacks: .init(),
                sandboxModeProvider: { .workspaceWrite },
                escalationApprover: nil))
            return (loop, gate)
        }
    }

    override func setUp() {
        super.setUp()
        // lineage/descriptor extensionEvent 写入前置（注册幂等）。
        SubagentEvents.register()
        harness = Harness()
    }

    override func tearDown() {
        for dir in harness.allDirs() {
            try? FileManager.default.removeItem(at: dir)
        }
        harness = Harness()
        super.tearDown()
    }

    private var harness = Harness()

    // MARK: - 边表 upsert / status 流转（local.rs:158-245 对拍）

    func testEdgeStatusWireNames() {
        // types.rs serde snake_case 1:1。
        XCTAssertEqual(ThreadSpawnEdgeStatus.open.rawValue, "open")
        XCTAssertEqual(ThreadSpawnEdgeStatus.closed.rawValue, "closed")
    }

    func testEdgeStoreUpsertsAndListsChildrenWithStatusFilters() throws {
        let database = try harness.makeEdgeDatabase()
        try database.upsertThreadSpawnEdge(parent: "p", child: "c2", status: .closed)
        try database.upsertThreadSpawnEdge(parent: "p", child: "c1", status: .open)

        // 全量（稳定排序：childThreadId 升序——local.rs 稳定排序契约）。
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: nil),
                       ["c1", "c2"])
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: .open),
                       ["c1"])
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: .closed),
                       ["c2"])
        // 未知父 = 空。
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "ghost",
                                                            statusFilter: nil),
                       [])
    }

    func testEdgeStoreSetStatusIsNoOpForMissingChild() throws {
        let database = try harness.makeEdgeDatabase()
        // 缺 child = 成功 no-op（store.rs:32-36 契约）。
        try database.setThreadSpawnEdgeStatus(child: "ghost", status: .closed)
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: nil), [])

        try database.upsertThreadSpawnEdge(parent: "p", child: "c1", status: .open)
        try database.setThreadSpawnEdgeStatus(child: "c1", status: .closed)
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: .open), [])
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p",
                                                            statusFilter: .closed),
                       ["c1"])
    }

    func testEdgeStoreReplacesParentOnUpsert() throws {
        let database = try harness.makeEdgeDatabase()
        // child 至多一父：重插同 child 替换 parent + status（store.rs:22-27）。
        try database.upsertThreadSpawnEdge(parent: "p1", child: "c1", status: .open)
        try database.upsertThreadSpawnEdge(parent: "p2", child: "c1", status: .closed)
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p1",
                                                            statusFilter: nil), [])
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "p2",
                                                            statusFilter: .closed),
                       ["c1"])
    }

    // MARK: - 恢复树重建（local.rs:248-343 对拍）

    func testEdgeStoreDescendantsBreadthFirstWithStatusFilters() throws {
        // local.rs 测试 3 的边集 1:1（数字 id 模拟 thread id 排序）。
        let database = try harness.makeEdgeDatabase()
        let root = "20"
        let edges: [(String, String, ThreadSpawnEdgeStatus)] = [
            (root, "22", .open),      // later_child
            (root, "21", .open),      // earlier_child
            ("21", "24", .open),      // open_grandchild
            ("22", "23", .closed),    // closed_grandchild
            (root, "25", .closed),    // closed_child
            ("25", "26", .closed),    // closed_great_grandchild
        ]
        for (parent, child, status) in edges {
            try database.upsertThreadSpawnEdge(parent: parent, child: child,
                                               status: status)
        }
        // 全量：逐层广度优先，层内按 thread id 升序。
        XCTAssertEqual(try database.listThreadSpawnDescendants(root: root,
                                                               statusFilter: nil),
                       ["21", "22", "25", "23", "24", "26"])
        // Open：过滤作用于沿途每条边（Closed 边之下 Open 后代不可达）。
        XCTAssertEqual(try database.listThreadSpawnDescendants(root: root,
                                                               statusFilter: .open),
                       ["21", "22", "24"])
        XCTAssertEqual(try database.listThreadSpawnDescendants(root: root,
                                                               statusFilter: .closed),
                       ["25", "26"])
    }

    // MARK: - AgentPath（agent_path.rs tests 对拍）

    func testAgentPathRootHasExpectedName() {
        let root = AgentPath.root()
        XCTAssertEqual(root.value, AgentPath.ROOT)
        XCTAssertEqual(root.name(), "root")
        XCTAssertTrue(root.isRoot())
    }

    func testAgentPathJoinBuildsChildPaths() throws {
        let child = try AgentPath.root().join("researcher")
        XCTAssertEqual(child.value, "/root/researcher")
        XCTAssertEqual(child.name(), "researcher")
    }

    func testAgentPathResolveSupportsRelativeAndAbsoluteReferences() throws {
        let current = try AgentPath(from: "/root/researcher")
        XCTAssertEqual(try current.resolve("worker").value, "/root/researcher/worker")
        XCTAssertEqual(try current.resolve("/root/other").value, "/root/other")
        XCTAssertEqual(try current.resolve(AgentPath.ROOT).value, AgentPath.ROOT)
    }

    func testAgentPathInvalidNamesAndPathsAreRejected() {
        // 非法字符名（agent_path.rs tests 1:1）。
        XCTAssertThrowsError(try AgentPath.root().join("BadName")) { error in
            XCTAssertEqual((error as? SubagentError)?.message,
                           "agent_name must use only lowercase letters, digits, and underscores")
        }
        // 非 /root 前缀绝对路径。
        XCTAssertThrowsError(try AgentPath.fromString("/not-root")) { error in
            XCTAssertEqual((error as? SubagentError)?.message,
                           "absolute agent paths must start with `/root` or be `/morpheus`")
        }
        // 禁 .. 上行（段校验拒绝）。
        XCTAssertThrowsError(try AgentPath.root().resolve("../sibling")) { error in
            XCTAssertEqual((error as? SubagentError)?.message,
                           "agent_name `..` is reserved")
        }
        // 空引用。
        XCTAssertThrowsError(try AgentPath.root().resolve(""))
        // 保留名 root。
        XCTAssertThrowsError(try AgentPath.root().join("root"))
    }

    // MARK: - 上限 CAS 拒绝（registry.rs AgentLimitReached 等价）

    func testContinuableTotalCapRejectsFourthChild() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())  // QA-4 P0-2
        // close_agent 的 Closed 置位需要边表宿主（缺 edgeStore 时恒返回
        // false——SubagentRuntime.closeAgent 的 `guard let edgeStore else
        // { return false }` 收尾面）。
        let database = try harness.makeEdgeDatabase()
        await runtime.registerEdgeStore(database)
        await runtime.registerChildMaterializer(harness.makeMaterializer())
        var started: [SubagentRuntime.ContinuableStart] = []
        for index in 0..<SubagentGovernance.totalChildrenLimit {
            started.append(try await runtime.startContinuable(
                provider: "fork",
                request: SubagentStartRequest(
                    label: "worker\(index)", prompt: "p",
                    parentSessionId: "root", parentCwd: nil, parentDepth: 0)))
        }
        XCTAssertEqual(started.count, SubagentGovernance.totalChildrenLimit)
        do {
            _ = try await runtime.startContinuable(
                provider: "fork",
                request: SubagentStartRequest(
                    label: "overflow", prompt: "p",
                    parentSessionId: "root", parentCwd: nil, parentDepth: 0))
            XCTFail("第 \(SubagentGovernance.totalChildrenLimit + 1) 个驻留子必须 AGENT_LIMIT_REACHED")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "AGENT_LIMIT_REACHED")
        }
        // close_agent 释放计数后可再启（registry.rs release_spawned_thread 回收）。
        let closed = try await runtime.closeAgent(
            childId: started[0].childId, callerSessionId: "root")
        XCTAssertTrue(closed)
        _ = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(
                label: "refill", prompt: "p",
                parentSessionId: "root", parentCwd: nil, parentDepth: 0))
    }

    func testFailedContinuableStartReleasesGovernanceSlot() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())  // QA-4 P0-2
        // 物化器恒抛 = 启动失败（registry.rs SpawnReservation Drop :393-402 回收）。
        await runtime.registerChildMaterializer { _, _, _ in
            throw SubagentError(message: "materialize failed")
        }
        do {
            _ = try await runtime.startContinuable(
                provider: "fork",
                request: SubagentStartRequest(
                    label: "doomed", prompt: "p",
                    parentSessionId: "root", parentCwd: nil, parentDepth: 0))
            XCTFail("物化失败必须上抛")
        } catch { /* 预期 */ }
        // 失败回收 → 上限额度的驻留子仍可启动。
        await runtime.registerChildMaterializer(harness.makeMaterializer())
        _ = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(
                label: "ok", prompt: "p",
                parentSessionId: "root", parentCwd: nil, parentDepth: 0))
    }

    // MARK: - close_agent 置 Closed / drain 不置（legacy.rs:5-7 崩溃恢复依据）

    func testCloseAgentPersistsClosedEdgeAndDrainLeavesOpen() async throws {
        let database = try harness.makeEdgeDatabase()
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())  // QA-4 P0-2
        await runtime.registerEdgeStore(database)
        await runtime.registerChildMaterializer(harness.makeMaterializer())

        let child = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(
                label: "worker", prompt: "p",
                parentSessionId: "root", parentCwd: nil, parentDepth: 0))
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "root",
                                                            statusFilter: .open),
                       [child.childId], "spawn 成功 upsert Open")
        XCTAssertEqual(try database.listThreadSpawnDescendants(root: "root",
                                                               statusFilter: .open),
                       [child.childId])

        // 非直接父关闭 = UNAUTHORIZED。
        do {
            _ = try await runtime.closeAgent(childId: child.childId,
                                             callerSessionId: "not-the-parent")
            XCTFail("close 需祖先授权")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "UNAUTHORIZED")
        }

        let closed = try await runtime.closeAgent(childId: child.childId,
                                                  callerSessionId: "root")
        XCTAssertTrue(closed)
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "root",
                                                            statusFilter: .open),
                       [], "close_agent 置 Closed")
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "root",
                                                            statusFilter: .closed),
                       [child.childId])

        // drain（宿主 shutdown 等价）不置 Closed：再启一子后 drain，边仍 Open。
        let child2 = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(
                label: "worker2", prompt: "p",
                parentSessionId: "root", parentCwd: nil, parentDepth: 0))
        await runtime.drainChildren(of: "root")
        XCTAssertEqual(try database.listThreadSpawnChildren(parent: "root",
                                                            statusFilter: .open),
                       [child2.childId], "shutdown 不置 Closed = 崩溃恢复依据")
    }

    // MARK: - 恢复树重建 + 惰性重挂（cold resume 台账偿还）

    func testRecoveryRestoresOpenTreeAndRemountsOnDemand() async throws {
        let database = try harness.makeEdgeDatabase()
        // 崩溃现场：子会话日志已带 lineage（含 agentPath）+ descriptor；边表
        // Open；runtime 内存全空（新进程等价）。
        let childId = "child-1"
        let (childWriter, _) = try await harness.makeWriter(id: childId)
        _ = try await childWriter.append(.extensionEvent(
            kind: SubagentLineage.eventKind,
            payload: SubagentLineage.payload(for: .init(
                parentSession: "root", delegationDepth: 1, seeded: false,
                agentPath: "/root/worker"))))
        _ = try await childWriter.append(.extensionEvent(
            kind: SubagentDescriptor.eventKind,
            payload: SubagentDescriptor.payload(for: .init(
                mode: .continuable, provider: "fork", label: "worker",
                agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
                persona: nil, toolFilter: nil))))
        try database.upsertThreadSpawnEdge(parent: "root", child: childId,
                                           status: .open)

        let runtime = SubagentRuntime()
        await runtime.registerEdgeStore(database)
        await runtime.registerChildMetadataReader { [harness, childWriter] id in
            let events = id == childId ? childWriter.events : childWriter.events
            guard let lineage = SubagentLineage.read(events: events) else {
                throw SubagentError(message: "no lineage",
                                    code: "RECOVERY_METADATA_INVALID")
            }
            return (lineage, SubagentDescriptor.fold(events: events))
        }
        let remounted = RemountBox()
        await runtime.registerRecoveryMaterializer { [harness, childWriter, remounted] id, onTurnEnd in
            XCTAssertEqual(id, childId)
            let loop = harness.makeLoop(sessionId: id, writer: childWriter)
            remounted.note(loop: loop, writer: childWriter)
            return (loop, childWriter)
        }

        // 崩溃恢复登记（Open 边 → pendingRecovery——listAgents ready 档的
        // 数据源；生产路径由宿主会话打开时调用 recoverOpenChildren，缺此步
        // 则恢复登记为空、sendMessage 惰性重挂无目标可命中）。
        _ = await runtime.recoverOpenChildren(rootSessionId: "root")

        // 恢复登记 = ready（ListAgentsTool 文案承诺的第三档）；path 取自
        // lineage 持久权威。
        var listings = await runtime.listAgents(callerSessionId: "root",
                                                includeDescendants: false)
        XCTAssertEqual(listings.map(\.status), ["ready"])
        XCTAssertEqual(listings.map(\.label), ["worker"])

        // sendMessage（path 寻址命中）→ 惰性重挂 → 投递成功。
        let messageId = try await runtime.sendMessage(
            from: "root", to: "/root/worker", text: "continue")
        XCTAssertFalse(messageId.isEmpty)
        XCTAssertTrue(remounted.loop != nil, "重挂必须发生")

        // 重挂后 = idle（phase 查询缝）——先等子 loop 收敛（followup 触发的
        // 回合在测试适配器下快速失败），避免 running 瞬态误报。
        if let remountedLoop = remounted.loop {
            await remountedLoop.whenIdle()
        }
        listings = await runtime.listAgents(callerSessionId: "root",
                                            includeDescendants: false)
        XCTAssertEqual(listings.map(\.status), ["idle"])

        // 重复恢复幂等（已驻留不重复登记）。
        let restored = await runtime.recoverOpenChildren(rootSessionId: "root")
        XCTAssertTrue(restored.isEmpty, "已重挂子不重复登记")
    }

    /// 重挂发生盒（@Sendable 闭包共享）。
    private final class RemountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLoop: AgentLoop?
        private var storedWriter: SessionWriter?
        func note(loop: AgentLoop, writer: SessionWriter) {
            lock.lock()
            storedLoop = loop
            storedWriter = writer
            lock.unlock()
        }
        var loop: AgentLoop? {
            lock.lock(); defer { lock.unlock() }; return storedLoop
        }
        var writer: SessionWriter? {
            lock.lock(); defer { lock.unlock() }; return storedWriter
        }
    }

    // MARK: - 执行槽占用-释放（SubagentStartGate 收编信号量）

    func testExecutionGateOccupancyAndRelease() async throws {
        let gate = SubagentStartGate(limit: 2)
        await gate.acquire()
        await gate.acquire()
        // 第三/四路等待（active<max 才启——execution.rs:81-83 has_capacity）。
        let third = Task { await gate.acquire() }
        let fourth = Task { await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release() // 一路放行（先到先得）。
        await third.value
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.release()
        await fourth.value
        gate.release()
        gate.release()
    }

    // MARK: - wait 超时 / 活动唤醒（wait.rs from_outcome 语义）

    func testWaitTimesOutWithNilOutcome() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wait-timeout")
        let loop = harness.makeLoop(sessionId: "wait-timeout", writer: writer)
        let startedAt = Date()
        let outcome = await loop.waitForInboxActivity(timeoutMs: 80)
        XCTAssertNil(outcome, "无活动 → TimedOut（wait.rs:203）")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.075)
    }

    func testWaitReturnsPendingSteerImmediately() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wait-pending")
        let loop = harness.makeLoop(sessionId: "wait-pending", writer: writer)
        // pending 语义（wait.rs:190-197）：已排队条目立即返回。
        await loop.inject("system note", source: .system)
        let outcome = await loop.waitForInboxActivity(timeoutMs: 5_000)
        XCTAssertEqual(outcome, .steer)
    }

    func testWaitReturnsPendingMailboxImmediately() async throws {
        // QA-4 P1-2 竞态修复：原实现 followup 先行——wake() 派生驱动器，
        // runTurn 首步 claim 整个 nextTurnInbox（AgentLoop.swift:692-695），
        // 与本测试的 pending 检查先到先消费（驱动器收敛回放后队列已空，
        // 断言偶发 nil + 5s 慢路径）。改占跑构造：驱动器卡在 gated 适配器
        // 处（claim 已发生），followup 仅排队 + 发射——pending 检查确定性
        // 立返 .mailbox（wait.rs:190-197 已排队条目立即返回）。
        let (writer, _) = try await harness.makeWriter(id: "wait-pending-mb")
        let (loop, gate) = harness.makeGatedLoop(sessionId: "wait-pending-mb",
                                                 writer: writer)
        await loop.submit("占跑 kick（被 gated 适配器阻塞）")
        // 确定性等待 claim 完成：适配器阻塞点在首步 claim 之后。
        let deadline = Date().addingTimeInterval(5)
        while !gate.isHeld && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(gate.isHeld, "驱动器应已在 gated 适配器处阻塞（claim 已发生）")

        await loop.followup("settlement notice", source: .subagentSettled(
            childId: "c", stopReason: "completed"))
        let outcome = await loop.waitForInboxActivity(timeoutMs: 5_000)
        XCTAssertEqual(outcome, .mailbox)

        gate.open()  // 放行驱动器：适配器抛出 → kick 空转收敛（回放队列已空）。
        await loop.whenIdle()
    }

    func testWaitWakesOnFollowupArrival() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wait-wake")
        let loop = harness.makeLoop(sessionId: "wait-wake", writer: writer)
        let waiter = Task { await loop.waitForInboxActivity(timeoutMs: 5_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await loop.followup("子结算通知", source: .subagentSettled(
            childId: "c", stopReason: "completed"))
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .mailbox, "watch 通道唤醒——不轮询（wait.rs MailboxActivity）")
    }

    func testWaitWakesOnSteerArrival() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wait-steer")
        let loop = harness.makeLoop(sessionId: "wait-steer", writer: writer)
        let waiter = Task { await loop.waitForInboxActivity(timeoutMs: 5_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await loop.steer("用户打断")
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .steer, "Steered（wait.rs:196）")
    }

    func testWaitAgentToolClampAndMessages() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wait-tool")
        // QA-4 P1-2：缺省段改占跑构造——原实现 followup 先行经 wake() 派生
        // 驱动器，runTurn 首步 claim 与工具内 pending 检查先到先消费。gated
        // loop 未 submit 前无驱动器（夹取段语义等同普通 loop）。
        let (loop, gate) = harness.makeGatedLoop(sessionId: "wait-tool",
                                                 writer: writer)
        let tool = WaitAgentTool(parentLoop: loop)
        let ctx = ToolExecutionContext(
            sessionId: "wait-tool", turn: 0, step: 0, callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "wait-tool"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: nil)

        // >max → RespondToModel 等价拒绝（wait.rs:58-61）。
        let tooLarge = try await tool.execute(
            .object(["timeout_ms":
                        .int(Int(SubagentGovernance.maxWaitTimeoutMs) + 1)]), ctx)
        XCTAssertTrue(tooLarge.isError, "超上限必须拒绝")
        XCTAssertEqual(tooLarge.errorCode, "WAIT_TIMEOUT_INVALID")
        XCTAssertTrue(tooLarge.text.contains("timeout_ms must be at most "
            + "\(SubagentGovernance.maxWaitTimeoutMs)"))

        // <min → 上夹 + 夹取提示（wait.rs:63 + :149-154）。
        let clamped = try await tool.execute(.object(["timeout_ms": .int(1)]), ctx)
        XCTAssertFalse(clamped.isError, "夹取路径应成功返回")
        XCTAssertTrue(clamped.text.contains("Wait timed out."), "1ms 必超时")
        XCTAssertTrue(clamped.text.contains("Requested timeout of 1ms was clamped to "
            + "the minimum of \(SubagentGovernance.minWaitTimeoutMs)ms."))

        // 缺省（无参数）→ default 30s（测试以 pending 活动提前返回校验通路；
        // QA-4 P1-2：占跑期 followup 不经 wake 派生消费——mailbox 确定性）。
        await loop.submit("占跑 kick（被 gated 适配器阻塞）")
        let claimDeadline = Date().addingTimeInterval(5)
        while !gate.isHeld && Date() < claimDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(gate.isHeld, "驱动器应已在 gated 适配器处阻塞（claim 已发生）")
        await loop.followup("notice", source: .system)
        let defaulted = try await tool.execute(.object([:]), ctx)
        XCTAssertFalse(defaulted.isError, "缺省路径应成功返回")
        XCTAssertTrue(defaulted.text.hasPrefix("Wait completed."))

        gate.open()  // 放行驱动器收敛（回放队列消费后 idle）。
        await loop.whenIdle()
    }
}
