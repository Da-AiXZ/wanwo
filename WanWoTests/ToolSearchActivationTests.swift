//
//  ToolSearchActivationTests.swift
//  WanWoTests
//
//  【M4-C5 测试锚】tool_search 激活面（ToolSearchActivation）：激活集推导
//  （事件流重放推导，拍板项 1A）+ 注入形态（Direct 集 + 激活集尾部首见序、
//  append-only 不收缩，拍板项 5）+ resume 重放推导（JSONL replay 解码 → 同一
//  纯函数，零新接入点）+ 侧会话空激活 + C1 输出文本→spec 解析往返。
//  对拍基准 = codex-rs core/src/models.rs:845/:1060/:1136（激活 = 协议级
//  tool_search_call/tool_search_output 项进历史；WanWo 等价 = 注入下一请求
//  tools 数组，gap11 §八.2）。
//  纪律：不真连 MCP（ToolSearchAssemblyTests 头注同款）；R8 本地不 build，
//  端到端由真机验收覆盖。
//

import XCTest
@testable import WanWo

final class ToolSearchActivationTests: XCTestCase {

    // MARK: - 夹具

    /// 构造一条事件（seq 仅保唯一，推导不消费 seq/time）。
    private func event(_ payload: SessionEvent.Payload, _ seq: Int) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: Int64(1_700_000_000_000 + seq),
                     payload: payload)
    }

    /// tool_search 调用事件。
    private func searchCall(_ callId: String, _ seq: Int) -> SessionEvent {
        event(.toolCall(turn: 1, step: 1, callId: callId,
                        name: "tool_search", arguments: "{\"query\":\"q\"}"), seq)
    }

    /// 配对 result 事件（isError 默认成功）。
    private func searchResult(_ callId: String, content: String,
                              isError: Bool = false, _ seq: Int) -> SessionEvent {
        event(.toolResult(turn: 1, step: 1, callId: callId, content: content,
                          isError: isError, errorName: nil, errorCode: nil,
                          meta: nil), seq)
    }

    /// C1 输出形态的 spec JSON 数组文本（单条）。
    private func specText(_ name: String, description: String = "desc \(name)") -> String {
        let params = "{\"additionalProperties\":false,\"properties\":{},"
            + "\"required\":[],\"type\":\"object\"}"
        return "[{\"description\":\"\(description)\",\"name\":\"\(name)\","
            + "\"parameters\":\(params)}]"
    }

    /// 多条 spec 的 JSON 数组文本（混排/去重用例）。
    private func specsText(_ names: [String]) -> String {
        let items = names.map { name in
            "{\"description\":\"desc \(name)\",\"name\":\"\(name)\","
                + "\"parameters\":{\"properties\":{},\"type\":\"object\"}}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// 直出 schema（Direct 集夹具）。
    private func direct(_ name: String) -> ToolSchemaEntry {
        ToolSchemaEntry(name: name, description: "direct \(name)",
                        parameters: .object([:]))
    }

    // MARK: 推导 — 正常解析（C5a）

    func testDerivesActivationFromPairedCallAndResult() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: specsText(["mcp__cal__create_event",
                                                   "mcp__docs__search"]), 1),
        ]

        let activated = ToolSearchActivation.activatedSpecs(events: events)

        // 首见序 = result 内条目序；字段逐项保真（C1 载荷 1:1）。
        XCTAssertEqual(activated.map { $0.name },
                       ["mcp__cal__create_event", "mcp__docs__search"])
        XCTAssertEqual(activated[0].description, "desc mcp__cal__create_event")
        XCTAssertNotNil(activated[0].parameters.objectFields,
                        "parameters 随行注入（chat completions spec 形态）")
    }

    /// 未配对（有 call 无 result / result 先于 call 的孤儿）不进激活集。
    func testUnpairedResultsDoNotActivate() {
        let events = [
            searchCall("c1", 0),
            searchResult("c-other", content: specText("mcp__x"), 1),
        ]

        XCTAssertTrue(ToolSearchActivation.activatedSpecs(events: events).isEmpty)
    }

    // MARK: 推导 — 同名去重（C5b，append-only 保留首见 spec）

    func testDeduplicatesByNameKeepingFirstSeenSpec() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: specText("mcp__cal__create_event",
                                                 description: "first"), 1),
            searchCall("c2", 2),
            searchResult("c2", content: specText("mcp__cal__create_event",
                                                 description: "second"), 3),
        ]

        let activated = ToolSearchActivation.activatedSpecs(events: events)

        XCTAssertEqual(activated.count, 1,
                       "同名重复激活不重复注入（幂等去重）")
        XCTAssertEqual(activated[0].description, "first",
                       "保留首见 spec——append-only 语义")
    }

    // MARK: 推导 — 容错（fail closed）

    /// result 文本非 JSON → 整段跳过，不崩。
    func testNonJSONResultIsSkipped() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: "not json at all {", 1),
        ]

        XCTAssertTrue(ToolSearchActivation.activatedSpecs(events: events).isEmpty)
    }

    /// result 为 JSON 但非数组（如 object）→ 跳过。
    func testNonArrayJSONResultIsSkipped() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: "{\"name\":\"mcp__x\"}", 1),
        ]

        XCTAssertTrue(ToolSearchActivation.activatedSpecs(events: events).isEmpty)
    }

    /// 空 result（零语料回空 "[]"，ToolSearchTool :93）→ 空激活。
    func testEmptyResultYieldsEmptyActivation() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: "[]", 1),
        ]

        XCTAssertTrue(ToolSearchActivation.activatedSpecs(events: events).isEmpty)
    }

    /// isError result（INVALID_ARGS 等合成失败）不进语料。
    func testErrorResultIsSkipped() {
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: specText("mcp__x"), isError: true, 1),
        ]

        XCTAssertTrue(ToolSearchActivation.activatedSpecs(events: events).isEmpty)
    }

    /// 条目畸形（缺 description）→ 跳过该条，其余条目照常激活（逐条 fail closed）。
    func testMalformedEntrySkippedValidEntriesKept() {
        let text = "[{\"name\":\"mcp__broken\"},"
            + "{\"description\":\"d\",\"name\":\"mcp__good\","
            + "\"parameters\":{\"type\":\"object\"}}]"
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: text, 1),
        ]

        let activated = ToolSearchActivation.activatedSpecs(events: events)

        XCTAssertEqual(activated.map { $0.name }, ["mcp__good"])
    }

    // MARK: 注入形态（C5c — Direct 集原样 + 激活集尾部首见序）

    func testInjectionAppendsActivationAtTailAfterOrderedDirectSet() {
        // Direct 集经 toolOrder 重排（zeta 在前）——激活集不得扰动该序。
        let direct = PromptAssembler.orderTools(
            [direct("alpha_read"), direct("zeta")],
            ["zeta", "alpha_read", TOOL_ORDER_REST.marker], knownNames: nil)
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: specsText(["mcp__b", "mcp__a"]), 1),
        ]

        let final = ToolSearchActivation.inject(into: direct, events: events)

        XCTAssertEqual(final.map { $0.name },
                       ["zeta", "alpha_read", "mcp__b", "mcp__a"],
                       "激活集保持首见序追加尾部；Direct 集原样透传不重排")
    }

    /// 零激活 = Direct 集原样返回（侧会话恒走本分支：hidden 不进语料 →
    /// 无 tool_search 调用 → 激活集恒空）。
    func testSideSessionEventsKeepDirectSetUntouched() {
        let directSet = [direct("alpha_read"), direct("write_file")]
        // 侧会话事件形态：普通工具调用对，无任何 tool_search 足迹。
        let events = [
            event(.toolCall(turn: 1, step: 1, callId: "c1", name: "alpha_read",
                            arguments: "{}"), 0),
            event(.toolResult(turn: 1, step: 1, callId: "c1", content: "ok",
                              isError: false, errorName: nil, errorCode: nil,
                              meta: nil), 1),
        ]

        let final = ToolSearchActivation.inject(into: directSet, events: events)

        XCTAssertEqual(final, directSet, "无 tool_search 足迹 ⇒ 注入零开销跳过")
    }

    /// 同名冲突：激活 spec 名与 Direct 集重名 → Direct 在位者胜（tools 数组
    /// 重名会破坏 chat completions 协议）。
    func testActivationExcludesNamesAlreadyDirect() {
        let directSet = [direct("alpha_read")]
        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: specsText(["alpha_read", "mcp__x"]), 1),
        ]

        let final = ToolSearchActivation.inject(into: directSet, events: events)

        XCTAssertEqual(final.map { $0.name }, ["alpha_read", "mcp__x"])
    }

    // MARK: append-only 不收缩（铁律）

    func testActivationSetNeverShrinksAcrossSteps() {
        let earlyEvents = [
            searchCall("c1", 0),
            searchResult("c1", content: specText("mcp__early"), 1),
        ]
        let laterEvents = earlyEvents + [
            searchCall("c2", 2),
            searchResult("c2", content: specText("mcp__late"), 3),
        ]

        let early = ToolSearchActivation.inject(into: [], events: earlyEvents)
        let later = ToolSearchActivation.inject(into: [], events: laterEvents)

        XCTAssertEqual(later.count, early.count + 1, "激活集只增不减")
        XCTAssertEqual(Array(later.prefix(early.count)), early,
                       "既有激活 spec 原位保留（前缀稳定——append-only 纪律）")
    }

    // MARK: resume 重放推导（C5e — 零新接入点）

    /// resume = SessionWriter init 从 JSONL replay 解码全量事件 → 同一推导
    /// 纯函数产出同一激活集（Codable 往返锚：JSONL 行解码产物可直接推导）。
    func testResumeReplayRoundtripRestoresActivation() throws {
        let liveEvents = [
            searchCall("c1", 0),
            searchResult("c1", content: specsText(["mcp__cal__create_event"]), 1),
            searchCall("c2", 2),
            searchResult("c2", content: specText("mcp__docs__search"), 3),
        ]

        // 模拟 resume 路径：JSONL 行编码 → 解码（SessionEvent Codable 1:1）。
        let data = try JSONEncoder().encode(liveEvents)
        let replayed = try JSONDecoder().decode([SessionEvent].self, from: data)

        let liveActivated = ToolSearchActivation.activatedSpecs(events: liveEvents)
        let resumed = ToolSearchActivation.activatedSpecs(events: replayed)

        XCTAssertEqual(resumed, liveActivated,
                       "resume 重放经同一推导，激活集免费恢复（R2 零新存储）")
        XCTAssertEqual(resumed.map { $0.name },
                       ["mcp__cal__create_event", "mcp__docs__search"])
    }

    // MARK: C1 输出文本 → spec 解析往返（C1 ↔ C5 对接面）

    /// ToolSearchTool 真实输出文本（C1 检索面产物）作为 result content →
    /// 激活 spec 与 deferred 工具注册 spec 全等（roundtrip）。
    func testC1OutputTextRoundtripsToActivationSpec() async throws {
        let registry = ToolRegistry()
        registry.register(StubDeferredTool(name: "mcp__cal__create_event",
                                           description: "Create a calendar event"))
        let assembly = ToolSearchAssembly(registry: registry)
        assembly.refresh()
        let tool = try XCTUnwrap(registry.get("tool_search") as? ToolSearchTool)

        let output = try await tool.execute(
            .object(["query": .string("create event")]), makeContext())
        XCTAssertFalse(output.isError)

        let events = [
            searchCall("c1", 0),
            searchResult("c1", content: output.text, 1),
        ]
        let activated = ToolSearchActivation.activatedSpecs(events: events)

        XCTAssertEqual(activated.count, 1)
        XCTAssertEqual(activated[0].name, "mcp__cal__create_event")
        XCTAssertEqual(activated[0].description, "Create a calendar event")
        XCTAssertEqual(activated[0].parameters,
                       StubDeferredTool(name: "mcp__cal__create_event",
                                        description: "Create a calendar event")
                           .parameters,
                       "spec 往返保真：parameters 无损（lossless 契约）")
    }

    // MARK: - 夹具辅助

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test-session",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test-session"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-tool-search-activation-tests-spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    /// deferred 桩工具（ToolSearchAssemblyTests 同款形态）。
    private struct StubDeferredTool: AgentTool {
        let name: String
        var description: String
        let parameters = JSONValue.schemaObject(properties: [:], required: [])
        let exposure: ToolExposure = .deferred
        init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }
}
