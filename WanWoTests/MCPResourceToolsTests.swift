//
//  MCPResourceToolsTests.swift
//  WanWoTests
//
//  【M4-A 件12】件8 锚点：资源三元元工具（MCPResourceTools.swift，参照=
//  codex codex-rs codex-mcp/src/pagination.rs:27-80 + mcp_resource.rs）——
//  collectPaginated 四重防护硬失败（页数 100/条目 2048 per-collect/cursor
//  64KB/重复 cursor 环）、normalizeOptional trim+空归无、validateCursor
//  64KB→MCP_CURSOR_TOO_LARGE、execute 级：聚合禁 cursor
//  MCP_CURSOR_REQUIRES_SERVER 文案 + read "server must be provided"
//  （codex normalize_required_string :337-344）+ MCP_UNKNOWN_SERVER。
//  Client 无法离线伪造 → 经 fetch 闭包/可构造 ToolExecutionContext 确定性
//  注入（不真等待：deadline 检查不可注入=测试缺口，汇报登记）。
//

import XCTest
import MCP
@testable import WanWo

// MARK: - 测试替身

/// MCPResourceConnecting 假实现：execute 级测试只走参数校验路径，
/// readyClient 恒抛（不可达即 fail loud）。
private struct MockResourceConnections: MCPResourceConnecting {
    let names: [String]

    func serverNames() -> [String] { names }

    func readyClient(named serverName: String) async throws -> Client {
        throw MCPConfigurationError("MockResourceConnections: network unreachable in tests")
    }

    func reportRequestFailure(serverName: String, generation: Client) {}
}

