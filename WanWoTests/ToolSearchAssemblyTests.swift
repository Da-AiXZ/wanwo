//
//  ToolSearchAssemblyTests.swift
//  WanWoTests
//
//  【M4-C2/C3/C6 测试锚】tool_search 组装面（ToolSearchAssembly）+ MCP 工具
//  默认 deferred（WanWoMCPServerTool C3 覆写）+ PromptAssembler knownNames
//  全集化（C6）。对拍基准 = codex-rs core/src/tools/spec_plan.rs:371-406
//  （finalize_tool_router：any deferred ⇒ 注册 tool_search）/ :530-542
//  （build_model_visible_specs 仅直出 direct）。
//  纪律：不真连 MCP（MCPResourceToolsTests 头注同款）——Client 离线构造、
//  executor 桩注入；R8 本地不 build，端到端由真机验收覆盖。
//

import XCTest
import MCP
@testable import WanWo

// MARK: - 测试替身

/// 直出桩工具（协议默认 exposure=.direct）。
private struct StubDirectTool: AgentTool {
    let name: String
    var description: String { "stub direct tool \(name)" }
    let parameters = JSONValue.schemaObject(properties: [:], required: [])
    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        .success("stub")
    }
}

/// deferred 桩工具（C3 形态：覆写 exposure + 可选 sourceInfo）。
private struct StubDeferredTool: AgentTool {
    let name: String
    var description: String { "stub deferred tool \(name)" }
    let parameters = JSONValue.schemaObject(properties: [:], required: [])
    let exposure: ToolExposure = .deferred
    let source: ToolSearchSourceInfo?
    var toolSearchSourceInfo: ToolSearchSourceInfo? { source }
    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        .success("stub")
    }
}

/// hidden 桩工具（侧会话写类工具形态）。
private struct StubHiddenTool: AgentTool {
    let name: String
    var description: String { "stub hidden tool \(name)" }
    let parameters = JSONValue.schemaObject(properties: [:], required: [])
    let exposure: ToolExposure = .hidden
    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        .success("stub")
    }
}

/// MCPToolExecuting 桩（C3 身份断言不触执行面）。
private struct StubMCPExecutor: MCPToolExecuting {
    func execute(client: Client,
                 rawName: String,
                 taskRequired: Bool,
                 options: MCPToolBridgeOptions,
                 args: JSONValue,
                 context: ToolExecutionContext) async throws -> ToolOutput {
        .success("stub")
    }
}

final class ToolSearchAssemblyTests: XCTestCase {

    // MARK: 夹具

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test-session",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test-session"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-tool-search-assembly-tests-spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    /// MCP deferred 工具（C3 覆写形态；离线构造，不连 server）。
    private func makeMCPDeferredTool(publicName: String) -> WanWoMCPServerTool {
        WanWoMCPServerTool(
            publicName: publicName,
            description: "Create a calendar event",
            parameters: .schemaObject(properties: [:], required: []),
            timeoutMs: 1000,
            client: Client(name: "test-client", version: "0.0.1",
                           capabilities: Client.Capabilities()),
            rawName: "create_event",
            taskRequired: false,
            options: MCPToolBridgeOptions(registrationFailure: .contain,
                                          serverName: "calendar",
                                          toolCallTimeoutMs: 1000),
            executor: StubMCPExecutor())
    }

