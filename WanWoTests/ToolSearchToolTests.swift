//
//  ToolSearchToolTests.swift
//  WanWoTests
//
//  【M4-C1/C7 测试锚】ToolSearchTool / ToolSearchInfo 行为锚——对拍基准 =
//  codex-rs core/src/tools/handlers/tool_search.rs handle_call（:191-227 逐式）
//  + tool_search_spec.rs create_tool_search_tool（Omit 变体基座）+
//  tools/src/tool_search.rs 语料构建 + tool_search_spec.rs:34-89/:93-95
//  （C7 动态 description：来源清单渲染段、Include 形态、字节稳定性与换手）。
//  纪律：不真连 MCP（MCPServerStoreTests 头注同款）——语料以 ToolSearchInfo
//  手工构造；判定面 = 纯函数 + execute 输出，端到端由真机验收覆盖。
//

import XCTest
@testable import WanWo

final class ToolSearchToolTests: XCTestCase {

    // MARK: 夹具

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test-session",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test-session"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-tool-search-tests-spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    private func makeTool(_ corpus: [ToolSearchInfo]) -> ToolSearchTool {
        ToolSearchTool(corpusProvider: { corpus })
    }

    private func makeCorpusEntry(_ name: String, _ description: String,
                                 parameters: JSONValue? = nil) -> ToolSearchInfo {
        ToolSearchInfo.from(
            name: name,
            description: description,
            parameters: parameters ?? .object(["type": .string("object"),
                                               "properties": .object([:]),
                                               "required": .array([]),
                                               "additionalProperties": .bool(false)]),
            sourceInfo: ToolSearchSourceInfo(name: "calendar", description: "Calendar server"))
    }