/// fetch 调用计数（@Sendable 闭包内串行调用，锁护纪律）。
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class MCPResourceToolsTests: XCTestCase {

    // MARK: collectPaginated（pagination.rs:27-80 直译）

    private func collect(
        _ fetch: @escaping @Sendable (String?) async throws -> ([JSONValue], String?)
    ) async throws -> [JSONValue] {
        try await MCPResourceTools.collectPaginated(
            connections: MockResourceConnections(names: []),
            serverName: "docs",
            method: "resources/list",
            fetch: fetch)
    }

    func testCollectAggregatesAllPages() async throws {
        let result = try await collect { cursor in
            switch cursor {
            case nil: return ([.string("a")], "c1")
            case "c1": return ([.string("b"), .string("c")], "c2")
            default: return ([.string("d")], nil)
            }
        }
        XCTAssertEqual(result, [.string("a"), .string("b"),
                                .string("c"), .string("d")])
    }

    /// 页数上限：恰好 100 次 fetch 后硬失败（:44-48——第 101 轮入口判定）。
    func testCollectFailsAtPageLimit() async {
        let counter = FetchCounter()
        do {
            _ = try await collect { _ in
                counter.increment()
                return ([.string("x")], "next")
            }
            XCTFail("expected pagination page-limit failure")
        } catch {
            XCTAssertEqual(String(describing: error),
                           "mcp-client(docs): resources/list exceeded the pagination "
                               + "limit of 100 pages")
            XCTAssertEqual(counter.value, 100)
        }
    }

    /// 条目上限（per-collect）：单页 2049 项即硬失败（:54-58）。
    func testCollectFailsOnSinglePageItemOverflow() async {
        do {
            _ = try await collect { _ in
                (Array(repeating: JSONValue.string("item"), count: 2049), nil)
            }
            XCTFail("expected catalog item-limit failure")
        } catch {
            XCTAssertEqual(String(describing: error),
                           "mcp-client(docs): resources/list exceeded the catalog "
                               + "limit of 2048 items")
        }
    }

    /// 条目上限：累计形态——首页恰好 2048 + 翻页后再来 1 项 → 硬失败非截断。
    func testCollectFailsOnCumulativeItemOverflow() async {
        do {
            _ = try await collect { cursor in
                cursor == nil
                    ? (Array(repeating: JSONValue.string("item"), count: 2048), "next")
                    : ([.string("one-more")], nil)
            }
            XCTFail("expected catalog item-limit failure")
        } catch {
            XCTAssertEqual(String(describing: error),
                           "mcp-client(docs): resources/list exceeded the catalog "
                               + "limit of 2048 items")
        }
    }

    /// 恰好 2048 项（单页收尾）= 合法边界。
    func testCollectAtExactItemLimitSucceeds() async throws {
        let result = try await collect { _ in
            (Array(repeating: JSONValue.string("item"), count: 2048), nil)
        }
        XCTAssertEqual(result.count, 2048)
    }

    /// nextCursor 超 64KB：跟随前校验硬失败（:64-68）。
    func testCollectFailsOnOversizedCursor() async {
        do {
            _ = try await collect { _ in
                ([.string("x")], String(repeating: "c", count: 64 * 1024 + 1))
            }
            XCTFail("expected cursor-size failure")
        } catch {
            XCTAssertEqual(String(describing: error),
                           "mcp-client(docs): resources/list returned a pagination "
                               + "cursor exceeding 65536 bytes")
        }
    }

    /// 64KB 恰好 = 合法边界（> 判定）。
    func testCollectAcceptsCursorAtExactLimit() async throws {
        let result = try await collect { cursor in
            cursor == nil
                ? ([.string("a")], String(repeating: "c", count: 64 * 1024))
                : ([.string("b")], nil)
        }
        XCTAssertEqual(result, [.string("a"), .string("b")])
    }

    /// 重复 cursor 环检测（:69-71）。
    func testCollectFailsOnRepeatedCursor() async {
        let counter = FetchCounter()
        do {
            _ = try await collect { _ in
                counter.increment()
                return ([.string("x")], "loop")
            }
            XCTFail("expected repeated-cursor failure")
        } catch {
            XCTAssertEqual(String(describing: error),
                           "mcp-client(docs): resources/list returned a repeated "
                               + "pagination cursor")
            XCTAssertEqual(counter.value, 2)
        }
    }

    // MARK: normalizeOptional（codex mcp_resource.rs:326-335）

    func testNormalizeOptional() {
        XCTAssertNil(MCPResourceTools.normalizeOptional(nil))
        XCTAssertNil(MCPResourceTools.normalizeOptional(""))
        XCTAssertNil(MCPResourceTools.normalizeOptional("   \n\t "))
        XCTAssertEqual(MCPResourceTools.normalizeOptional("  docs  "), "docs")
        XCTAssertEqual(MCPResourceTools.normalizeOptional("docs"), "docs")
    }

    // MARK: validateCursor（64KB 硬上限；MCP_CURSOR_TOO_LARGE）

    func testValidateCursorPassesNilAndNormal() {
        XCTAssertNil(MCPResourceTools.validateCursor(nil))
        XCTAssertNil(MCPResourceTools.validateCursor("normal"))
    }

    func testValidateCursorRejectsOversized() throws {
        let oversized = String(repeating: "c", count: 64 * 1024 + 1)
        let rejection = try XCTUnwrap(MCPResourceTools.validateCursor(oversized))
        XCTAssertTrue(rejection.isError)
        XCTAssertEqual(rejection.errorCode, "MCP_CURSOR_TOO_LARGE")
        XCTAssertEqual(rejection.errorName, "McpResourceError")
        XCTAssertTrue(rejection.text.contains(
            "mcp-client: cursor exceeds the 65536 byte limit"),
                      "unexpected: \(rejection.text)")
    }

    // MARK: execute 级（参数校验路径；不触网）

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test-session",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test-session"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-mcp-resource-tests")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    /// codex :89-91——cursor 无 server 拒绝（文案形态保留本件版本）。
    func testListResourcesRejectsCursorWithoutServer() async throws {
        let tool = MCPResourceTools.ListMcpResourcesTool(
            connections: MockResourceConnections(names: ["docs"]))
        let output = try await tool.execute(
            .object(["cursor": .string("abc")]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "MCP_CURSOR_REQUIRES_SERVER")
        XCTAssertEqual(output.errorName, "McpResourceError")
        XCTAssertTrue(output.text.contains("'cursor' requires 'server'"),
                      "unexpected: \(output.text)")
        XCTAssertTrue(output.text.contains(
            "aggregate listing fetches every page up to the guard limits"),
                      "unexpected: \(output.text)")
    }

    /// templates 同款（共用 ListResourceArgs.target——源码纠正锚点）。
    func testListTemplatesRejectsCursorWithoutServer() async throws {
        let tool = MCPResourceTools.ListMcpResourceTemplatesTool(
            connections: MockResourceConnections(names: ["docs"]))
        let output = try await tool.execute(
            .object(["cursor": .string("abc")]), makeContext())
        XCTAssertEqual(output.errorCode, "MCP_CURSOR_REQUIRES_SERVER")
    }

    /// codex normalize_required_string :337-344——"<field> must be provided"。
    func testReadResourceRequiresServer() async throws {
        let tool = MCPResourceTools.ReadMcpResourceTool(
            connections: MockResourceConnections(names: ["docs"]))
        let argList: [JSONValue] = [
            .object([:]),
            .object(["server": .string("   ")]),  // trim 后空 → 同拒绝路径
        ]
        for args in argList {
            let output = try await tool.execute(args, makeContext())
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
            XCTAssertTrue(output.text.contains("server must be provided"),
                          "unexpected: \(output.text)")
        }
    }

    func testReadResourceRequiresUri() async throws {
        let tool = MCPResourceTools.ReadMcpResourceTool(
            connections: MockResourceConnections(names: ["docs"]))
        let output = try await tool.execute(
            .object(["server": .string("docs")]), makeContext())
        XCTAssertEqual(output.errorCode, "MCP_INVALID_ARGUMENTS")
        XCTAssertTrue(output.text.contains("uri must be provided"),
                      "unexpected: \(output.text)")
    }

    /// 未知 server：fail closed（codex 单 server 未知即拒）。
    func testListResourcesRejectsUnknownServer() async throws {
        let tool = MCPResourceTools.ListMcpResourcesTool(
            connections: MockResourceConnections(names: ["docs"]))
        let output = try await tool.execute(
            .object(["server": .string("nope")]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "MCP_UNKNOWN_SERVER")
        XCTAssertTrue(output.text.contains("unknown MCP server \"nope\""),
                      "unexpected: \(output.text)")
    }
}