    /// 工具输出 JSON 文本 → 解析（命中数组断言用）。
    private func parseArray(_ text: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: C2a — schemas() 过滤收窄（codex spec_plan.rs:530-542 同构）

    /// direct 收 / deferred 排 / hidden 排。
    func testSchemasExposesDirectOnly() {
        let registry = ToolRegistry()
        registry.register(StubDirectTool(name: "alpha_read"))
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        registry.register(StubHiddenTool(name: "write_file"))

        let names = registry.schemas().map { $0.name }
        XCTAssertEqual(names, ["alpha_read"],
                       "schemas() must expose direct only: deferred (F023) and hidden excluded")
    }

    /// tool_search 本身 .direct：注册后进 schemas()（元工具恒可调用的 wire 面）。
    func testToolSearchEntersSchemasOnceRegistered() {
        let registry = ToolRegistry()
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        let assembly = ToolSearchAssembly(registry: registry)
        assembly.refresh()

        XCTAssertEqual(registry.schemas().map { $0.name }, ["tool_search"],
                       "only the direct meta-tool is model-visible after assembly")
    }

    // MARK: C2b — deferred 存在才注册（零 deferred 零注册）

    func testZeroDeferredDoesNotRegisterToolSearch() {
        let registry = ToolRegistry()
        registry.register(StubDirectTool(name: "alpha_read"))
        let assembly = ToolSearchAssembly(registry: registry)

        assembly.refresh()

        XCTAssertNil(registry.get("tool_search"), "zero deferred ⇒ zero registration")
        XCTAssertFalse(assembly.isRegistered)
    }

    func testDeferredPresenceRegistersToolSearch() {
        let registry = ToolRegistry()
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        let assembly = ToolSearchAssembly(registry: registry)

        assembly.refresh()

        XCTAssertNotNil(registry.get("tool_search"), "deferred present ⇒ tool_search registered")
        XCTAssertTrue(assembly.isRegistered)
    }

    /// 幂等：重复 refresh 不重复注册、不触发 tryRegister 冲突路径。
    func testRefreshIsIdempotent() {
        let registry = ToolRegistry()
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        let assembly = ToolSearchAssembly(registry: registry)

        assembly.refresh()
        assembly.refresh()
        assembly.refresh()

        XCTAssertTrue(assembly.isRegistered)
        XCTAssertNotNil(registry.get("tool_search"))
    }

    // MARK: C2b — registry 变化换手（tryRegister+disposer，M4-A 件4 语义复用）

    /// 末个 deferred 离场 ⇒ 注销；再入场 ⇒ 重新注册（disposer 双向换手）。
    func testRefreshSwapsRegistrationWithDeferredSet() {
        let registry = ToolRegistry()
        let assembly = ToolSearchAssembly(registry: registry)
        let tool = StubDeferredTool(name: "mcp__cal__create_event", source: nil)

        registry.register(tool)
        assembly.refresh()
        XCTAssertTrue(assembly.isRegistered)

        // 世代换手：旧代离场（MCPToolBridge.syncTools Phase2 同款注销语义）。
        registry.unregister("mcp__cal__create_event")
        assembly.refresh()
        XCTAssertFalse(assembly.isRegistered, "last deferred left ⇒ tool_search unregistered")
        XCTAssertNil(registry.get("tool_search"))

        // 新一代入场。
        registry.register(StubDeferredTool(name: "mcp__docs__search", source: nil))
        assembly.refresh()
        XCTAssertTrue(assembly.isRegistered, "new deferred generation ⇒ tool_search re-registered")
    }

    /// 外来工具占据 tool_search 名：fail contained（不覆盖、不 fatal）。
    func testForeignToolSearchNameIsFailContained() {
        let registry = ToolRegistry()
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        registry.register(StubDirectTool(name: "tool_search"))
        let assembly = ToolSearchAssembly(registry: registry)

        assembly.refresh()

        XCTAssertFalse(assembly.isRegistered, "conflict ⇒ contained, no disposer held")
        // 在位者原样保留（不覆盖外来注册面）。
        XCTAssertTrue(registry.get("tool_search") is StubDirectTool)
    }

    // MARK: C2c — 语料缝（deferred 全集 + sourceInfo + hidden/direct 不入语料）

    func testCorpusCoversDeferredOnlyWithSourceInfo() async throws {
        let registry = ToolRegistry()
        registry.register(StubDirectTool(name: "alpha_read"))
        registry.register(StubDeferredTool(name: "mcp__cal__create_event",
                                           source: ToolSearchSourceInfo(name: "calendar",
                                                                        description: nil)))
        registry.register(StubHiddenTool(name: "write_file"))
        let assembly = ToolSearchAssembly(registry: registry)
        assembly.refresh()

        // 语料快照面：仅 deferred，sourceInfo 透传（server 名；内置 nil）。
        let deferred = registry.deferredTools()
        XCTAssertEqual(deferred.map { $0.name }, ["mcp__cal__create_event"])
        XCTAssertEqual(deferred.first?.toolSearchSourceInfo?.name, "calendar")

        // 执行面：命中 deferred 工具 spec；direct/hidden 不入语料。
        let tool = try XCTUnwrap(registry.get("tool_search") as? ToolSearchTool)
        let output = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        let specs = try parseArray(output.text)
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0]["name"] as? String, "mcp__cal__create_event")
        XCTAssertNotNil(specs[0]["parameters"], "spec payload carries parameters (C5 激活面)")
    }

    /// 语料新鲜度：deferred 工具换代后 provider 实时读 registry（引擎全等缓存
    /// 失效重建——codex per-turn remove+append 的 WanWo 输出等价锚）。
    func testCorpusFollowsRegistryGenerations() async throws {
        let registry = ToolRegistry()
        let assembly = ToolSearchAssembly(registry: registry)
        registry.register(StubDeferredTool(name: "mcp__cal__create_event", source: nil))
        assembly.refresh()
        let tool = try XCTUnwrap(registry.get("tool_search") as? ToolSearchTool)

        let first = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertEqual(try parseArray(first.text).first?["name"] as? String,
                       "mcp__cal__create_event")

        // 换代：旧工具离场 → 同一 tool_search 实例语料随 provider 收敛。
        registry.unregister("mcp__cal__create_event")
        let second = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertEqual(try parseArray(second.text).count, 0)
    }

    // MARK: C3 — MCP 工具默认 deferred 覆写生效

    func testMCPToolDefaultsToDeferredWithSourceInfo() {
        let tool = makeMCPDeferredTool(publicName: "mcp__calendar__create_event")

        XCTAssertEqual(tool.exposure, .deferred,
                       "C3：WanWoMCPServerTool 必须覆写 exposure=.deferred（F023）")
        XCTAssertEqual(tool.toolSearchSourceInfo?.name, "calendar",
                       "C2c：sourceInfo.name = server 名")
        XCTAssertNil(tool.toolSearchSourceInfo?.description,
                     "MCPClientConfig 无 server description 字段（上游缺口登记，恒 nil）")
        XCTAssertEqual(tool.timeoutMs, 1000, "既有协议面不受 C3 影响")
    }

    /// MCP 工具经 C3 覆写后：不进 schemas()、进 deferredTools()（注册面行为锚）。
    func testMCPToolRegistrationSurfaceAfterC3() {
        let registry = ToolRegistry()
        registry.register(makeMCPDeferredTool(publicName: "mcp__calendar__create_event"))

        XCTAssertFalse(registry.schemas().map { $0.name }
            .contains("mcp__calendar__create_event"),
            "MCP 工具名不得出现在请求 tools 数组（C2a 过滤 + C3 覆写联动）")
        XCTAssertEqual(registry.deferredTools().map { $0.name },
                       ["mcp__calendar__create_event"])
        XCTAssertEqual(registry.knownNames, ["mcp__calendar__create_event"],
                       "knownNames 全集仍含 deferred 工具名（C6 校验集数据源）")
    }

    // MARK: C6 — knownNames 全集化（toolOrder 含 MCP deferred 名不再 fatal）

    func testOrderToolsAcceptsDeferredNameViaKnownNames() {
        let toolSchemas = [ToolSchemaEntry(name: "tool_search", description: "d",
                                           parameters: .object([:]))]
        let toolOrder = ["mcp__calendar__create_event", TOOL_ORDER_REST.marker]
        // C6 形态：校验集 = registry.knownNames 全集（deferred 名在其中）。
        let knownNames: Set<String> = ["tool_search", "mcp__calendar__create_event"]

        let ordered = PromptAssembler.orderTools(toolSchemas, toolOrder,
                                                 knownNames: knownNames)

        // deferred 名合法列出但不进请求 tools 数组（输出循环按名查找落空即跳过）；
        // rest 标记位兜住剩余。
        XCTAssertEqual(ordered.map { $0.name }, ["tool_search"])
    }

    /// 端到端组装面：assemble(knownNames: registry.knownNames) —— toolOrder
    /// 列出 MCP 工具名不再 fatalError（回归防线锚）。
    func testAssembleWithKnownNamesSurvivesMCPTNamesInToolOrder() throws {
        let registry = ToolRegistry()
        registry.register(makeMCPDeferredTool(publicName: "mcp__calendar__create_event"))
        let assembly = ToolSearchAssembly(registry: registry)
        assembly.refresh()

        let assembler = PromptAssembler()
        assembler.setToolOrder(["mcp__calendar__create_event", TOOL_ORDER_REST.marker])

        let result = try assembler.assemble(
            toolSchemas: registry.schemas(),
            knownNames: registry.knownNames)

        XCTAssertEqual(result.tools.map { $0.name }, ["tool_search"],
                       "toolOrder 列出的 deferred 名不 fatal、也不进 tools 数组")
    }

    /// 缺省（nil）回落收窄集：既有调用面/测试的 dsh 原语义保留。
    func testAssembleFallbackKeepsNarrowSetSemantics() {
        let toolSchemas = [ToolSchemaEntry(name: "alpha_read", description: "d",
                                           parameters: .object([:]))]
        let ordered = PromptAssembler.orderTools(
            toolSchemas, ["alpha_read", TOOL_ORDER_REST.marker], knownNames: nil)
        XCTAssertEqual(ordered.map { $0.name }, ["alpha_read"])
    }

    // MARK: 侧会话锚 — 写类工具 hidden，组装语义自然跳过/不受影响

    func testSideSessionHiddenToolsSkipAssembly() async throws {
        let registry = ToolRegistry()
        // 侧会话形态：读类 direct + 写类 hidden，无 deferred。
        registry.register(StubDirectTool(name: "alpha_read"))
        registry.register(StubHiddenTool(name: "write_file"))
        let assembly = ToolSearchAssembly(registry: registry)

        assembly.refresh()

        // 无 deferred ⇒ tool_search 不注册（组装步零开销跳过）。
        XCTAssertNil(registry.get("tool_search"))
        XCTAssertFalse(assembly.isRegistered)
        // hidden 不进请求 tools 数组，但 knownNames 全集保留（toolOrder 合法列出）。
        XCTAssertEqual(registry.schemas().map { $0.name }, ["alpha_read"])
        XCTAssertEqual(registry.knownNames.sorted(), ["alpha_read", "write_file"])
        let result = try assemblerAnchor(registry: registry)
        XCTAssertEqual(result.tools.map { $0.name }, ["alpha_read"])
    }

    /// 侧会话组装锚辅助（toolOrder 列出 hidden 写工具名 → 全集校验不 fatal）。
    private func assemblerAnchor(registry: ToolRegistry) throws
        -> (system: String, contextSnapshot: String, tools: [ToolSchemaEntry]) {
        let assembler = PromptAssembler()
        assembler.setToolOrder(["alpha_read", "write_file", TOOL_ORDER_REST.marker])
        return try assembler.assemble(toolSchemas: registry.schemas(),
                                      knownNames: registry.knownNames)
    }
}
