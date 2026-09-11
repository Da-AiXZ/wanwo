//
//  MCPServerConfigToolTests.swift
//  WanWoTests
//
//  【M4-B B8 · 测试回归】B7 mcp_server_config 断言（lead 派单）：
//    · 查询形态（无门——read-only standing 照常）+ lastActivation 直通；
//    · 写入白名单值域（1-900；浮点/字符串形态拒不静默降级查询）；
//    · http 条目写入拒绝；read-only 拒（denial marker，FS_SANDBOX_DENIED）；
//    · 'never'/rejected 审批确定性拒绝（SANDBOX_ESCALATION_ERROR）；
//    · approved 提权放行并落盘（'danger 直通' 锚点：read-only standing +
//      approved danger-full-access → 成功）；
//    · TOCTOU（lead 批准加固）：审批窗口内条目被改 → MCP_CONFIG_RACE，
//      不做条件式半写；
//    · 文案修正后 hint 断言（stdio 有 hint/http 无；B7 返工锚：不含
//      "reconnect"，指向新会话生效）。
//  审批缝注入形态（lead：件内决策）：SandboxEscalationApprover 结构闭包
//  直注入 ToolExecutionContext.escalationApprover——确定性四值结算，
//  不真弹窗。竞态类确定性注入纪律：TOCTOU 用 approver 闭包内改 store。
//

import XCTest
@testable import WanWo

final class MCPServerConfigToolTests: XCTestCase {

    // MARK: fixture

    private let stdioServer = "py"
    private let httpServer = "web"

