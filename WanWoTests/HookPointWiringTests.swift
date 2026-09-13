//
//  HookPointWiringTests.swift
//  WanWoTests
//
//  【M4-E 批 E5 测试 · ToolPipeline 接线集成（真件）】真 ToolPipeline + 真
//  ToolRegistry + 桩 executor：PreToolUse deny=UNKNOWN_TOOL 后 guard 前合成
//  错误（工具体不触达）/ ask→审批缝（SandboxGate 同通道；allowedOnce 准入 /
//  rejected 合成失败）/ PostToolUse deny=结果替换 isError+短路 adviser /
//  additionalContext 并入结果文本 / hookPoints=nil 旁路保既有面（默认值
//  纪律回归）。
//

import XCTest
@testable import WanWo

/// 最小回声工具（execute 触达记录）。
private final class EchoHookTool: AgentTool, @unchecked Sendable {
    let name = "echo_hooktest"
    let description = "test echo tool"
    var parameters: JSONValue { .object([:]) }
    let lock = NSLock()
    var executeCount = 0

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        lock.lock(); executeCount += 1; lock.unlock()
        return .success("ran")
    }
}

final class HookPointWiringTests: XCTestCase {

    private var executor: RecordingHookExecutorWiring!
    private var writer: SessionWriter!
    private var directory: URL!
    private var tool: EchoHookTool!
    private var registry: ToolRegistry!
    private var spillRoot: URL!
    private(set) var approverCalls: [(tool: String, callId: String?, reason: String)] = []
    private var approverOutcome: ApprovalOutcome = .allowedOnce

