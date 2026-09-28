//
//  M7WorkflowTests.swift
//  WanWoTests
//
//  【M7.4 件 K · F047 单测】Workflow 引擎执行核心+控制面（派单落点⑨断言面；
//  语义源 dsh session.spec.ts:280-340 + runtime.ts 行为面）：
//    - 五钩子行为：phase/log 叙述、agent() 文本返回、parallel/pipeline 组合
//      （fatal-null 二分：普通 throw 溶 null / fatal 选项拒绝杀脚本）。
//    - 上限四支：maxConcurrentAgents（FIFO 槽实测并发 1）/ maxTotalAgents
//      （AGENT_CAP 文案）/ maxItemsPerCall（ITEM_CAP 文案）/ syncTimeoutMs
//      （Watchdog while(true) 真死循环 → SCRIPT_TIMEOUT——dsh session.spec.
//      ts:303 锚点 1:1）。
//    - 取消边界：脚本前已取消 body 不执行（dsh drive() 契约）；钩子边界
//      取消 + agent-start/end 恰好配对 + agent-end outcome 面。
//    - 值物化拒绝：function / 嵌套 undefined → RESULT_UNSERIALIZABLE 文案。
//    - 引擎校验面：META_INVALID / SCRIPT_PARSE（META_STATEMENT 指名）/
//      AGENT_START 未注册 provider / resolveMaxTotalAgents 两支文案。
//    - schema 子集拒绝：非 object-rooted → UNSUPPORTED_SCHEMA。
//

import XCTest
@testable import WanWo

final class M7WorkflowTests: XCTestCase {

    // MARK: - Harness（@unchecked Sendable 盒——M7 族同款纪律）

    /// 脚本化 provider：agent() 每次调用按 callIndex 交付 SubagentResult，
    /// 并观测 in-flight 并发峰值与收到的 prompt 序列。
    final class ScriptedProvider: SubagentProviderProtocol, @unchecked Sendable {
        let name: String
        let capabilities = SubagentCapabilities.inProcess
        let inheritsParentContext = false

        typealias Handler = @Sendable (_ prompt: String, _ callIndex: Int) async throws -> SubagentResult
        private let handler: Handler

        private let lock = NSLock()
        private var _callCount = 0
        private var _inFlight = 0
        private var _maxInFlight = 0
        private var _prompts: [String] = []

        init(name: String, handler: @escaping Handler) {
            self.name = name
            self.handler = handler
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
        var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }

        func start(_ request: SubagentResolvedRequest,
                   seed: [SessionEvent]?) async throws -> SubagentRun {
            lock.lock()
            let index = _callCount
            _callCount += 1
            _prompts.append(request.request.prompt)
            _inFlight += 1
            _maxInFlight = max(_maxInFlight, _inFlight)
            lock.unlock()
            let task = Task<SubagentResult, Error> { [handler, weak self] in
                defer {
                    if let self {
                        self.lock.lock(); self._inFlight -= 1; self.lock.unlock()
                    }
                }
                return try await handler(request.request.prompt, index)
            }
            return SubagentRun(id: request.childId, result: task) {}
        }

        /// Workflow 桩走 one-shot start 路径——无 continuable 创建面（协议
        /// requirement 批3 补齐：M7TeamTests 同期发现测试文件编译段后置暴露）。
        func seedFor(_ request: SubagentResolvedRequest,
                     parentLogEvents: [SessionEvent]) -> [SessionEvent]? { return nil }

        /// 阻塞闸（取消测试用：child 卡在 handler 内，测试方择机放行）。
        final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func hold() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    cont.resume()
                    return
                }
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

    /// 引擎生命周期事件收集器（listener 注册表面）。
    final class EventCollector: @unchecked Sendable {
        struct Entry: Sendable {
            let name: String
            var title: String?
            var message: String?
            var seq: Int?
            var label: String?
            var outcome: String?
            var stopReason: String?
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []

        func add(_ name: WorkflowEventName, _ detail: WorkflowEventDetail) {
            var entry = Entry(name: name.rawValue, title: nil, message: nil,
                              seq: nil, label: nil, outcome: nil, stopReason: nil)
            switch detail {
            case .none:
                break
            case .title(let value):
                entry.title = value
            case .message(let value):
                entry.message = value
            case .agent(let info):
                entry.seq = info.seq
                entry.label = info.label
            case .agentEnd(let end):
                entry.seq = end.seq
                entry.label = end.label
                entry.outcome = end.outcome.rawValue
            case .result(let info):
                entry.stopReason = info.stopReason.rawValue
            }
            lock.lock()
            _entries.append(entry)
            lock.unlock()
        }

        var entries: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return _entries
        }

        func names() -> [String] { entries.map { $0.name } }
    }

    override func setUp() {
        super.setUp()
        collector = EventCollector()
    }

    private var collector = EventCollector()

    // MARK: 工具

    /// 带期限 await（防 Watchdog 缺席时测试永久悬挂——dlsym 失败为退化面，
    /// 失败以 timeout 错误呈现而非挂死）。
    private struct WorkflowTestTimeout: Error {}

    private func withDeadline<T: Sendable>(_ seconds: Double,
                                           _ op: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WorkflowTestTimeout()
            }
            guard let first = try await group.next() else {
                throw WorkflowTestTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    /// echo provider：第 N 次调用返回 "child-N" 文本（注册名与引擎缺省路由
    /// 对齐——WorkflowEngine.start 以 request.subagentProvider ?? config.provider
    /// 查注册表，config.provider 缺省 "spawn"）。
    private func makeEchoProvider(name: String = "spawn") -> ScriptedProvider {
        ScriptedProvider(name: name) { _, index in
            SubagentResult(output: "child-\(index)", structured: nil,
                           diagnostic: nil, stopReason: .completed)
        }
    }

    private func makeEngine(runtime: SubagentRuntime,
                            config: WorkflowEngineConfig = WorkflowEngineConfig())
        -> WorkflowEngine {
        let engine = WorkflowEngine(config: config, runtime: runtime)
        let obs = collector
        _ = engine.addWorkflowListener { name, detail in
            obs.add(name, detail)
        }
        return engine
    }

    private func startRequest(_ script: String,
                              meta: WorkflowMeta = WorkflowMeta(
                                name: "test-flow", description: "test",
                                whenToUse: nil, phases: nil),
                              args: JSONValue? = nil,
                              subagentProvider: String? = nil,
                              maxTotalAgents: Int? = nil) -> WorkflowStartRequest {
        WorkflowStartRequest(
            script: script, meta: meta, args: args,
            subagentProvider: subagentProvider, maxTotalAgents: maxTotalAgents,
            parent: WorkflowParent(sessionId: "test-parent", depth: 0, cwd: nil))
    }

    /// 完整 run 收敛：await result + dispose（工具侧同款善后序）。
    private func runToCompletion(_ handle: WorkflowRunHandle) async -> WorkflowResult {
        let result = await handle.result.value
        await handle.dispose()
        return result
    }

    /// 轮询等待事件到账（workflow/end 由结算后独立 Task 发射——断言时序面）。
    private func waitForEvent(_ name: String, timeoutMs: Int = 2000) async {
        for _ in 0..<(timeoutMs / 10) {
            if collector.names().contains(name) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 五钩子行为

    func testPhaseLogAgentEventSequence() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            phase('build');
            log('starting');
            const a = await agent('do it', { label: 'Worker A' });
            return a;
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.value, .string("child-0"))
        XCTAssertEqual(result.agentsStarted, 1)

        await waitForEvent("workflow/end")
        let names = collector.names()
        XCTAssertEqual(names.first, "workflow/start")
        XCTAssertEqual(names.last, "workflow/end")
        XCTAssertTrue(names.contains("workflow/phase"))
        XCTAssertTrue(names.contains("workflow/log"))
        XCTAssertEqual(names.filter { $0 == "workflow/agent-start" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "workflow/agent-end" }.count, 1)

        let phaseEntry = collector.entries.first { $0.name == "workflow/phase" }
        XCTAssertEqual(phaseEntry?.title, "build")
        let logEntry = collector.entries.first { $0.name == "workflow/log" }
        XCTAssertEqual(logEntry?.message, "starting")
        let startEntry = collector.entries.first { $0.name == "workflow/agent-start" }
        XCTAssertEqual(startEntry?.seq, 1)
        XCTAssertEqual(startEntry?.label, "Worker A")
        let endEntry = collector.entries.first { $0.name == "workflow/agent-end" }
        XCTAssertEqual(endEntry?.outcome, "completed")
        let endEvent = collector.entries.last
        XCTAssertEqual(endEvent?.stopReason, "completed")
    }

    func testParallelPipelineAndNullBifurcation() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            const p = await parallel([
              async () => 1,
              async () => { throw new Error('boom'); },
            ]);
            const pl = await pipeline(
              [1, 2, 3],
              (v) => v * 2,
              (v) => { if (v === 4) { throw new Error('skip'); } return v + 1; },
            );
            return { p: p, pl: pl };
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .completed)
        guard case .object(let fields) = result.value else {
            return XCTFail("expected object value, got \(result.value)")
        }
        // parallel：普通 thunk throw → null（fatal-null 二分的 null 面）。
        XCTAssertEqual(fields["p"], .array([.int(1), .null]))
        // pipeline：无跨 stage 屏障；stage throw 丢该 ITEM，其余照走。
        XCTAssertEqual(fields["pl"], .array([.int(3), .null, .int(7)]))
    }

    func testFatalOptionKillsScript() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            await agent('x', { effort: 'high' });
            return 1;
            """))
        let result = await runToCompletion(handle)

        // Misused hooks ALWAYS kill the script（description 契约面）。
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("effort") ?? false,
                      "error should name the deferred option: \(result.error ?? "nil")")
        XCTAssertTrue(result.error?.contains("deferred and not supported") ?? false)
    }

    func testUnknownAgentOptionRejected() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            await agent('x', { nonsense: true });
            return 1;
            """))
        let result = await runToCompletion(handle)
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("not recognized") ?? false)
    }

    func testUnsupportedSchemaRejected() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        // schema 必须 object-rooted（type:'string' 根不在子集内）。
        let handle = try await engine.start(startRequest("""
            await agent('x', { schema: { type: 'string' } });
            return 1;
            """))
        let result = await runToCompletion(handle)
        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("supported subset") ?? false)
    }

    // MARK: 上限四支

    func testMaxConcurrentAgentsFifoSlot() async throws {
        let runtime = SubagentRuntime()
        let provider = ScriptedProvider(name: "scripted") { _, _ in
            // 每个 child 持续一小段，制造并发窗口。
            try? await Task.sleep(nanoseconds: 80_000_000)
            return SubagentResult(output: "ok", structured: nil,
                                  diagnostic: nil, stopReason: .completed)
        }
        await runtime.registerProvider(provider)
        var config = WorkflowEngineConfig()
        config.provider = "scripted"
        config.maxConcurrentAgents = 1
        let engine = makeEngine(runtime: runtime, config: config)

        let handle = try await engine.start(startRequest("""
            const r = await parallel([
              () => agent('a'), () => agent('b'), () => agent('c'),
            ]);
            return r.length;
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.value, .int(3))
        // FIFO 槽：并发帽 1 下实测峰值恰为 1。
        XCTAssertEqual(provider.maxInFlight, 1)
    }

    func testMaxTotalAgentsCap() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        var config = WorkflowEngineConfig()
        config.maxTotalAgents = 2
        let engine = makeEngine(runtime: runtime, config: config)

        let handle = try await engine.start(startRequest("""
            for (let i = 0; i < 5; i++) { await agent('x' + i); }
            return 'done';
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("total agent cap (2)") ?? false,
                      "error: \(result.error ?? "nil")")
        XCTAssertTrue(result.error?.contains("runaway-loop backstop") ?? false)
        // 已被接受的两枚计入 agentsStarted。
        XCTAssertEqual(result.agentsStarted, 2)
    }

    func testMaxItemsPerCallCap() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        var config = WorkflowEngineConfig()
        config.maxItemsPerCall = 10
        let engine = makeEngine(runtime: runtime, config: config)

        let handle = try await engine.start(startRequest("""
            await parallel(new Array(11).fill(0).map(() => () => 1));
            return 1;
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("received 11 items") ?? false)
        XCTAssertTrue(result.error?.contains("over the per-call cap (10)") ?? false)
    }

    /// Watchdog 真死循环 → SCRIPT_TIMEOUT（dsh session.spec.ts:303 锚点 1:1：
    /// `while (true) {}` + 小 syncTimeoutMs → 'timed out'）。
    func testWatchdogSyncTimeout() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        var config = WorkflowEngineConfig()
        config.syncTimeoutMs = 300
        let engine = makeEngine(runtime: runtime, config: config)

        let handle = try await engine.start(startRequest("""
            while (true) {}
            """))
        let result = try await withDeadline(15) { await handle.result.value }
        await handle.dispose()

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("timed out after 300ms") ?? false,
                      "error: \(result.error ?? "nil")")
        XCTAssertTrue(result.error?.contains("synchronous slice") ?? false)
        XCTAssertEqual(result.agentsStarted, 0)
    }

    // MARK: 取消边界

    /// 脚本前已取消 → body 不执行（dsh drive() 契约：run.result 恒 cancelled）。
    func testCancelBeforeBodyDoesNotExecute() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            await agent('should never run');
            return 1;
            """))
        handle.cancel("early cancel")
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertTrue(result.error?.contains("early cancel") ?? false)
        XCTAssertEqual(result.agentsStarted, 0)
        XCTAssertFalse(collector.names().contains("workflow/agent-start"))
        XCTAssertFalse(collector.names().contains("workflow/agent-end"))
    }

    /// 钩子边界取消：在飞 child 放行后自然配对 agent-end；下一个 agent()
    /// 钩子入口抛 CANCELLED；start/end 恰好配对。
    func testCancelAtHookBoundaryPairsAgentEvents() async throws {
        let runtime = SubagentRuntime()
        let gate = ScriptedProvider.Gate()
        let provider = ScriptedProvider(name: "scripted") { prompt, _ in
            if prompt == "hold me" {
                await gate.hold()
            }
            return SubagentResult(output: "ok", structured: nil,
                                  diagnostic: nil, stopReason: .completed)
        }
        await runtime.registerProvider(provider)
        var config = WorkflowEngineConfig()
        config.provider = "scripted"
        config.disposeGraceMs = 2000
        let engine = makeEngine(runtime: runtime, config: config)

        let handle = try await engine.start(startRequest("""
            await agent('hold me');
            await agent('never starts');
            return 1;
            """))

        // 等 agent-start 落账（确定性等待而非 sleep 竞速）。
        for _ in 0..<200 {
            if collector.names().contains("workflow/agent-start") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(collector.names().contains("workflow/agent-start"))

        handle.cancel("hook boundary cancel")
        // 放行在飞 child：其 agent-end 以 completed 配对；脚本下一个 agent()
        // 抛 CANCELLED → run cancelled。
        gate.open()
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertTrue(result.error?.contains("hook boundary cancel") ?? false)
        // agent-start / agent-end 恰好配对（host.ts:563-567 单一配对闸）。
        let starts = collector.names().filter { $0 == "workflow/agent-start" }.count
        let ends = collector.names().filter { $0 == "workflow/agent-end" }.count
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        let endEntry = collector.entries.first { $0.name == "workflow/agent-end" }
        XCTAssertEqual(endEntry?.outcome, "completed")
        // 取消后 phase/log 不前进（narration 抑制——本脚本无叙述，防御断言：
        // end 事件存在且为 cancelled）。
        await waitForEvent("workflow/end")
        let endEvent = collector.entries.last
        XCTAssertEqual(endEvent?.name, "workflow/end")
        XCTAssertEqual(endEvent?.stopReason, "cancelled")
    }

    // MARK: 值物化拒绝

    func testMaterializeRejectsFunctionValue() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            return function () {};
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("not plain JSON data") ?? false,
                      "error: \(result.error ?? "nil")")
        XCTAssertTrue(result.error?.contains("not plain JSON data — ")
                          ?? false, // RESULT_UNSERIALIZABLE 包裹文案前缀
                      "must carry the runtime wrapper sentence")
        XCTAssertTrue(result.error?.contains("Return only JSON-serializable") ?? false)
    }

    func testMaterializeRejectsNestedUndefined() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let handle = try await engine.start(startRequest("""
            return { nested: undefined };
            """))
        let result = await runToCompletion(handle)

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("undefined is not JSON data") ?? false)
    }

    // MARK: 引擎校验面（start 发布前 throw）

    func testMetaValidationThrows() async {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        let badMeta = WorkflowMeta(name: "test-flow", description: "",
                                   whenToUse: nil, phases: nil)
        do {
            _ = try await engine.start(startRequest("return 1;", meta: badMeta))
            XCTFail("expected META_INVALID")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.code, .metaInvalid)
            XCTAssertTrue(error.message.contains("meta.description must be a non-empty string"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testMetaStatementInBodyThrows() async {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        do {
            _ = try await engine.start(startRequest("""
                export const meta = { name: 'x' };
                return 1;
                """))
            XCTFail("expected SCRIPT_PARSE (meta statement)")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.code, .scriptParse)
            XCTAssertTrue(error.message.contains("workflow meta rides the `meta` request field"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testUnparsableBodyThrows() async {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(makeEchoProvider())
        let engine = makeEngine(runtime: runtime)

        do {
            _ = try await engine.start(startRequest("const x = ;"))
            XCTFail("expected SCRIPT_PARSE")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.code, .scriptParse)
            XCTAssertTrue(error.message.contains("workflow script does not parse"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testUnregisteredProviderThrows() async {
        let runtime = SubagentRuntime()
        let engine = makeEngine(runtime: runtime)

        do {
            _ = try await engine.start(startRequest("return 1;",
                                                     subagentProvider: "ghost"))
            XCTFail("expected AGENT_START")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.code, .agentStart)
            XCTAssertEqual(error.message, "no subagent provider registered for \"ghost\"")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testResolveMaxTotalAgentsTexts() {
        // 缺省 → ceiling。
        XCTAssertEqual(try? WorkflowEngine.resolveMaxTotalAgents(nil, ceiling: 1000), 1000)
        // < 1。
        do {
            _ = try WorkflowEngine.resolveMaxTotalAgents(0, ceiling: 1000)
            XCTFail("expected INVALID_ARGUMENT")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.message,
                           "workflow maxTotalAgents must be a positive safe integer")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        // > ceiling。
        do {
            _ = try WorkflowEngine.resolveMaxTotalAgents(2000, ceiling: 1000)
            XCTFail("expected INVALID_ARGUMENT")
        } catch let error as WorkflowError {
            XCTAssertEqual(error.message,
                           "workflow maxTotalAgents 2000 exceeds the engine ceiling 1000")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: 工具渲染面（WorkflowTool 纯函数）

    func testWorkflowToolRenderAndTruncation() {
        let value = JSONValue.object(["k": .string("v")])
        let rendered = WorkflowTool.renderResult(name: "my-flow", agentsStarted: 1,
                                                 value: value, maxChars: 50000)
        XCTAssertTrue(rendered.hasPrefix("workflow \"my-flow\" completed (1 agent).\nReturn value:\n"))
        XCTAssertTrue(rendered.contains("\"k\""))

        // 复数形态。
        let plural = WorkflowTool.renderResult(name: "f", agentsStarted: 2,
                                               value: .null, maxChars: 50000)
        XCTAssertTrue(plural.contains("(2 agents)"))

        // 截断通知（index.ts:198-199 文案；计数 = 渲染 JSON 总长 − 保留长度
        // ——字符串字面量含引号，须按 prettyJSON 实长推）。
        let big = JSONValue.string(String(repeating: "x", count: 100))
        let renderedLength = WorkflowTool.prettyJSON(big).count
        let clipped = WorkflowTool.renderResult(name: "f", agentsStarted: 0,
                                                value: big, maxChars: 10)
        XCTAssertTrue(clipped.contains(
            "\n… [truncated: \(renderedLength - 10) more characters]"))
    }

    func testWorkflowToolStopReasonErrorTexts() {
        XCTAssertEqual(WorkflowTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .completed, error: nil, agentsStarted: 0)), nil)
        XCTAssertEqual(WorkflowTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .cancelled, error: nil, agentsStarted: 0)),
            "workflow run was cancelled")
        XCTAssertEqual(WorkflowTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .cancelled, error: "reason", agentsStarted: 0)),
            "workflow run was cancelled (reason)")
        XCTAssertEqual(WorkflowTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .error, error: "boom", agentsStarted: 0)),
            "workflow run failed: boom")
        XCTAssertEqual(WorkflowTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .error, error: nil, agentsStarted: 0)),
            "workflow run failed: unknown error")
    }

    // MARK: - outputSchema 缝（SubagentInProcessDriver.readResult · QA-7 缝③）

    private func event(_ payload: SessionEvent.Payload, seq: Int) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: payload)
    }

    /// 一段已 completed 的子自有事件（单 assistant 消息 + turnEnd）。
    private func completedChildEvents(output: String) -> [SessionEvent] {
        [
            event(.turnStart(turn: 1), seq: 0),
            event(.assistantMessage(turn: 1, step: 1,
                                    message: AssistantMessage(id: "a1", provider: "p",
                                                              model: "m",
                                                              content: [.text(output)]),
                                    usage: nil, interrupted: false),
                  seq: 1),
            event(.turnEnd(turn: 1, reason: .completed), seq: 2),
        ]
    }

    /// {answer: number} 必填 + 禁未知键。
    private let answerNumberSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "answer": .object(["type": .string("number")]),
        ]),
        "required": .array([.string("answer")]),
        "additionalProperties": .bool(false),
    ])

    /// schema 解析成功：structured 回填 + completed 保持。
    func testReadResultSchemaParseSuccess() {
        let result = SubagentInProcessDriver.readResult(
            completedChildEvents(output: "{\"answer\": 42}"),
            cancelled: false, schema: answerNumberSchema)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.structured, .object(["answer": .int(42)]))
        XCTAssertNil(result.diagnostic)
    }

    /// 校验失败降 error 两支：schema 违规（缺必填/未知键/类型错）与
    /// 非 JSON 文本——结构化承诺未兑现 = 子失败（:231-236 语义）。
    func testReadResultSchemaViolationDropsToError() {
        // 缺必填字段。
        let missing = SubagentInProcessDriver.readResult(
            completedChildEvents(output: "{}"),
            cancelled: false, schema: answerNumberSchema)
        XCTAssertEqual(missing.stopReason, .error)
        XCTAssertNil(missing.structured)
        XCTAssertTrue(missing.diagnostic?.contains("violates outputSchema") ?? false)

        // 未知键（additionalProperties: false）。
        let extra = SubagentInProcessDriver.readResult(
            completedChildEvents(output: "{\"answer\": 1, \"junk\": true}"),
            cancelled: false, schema: answerNumberSchema)
        XCTAssertEqual(extra.stopReason, .error)
        XCTAssertNil(extra.structured)

        // 非 JSON 文本。
        let junk = SubagentInProcessDriver.readResult(
            completedChildEvents(output: "plain prose, not json"),
            cancelled: false, schema: answerNumberSchema)
        XCTAssertEqual(junk.stopReason, .error)
        XCTAssertNil(junk.structured)
        XCTAssertTrue(junk.diagnostic?.contains("not valid JSON") ?? false)
    }

    /// 无 schema 回归面：structured 恒 nil、stopReason 行为不变。
    func testReadResultWithoutSchemaLeavesStructuredNil() {
        let result = SubagentInProcessDriver.readResult(
            completedChildEvents(output: "{\"answer\": 1}"),
            cancelled: false)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertNil(result.structured)
        XCTAssertNil(result.diagnostic)
    }
}