    /// 工具输出 JSON 文本 → 解析（命中数组断言用）。
    private func parseArray(_ text: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: 语料构建（codex tool_search.rs default_tool_search_text 同构）

    /// 语料含：名称 + 下划线空格变体 + 描述 + 属性名/属性描述递归。
    func testCorpusIncludesNameVariantsDescriptionAndPropertyNames() {
        let parameters = JSONValue.schemaObject(properties: [
            "calendar_id": .stringSchema(description: "Target calendar identifier."),
            "when": .object([
                "type": .string("object"),
                "properties": .object([
                    "start": .stringSchema(description: "Start time."),
                ]),
            ]),
        ], required: ["calendar_id"])
        let info = ToolSearchInfo.from(name: "create_event", description: "Create events",
                                       parameters: parameters, sourceInfo: nil)
        let tokens = Set(BM25Tokenizer.tokenize(info.entry.searchText))
        XCTAssertTrue(tokens.contains("create"))
        XCTAssertTrue(tokens.contains("event"), "underscore variant 'create event' must feed corpus")
        XCTAssertTrue(tokens.contains("calendar"), "property name must feed corpus")
        XCTAssertTrue(tokens.contains("identifier"), "property description must feed corpus")
        XCTAssertTrue(tokens.contains("start"), "nested property name must feed corpus")
    }

    /// 语料不含完整 parameters：非检索字段载荷（default 值、type 枚举）不进语料。
    func testCorpusExcludesFullParameters() {
        let parameters = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "default": .string("ZZZUNIQUEMARKER"),
                ]),
            ]),
        ])
        let info = ToolSearchInfo.from(name: "tool_x", description: "desc",
                                       parameters: parameters, sourceInfo: nil)
        XCTAssertFalse(info.entry.searchText.lowercased().contains("zzzuniquemarker"),
                       "full parameters payload must NOT leak into search corpus")
        XCTAssertFalse(BM25Tokenizer.tokenize(info.entry.searchText).contains("zzzuniquemarker"))
    }

    /// 命中输出载荷 = function spec object {name, description, parameters}。
    func testCorpusOutputIsLoadableSpecShape() {
        let parameters = JSONValue.schemaObject(properties: [:], required: [])
        let info = ToolSearchInfo.from(name: "create_event", description: "Create events",
                                       parameters: parameters, sourceInfo: nil)
        XCTAssertEqual(info.entry.output, .object([
            "name": .string("create_event"),
            "description": .string("Create events"),
            "parameters": parameters,
        ]))
    }

    /// 来源信息透传（C7 来源清单消费面）。
    func testSourceInfoRoundTrip() {
        let source = ToolSearchSourceInfo(name: "calendar", description: "Calendar server")
        let info = ToolSearchInfo.from(name: "t", description: "d",
                                       parameters: .object([:]), sourceInfo: source)
        XCTAssertEqual(info.sourceInfo, source)
    }

    /// 空段不进语料（codex push_search_part：trim 非空才收）。
    func testEmptyPartsAreSkipped() {
        let info = ToolSearchInfo.from(name: "  tool_y  ", description: "   ",
                                       parameters: .object([:]), sourceInfo: nil)
        XCTAssertTrue(info.entry.searchText.hasPrefix("tool_y"),
                      "name must be trimmed; empty description must not add part")
        XCTAssertFalse(info.entry.searchText.contains("  "))
    }

    // MARK: 工具身份（F023 词汇面）

    /// 元工具恒直出：name/exposure/isConcurrencySafe（codex
    /// supports_parallel_tool_calls=true）+ R4 素净卡默认（presentCall/presentResult nil）。
    func testToolIdentityAndDirectExposure() {
        let tool = makeTool([])
        XCTAssertEqual(tool.name, "tool_search")
        XCTAssertEqual(tool.exposure, .direct,
                       "tool_search 元工具必须恒 .direct（模型管理面死锁防线同源）")
        XCTAssertTrue(tool.isConcurrencySafe(.null))
        XCTAssertNil(tool.presentCall(.null), "R4：M9 前不做专属呈现，走协议默认 nil")
        XCTAssertNil(tool.presentResult(.null, .success("")))
    }

    /// 内置工具协议默认 exposure = .direct（10-design 清单外暴露项 5 显式锚：
    /// mcp_server_config 等元工具若被延迟则死锁——协议默认保证内置恒直出）。
    func testBuiltinToolProtocolDefaultIsDirect() {
        struct StubTool: AgentTool {
            let name = "stub_tool"
            let description = "stub"
            let parameters = JSONValue.schemaObject(properties: [:], required: [])
        }
        XCTAssertEqual(StubTool().exposure, .direct,
                       "AgentTool 协议默认值必须保持 .direct（ToolRegistry.swift:111 不动）")
    }

    // MARK: execute（codex handle_call :191-227 逐式对拍）

    /// query 缺失 → 失败结果（codex payload 反序列化失败的平台等价）。
    func testMissingQueryFails() async throws {
        let tool = makeTool([makeCorpusEntry("tool_a", "desc a")])
        let output = try await tool.execute(.object([:]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("query"), "unexpected: \(output.text)")
    }

    /// query trim 后空 → 失败（codex :207-211 "query must not be empty" 逐字）。
    func testBlankQueryFailsWithCodexWording() async throws {
        let tool = makeTool([makeCorpusEntry("tool_a", "desc a")])
        let output = try await tool.execute(
            .object(["query": .string("   ")]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("query must not be empty"),
                      "codex RespondToModel wording must be preserved: \(output.text)")
    }

    /// limit 0 → 失败（codex :214-218 逐字）。
    func testZeroLimitFails() async throws {
        let tool = makeTool([makeCorpusEntry("tool_a", "desc a")])
        let output = try await tool.execute(
            .object(["query": .string("anything"), "limit": .int(0)]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("limit must be greater than zero"),
                      "unexpected: \(output.text)")
    }

    /// 零语料 → 成功空数组（codex :220-222：回空保持配对，非报错）。
    func testEmptyCorpusReturnsPairedEmptyOutput() async throws {
        let tool = makeTool([])
        let output = try await tool.execute(
            .object(["query": .string("anything")]), makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "[]")
    }

    /// 无命中 → 成功空数组。
    func testNoHitReturnsEmptyArray() async throws {
        let tool = makeTool([makeCorpusEntry("calendar_create_event", "Create events")])
        let output = try await tool.execute(
            .object(["query": .string("zzzqqq unrelated")]), makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "[]")
    }

    /// 命中 → LoadableToolSpec 形 JSON 数组（name/parameters 随行——C5 激活注入面）。
    func testHitReturnsSpecPayload() async throws {
        let tool = makeTool([makeCorpusEntry("calendar_create_event", "Create events")])
        let output = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertFalse(output.isError, "unexpected: \(output.text)")
        let specs = try parseArray(output.text)
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0]["name"] as? String, "calendar_create_event")
        XCTAssertNotNil(specs[0]["parameters"], "spec payload must carry parameters for activation")
    }

    /// limit 默认 8（codex TOOL_SEARCH_DEFAULT_LIMIT）：12 条全命中 → 8 条。
    func testDefaultLimitIsEight() async throws {
        let corpus = (0..<12).map { index in
            makeCorpusEntry("tool_item_\(String(format: "%02d", index))",
                            "misc item widget")
        }
        let tool = makeTool(corpus)
        let output = try await tool.execute(
            .object(["query": .string("widget")]), makeContext())
        let specs = try parseArray(output.text)
        XCTAssertEqual(specs.count, 8, "default limit must be 8 (tool_discovery.rs:7)")
    }

    /// 显式 limit 覆盖默认。
    func testExplicitLimitOverridesDefault() async throws {
        let corpus = (0..<12).map { index in
            makeCorpusEntry("tool_item_\(String(format: "%02d", index))",
                            "misc item widget")
        }
        let tool = makeTool(corpus)
        let output = try await tool.execute(
            .object(["query": .string("widget"), "limit": .int(3)]), makeContext())
        let specs = try parseArray(output.text)
        XCTAssertEqual(specs.count, 3)
    }

    /// 语料变化 → 引擎重建（登记版 ToolSearchHandlerCache：全等缓存失效）。
    func testCorpusChangeRebuildsEngine() async throws {
        final class CorpusBox: @unchecked Sendable {
            var items: [ToolSearchInfo]
            init(_ items: [ToolSearchInfo]) { self.items = items }
        }
        let box = CorpusBox([makeCorpusEntry("calendar_create_event", "Create events")])
        let tool = ToolSearchTool(corpusProvider: { box.items })

        let hit = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertFalse(try parseArray(hit.text).isEmpty)

        // 换代：旧工具离场，新工具入场（两阶段换手后的 registry 快照）。
        box.items = [makeCorpusEntry("fs_read_file", "Read file contents")]
        let miss = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertEqual(try parseArray(miss.text).count, 0)

        let newHit = try await tool.execute(
            .object(["query": .string("read file")]), makeContext())
        XCTAssertEqual(try parseArray(newHit.text).first?["name"] as? String, "fs_read_file")
    }

    // MARK: C7 — 动态 description（来源清单渲染）

    /// description = 基座 + 来源清单段 + 发现指引（codex tool_search_spec.rs
    /// :93-95 Include 形态；WanWo 无 DeferredToolWorldState 门控 → 恒 Include）。
    func testDescriptionIncludesSourceListing() {
        let tool = makeTool([makeCorpusEntry("cal_create_event", "Create events")])
        XCTAssertTrue(tool.description.hasPrefix(
            "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes "
            + "matching tools for the next model call.\n\nYou have access to tools from the "
            + "following sources:\n- calendar: Calendar server\n"),
            "unexpected: \(tool.description)")
        XCTAssertTrue(tool.description.contains(
            "\nSome of the tools may not have been provided to you upfront"),
            "Include 形态下指引段紧随清单尾 \\n（codex :87 无额外空行）")
    }

    /// 零来源（语料全为内置形态）→ "None currently enabled."（codex :48-49）。
    func testDescriptionWithoutSourcesUsesPlaceholder() {
        let info = ToolSearchInfo.from(name: "t", description: "d",
                                       parameters: .object([:]), sourceInfo: nil)
        let tool = makeTool([info])
        XCTAssertTrue(tool.description.contains(
            "You have access to tools from the following sources:\nNone currently enabled.\n"))
    }

    /// 同一语料下 description 字节稳定（红线：缓存前缀纪律）。
    func testDescriptionIsByteStableForSameCorpus() {
        let tool = makeTool([makeCorpusEntry("cal_create_event", "Create events")])
        XCTAssertEqual(tool.description, tool.description)
    }

    /// 来源集变化 → description 换手（syncCorpus 同手刷新；引擎缓存同步失效，
    /// 执行面语料换新——同一实例，无重注册）。
    func testDescriptionFollowsSourceSetChanges() async throws {
        final class CorpusBox: @unchecked Sendable {
            var items: [ToolSearchInfo]
            init(_ items: [ToolSearchInfo]) { self.items = items }
        }
        let box = CorpusBox([makeCorpusEntry("cal_create_event", "Create events")])
        let tool = ToolSearchTool(corpusProvider: { box.items })
        XCTAssertTrue(tool.description.contains("- calendar: Calendar server"))

        // 换代：来源消失（新语料无 sourceInfo）→ description 收敛到占位文案。
        box.items = [ToolSearchInfo.from(name: "fs_read_file", description: "Read files",
                                         parameters: .object([:]), sourceInfo: nil)]
        tool.syncCorpus(box.items)
        XCTAssertTrue(tool.description.contains("None currently enabled."))
        XCTAssertFalse(tool.description.contains("Calendar server"))
        // 执行面语料同步换新（缓存失效重建语义不受 C7 影响）。
        let output = try await tool.execute(
            .object(["query": .string("read file")]), makeContext())
        XCTAssertEqual(try parseArray(output.text).first?["name"] as? String,
                       "fs_read_file")
    }
}
