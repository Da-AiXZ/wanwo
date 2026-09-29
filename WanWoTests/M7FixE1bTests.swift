//
//  M7FixE1bTests.swift
//  WanWoTests
//
//  【M7-Fix E1b · 修复批单测】dsh 语义对拍断言点（逐项对应 e1b-report.md）：
//    - 任务1 P0：SessionStore.liveWriter 只读查询缝——命中复用/未命中 nil；
//      openWriter 排他挤占前提实证（第二次 open 换新 writer）。
//    - 任务2：sendMessage 运行中 → steer（nextStepInbox，wait .steer）；
//      空闲 → followup（新回合，userMessage 落盘）。
//    - 任务3：interrupt 祖链 transitive 授权（dsh continuation-activation.ts
//      :255-289：活祖链命中 / 自打断拒 / 非祖先拒）。
//    - 任务4：sendMessage 跨代寻址拒绝（直接子白名单）；直接父路由
//      （deliverFromSubagent 包装文案落父日志）。
//    - 任务5：listAgents 持久边表权威——parentSessionId 真实父 + 不可读子
//      diagnostic（corrupt）形态（dsh list-agents.ts:30-45/:66-85）。
//    - 任务8：WorkflowEventRecorder 四事件（tool-workflow/run-start|agent-start|
//      agent-end|run-end）顺序落日志 + 载荷字段对照 payload-validation.ts
//      :233-250 + 无活跃 run 跳过（active.delete 语义）。
//  （任务6/7 Team 面断言在 M7TeamTests.swift；任务1 装配面闭包在
//  AppEnvironment——本文件覆盖可独立构造的缝语义。）
//

import XCTest
@testable import WanWo

final class M7FixE1bTests: XCTestCase {

    // MARK: - 测试基建（M7SupervisorTests 同款 harness 形态）

    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var dirs: [URL] = []

        func addDir(_ url: URL) {
            lock.lock(); dirs.append(url); lock.unlock()
        }

        func allDirs() -> [URL] {
            lock.lock(); defer { lock.unlock() }; return dirs
        }

