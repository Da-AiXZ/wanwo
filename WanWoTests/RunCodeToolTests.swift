//
//  RunCodeToolTests.swift
//  WanWoTests
//
//  【M5-B 批 P3 测试 · run_code 工具本体】派单九面对拍 + 渲染/schema 单面：
//    · 单子派发成功（值面交付 + 两事件落盘 + presentCall 形态）；
//    · 子派发失败 → binding 拒绝 → ToolCallError → CodeRunFailedError
//      （code 'CODE_RUN_FAILED' + Captured output 逐字形态）；
//    · 渲染三面：嵌套值两空格缩进（JSON.stringify(v,2) 同形）/ string 直出 /
//      深层缩进帽折叠（(depth+1)*2 > 10）/ 空态 '(run_code completed with
//      no output)' 逐字；
//    · description 空拒（ptc.ts:329 文案逐字；缺失同拒）；
//    · maxParallel=1 串行（parallel 类子调用重叠帽；进/出序断言）；
//    · 排队未启动子派发弃单：不落 start 事件（types.ts:33-34）+ 在飞子派发
//      以 isError 产出落定（types.ts:44-49 "abort included"）；
//    · 两事件全形态对拍（真 SessionWriter；rootCallId=parentCallId=call-1，
//      subCallId 'call-1:ptc:1'——登记⑭）；
//    · logOnly projection / pairing none / schema 校验（arguments 开放值域
//      不入 required——登记⑰）；
//    · 子派发不进模型历史（事件流零 tool/call、tool/result）；
//    · 车道弃单文案逐字（ptc.ts:531 单元面——程序面弃单拒绝被硬停吞没，
//      只能单元面取证，见呈报）。
//

import XCTest
@testable import WanWo

/// 【挂死族·专门修复件】CI 两轮实证两测试挂死（testAbandoned/testDispatch-
/// Events 各 20min+ 无进展）——真 JSCore+真 SessionWriter+gate 集成面存在
/// 未定位的并发时序挂点（两轮修复：JSCore 在飞 binding 统一拒绝+车道丢唤
/// 醒窗口，未覆盖全部挂因）。整文件 skip 拿全量绿基线；深挖=本地 macOS
/// 调试（CI 黑盒 30min/轮成本过高）+真机验收补偿 run_code 验证。
final class RunCodeToolTests: XCTestCase {
    // MARK: 夹具（真 JsonlEventLog + SessionDatabase + SessionWriter，临时目录）

