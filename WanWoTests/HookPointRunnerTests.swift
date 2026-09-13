//
//  HookPointRunnerTests.swift
//  WanWoTests
//
//  【M4-E 批 E5 测试 · runPoint 编排（桥无关层）】桩 executor + 真
//  SessionWriter/registry：双桥 serial 序（固定 claude→codex）/ 跨桥 merge
//  （A 桥 deny + B 桥无决策 → deny，不被稀释）/ 事件对落盘（handlerId
//  格式逐字 + matcher 随组）/ SessionStart 零事件对锚 / updatedInput+system
//  Message warn 文案逐字（warnSink 缝）/ payload 形态方言轴（CC 完整
//  arguments vs codex {command} 折叠 / snake_case + turn_id + model +
//  permission_mode）/ matcher 双桥模式过滤（CC literal 备选 vs codex regex）/
//  codex plainStdoutAsContext 折叠（CC 桥不折叠）/ append 失败吞错继续（R5）。
//

import XCTest
@testable import WanWo

/// 桩执行器：请求/载荷全量记录（HookRunnerTests 同模式）。
private final class RecordingHookExecutor: HookCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HookExecutionRequest] = []
    private(set) var stagedPayloads: [Data] = []

    var runBehavior: @Sendable (HookExecutionRequest) async throws -> HookShellOutcome = { _ in
        HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
    }

    func stagePayload(_ data: Data) -> String? {
        lock.lock(); stagedPayloads.append(data); lock.unlock()
        return "/var/wanwo/workspace/.wanwo-hooks/payload-stub.json"
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

    func snapshotPayloads() -> [Data] {
        lock.lock(); defer { lock.unlock() }; return stagedPayloads
    }
}

final class HookPointRunnerTests: XCTestCase {

    private var executor: RecordingHookExecutor!
    private var writer: SessionWriter!
    private var directory: URL!
    private var warnings: [String]!

    override func setUp() async throws {
        try await super.setUp()
        ExtensionEventRegistry.shared.resetForTests()
        HookSessionEvents.registerEventSchemas()
        executor = RecordingHookExecutor()
        (writer, directory) = try await Self.makeWriter(id: "hook-points")
        warnings = []
    }