    /// 两形态 fixture：stdio（startupTimeoutSeconds=90）+ http。
    /// @MainActor：MCPServerStore init 是 @MainActor 隔离（B9 首跑编译红自修）。
    @MainActor
    private func makeStore() throws -> MCPServerStore {
        let json = #"""
        {"mcpServers":{"py":{"command":"/usr/bin/python3",
            "args":["-u","srv.py"],"env":{"A":"1"},
            "startupTimeoutSeconds":90},
            "web":{"url":"https://example.com/mcp"}}}
        """#
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-mcp-config-tool-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("servers.json")
        try Data(json.utf8).write(to: url)
        return MCPServerStore(fileURL: url)
    }

    /// lastActivation 独立 suite（逐测隔离——removePersistentDomain 先行）；
    /// 预置 "py" 一次 spawn 失败记录（查询直通锚点）。
    @MainActor
    private func makeLastActivation() throws -> MCPLastActivationStore {
        let suiteName = "test.mcpserverconfigtool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = MCPLastActivationStore(defaults: defaults)
        store.recordFailure(serverName: stdioServer,
                            message: "mcp-client(py): stdio spawn failed — "
                                + "the start command was not found or is not executable")
        return store
    }

    private func makeContext(sandboxMode: SandboxMode,
                             approver: SandboxEscalationApprover?) -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test-session",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test-session"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-mcp-config-tool-tests-spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: sandboxMode,
            escalationApprover: approver)
    }

    @MainActor
    private func makeTool() throws -> (MCPServerConfigTool, MCPServerStore) {
        let store = try makeStore()
        let tool = MCPServerConfigTool(store: store,
                                       lastActivation: try makeLastActivation())
        return (tool, store)
    }

    /// 工具输出 JSON 文本 → 解析（查询/写入结果断言用）。
    private func parse(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data)
            as? [String: Any])
        return root
    }

    // MARK: 查询（无门——read-only standing 照常）

    @MainActor
    func testQueryReturnsShapeAndUnGatedUnderReadOnly() async throws {
        let (tool, _) = try makeTool()
        let output = try await tool.execute(
            .object(["server": .string(stdioServer)]),
            makeContext(sandboxMode: .readOnly, approver: nil))
        XCTAssertFalse(output.isError, "unexpected: \(output.text)")
        let root = try parse(output.text)
        XCTAssertEqual(root["server"] as? String, stdioServer)
        XCTAssertEqual(root["transport"] as? String, "stdio")
        XCTAssertEqual(root["startupTimeoutSeconds"] as? Int, 90)
        XCTAssertEqual(root["effectiveStartupTimeoutSeconds"] as? Int, 90)
        // lastActivation 直通（spawn 失败原因——反馈闭环锚点）。
        let activation = try XCTUnwrap(root["lastActivation"] as? [String: Any])
        XCTAssertEqual(activation["succeeded"] as? Bool, false)
        XCTAssertNotNil(activation["message"] as? String)
        // B9 验收反馈修正锚：time 为带时区的 ISO8601（roundtrip 可解析，
        // 且解析回记录的绝对时刻——本地时区展示，非 UTC 恒定值误导）。
        let timeText = try XCTUnwrap(activation["time"] as? String)
        let roundtrip = try XCTUnwrap(ISO8601DateFormatter().date(from: timeText))
        XCTAssertLessThan(abs(roundtrip.timeIntervalSinceNow), 300,
                          "activation time must round-trip to the record moment")
        // 查询注记（模型区分查询/写入）。
        XCTAssertTrue(output.text.contains("query"), "unexpected: \(output.text)")
    }

    /// http 条目查询：transport=http、lastActivation 无记录=null。
    @MainActor
    func testQueryHttpEntryShape() async throws {
        let (tool, _) = try makeTool()
        let output = try await tool.execute(
            .object(["server": .string(httpServer)]),
            makeContext(sandboxMode: .readOnly, approver: nil))
        XCTAssertFalse(output.isError, "unexpected: \(output.text)")
        let root = try parse(output.text)
        XCTAssertEqual(root["transport"] as? String, "http")
        XCTAssertNil(root["startupTimeoutSeconds"] as? Int)
        XCTAssertTrue(root["lastActivation"] is NSNull)
    }

    /// unknown server → MCP_UNKNOWN_SERVER（查询/写入共用前置）。
    @MainActor
    func testQueryUnknownServerRejected() async throws {
        let (tool, _) = try makeTool()
        let output = try await tool.execute(
            .object(["server": .string("nope")]),
            makeContext(sandboxMode: .readOnly, approver: nil))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "MCP_UNKNOWN_SERVER")
    }

    /// server 缺失/空串 → must be provided（normalize_required_string 语义）。
    @MainActor
    func testMissingServerRejected() async throws {
        let (tool, _) = try makeTool()
        // 显式 [JSONValue] 标注：数组字面量含 `as` 转换时编译器推断为 [Any]
        //（B9 首跑编译红自修——:145/:146）。
        let argCases: [JSONValue] = [.object([:]),
                                     .object(["server": .string("   ")])]
        for args in argCases {
            let output = try await tool.execute(
                args, makeContext(sandboxMode: .readOnly, approver: nil))
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
            XCTAssertTrue(output.text.contains("server must be provided"),
                          "unexpected: \(output.text)")
        }
    }

    // MARK: 写入——白名单值域 + 参数形态纪律

    /// 值域 1-900：0 与 901 拒（写入面比读侧严——读侧忽略回默认，写侧拒绝）。
    @MainActor
    func testWriteValueRangeRejected() async throws {
        let (tool, _) = try makeTool()
        for value in [0, 901] {
            let output = try await tool.execute(
                .object(["server": .string(stdioServer),
                         "startup_timeout_seconds": .int(value)]),
                makeContext(sandboxMode: .workspaceWrite, approver: nil))
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
            XCTAssertTrue(output.text.contains(
                "must be an integer between 1 and \(MCPConstants.maxStartupTimeoutSeconds)"),
                "unexpected: \(output.text)")
        }
    }

    /// 参数形态纪律：字符串/浮点在场 = 拒（不静默降级查询——否则模型误判
    /// 写入已生效）。null 视同省略 → 查询路径。
    @MainActor
    func testWriteNonIntegerRejectedAndNullMeansQuery() async throws {
        let (tool, _) = try makeTool()
        for bad in [JSONValue.string("45"), .double(45.5)] {
            let output = try await tool.execute(
                .object(["server": .string(stdioServer),
                         "startup_timeout_seconds": bad]),
                makeContext(sandboxMode: .workspaceWrite, approver: nil))
            XCTAssertTrue(output.isError, "unexpected: \(output.text)")
            XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
        }
        // null → 查询（宽松 wire 纪律）。
        let query = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .null]),
            makeContext(sandboxMode: .workspaceWrite, approver: nil))
        XCTAssertFalse(query.isError, "unexpected: \(query.text)")
        XCTAssertTrue(query.text.contains("query"), "unexpected: \(query.text)")
    }

    // MARK: 写入——http 条目拒绝 + read-only fence

    /// http 条目写入拒绝（startup_timeout_seconds 对 streamable-http 无语义
    /// ——fail closed 不静默接受）。
    @MainActor
    func testWriteOnHttpEntryRejected() async throws {
        let (tool, _) = try makeTool()
        let output = try await tool.execute(
            .object(["server": .string(httpServer),
                     "startup_timeout_seconds": .int(120)]),
            makeContext(sandboxMode: .workspaceWrite, approver: nil))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
        XCTAssertTrue(output.text.contains("stdio servers only"),
                      "unexpected: \(output.text)")
    }

    /// standing read-only 拒：denial marker + hint（dsh mapError 形态），
    /// code FS_SANDBOX_DENIED——什么都没写。
    @MainActor
    func testWriteDeniedUnderReadOnly() async throws {
        let (tool, store) = try makeTool()
        let output = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .int(120)]),
            makeContext(sandboxMode: .readOnly, approver: nil))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "FS_SANDBOX_DENIED")
        XCTAssertTrue(output.text.contains(
            sandboxDenialMarker(.readOnly)), "unexpected: \(output.text)")
        XCTAssertTrue(output.text.contains(
            escalationHintMarker("MCP server configuration change")),
            "unexpected: \(output.text)")
        // 落盘未发生。
        let entry = try XCTUnwrap(store.servers.first { $0.id == stdioServer })
        XCTAssertEqual(entry.startupTimeoutSeconds, 90)
    }

    // MARK: 写入——审批缝四值结算

    /// approver rejected → SANDBOX_ESCALATION_ERROR（'never' 政策同径——
    /// 闭包首行确定性 rejected），落盘未发生。
    @MainActor
    func testWriteRejectedByApprover() async throws {
        let (tool, store) = try makeTool()
        let approver: SandboxEscalationApprover = { _, _, _ in .rejected }
        let output = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .int(120),
                     "sandbox_permissions": .string("danger-full-access"),
                     "justification": .string("update MCP server startup timeout")]),
            makeContext(sandboxMode: .workspaceWrite, approver: approver))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "SANDBOX_ESCALATION_ERROR")
        let entry = try XCTUnwrap(store.servers.first { $0.id == stdioServer })
        XCTAssertEqual(entry.startupTimeoutSeconds, 90)
    }

    /// approved → 放行落盘 + takesEffect 文案（B7 返工锚：only 新会话栈，
    /// 不再出现 "reconnects"）。
    @MainActor
    func testWriteApprovedPersists() async throws {
        let (tool, store) = try makeTool()
        let approver: SandboxEscalationApprover = { _, _, _ in .allowedOnce }
        let output = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .int(120),
                     "sandbox_permissions": .string("danger-full-access"),
                     "justification": .string("update MCP server startup timeout")]),
            makeContext(sandboxMode: .workspaceWrite, approver: approver))
        XCTAssertFalse(output.isError, "unexpected: \(output.text)")
        let root = try parse(output.text)
        XCTAssertEqual(root["startupTimeoutSeconds"] as? Int, 120)
        let takesEffect = try XCTUnwrap(root["takesEffect"] as? String)
        XCTAssertTrue(takesEffect.contains("newly spawned sessions only"),
                      "unexpected: \(takesEffect)")
        XCTAssertFalse(takesEffect.contains("reconnect"),
                       "B7 返工锚：生效语义不得指向 reconnect")
        // 落盘（其余字段保留）。
        let entry = try XCTUnwrap(store.servers.first { $0.id == stdioServer })
        XCTAssertEqual(entry.startupTimeoutSeconds, 120)
        XCTAssertEqual(entry.command, "/usr/bin/python3")
        XCTAssertEqual(entry.args, ["-u", "srv.py"])
    }

    /// 「danger 直通」锚点：read-only standing + approved danger-full-access
    /// → fence 过（granted mode 仅 stamp 本调用）→ 写入成功。
    @MainActor
    func testWriteApprovedUnderReadOnlyStandingPassesFence() async throws {
        let (tool, store) = try makeTool()
        let approver: SandboxEscalationApprover = { _, _, _ in .allowedOnce }
        let output = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .int(300),
                     "sandbox_permissions": .string("danger-full-access"),
                     "justification": .string("update MCP server startup timeout")]),
            makeContext(sandboxMode: .readOnly, approver: approver))
        XCTAssertFalse(output.isError, "unexpected: \(output.text)")
        let entry = try XCTUnwrap(store.servers.first { $0.id == stdioServer })
        XCTAssertEqual(entry.startupTimeoutSeconds, 300)
    }

    /// TOCTOU（lead 批准加固）：审批窗口内条目被移除（模拟设置页并发改动）
    /// → 落盘前重读判负 → MCP_CONFIG_RACE，不做条件式半写。
    @MainActor
    func testWriteTectouRaceRejected() async throws {
        let (tool, store) = try makeTool()
        let approver: SandboxEscalationApprover = { [weak store] _, _, _ in
            // 审批窗口内条目被改（设置页 remove）——跨 actor await。
            await store?.remove(id: "py")
            return .allowedOnce
        }
        let output = try await tool.execute(
            .object(["server": .string(stdioServer),
                     "startup_timeout_seconds": .int(120),
                     "sandbox_permissions": .string("danger-full-access"),
                     "justification": .string("update MCP server startup timeout")]),
            makeContext(sandboxMode: .workspaceWrite, approver: approver))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "MCP_CONFIG_RACE")
        XCTAssertTrue(output.text.contains("changed while the update was pending"),
                      "unexpected: \(output.text)")
        // 半写未发生：条目确已被 remove（而非被陈旧快照复活）。
        XCTAssertNil(store.servers.first { $0.id == stdioServer })
    }

    // MARK: schema（审批缝字段接线 + required）

    @MainActor
    func testSchemaWiresEscalationFieldsAndRequired() throws {
        let (tool, _) = try makeTool()
        let properties = try XCTUnwrap(tool.parameters
            .field("properties")?.objectValue)
        XCTAssertNotNil(properties["sandbox_permissions"],
                        "escalation schema fields must be wired")
        XCTAssertNotNil(properties["justification"])
        XCTAssertNotNil(properties["startup_timeout_seconds"])
        // startup_timeout_seconds 上界 = maxStartupTimeoutSeconds。
        let seconds = try XCTUnwrap(properties["startup_timeout_seconds"]?
            .objectValue)
        XCTAssertEqual(seconds["maximum"], .int(MCPConstants.maxStartupTimeoutSeconds))
        let required = try XCTUnwrap(tool.parameters.field("required")?.arrayValue)
        XCTAssertEqual(required, [.string("server")])
    }

    /// 待执行卡意图（纯函数）：写入展示新值，查询只展示 server。
    @MainActor
    func testPresentCallPureFunction() throws {
        let (tool, _) = try makeTool()
        let write = tool.presentCall(.object(
            ["server": .string(stdioServer),
             "startup_timeout_seconds": .int(120)]))
        XCTAssertEqual(write?.detail, "py → startup 120s")
        let query = tool.presentCall(.object(["server": .string(stdioServer)]))
        XCTAssertEqual(query?.detail, stdioServer)
    }

    // MARK: B7 返工后 hint 断言（stdio 有 / http 无）

    /// hint 文案锚：stdio 超时提示指向 mcp_server_config 且指到「新会话」
    ///（B7 返工：config=会话栈快照，重连不拾取新值——文案不得再含
    /// "reconnect"，否则模型引导用户重连→仍超时→困惑循环）；http 恒 nil。
    func testConnectTimeoutHintStdioHasHintHttpNil() {
        let stdio = McpConnectionSupervisor.connectTimeoutHint(
            for: .stdio(command: "/usr/bin/python3", args: [], env: [:], cwd: nil))
        let hint = try! XCTUnwrap(stdio)
        XCTAssertTrue(hint.contains("mcp_server_config"), "unexpected: \(hint)")
        XCTAssertTrue(hint.contains("start a new session"), "unexpected: \(hint)")
        XCTAssertFalse(hint.contains("reconnect"),
                       "B7 返工锚：hint 不得指向 reconnect")
        let http = McpConnectionSupervisor.connectTimeoutHint(
            for: .streamableHTTP(url: "https://example.com/mcp", headers: [:]))
        XCTAssertNil(http, "http hint must stay nil (文案不变锚点)")
    }
}