    private func makeWriter(id: String) async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-code-\(id)-\(UUID().uuidString)",
                                     isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let header = SessionHeader(id: id, createdAtMs: 0, cwd: nil)
        let log = try JsonlEventLog.create(
            header: header, at: dir.appendingPathComponent("events.jsonl"))
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite").path)
        let writer = try await SessionWriter(id: id, header: header,
                                             log: log, database: database)
        return (writer, dir)
    }

    override func setUpWithError() throws {
        // 【挂死族·根因已修 2026-09-15】CI 两测试各 20min+ 挂死的真凶=
        // 车道 drain 等常驻服务循环（driveLoop while true 无退出条件，
        // waitForWake 永挂）→ run_code 程序成功后 runProgram 永不返回
        // （真机 run 34903942927 事件流 +124.2s 后 448s 静默同根因）。
        // 修复=drain 就地泵干（dsh ptc.ts:448-456 "一轮有限推进" 语义）。
        // 整类解禁作回归验证。
        try super.setUpWithError()
        // 注册表是进程级单例：隔离重建（E3 同款纪律）。
        ExtensionEventRegistry.shared.resetForTests()
        PtcDispatchEvents.registerEventSchemas()
    }

    override func tearDownWithError() throws {
        ExtensionEventRegistry.shared.resetForTests()
        try super.tearDownWithError()
    }

    // MARK: 测试桩工具

    /// echo 桩：固定文本成功产出。
    private struct EchoTool: AgentTool {
        let name = "ptc_echo"
        let description = "echo stub"
        let parameters: JSONValue = .schemaObject(properties: [:], required: [])
        func execute(_ args: JSONValue,
                     _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            .success("echo-ok")
        }
    }

    /// boom 桩：结构化失败产出。
    private struct BoomTool: AgentTool {
        let name = "ptc_boom"
        let description = "boom stub"
        let parameters: JSONValue = .schemaObject(properties: [:], required: [])
        func execute(_ args: JSONValue,
                     _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            .failure("boom")
        }
    }

    /// gate 桩：进入位记录 + 放行闸（并行/排他分类由 parallelSafe 决定）。
    private struct GateTool: AgentTool {
        let name = "ptc_gate"
        let description = "gate stub"
        let parameters: JSONValue = .schemaObject(properties: [:], required: [])
        let gate: PtcTestGate
        let parallelSafe: Bool
        func isConcurrencySafe(_ args: JSONValue) -> Bool { parallelSafe }
        func execute(_ args: JSONValue,
                     _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            let tag = args.objectValue?["i"]?.intValue ?? 0
            gate.enter(tag)
            await gate.waitRelease()
            gate.exit(tag)
            return .success("gate-\(tag)")
        }
    }

    /// 测试闸：进/出序记录 + 放行续延（线程安全）。
    final class PtcTestGate: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        private var enteredCount = 0
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

        func enter(_ tag: Int) {
            lock.lock()
            enteredCount += 1
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            lock.unlock()
            lock.lock()
            events.append("in:\(tag)")
            lock.unlock()
            waiters.forEach { $0.resume() }
        }

        func exit(_ tag: Int) {
            lock.lock()
            events.append("out:\(tag)")
            lock.unlock()
        }

        func logSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        func enteredTotal() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return enteredCount
        }

        func awaitEntered(count: Int) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if enteredCount >= count {
                    lock.unlock()
                    cont.resume()
                    return
                }
                enteredWaiters.append(cont)
                lock.unlock()
            }
        }

        func releaseOne() {
            lock.lock()
            let waiter = releaseWaiters.isEmpty ? nil : releaseWaiters.removeFirst()
            lock.unlock()
            waiter?.resume()
        }

        func waitRelease() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                releaseWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    /// 单元面闩（车道 start 取证）。
    final class TestLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func openGate() {
            lock.lock()
            open = true
            let snapshot = waiters
            waiters.removeAll()
            lock.unlock()
            snapshot.forEach { $0.resume() }
        }

        func awaitOpen() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if open {
                    lock.unlock()
                    cont.resume()
                    return
                }
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    // MARK: 组装缝

    private struct TestStack {
        let registry: ToolRegistry
        let pipeline: ToolPipeline
        let writer: SessionWriter
        let tool: RunCodeTool
        let dir: URL
    }

    private func makeStack(id: String,
                           gate: PtcTestGate? = nil,
                           gateParallelSafe: Bool = false,
                           maxParallelSubCalls: Int = 10) async throws -> TestStack {
        let (writer, dir) = try await makeWriter(id: id)
        let registry = ToolRegistry()
        registry.register(EchoTool())
        registry.register(BoomTool())
        if let gate {
            registry.register(GateTool(gate: gate, parallelSafe: gateParallelSafe))
        }
        let pipeline = ToolPipeline(registry: registry, repeatAdviser: RepeatCallAdviser())
        let tool = RunCodeTool(pipeline: pipeline, writer: writer,
                               runtime: try JSCodeRuntime(),
                               maxParallelSubCalls: maxParallelSubCalls)
        return TestStack(registry: registry, pipeline: pipeline, writer: writer,
                         tool: tool, dir: dir)
    }

    private func makeCtx(callId: String) -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test", turn: 1, step: 1, callId: callId,
            workspace: WorkspaceFileAccess(sessionId: "test"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: nil)
    }

    private func runArgs(code: String, description: String = "count things") -> JSONValue {
        .object(["code": .string(code), "description": .string(description)])
    }

    private func extensionFields(of event: SessionEvent)
        -> (kind: String, fields: [String: JSONValue])? {
        guard case .extensionEvent(let kind, let payload) = event.payload,
              case .object(let fields) = payload else { return nil }
        return (kind, fields)
    }

    private func dispatchEvents(of writer: SessionWriter, kind: String)
        -> [(subCallId: String, fields: [String: JSONValue])] {
        writer.events.compactMap { event in
            guard let extracted = extensionFields(of: event),
                  extracted.kind == kind,
                  case .string(let subCallId) = extracted.fields["subCallId"]
            else { return nil }
            return (subCallId, extracted.fields)
        }
    }

    // MARK: - 单子派发成功（值面 + 两事件 + presentCall）

    func testSingleSubDispatchSuccess() async throws {
        let stack = try await makeStack(id: "success")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        let output = try await stack.tool.execute(
            runArgs(code: "return await tools.ptc_echo({ i: 1 });"),
            makeCtx(callId: "call-1"))
        // 值面（登记⑪）：binding 交付子调用产出文本 → 程序 completion →
        // string 直出渲染。
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "echo-ok")

        // 两事件落盘（start + settle，subCallId 形态逐字）。
        let starts = dispatchEvents(of: stack.writer, kind: PtcDispatchEvents.startKind)
        let settles = dispatchEvents(of: stack.writer, kind: PtcDispatchEvents.dispatchKind)
        XCTAssertEqual(starts.map { $0.subCallId }, ["call-1:ptc:1"])
        XCTAssertEqual(settles.map { $0.subCallId }, ["call-1:ptc:1"])
        // settle 事件 isError=false（成功产出）。
        XCTAssertEqual(settles[0].fields["isError"], .bool(false))

        // presentCall（ptc.ts:650-655 映射——title=description、程序随行）。
        let card = stack.tool.presentCall(runArgs(code: "return 1;"))
        XCTAssertEqual(card?.title, "count things")
        XCTAssertEqual(card?.detail, "return 1;")
    }

    // MARK: - 子派发失败 → CodeRunFailedError（code CODE_RUN_FAILED）

    func testSubDispatchFailureBecomesCodeRunFailed() async throws {
        let stack = try await makeStack(id: "failure")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        let output = try await stack.tool.execute(
            runArgs(code: "console.log('step-a'); await tools.ptc_boom({});"),
            makeCtx(callId: "call-1"))
        // ptc.ts:636-638 逐字形态：kind + message + Captured output。
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "CODE_RUN_FAILED")
        XCTAssertEqual(output.errorName, "CodeRunFailedError")
        XCTAssertTrue(output.text.contains("code run failed (exception):"),
                      "text=\(output.text)")
        // binding 拒绝（isError 产出 message）→ 程序内 ToolCallError →
        // 异常消息携带子调用模型可见失败面全量。
        XCTAssertTrue(output.text.contains("Error: boom"), "text=\(output.text)")
        XCTAssertTrue(output.text.contains("Captured output:\nstep-a"),
                      "text=\(output.text)")
        // settle 事件 isError=true（子调用失败留痕）。
        let settles = dispatchEvents(of: stack.writer, kind: PtcDispatchEvents.dispatchKind)
        XCTAssertEqual(settles.map { $0.subCallId }, ["call-1:ptc:1"])
        XCTAssertEqual(settles[0].fields["isError"], .bool(true))
    }

    // MARK: - 渲染（ptc.ts:184-256）

    func testRenderValueNestedIndentationAndStringDirect() async throws {
        let stack = try await makeStack(id: "render")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        // 嵌套对象/数组 = JSON.stringify(v, null, 2) 同形。
        let nested = try await stack.tool.execute(
            runArgs(code: "return { a: [1, { b: 'x' }] };"),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(nested.text,
                       "{\n  \"a\": [\n    1,\n    {\n      \"b\": \"x\"\n    }\n  ]\n}")
        // string 值直出（不引号，ptc.ts:254-256）。
        let direct = try await stack.tool.execute(
            runArgs(code: "return 'hello';"),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(direct.text, "hello")
    }

    func testRenderIndentCapCompactsDeepSubtree() async throws {
        let stack = try await makeStack(id: "render-cap")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        // (depth+1)*2 > 10 的容器折叠为紧凑形态（depth 5 起）。
        let output = try await stack.tool.execute(
            runArgs(code: "return [1, [2, [3, [4, [5, [6]]]]]];"),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(output.text,
                       "[\n  1,\n  [\n    2,\n    [\n      3,\n      [\n        4,"
                       + "\n        [\n          5,\n          [6]\n        ]"
                       + "\n      ]\n    ]\n  ]\n]")
    }

    func testRenderEmptyStateNoOutput() async throws {
        let stack = try await makeStack(id: "render-empty")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        // 无日志无值（程序不 return 不 print）→ 空态文案逐字（ptc.ts:324）。
        let output = try await stack.tool.execute(
            runArgs(code: "1 + 1;"),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(output.text, "(run_code completed with no output)")
    }

    // MARK: - description 校验（ptc.ts:328-330 文案逐字）

    func testEmptyDescriptionRejectedVerbatim() async throws {
        let stack = try await makeStack(id: "desc")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        // 空白 description。
        let blank = try await stack.tool.execute(
            runArgs(code: "return 1;", description: "   "),
            makeCtx(callId: "call-1"))
        XCTAssertTrue(blank.isError)
        XCTAssertEqual(blank.text,
                       "Error: invalid description: expected a non-empty string")
        // 缺失同拒（登记⑫——dsh 对 undefined 的 .trim TypeError 归一）。
        let missing = try await stack.tool.execute(
            .object(["code": .string("return 1;")]),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(missing.text,
                       "Error: invalid description: expected a non-empty string")
        // code 缺失（schema required 兜底）。
        let noCode = try await stack.tool.execute(
            .object(["description": .string("count things")]),
            makeCtx(callId: "call-1"))
        XCTAssertTrue(noCode.isError)
        XCTAssertEqual(noCode.text, "Error: missing required parameter \"code\"")
    }

    // MARK: - maxParallel=1 串行（并行类重叠帽）

    func testMaxParallelOneSerializesParallelClassSubCalls() async throws {
        let gate = PtcTestGate()
        let stack = try await makeStack(id: "parallel-cap", gate: gate,
                                        gateParallelSafe: true,
                                        maxParallelSubCalls: 1)
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        let runTask = Task {
            try await stack.tool.execute(
                runArgs(code:
                    "await Promise.all([tools.ptc_gate({ i: 1 }), tools.ptc_gate({ i: 2 })]);"
                    + " return 'done';"),
                makeCtx(callId: "call-1"))
        }
        // 第一个进闸；并行类帽=1 ⇒ 第二个排队未启动（未进闸）。
        await gate.awaitEntered(count: 1)
        XCTAssertEqual(gate.enteredTotal(), 1)
        gate.releaseOne()
        // 第一个出闸后第二个才进（提交序启动 + 帽内串行）。
        await gate.awaitEntered(count: 2)
        gate.releaseOne()
        let output = try await runTask.value
        XCTAssertEqual(output.text, "done")
        // 进/出序：无重叠（in:1 → out:1 → in:2 → out:2）。
        XCTAssertEqual(gate.logSnapshot(), ["in:1", "out:1", "in:2", "out:2"])
    }

    // MARK: - 排队未启动子派发弃单（不落 start 事件；在飞 isError 收敛）

    func testAbandonedQueuedSubDispatchLogsNothing() async throws {
        // 【根因已修 2026-09-15】当年 CI 两轮 20min+ 挂死=车道 drain 等
        // 常驻服务循环（见 setUpWithError 注释）——本测试覆盖的正是
        // run-cancel 后 drain 收敛路径，修复后应为天然回归面。
        let gate = PtcTestGate()
        let stack = try await makeStack(id: "abandon", gate: gate,
                                        gateParallelSafe: true,
                                        maxParallelSubCalls: 1)
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        // 第一个占满帽并持闸；第二个排队未启动；外层取消燃 run 作用域。
        let runTask = Task {
            try await stack.tool.execute(
                runArgs(code:
                    "tools.ptc_gate({ i: 1 }); return await tools.ptc_gate({ i: 2 });"),
                makeCtx(callId: "call-1"))
        }
        await gate.awaitEntered(count: 1)
        runTask.cancel()
        // 先放闸再取值（真机批 B4 重写）：在飞 body 恢复后以 isError 产出
        // 落定（ToolTimeout 入口 ABORTED——types.ts:44-49）并 commit 落盘
        // settle 事件——execute 内 drain 泵干等待在飞 commit，返回时事件
        // 必已落盘（原顺序 releaseOne 后置 → execute 返回时 settle 未落，
        // settles[0] 越界崩溃实证）。弃单条目零事件。
        gate.releaseOne()
        let output = try await runTask.value
        XCTAssertTrue(output.isError)
        // 程序 await 的第二个 binding 被弃单（逐字文案）→ 程序 throw →
        // handleReject → messageOf 提取（B4 修复后取 message 非 stack）。
        XCTAssertTrue(output.text.contains("run_code run is over (canceled)"),
                      "text=\(output.text)")
        let starts = dispatchEvents(of: stack.writer, kind: PtcDispatchEvents.startKind)
        let settles = dispatchEvents(of: stack.writer, kind: PtcDispatchEvents.dispatchKind)
        XCTAssertEqual(starts.map { $0.subCallId }, ["call-1:ptc:1"])
        XCTAssertEqual(settles.map { $0.subCallId }, ["call-1:ptc:1"])
        XCTAssertEqual(settles[0].fields["isError"], .bool(true))
        // 事件流零 tool/call、tool/result（子派发不进模型历史）。
        for event in stack.writer.events {
            guard case .extensionEvent = event.payload else {
                return XCTFail("非 extension 事件混入: \(event.wireType)")
            }
        }
    }

    // MARK: - 两事件全形态对拍（真 SessionWriter）

    func testDispatchEventsFullFormPayloadRealWriter() async throws {
        let stack = try await makeStack(id: "full-form")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        _ = try await stack.tool.execute(
            runArgs(code: "return await tools.ptc_echo({ i: 1 });"),
            makeCtx(callId: "call-1"))
        XCTAssertEqual(stack.writer.events.count, 2)
        // E1 通道 wire 恒 ignorable（SessionEvent.defaultIgnorable）。
        XCTAssertTrue(stack.writer.events.allSatisfy(\.ignorable))
        // start 全形态（types.ts:11-17；arguments = logged 孪生值）。
        let start = try XCTUnwrap(extensionFields(of: stack.writer.events[0]))
        XCTAssertEqual(start.kind, PtcDispatchEvents.startKind)
        XCTAssertEqual(start.fields, [
            "rootCallId": .string("call-1"),
            "parentCallId": .string("call-1"),
            "subCallId": .string("call-1:ptc:1"),
            "name": .string("ptc_echo"),
            "arguments": .object(["i": .int(1)]),
        ])
        // settle 全形态（types.ts:20-23；content = 单 text 块**数组**——
        // schema :167 requiredFields 声明 .array，真机批 B2 对齐）。
        let settle = try XCTUnwrap(extensionFields(of: stack.writer.events[1]))
        XCTAssertEqual(settle.kind, PtcDispatchEvents.dispatchKind)
        XCTAssertEqual(settle.fields, [
            "rootCallId": .string("call-1"),
            "parentCallId": .string("call-1"),
            "subCallId": .string("call-1:ptc:1"),
            "name": .string("ptc_echo"),
            "arguments": .object(["i": .int(1)]),
            "isError": .bool(false),
            "content": .array([.object(["type": .string("text"), "text": .string("echo-ok")])]),
        ])
    }

    // MARK: - 注册面（logOnly / pairing / schema 校验）

    func testRegistryLogOnlyProjectionAndValidation() {
        let registry = ExtensionEventRegistry.shared
        XCTAssertTrue(registry.isRegistered(PtcDispatchEvents.startKind))
        XCTAssertTrue(registry.isRegistered(PtcDispatchEvents.dispatchKind))
        // 拍板⑤：projection = .logOnly（子调用永不重入模型上下文）、
        // pairing = .none（UI 按 subCallId 配对，非 SessionInvariant 应答对）。
        XCTAssertEqual(registry.projectionRule(for: PtcDispatchEvents.startKind), .logOnly)
        XCTAssertEqual(registry.projectionRule(for: PtcDispatchEvents.dispatchKind), .logOnly)
        XCTAssertEqual(registry.pairingRule(for: PtcDispatchEvents.startKind), .none)
        XCTAssertEqual(registry.pairingRule(for: PtcDispatchEvents.dispatchKind), .none)
        // 合法 payload（arguments 不入 required——开放值域，登记⑰）。
        let identity: [String: JSONValue] = [
            "rootCallId": .string("call-1"), "parentCallId": .string("call-1"),
            "subCallId": .string("call-1:ptc:1"), "name": .string("ptc_echo"),
        ]
        XCTAssertNil(registry.validationReason(
            kind: PtcDispatchEvents.startKind, payload: .object(identity)))
        let legalSettle: [String: JSONValue] = [
            "rootCallId": .string("call-1"), "parentCallId": .string("call-1"),
            "subCallId": .string("call-1:ptc:1"), "name": .string("ptc_echo"),
            "isError": .bool(false),
            "content": .array([.object(["type": .string("text"),
                                        "text": .string("x")])]),
        ]
        XCTAssertNil(registry.validationReason(
            kind: PtcDispatchEvents.dispatchKind, payload: .object(legalSettle)))
        // 缺必填（settle 缺 isError）拒。
        XCTAssertNotNil(registry.validationReason(
            kind: PtcDispatchEvents.dispatchKind, payload: .object(identity)))
        // 类型错（isError 非布尔）拒。
        let wrongType: [String: JSONValue] = [
            "rootCallId": .string("call-1"), "parentCallId": .string("call-1"),
            "subCallId": .string("call-1:ptc:1"), "name": .string("ptc_echo"),
            "isError": .string("no"), "content": .array([]),
        ]
        XCTAssertNotNil(registry.validationReason(
            kind: PtcDispatchEvents.dispatchKind, payload: .object(wrongType)))
    }

    // MARK: - 子派发不进模型历史

    func testSubDispatchNeverEntersModelHistory() async throws {
        let stack = try await makeStack(id: "no-history")
        defer { try? FileManager.default.removeItem(at: stack.dir) }
        _ = try await stack.tool.execute(
            runArgs(code: "await tools.ptc_echo({ i: 1 }); return 'done';"),
            makeCtx(callId: "call-1"))
        // 子派发桥 = 纯 ToolPipeline.run（裁定①）：零 tool/call、tool/result
        // 落盘——事件流仅两条 log-only 扩展事件；派生折叠按 logOnly 跳过
        //（DeriveFold.swift:84-86），子调用永不重入模型上下文。
        XCTAssertEqual(stack.writer.events.count, 2)
        let kinds = stack.writer.events.compactMap { event -> String? in
            guard let extracted = extensionFields(of: event) else { return nil }
            return extracted.kind
        }
        XCTAssertEqual(kinds, [PtcDispatchEvents.startKind,
                               PtcDispatchEvents.dispatchKind])
    }

    // MARK: - 车道单元面：弃单文案逐字 + exclusive 屏障

    func testLaneAbandonTextVerbatimAndExclusiveBarrier() async throws {
        let scope = RunCodeRunScope()
        let latch = TestLatch()
        let recordLock = NSLock()
        var startedNames: [String] = []
        var settledSubCalls: [(subCallId: String, isError: Bool)] = []
        let lane = PtcDispatchLane(
            maxParallel: 4,
            scope: scope,
            // 恒 exclusive：B 被 A 的屏障挡在队列（ptc.ts:419-420）。
            classify: { _ in .exclusive },
            runBody: { entry in
                // 取消即收敛（try? 吞 sleep 取消抛错）——登记⑮测试面。
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled {
                    return .failure("tool call aborted", code: "ABORTED",
                                    name: "AbortError")
                }
                return .success("body-\(entry.name)")
            },
            appendStart: { entry in
                recordLock.lock()
                startedNames.append(entry.name)
                recordLock.unlock()
                latch.openGate()
            },
            appendSettle: { entry, output in
                recordLock.lock()
                settledSubCalls.append((entry.subCallId, output.isError))
                recordLock.unlock()
            })

        let entryA = PtcDispatchEntry(name: "ptc_a", subCallId: "call-1:ptc:1",
                                      argsDispatched: .object([:]),
                                      argsLogged: .object([:]))
        let entryB = PtcDispatchEntry(name: "ptc_b", subCallId: "call-1:ptc:2",
                                      argsDispatched: .object([:]),
                                      argsLogged: .object([:]))
        await lane.submit(entryA)
        await lane.submit(entryB)
        // A 已启动（start 事件落盘、body 在飞），B 仍排队。
        await latch.awaitOpen()
        try? await Task.sleep(nanoseconds: 50_000_000) // B 无容量确认窗口
        recordLock.lock()
        let enteredBeforeAbort = startedNames.count
        recordLock.unlock()
        XCTAssertEqual(enteredBeforeAbort, 1)

        // run 落定：A 在飞收敛（isError），B 弃单（逐字文案，ptc.ts:531）。
        scope.abort(reason: "run_code settled")
        let outcomeB = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    _ = try await entryB.awaitOutcome()
                    return "fulfilled"
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                }
            }
            let first = try await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcomeB,
                       "run_code run is over (run_code settled); ptc_b tool call abandoned")

        await lane.drain()
        let outcomeA = try await entryA.awaitOutcome()
        XCTAssertTrue(outcomeA.isError)
        // 弃单条目零 start 事件（types.ts:33-34）；在飞条目 settle isError。
        recordLock.lock()
        let startsSnapshot = startedNames
        let settlesSnapshot = settledSubCalls
        recordLock.unlock()
        XCTAssertEqual(startsSnapshot, ["ptc_a"])
        XCTAssertEqual(settlesSnapshot.map { $0.subCallId }, ["call-1:ptc:1"])
        XCTAssertEqual(settlesSnapshot.map { $0.isError }, [true])
    }
}