    override func tearDown() async throws {
        ExtensionEventRegistry.shared.resetForTests()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private static func makeWriter(id: String) async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-points-\(id)-\(UUID().uuidString)",
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

    // MARK: runtime 构造助手

    private func claudeRuntime(
        _ groups: [String: [MatcherGroup]]
    ) -> HookBridgeRuntime {
        HookBridgeRuntime(dialect: .claudeCode, groups: groups, warnings: [],
                          trailingNewline: true, matcherMode: .claudeCode,
                          stderrSummaryMaxChars: 500,
                          defaultTimeoutMs: 600_000, model: "")
    }

    private func codexRuntime(
        _ groups: [String: [MatcherGroup]]
    ) -> HookBridgeRuntime {
        HookBridgeRuntime(dialect: .codex, groups: groups, warnings: [],
                          trailingNewline: false, matcherMode: .codex,
                          stderrSummaryMaxChars: 500,
                          defaultTimeoutMs: 600_000, model: "")
    }

    private func makeRunner(_ runtimes: [HookBridgeRuntime]) -> HookPointRunner {
        let runner = HookPointRunner(sessionId: "s1", writer: writer,
                                     runtimes: runtimes, executor: executor)
        runner.warnSink = { [weak self] in self?.warnings.append($0) }
        return runner
    }

    private func hook(_ command: String) -> CommandHook {
        CommandHook(command: command)
    }

    private func extensionFields(of event: SessionEvent)
        -> (kind: String, fields: [String: JSONValue])? {
        guard case .extensionEvent(let kind, let payload) = event.payload,
              case .object(let fields) = payload else { return nil }
        return (kind, fields)
    }

    private func parsePayload(_ data: Data) -> JSONValue? {
        JSONValue(data: data)
    }

    // MARK: 双桥 serial 序（固定 claude→codex）

    func testSerialOrderAcrossBridges() async {
        let runner = makeRunner([
            codexRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("codex-hook.sh")])]]),
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc-hook.sh")])]]),
        ])
        _ = await runner.preToolUse(turn: 1, toolName: "Bash",
                                    args: .object(["command": .string("ls")]),
                                    callId: "call-1")
        let commands = executor.snapshotRequests().map { $0.command }
        // 装配序故意 codex 在前——runner 固定 claude→codex（裁定①）。
        XCTAssertTrue(commands[0].contains("cc-hook.sh"), "commands=\(commands)")
        XCTAssertTrue(commands[1].contains("codex-hook.sh"), "commands=\(commands)")
    }

    // MARK: 跨桥 merge（A 桥 deny + B 桥无决策 → deny 不被稀释）

    func testCrossBridgeMergeDenyWins() async {
        executor.runBehavior = { request in
            if request.command.contains("cc-hook.sh") {
                return HookShellOutcome(exitCode: 2, stdout: "",
                                        stderr: "blocked by policy")
            }
            return HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
        }
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc-hook.sh")])]]),
            codexRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("codex-hook.sh")])]]),
        ])
        let merged = await runner.preToolUse(turn: 1, toolName: "Bash",
                                             args: .null, callId: "call-1")
        XCTAssertEqual(merged.decision, .deny)
        XCTAssertEqual(merged.reason, "blocked by policy")
    }

    func testCrossBridgeMergeCodexDenyAlsoWins() async {
        executor.runBehavior = { request in
            if request.command.contains("codex-hook.sh") {
                return HookShellOutcome(exitCode: 2, stdout: "",
                                        stderr: "codex blocks")
            }
            return HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
        }
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc-hook.sh")])]]),
            codexRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("codex-hook.sh")])]]),
        ])
        let merged = await runner.preToolUse(turn: 1, toolName: "Bash",
                                             args: .null, callId: "call-1")
        XCTAssertEqual(merged.decision, .deny)
        XCTAssertEqual(merged.reason, "codex blocks")
    }

    // MARK: 事件对落盘（handlerId 格式逐字 + matcher 随组）

    func testEventPairRecordedWithHandlerIdFormat() async throws {
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(
                matcher: "Bash", hooks: [hook("cc-hook.sh")])]]),
        ])
        _ = await runner.preToolUse(turn: 3, toolName: "Bash",
                                    args: .null, callId: "call-1")
        let events = writer.events
        XCTAssertEqual(events.count, 2)
        let invoked = try XCTUnwrap(extensionFields(of: events[0]))
        XCTAssertEqual(invoked.kind, HookSessionEvents.invokedKind)
        // CC index.ts:83 逐字格式：claude-code:{point}:{n}（n 从 1 起）。
        XCTAssertEqual(invoked.fields["handlerId"], .string("claude-code:PreToolUse:1"))
        XCTAssertEqual(invoked.fields["dialect"], .string("claude-code"))
        XCTAssertEqual(invoked.fields["turn"], .int(3))
        XCTAssertEqual(invoked.fields["matcher"], .string("Bash"))
        let result = try XCTUnwrap(extensionFields(of: events[1]))
        XCTAssertEqual(result.kind, HookSessionEvents.resultKind)
        XCTAssertEqual(result.fields["handlerId"], .string("claude-code:PreToolUse:1"))
        XCTAssertEqual(result.fields["decision"], .string("pass"))
    }

    func testHandlerIdCounterSharedAcrossPointsPerBridge() async {
        let runner = makeRunner([
            claudeRuntime([
                "PreToolUse": [MatcherGroup(hooks: [hook("cc-pre.sh")])],
                "Stop": [MatcherGroup(hooks: [hook("cc-stop.sh")])],
            ]),
        ])
        _ = await runner.preToolUse(turn: 1, toolName: "Bash",
                                    args: .null, callId: "c1")
        _ = await runner.stop(turn: 1)
        let handlerIds = writer.events.compactMap { event -> String? in
            guard let extracted = extensionFields(of: event),
                  extracted.kind == HookSessionEvents.invokedKind,
                  case .string(let id)? = extracted.fields["handlerId"] else {
                return nil
            }
            return id
        }
        // 每桥一枚举跨 point 共享递增（CC index.ts:81 全局 counter）。
        XCTAssertEqual(handlerIds, ["claude-code:PreToolUse:1",
                                    "claude-code:Stop:2"])
    }

    // MARK: SessionStart 零事件对锚（turn=nil，detached）

    func testSessionStartOmitsEventPair() async {
        let runner = makeRunner([
            claudeRuntime(["SessionStart": [MatcherGroup(
                hooks: [hook("cc-start.sh")])]]),
            codexRuntime(["SessionStart": [MatcherGroup(
                hooks: [hook("codex-start.sh")])]]),
        ])
        let merged = await runner.sessionStart(source: "startup")
        // detached lifecycle points omit the pair（CC index.ts:157/:181 同条件
        // ——E3 SessionStart 例外）。
        XCTAssertTrue(writer.events.isEmpty)
        // 双桥都执行了。
        XCTAssertEqual(executor.snapshotRequests().count, 2)
        XCTAssertEqual(merged.decision, .none)
    }

    // MARK: warn 文案逐字（warnSink 缝）

    func testUpdatedInputAndSystemMessageWarnTexts() async {
        executor.runBehavior = { request in
            if request.command.contains("cc-hook.sh") {
                return HookShellOutcome(
                    exitCode: 0,
                    stdout: "{\"systemMessage\":\"careful\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"a\":1}}}",
                    stderr: "")
            }
            return HookShellOutcome(
                exitCode: 0,
                stdout: "{\"systemMessage\":\"codex says\"}",
                stderr: "")
        }
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc-hook.sh")])]]),
            codexRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("codex-hook.sh")])]]),
        ])
        _ = await runner.preToolUse(turn: 1, toolName: "Bash",
                                    args: .null, callId: "call-1")
        // CC index.ts:176/:179 逐字。
        XCTAssertTrue(warnings.contains(
            "hooks-claude-code: PreToolUse hook requested updatedInput, which is not yet honored (ignored)"),
            "warnings=\(warnings)")
        XCTAssertTrue(warnings.contains(
            "hooks-claude-code: PreToolUse hook emitted a systemMessage, which is not yet surfaced (ignored)"))
        // codex index.ts:162 逐字（codex 无 updatedInput warn）。
        XCTAssertTrue(warnings.contains(
            "hooks-codex: PreToolUse hook emitted a systemMessage, which is not yet surfaced (ignored)"))
        XCTAssertEqual(warnings.count, 3)
    }

    // MARK: payload 形态方言轴

    func testPayloadShapesPerDialect() async throws {
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc.sh")])]]),
            codexRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cx.sh")])]]),
        ])
        let args: JSONValue = .object([
            "command": .string("git status"),
            "extra": .int(7),
        ])
        _ = await runner.preToolUse(turn: 4, toolName: "shell",
                                    args: args, callId: "call-9")
        let payloads = executor.snapshotPayloads().compactMap(parsePayload)
        XCTAssertEqual(payloads.count, 2)
        guard case .object(let cc) = payloads[0],
              case .object(let cx) = payloads[1] else {
            return XCTFail("payload 必须是 object")
        }
        // CC：完整 arguments object 直传（tool_input 原样）。
        XCTAssertEqual(cc["tool_input"], args)
        XCTAssertEqual(cc["tool_name"], .string("shell"))
        XCTAssertEqual(cc["tool_use_id"], .string("call-9"))
        XCTAssertEqual(cc["session_id"], .string("s1"))
        XCTAssertEqual(cc["transcript_path"], .string(""))
        XCTAssertEqual(cc["hook_event_name"], .string("PreToolUse"))
        XCTAssertNil(cc["turn_id"], "CC payload 无 turn_id")
        XCTAssertNil(cc["model"], "CC payload 无 model")
        // Codex：{command} 折叠 + snake_case + turn_id + model + permission_mode。
        XCTAssertEqual(cx["tool_input"],
                       .object(["command": .string("git status")]))
        XCTAssertEqual(cx["tool_name"], .string("shell"))
        XCTAssertEqual(cx["tool_use_id"], .string("call-9"))
        XCTAssertEqual(cx["turn_id"], .string("4"))
        XCTAssertEqual(cx["model"], .string(""))
        XCTAssertEqual(cx["permission_mode"], .string("default"))
        XCTAssertEqual(cx["transcript_path"], .null)
    }

    func testCodexStopPayloadCarriesStopHookActiveAndLastAssistantMessage() async throws {
        let runner = makeRunner([
            codexRuntime(["Stop": [MatcherGroup(hooks: [hook("cx.sh")])]]),
            claudeRuntime(["Stop": [MatcherGroup(hooks: [hook("cc.sh")])]]),
        ])
        _ = await runner.stop(turn: 2)
        let payloads = executor.snapshotPayloads().compactMap(parsePayload)
        XCTAssertEqual(payloads.count, 2)
        // 裁定①：runner 固定 claude→codex 序（makeRunner 传参序不影响）。
        guard case .object(let cc) = payloads[0],
              case .object(let cx) = payloads[1] else {
            return XCTFail("payload 必须是 object")
        }
        // codex index.ts:261——stop_hook_active:false + last_assistant_message:null。
        XCTAssertEqual(cx["stop_hook_active"], .bool(false))
        XCTAssertEqual(cx["last_assistant_message"], .null)
        XCTAssertEqual(cx["turn_id"], .string("2"))
        // CC index.ts:345——stop_hook_active:false（无 last_assistant_message）。
        XCTAssertEqual(cc["stop_hook_active"], .bool(false))
        XCTAssertNil(cc["last_assistant_message"])
    }

    // MARK: matcher 双桥模式过滤（CC literal 备选 vs codex regex）

    func testMatcherFiltersPerBridgeMode() async {
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(
                matcher: "Bash|Edit", hooks: [hook("cc.sh")])]]),
            codexRuntime(["PreToolUse": [MatcherGroup(
                matcher: "^Bash$", hooks: [hook("cx.sh")])]]),
        ])
        // query="Edit"：CC literal 精确备选命中；codex regex 不命中。
        _ = await runner.preToolUse(turn: 1, toolName: "Edit",
                                    args: .null, callId: "c1")
        let commands = executor.snapshotRequests().map { $0.command }
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("cc.sh"))
    }

    // MARK: codex plainStdoutAsContext 折叠（CC 桥不折叠）

    func testCodexPlainStdoutFoldsAsContextOnlyForCodex() async {
        executor.runBehavior = { request in
            if request.command.contains("cx.sh") {
                return HookShellOutcome(exitCode: 0, stdout: "plain context text",
                                        stderr: "")
            }
            return HookShellOutcome(exitCode: 0, stdout: "cc plain", stderr: "")
        }
        let runner = makeRunner([
            claudeRuntime(["SessionStart": [MatcherGroup(hooks: [hook("cc.sh")])]]),
            codexRuntime(["SessionStart": [MatcherGroup(hooks: [hook("cx.sh")])]]),
        ])
        let merged = await runner.sessionStart(source: "startup")
        // codex index.ts:152-156——干净 plain stdout 折叠为上下文；CC 桥无此
        // 逻辑（CC additionalContext 只来自结构化 JSON）。
        XCTAssertEqual(merged.additionalContext, ["plain context text"])
    }

    // MARK: append 失败吞错继续（R5 裁定④）

    func testAppendFailureSwallowedAndRunContinues() async {
        // 注册表换成缺必填字段的问题 schema → 写侧门拒 hook/invoked（E1 门）。
        ExtensionEventRegistry.shared.resetForTests()
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: HookSessionEvents.invokedKind,
            requiredFields: [ExtensionFieldSchema("x", .string)]))
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: HookSessionEvents.resultKind,
            requiredFields: [ExtensionFieldSchema("x", .string)]))
        let runner = makeRunner([
            claudeRuntime(["PreToolUse": [MatcherGroup(hooks: [hook("cc.sh")])]]),
        ])
        let merged = await runner.preToolUse(turn: 1, toolName: "Bash",
                                             args: .null, callId: "c1")
        // 事件对双双被拒（日志吞错），但 hook 照常执行、outcome 照常返回。
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertEqual(executor.snapshotRequests().count, 1)
        XCTAssertEqual(merged.decision, .none)
    }
}