    override func setUp() async throws {
        try await super.setUp()
        ExtensionEventRegistry.shared.resetForTests()
        HookSessionEvents.registerEventSchemas()
        executor = RecordingHookExecutorWiring()
        (writer, directory) = try await Self.makeWriter(id: "wiring")
        tool = EchoHookTool()
        registry = ToolRegistry()
        registry.register(tool)
        spillRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-wiring-spill-\(UUID().uuidString)",
                                     isDirectory: true)
        approverCalls = []
        approverOutcome = .allowedOnce
    }

    override func tearDown() async throws {
        ExtensionEventRegistry.shared.resetForTests()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: spillRoot)
        try await super.tearDown()
    }

    private static func makeWriter(id: String) async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-wiring-\(id)-\(UUID().uuidString)",
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

    private func claudeRuntime(
        _ groups: [String: [MatcherGroup]]
    ) -> HookBridgeRuntime {
        HookBridgeRuntime(dialect: .claudeCode, groups: groups, warnings: [],
                          trailingNewline: true, matcherMode: .claudeCode,
                          stderrSummaryMaxChars: 500,
                          defaultTimeoutMs: 600_000, model: "")
    }

    private func makeRunner(
        _ groups: [String: [MatcherGroup]]
    ) -> HookPointRunner {
        HookPointRunner(sessionId: "w1", writer: writer,
                        runtimes: [claudeRuntime(groups)],
                        executor: executor)
    }

    private func makePipeline(hookPoints: HookPointRunner?) -> ToolPipeline {
        ToolPipeline(registry: registry, repeatAdviser: RepeatCallAdviser(),
                     hookPoints: hookPoints)
    }

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "w1",
            turn: 1,
            step: 1,
            callId: "call-1",
            workspace: AgentLoop.workspaceAccess(sessionId: "w1"),
            spill: SpillStore(root: spillRoot),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: { [weak self] toolName, callId, reason in
                self?.approverCalls.append((toolName, callId, reason))
                return self?.approverOutcome ?? .allowedOnce
            })
    }

    private func run(_ pipeline: ToolPipeline) async -> ToolOutput {
        await pipeline.run(toolName: "echo_hooktest",
                           args: .object(["command": .string("hi")]),
                           ctx: makeContext())
    }

    // MARK: PreToolUse deny → 合成错误 + 工具体不触达（UNKNOWN_TOOL 后 guard 前）

    func testPreToolUseDenySynthesizesFailureBeforeExecute() async {
        executor.runBehavior = { _ in
            HookShellOutcome(exitCode: 2, stdout: "", stderr: "no shell for you")
        }
        let pipeline = makePipeline(hookPoints: makeRunner([
            "PreToolUse": [MatcherGroup(matcher: "echo_hooktest",
                                        hooks: [CommandHook(command: "pre.sh")])],
        ]))
        let output = await run(pipeline)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("no shell for you"))
        XCTAssertEqual(output.errorCode, "DENIED_BY_HOOK")
        tool.lock.lock()
        let count = tool.executeCount
        tool.lock.unlock()
        XCTAssertEqual(count, 0, "deny 时工具体不得触达")
        // 事件对已落盘（turn 非 nil）。
        XCTAssertEqual(writer.events.count, 2)
    }

    // MARK: PreToolUse ask → 审批缝（SandboxGate 提权同通道）

    func testPreToolUseAskApprovedExecutes() async {
        executor.runBehavior = { _ in
            HookShellOutcome(
                exitCode: 0,
                stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
                    + "\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"confirm?\"}}",
                stderr: "")
        }
        approverOutcome = .allowedOnce
        let pipeline = makePipeline(hookPoints: makeRunner([
            "PreToolUse": [MatcherGroup(matcher: "echo_hooktest",
                                        hooks: [CommandHook(command: "pre.sh")])],
        ]))
        let output = await run(pipeline)
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "ran")
        XCTAssertEqual(approverCalls.first?.tool, "echo_hooktest")
        XCTAssertEqual(approverCalls.first?.callId, "call-1")
        XCTAssertEqual(approverCalls.first?.reason, "confirm?")
    }

    func testPreToolUseAskRejectedFailsClosed() async {
        executor.runBehavior = { _ in
            HookShellOutcome(
                exitCode: 0,
                stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
                    + "\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"confirm?\"}}",
                stderr: "")
        }
        approverOutcome = .rejected
        let pipeline = makePipeline(hookPoints: makeRunner([
            "PreToolUse": [MatcherGroup(matcher: "echo_hooktest",
                                        hooks: [CommandHook(command: "pre.sh")])],
        ]))
        let output = await run(pipeline)
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "HOOK_ASK_REJECTED")
        tool.lock.lock()
        let count = tool.executeCount
        tool.lock.unlock()
        XCTAssertEqual(count, 0)
    }

    // MARK: PostToolUse deny → 结果替换 isError + 短路 adviser

    func testPostToolUseDenyReplacesResult() async {
        executor.runBehavior = { _ in
            HookShellOutcome(exitCode: 2, stdout: "",
                             stderr: "result must not stand")
        }
        let pipeline = makePipeline(hookPoints: makeRunner([
            "PostToolUse": [MatcherGroup(matcher: "echo_hooktest",
                                         hooks: [CommandHook(command: "post.sh")])],
        ]))
        let output = await run(pipeline)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("result must not stand"))
        XCTAssertEqual(output.errorCode, "DENIED_BY_HOOK")
        XCTAssertFalse(output.text.contains("ran"), "原结果被替换")
    }

    // MARK: PostToolUse additionalContext → 并入结果文本

    func testPostToolUseContextAppendedToResult() async {
        executor.runBehavior = { _ in
            HookShellOutcome(
                exitCode: 0,
                stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\","
                    + "\"permissionDecision\":\"allow\",\"additionalContext\":\"hook says hi\"}}",
                stderr: "")
        }
        let pipeline = makePipeline(hookPoints: makeRunner([
            "PostToolUse": [MatcherGroup(matcher: "echo_hooktest",
                                         hooks: [CommandHook(command: "post.sh")])],
        ]))
        let output = await run(pipeline)
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("ran"))
        XCTAssertTrue(output.text.contains("hook says hi"))
    }

    // MARK: hookPoints = nil 旁路（默认值保既有调用面回归）

    func testNilRunnerBypassesHooks() async {
        let pipeline = makePipeline(hookPoints: nil)
        let output = await run(pipeline)
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "ran")
        XCTAssertTrue(executor.snapshotRequests().isEmpty)
        XCTAssertTrue(writer.events.isEmpty)
    }
}

/// 桩执行器（独立文件私有——HookPointRunnerTests 同模式复制避免跨文件耦合）。
private final class RecordingHookExecutorWiring: HookCommandExecuting,
                                                  @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HookExecutionRequest] = []

    var runBehavior: @Sendable (HookExecutionRequest) async throws -> HookShellOutcome = { _ in
        HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
    }

    func stagePayload(_ data: Data) -> String? {
        "/var/wanwo/workspace/.wanwo-hooks/payload-stub.json"
    }

    func cleanupPayload(_ guestPath: String) {}

    func cancel(pid: Int32) {}

    func run(_ request: HookExecutionRequest) async throws -> HookShellOutcome {
        lock.lock(); requests.append(request); lock.unlock()
        return try await runBehavior(request)
    }

    func snapshotRequests() -> [HookExecutionRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}