        func makeDirectory(_ prefix: String) throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)",
                                         isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            addDir(dir)
            return dir
        }

        /// 最小 writer（+ 独立 SessionDatabase——SessionStore 复用）。
        func makeWriter(id: String) async throws -> (SessionWriter, URL) {
            let dir = try makeDirectory("wanwo-e1b-\(id)")
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

        /// 最小 AgentLoop（适配器恒抛 = 回合快速失败收敛）。
        func makeLoop(sessionId: String, writer: SessionWriter) -> AgentLoop {
            AgentLoop(deps: Self.loopDeps(sessionId: sessionId, writer: writer,
                                          makeAdapter: {
                throw LLMError(message: "unused", code: "TEST")
            }))
        }

        /// 占跑 loop（初始 prompt claim 后驱动器卡在 gated 适配器——running）。
        func makeGatedLoop(sessionId: String, writer: SessionWriter)
            -> (loop: AgentLoop, gate: Gate) {
            let gate = Gate()
            let loop = AgentLoop(deps: Self.loopDeps(sessionId: sessionId, writer: writer,
                                                     makeAdapter: {
                await gate.hold()
                throw LLMError(message: "gated adapter released", code: "TEST")
            }))
            return (loop, gate)
        }

        private static func loopDeps(
            sessionId: String, writer: SessionWriter,
            makeAdapter: @escaping @Sendable () async throws -> OpenAICompatAdapter
        ) -> AgentLoop.Dependencies {
            let registry = ToolRegistry()
            let pipeline = ToolPipeline(registry: registry,
                                        repeatAdviser: RepeatCallAdviser())
            return AgentLoop.Dependencies(
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
                makeAdapter: makeAdapter,
                callbacks: .init(),
                sandboxModeProvider: { .workspaceWrite },
                escalationApprover: nil)
        }

        func makeEdgeDatabase() throws -> SessionDatabase {
            let dir = try makeDirectory("wanwo-e1b-db")
            return try SessionDatabase(
                path: dir.appendingPathComponent("index.sqlite3").path)
        }

        /// continuable 启动 materializer（每子一份独立 writer+loop；M7Supervisor
        /// makeMaterializer 同款）。
        func makeMaterializer() -> SubagentRuntime.ChildMaterializer {
            return { resolved, _, _ in
                let (writer, _) = try await self.makeWriter(id: resolved.childId)
                let loop = self.makeLoop(sessionId: resolved.childId, writer: writer)
                return (loop, writer)
            }
        }

        /// continuable 路径不调 childFactory——工厂恒返 unused run 即可。
        func makeForkProvider() -> ForkInProcessProvider {
            return ForkInProcessProvider(name: "fork", childFactory: { resolved, _ in
                SubagentRun(id: resolved.childId,
                            result: Task<SubagentResult, Error> {
                    SubagentResult(output: "unused", structured: nil,
                                   diagnostic: nil, stopReason: .completed)
                }) {}
            })
        }

        /// 可控闸（M7SupervisorTests Gate 同款）。
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
    }

    private var harness = Harness()

    override func setUp() {
        super.setUp()
        // lineage/descriptor/tool-workflow extensionEvent 写入前置（注册幂等）。
        SubagentEvents.register()
        WorkflowRecordEvents.registerEventSchemas()
        harness = Harness()
    }

    override func tearDown() {
        for dir in harness.allDirs() {
            try? FileManager.default.removeItem(at: dir)
        }
        harness = Harness()
        super.tearDown()
    }

    /// 轮询至条件命中或超时（异步追加链收敛面）。
    private func waitUntil(_ condition: () -> Bool, timeoutMs: Int = 5_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 注册 fork provider + materializer 的 runtime。
    private func makeRuntime(materializer: SubagentRuntime.ChildMaterializer? = nil)
        async -> SubagentRuntime {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())
        await runtime.registerChildMaterializer(materializer ?? harness.makeMaterializer())
        return runtime
    }

    // MARK: - 任务1：SessionStore.liveWriter 只读查询缝

    func testLiveWriterReturnsOpenWriterAndNilAfterClose() async throws {
        let dir = try harness.makeDirectory("wanwo-e1b-store")
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite3").path)
        let store = SessionStore(root: dir, database: database)
        _ = try await store.createSession(withID: "s1", cwd: nil)

        // 未打开 = nil（不创建、不抛）。
        let before = await store.liveWriter(id: "s1")
        XCTAssertNil(before)

        // 打开后命中同一实例（appendEvent 复用面——绝不挤占排他所有权）。
        let (writer, _) = try await store.openWriter(id: "s1")
        let live = await store.liveWriter(id: "s1")
        XCTAssertTrue(live === writer, "liveWriter 必须命中同一活跃 writer")
        // 经活写柄 append 合法（TeamSeams.appendEvent 的新路径）。
        _ = try await live!.append(.system(note: "via live writer"))

        // 关闭后 = nil（fallback openWriter 路径的前提面）。
        await store.closeWriter(id: "s1")
        let after = await store.liveWriter(id: "s1")
        XCTAssertNil(after)
    }

    func testOpenWriterExclusivityPremise() async throws {
        // 挤占前提实证：openWriter 内部先 closeWriter（SessionStore.swift:192）
        // ——这正是 P0 修复绕开的路径；本断言钉住该语义防回退误用。
        let dir = try harness.makeDirectory("wanwo-e1b-store2")
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite3").path)
        let store = SessionStore(root: dir, database: database)
        _ = try await store.createSession(withID: "s2", cwd: nil)
        let (first, _) = try await store.openWriter(id: "s2")
        let (second, _) = try await store.openWriter(id: "s2")
        XCTAssertFalse(first === second, "openWriter 排他：第二次 open 换新 writer")
        let live = await store.liveWriter(id: "s2")
        XCTAssertTrue(live === second, "登记表指向最新 writer")
    }

    // MARK: - 任务3：interrupt 祖链 transitive 授权

    func testInterruptTransitiveAncestorAuthority() async throws {
        let runtime = await makeRuntime()
        // root → c1 → c2 三层驻留链。
        let c1 = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "mid", prompt: "p",
                                          parentSessionId: "root", parentCwd: nil,
                                          parentDepth: 0))
        let c2 = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "leaf", prompt: "p",
                                          parentSessionId: c1.childId, parentCwd: nil,
                                          parentDepth: 1))

        // 祖父（root）打断孙代（c2）——transitive 活祖链命中即授权
        //（dsh :279 activation.ancestry.has 语义；旧实现仅直接父校验必拒）。
        let granted = try await runtime.interrupt(childId: c2.childId,
                                                  callerSessionId: "root")
        XCTAssertTrue(granted)

        // 自打断显式拒绝（dsh :270-274）。
        do {
            _ = try await runtime.interrupt(childId: c2.childId,
                                            callerSessionId: c2.childId)
            XCTFail("自打断必须 UNAUTHORIZED")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "UNAUTHORIZED")
        }

        // 非祖先（孙打断祖）拒绝。
        do {
            _ = try await runtime.interrupt(childId: c1.childId,
                                            callerSessionId: c2.childId)
            XCTFail("非祖先必须 UNAUTHORIZED")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "UNAUTHORIZED")
        }
    }

    // MARK: - 任务4：sendMessage 跨代寻址拒绝 + 直接父路由

    func testSendMessageRejectsGrandchildTarget() async throws {
        let runtime = await makeRuntime()
        let c1 = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "mid", prompt: "p",
                                          parentSessionId: "root", parentCwd: nil,
                                          parentDepth: 0))
        let c2 = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "leaf", prompt: "p",
                                          parentSessionId: c1.childId, parentCwd: nil,
                                          parentDepth: 1))

        // dsh send_message 仅"直接 continuable 子或父"——跨代目标 UNAUTHORIZED
        //（continuation.ts:202-232 + continuation-activation.ts:437-451）。
        do {
            _ = try await runtime.sendMessage(from: "root", to: c2.childId, text: "hi")
            XCTFail("跨代目标必须拒绝")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "UNAUTHORIZED")
        }
    }

    func testSendMessageRoutesToParentViaDeliverFromSubagent() async throws {
        let runtime = await makeRuntime()
        let (parentWriter, _) = try await harness.makeWriter(id: "root")
        let parentLoop = harness.makeLoop(sessionId: "root", writer: parentWriter)
        await runtime.registerParentLoop(sessionId: "root", loop: parentLoop)
        let child = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "worker", prompt: "p",
                                          parentSessionId: "root", parentCwd: nil,
                                          parentDepth: 0))

        // 驻留子 → 直接父（dsh continuation.ts:213-219 sendToParent 路由）；
        // 父日志落 deliverFromSubagent 包装文案（QA-2 P1-2 既有形态）。
        let messageId = try await runtime.sendMessage(from: child.childId, to: "root",
                                                      text: "stage done")
        XCTAssertFalse(messageId.isEmpty)
        await parentLoop.whenIdle()
        let delivered = parentWriter.events.contains {
            if case .userMessage(let text) = $0.payload {
                return text.hasPrefix("Agent \(child.childId) sent a message: stage done")
            }
            return false
        }
        XCTAssertTrue(delivered, "父日志必须含 deliverFromSubagent 包装文案")
    }

    // MARK: - 任务2：sendMessage 运行中 steer / 空闲 followup

    func testSendMessageToRunningChildSteersNearestStep() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())
        // gated 子 loop：startContinuable 初始 prompt claim 后驱动器即阻塞在
        // 适配器闸（phase = .running——claim 已发生的确定性信号）。
        let (childWriter, _) = try await harness.makeWriter(id: "kid")
        let (childLoop, gate) = harness.makeGatedLoop(sessionId: "kid",
                                                      writer: childWriter)
        await runtime.registerChildMaterializer { _, _, _ in (childLoop, childWriter) }
        let started = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "kid", prompt: "kick",
                                          parentSessionId: "root", parentCwd: nil,
                                          parentDepth: 0))
        let deadline = Date().addingTimeInterval(5)
        while !gate.isHeld && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(gate.isHeld, "驱动器应已阻塞在 gated 适配器（claim 已发生）")

        // 运行中投递 → steer 最近步边界（dsh delivery:'steer'——
        // inbox.ts:53 steer → agent.steer）。
        _ = try await runtime.sendMessage(from: "root", to: started.childId,
                                          text: "mid-turn steer")
        let outcome = await childLoop.waitForInboxActivity(timeoutMs: 5_000)
        XCTAssertEqual(outcome, .steer, "运行中 = nextStepInbox（steer 词汇）")

        // 放行后收敛：steer 文本经新回合落盘（投递必达）。CI修23：whenIdle
        // 在驱动器首次收敛 idle 即返回（kick 收敛回放 wake 随后再起新回合，
        // 落盘是异步后续）——一次性检查是竞态断言，改轮询（与 idle followup
        // 用例同口径）；新回合卡 gated 适配器前 userMessage 已落盘（落盘序
        // 先于 adapter 构造），轮询必达。
        gate.open()
        await childLoop.whenIdle()
        await waitUntil {
            childWriter.events.contains {
                if case .userMessage(let text) = $0.payload {
                    return text == "mid-turn steer"
                }
                return false
            }
        }
        let delivered = childWriter.events.contains {
            if case .userMessage(let text) = $0.payload {
                return text == "mid-turn steer"
            }
            return false
        }
        XCTAssertTrue(delivered, "steer 文本必须最终落盘子日志")
        gate.open()  // 新回合若已卡闸——放行收敛，防测试进程残留挂起任务
    }

    func testSendMessageToIdleChildStartsTurn() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(harness.makeForkProvider())
        // 非 gated 子：初始 prompt 回合快速失败收敛 → 子 loop 空闲。
        let (childWriter, _) = try await harness.makeWriter(id: "sleepy")
        let childLoop = harness.makeLoop(sessionId: "sleepy", writer: childWriter)
        await runtime.registerChildMaterializer { _, _, _ in (childLoop, childWriter) }
        let started = try await runtime.startContinuable(
            provider: "fork",
            request: SubagentStartRequest(label: "sleepy", prompt: "seed",
                                          parentSessionId: "root", parentCwd: nil,
                                          parentDepth: 0))
        await childLoop.whenIdle()

        // 空闲投递 → followup 新回合（dsh inbox.ts:54 else 分支；idle 时
        // WanMo driver 首步 claim nextTurnInbox——woken prompt turn 等价）。
        _ = try await runtime.sendMessage(from: "root", to: started.childId,
                                          text: "idle followup")
        await childLoop.whenIdle()
        await waitUntil {
            childWriter.events.contains {
                if case .userMessage(let text) = $0.payload {
                    return text == "idle followup"
                }
                return false
            }
        }
        XCTAssertTrue(childWriter.events.contains {
            if case .userMessage(let text) = $0.payload {
                return text == "idle followup"
            }
            return false
        }, "空闲目标 = 新回合落盘（followup 词汇）")
    }

    // MARK: - 任务5：listAgents 持久边表权威 + diagnostic 形态

    func testListAgentsReportsRealParentAndDiagnosticForUnreadable() async throws {
        let database = try harness.makeEdgeDatabase()
        // 崩溃现场：a 可读（lineage+descriptor）；b 仅剩 Open 边、元数据不可读。
        let aId = "child-a"
        let (aWriter, _) = try await harness.makeWriter(id: aId)
        _ = try await aWriter.append(.extensionEvent(
            kind: SubagentLineage.eventKind,
            payload: SubagentLineage.payload(for: .init(
                parentSession: "root", delegationDepth: 1, seeded: false,
                agentPath: "/root/a"))))
        _ = try await aWriter.append(.extensionEvent(
            kind: SubagentDescriptor.eventKind,
            payload: SubagentDescriptor.payload(for: .init(
                mode: .continuable, provider: "fork", label: "aye",
                agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
                persona: nil, toolFilter: nil))))
        try database.upsertThreadSpawnEdge(parent: "root", child: aId, status: .open)
        try database.upsertThreadSpawnEdge(parent: aId, child: "child-b", status: .open)

        let runtime = SubagentRuntime()
        await runtime.registerEdgeStore(database)
        await runtime.registerChildMetadataReader { [aWriter] id in
            guard id == aId else {
                throw SubagentError(message: "unreadable",
                                    code: "RECOVERY_METADATA_INVALID")
            }
            guard let lineage = SubagentLineage.read(events: aWriter.events) else {
                throw SubagentError(message: "no lineage",
                                    code: "RECOVERY_METADATA_INVALID")
            }
            return (lineage, SubagentDescriptor.fold(events: aWriter.events))
        }
        // 恢复登记：a 命中 pendingRecovery；b 元数据读取抛错 → warn 跳过
        //（listAgents 双缺席 → diagnostic 面的输入形态）。
        _ = await runtime.recoverOpenChildren(rootSessionId: "root")

        // children scope：仅直接子 a；parentSessionId = 持久真实父（非调用方
        // 拼凑）；可读持久子 = ready。
        let children = await runtime.listAgents(callerSessionId: "root",
                                                includeDescendants: false)
        XCTAssertEqual(children.map(\.subagentId), [aId])
        XCTAssertEqual(children.first?.parentSessionId, "root")
        XCTAssertEqual(children.first?.status, "ready")
        XCTAssertNil(children.first?.diagnosticReason)

        // descendants scope：b 不可读 → diagnostic（corrupt）条目，绝不静默
        // 丢弃（dsh list-agents.ts:72-74/:102）；parent = a（真实父）、depth 2。
        let all = await runtime.listAgents(callerSessionId: "root",
                                           includeDescendants: true)
        XCTAssertEqual(all.count, 2)
        let b = all.first { $0.subagentId == "child-b" }
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.parentSessionId, aId)
        XCTAssertEqual(b?.depth, 2)
        XCTAssertEqual(b?.diagnosticReason, "corrupt")
        let a = all.first { $0.subagentId == aId }
        XCTAssertEqual(a?.depth, 1)
        XCTAssertEqual(a?.diagnosticReason, nil)
    }

    // MARK: - 任务8：Workflow recorder 四事件落日志

    func testWorkflowRecorderAppendsFourEventsInOrder() async throws {
        let (writer, _) = try await harness.makeWriter(id: "wf-host")

        let recorder = WorkflowEventRecorder(writer: writer)
        let info = WorkflowAgentInfo(seq: 1, label: "map phase",
                                     phase: "mapping", childId: "child-1")
        recorder.handle(.start, .none)
        recorder.handle(.agentStart, .agent(info))
        recorder.handle(.agentEnd, .agentEnd(WorkflowAgentEndInfo(
            info: info, outcome: .completed)))
        recorder.handle(.end, .result(WorkflowResultInfo(
            stopReason: .completed, error: nil, agentsStarted: 1)))

        // 追加走异步串行链——轮询收敛。
        await waitUntil {
            writer.events.filter {
                if case .extensionEvent(let kind, _) = $0.payload {
                    return kind.hasPrefix("tool-workflow/")
                }
                return false
            }.count >= 4
        }
        let events = writer.events.filter {
            if case .extensionEvent(let kind, _) = $0.payload {
                return kind.hasPrefix("tool-workflow/")
            }
            return false
        }
        XCTAssertEqual(events.count, 4, "恰好四事件（phase/log 不落）")
        guard events.count >= 4 else { return }

        func payloadFields(_ event: SessionEvent) -> [String: JSONValue] {
            if case .extensionEvent(_, let payload) = event.payload,
               case .object(let fields) = payload {
                return fields
            }
            return [:]
        }
        // 顺序：run-start → agent-start → agent-end → run-end。
        XCTAssertEqual(events[0].wireType, "extension/tool-workflow/run-start")
        XCTAssertEqual(events[1].wireType, "extension/tool-workflow/agent-start")
        XCTAssertEqual(events[2].wireType, "extension/tool-workflow/agent-end")
        XCTAssertEqual(events[3].wireType, "extension/tool-workflow/run-end")

        // 载荷逐字段（payload-validation.ts:233-250 对照；四事件同 runId）。
        let runStart = payloadFields(events[0])
        XCTAssertEqual(runStart["name"], .string("workflow"))
        let runId = runStart["runId"]
        XCTAssertNotNil(runId)

        let agentStart = payloadFields(events[1])
        XCTAssertEqual(agentStart["runId"], runId, "四事件同 run correlation id")
        XCTAssertEqual(agentStart["seq"], .int(1))
        XCTAssertEqual(agentStart["label"], .string("map phase"))
        XCTAssertEqual(agentStart["phase"], .string("mapping"))
        XCTAssertEqual(agentStart["childId"], .string("child-1"))

        let agentEnd = payloadFields(events[2])
        XCTAssertEqual(agentEnd["runId"], runId)
        XCTAssertEqual(agentEnd["seq"], .int(1))
        XCTAssertEqual(agentEnd["outcome"], .string("completed"))

        let runEnd = payloadFields(events[3])
        XCTAssertEqual(runEnd["runId"], runId)
        XCTAssertEqual(runEnd["stopReason"], .string("completed"))
    }

    func testWorkflowRecorderSkipsWithoutActiveRun() async throws {
        // 无活跃 run（未 start）直接 end → 跳过（dsh finish: session undefined
        // → 仅 delete；index.ts:118-123 语义）。
        let (writer, _) = try await harness.makeWriter(id: "wf-idle")
        let recorder = WorkflowEventRecorder(writer: writer)
        recorder.handle(.end, .result(WorkflowResultInfo(
            stopReason: .cancelled, error: nil, agentsStarted: 0)))
        try await Task.sleep(nanoseconds: 100_000_000)
        let workflowEvents = writer.events.filter {
            if case .extensionEvent(let kind, _) = $0.payload {
                return kind.hasPrefix("tool-workflow/")
            }
            return false
        }
        XCTAssertTrue(workflowEvents.isEmpty, "无活跃 run 不落事件")
    }
}
