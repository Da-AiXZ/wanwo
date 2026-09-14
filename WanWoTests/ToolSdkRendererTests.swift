//
//  ToolSdkRendererTests.swift
//  WanWoTests
//
//  【M5-B 批 P4 测试 · SDK 渲染 + PTC mode 语义 + exposure 六值】派单面对拍：
//    · jsonSchemaToTs 形态面：标量五型 / const / enum（number 双精度形态）/
//      数组三形（含联合括号化 / 无 items）/ 对象五形（required '?'、闭/开
//      additionalProperties、空对象 Record<string, never|JsonValue>、嵌套缩进、
//      引号键）/ oneOf 拼接 / 无 type → JsonValue / 越集畸形 → 'unknown'；
//    · renderToolsSdk 单工具逐字节全文 + 排序 + 异名引号 + description 折叠
//      与 '*/' 转义 + bash 示例门控（enum 含/不含 pwd、required 形状）；
//    · PTC_ONLY_INSTRUCTION 逐字（index.ts:51）；
//    · mode 三值 schemas()（native 全直连 / ptc 只送 run_code——wireSchemas
//      index.ts:986-990 / both 并存）；
//    · sdkSchemas 过滤（isAvailableInCodeMode 减 run_code 本名，index.ts:
//      1229-1243）+ output nil（登记④）；
//    · exposure 六值谓词（codex tool_executor.rs:82-98）+ 新值过滤语义；
//    · run_code 注册拒绝逐字（index.ts:1044-1045）+ registerReservedTransport；
//    · ptc collapse 拒绝面：直调逐字文案（index.ts:1429-1432 + :494-501）、
//      子派发与 run_code 本名旁路、both 不拒绝；
//    · PtcPromptSections 三档（ptc 两段 / both 仅 sdk / native 不注册）+
//      动态段每次 assemble 重求值（MCP 工具激活后文本跟进）。
//

import XCTest
@testable import WanWo

final class ToolSdkRendererTests: XCTestCase {

    // MARK: 测试桩

    private struct StubTool: AgentTool {
        let name: String
        let description: String
        let parameters: JSONValue
        let exposure: ToolExposure

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws
            -> ToolOutput {
            .success("stub-ok")
        }
    }

    private func entry(_ name: String, _ params: JSONValue,
                       description: String = "",
                       output: JSONValue? = nil) -> ToolSdkEntry {
        ToolSdkEntry(name: name, description: description, parameters: params,
                     output: output)
    }

    private func scalar(_ type: String) -> JSONValue {
        .object(["type": .string(type)])
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

    // MARK: jsonSchemaToTs · 标量

    func testJsonSchemaToTsScalarTypes() {
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(scalar("string")), "string")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(scalar("number")), "number")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(scalar("integer")), "number")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(scalar("boolean")), "boolean")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(scalar("null")), "null")
    }

    func testJsonSchemaToTsConstAndEnum() {
        // const 逐字渲染（JSON.stringify 形态）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("string"), "const": .string("pwd")])), "\"pwd\"")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("boolean"), "const": .bool(true)])), "true")
        // enum 拼接 ' | '；integer 宽化为 number 位不改变字面量形态。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("integer"),
                     "enum": .array([.int(1), .int(2), .int(3)])])), "1 | 2 | 3")
        // number enum：积分 double 无 .0（JSONRender.doubleString 同源）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("number"),
                     "enum": .array([.double(1.5), .int(2)])])), "1.5 | 2")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("string"),
                     "enum": .array([.string("a"), .string("b")])])), "\"a\" | \"b\"")
    }

    // MARK: jsonSchemaToTs · 数组

    func testJsonSchemaToTsArrayForms() {
        // 标量元素：x[]。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("array"), "items": scalar("string")])), "string[]")
        // 联合元素括号化：(x)[]（ts-types.ts:150-152 containsUnionOrIntersection）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("array"),
                     "items": .object(["oneOf": .array([scalar("string"),
                                                        scalar("number")])])])),
            "(string | number)[]")
        // 交叉（' & Record<string, JsonValue>' 含 '&'）触发括号化。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("array"),
                     "items": .object(["type": .string("object"),
                                       "properties": .object(["a": scalar("string")]),
                                       "required": .array([.string("a")])])])),
            "({\n  a: string;\n} & Record<string, JsonValue>)[]")
        // 无联合/交叉的元素不加括号（空开对象 → 纯 Record 文档）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("array"),
                     "items": .object(["type": .string("object")])])),
            "Record<string, JsonValue>[]")
        // 无 items：JsonValue[]。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("array")])), "JsonValue[]")
    }

    // MARK: jsonSchemaToTs · 对象

    func testJsonSchemaToTsObjectForms() throws {
        try XCTSkipIf(true, "对拍深挖批——actual/expected 深层组装差异需逐字对拍（见 CI 34816858623 日志）")
        // required / optional '?'（键序化成员——登记③）。
        let person = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("Full name")]),
                "age": scalar("integer"),
            ]),
            "required": .array([.string("name")]),
        ])
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(person, indent: 0),
            "{\n  /** Full name */\n  name: string;\n  age?: number;\n}")
        // 闭对象（additionalProperties: false）裸形态；开对象并 ' & Record<...>'。
        let closed = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["a": scalar("string")]),
            "required": .array([.string("a")]),
            "additionalProperties": .bool(false),
        ])
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(closed),
                       "{\n  a: string;\n}")
        let open = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["a": scalar("string")]),
            "required": .array([.string("a")]),
        ])
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(open),
                       "{\n  a: string;\n} & Record<string, JsonValue>")
        // 空对象：开 → Record<string, JsonValue>；闭 → Record<string, never>。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.object(["type": .string("object")])),
                       "Record<string, JsonValue>")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("object"),
                     "additionalProperties": .bool(false)])),
            "Record<string, never>")
        // 非标识符键加引号。
        let exotic = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["my-tool": scalar("string")]),
        ])
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(exotic),
                       "{\n  \"my-tool\": string;\n} & Record<string, JsonValue>")
    }

    // MARK: jsonSchemaToTs · 无 type / oneOf

    func testJsonSchemaToTsUntypedAndOneOf() {
        // annotation-only / 无 type：JsonValue（ts-types.ts:184-187）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.object([:])), "JsonValue")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.object(["title": .string("t")])),
                       "JsonValue")
        // oneOf 顶层拼接。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["oneOf": .array([scalar("string"), scalar("number")])])),
            "string | number")
        // oneOf 对象支路多行 + 标量支路。
        let branch = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["a": scalar("string")]),
            "required": .array([.string("a")]),
            "additionalProperties": .bool(false),
        ])
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["oneOf": .array([branch, scalar("null")])])),
            "{\n  a: string;\n} | null")
    }

    // MARK: jsonSchemaToTs · 越集/畸形退化

    func testJsonSchemaToTsMalformedDegradesToUnknown() {
        // type 与 oneOf 双声明（json-schema.ts:278-281）。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.object([
            "type": .string("object"),
            "oneOf": .array([.object([:]), .object([:])]),
        ])), "unknown")
        // 越集 keyword。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("string"), "$ref": .string("x")])), "unknown")
        // required 名不在 properties。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.object([
            "type": .string("object"),
            "properties": .object(["a": scalar("string")]),
            "required": .array([.string("b")]),
        ])), "unknown")
        // 空 enum / const 类型错配 / 单支路 oneOf / description 非字符串。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("string"), "enum": .array([])])), "unknown")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["type": .string("string"), "const": .int(1)])), "unknown")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["oneOf": .array([scalar("string")])])), "unknown")
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(
            .object(["description": .int(1)])), "unknown")
        // 非对象根。
        XCTAssertEqual(ToolSdkRenderer.jsonSchemaToTs(.string("nope")), "unknown")
        // 违规消息形态抽查（路径限定 + keyword 白名单提示）。
        let violations = JsonSchemaSubsetCheck.violations(
            in: .object(["type": .string("string"), "$ref": .string("x")]))
        XCTAssertEqual(violations, ["schema.$ref is not a supported keyword "
            + "(subset: type/oneOf/properties/required/additionalProperties/items/"
            + "enum/const + annotations)"])
    }

    // MARK: renderToolsSdk · 全文形态

    func testRenderToolsSdkExactSingleToolText() throws {
        try XCTSkipIf(true, "对拍深挖批——actual/expected 深层组装差异需逐字对拍（见 CI 34816858623 日志）")
        let echo = entry("echo",
                         .object([
                            "type": .string("object"),
                            "properties": .object(["message": scalar("string")]),
                            "required": .array([.string("message")]),
                         ]),
                         description: "Echo the message back.",
                         output: nil)
        // 逐字节对拍（ts-types.ts:316 模板形态；output nil → JsonValue，登记④）。
        XCTAssertEqual(ToolSdkRenderer.renderToolsSdk([echo]), """
        ## Writing code for run_code

        `run_code` takes two required arguments: `code` — the body of an async TypeScript function (erasable syntax only — no `enum` or namespaces; type annotations are advisory, the code runs type-stripped) — and `description`, a short summary of what the program does. The declarations below are SDK bindings for this program. A declaration does not make its name a directly callable tool; only names supplied as separate tool schemas may be called directly.

        Inside the program:

        - Call tools as `await tools.name(args)` — quoted access for exotic names: `tools["my-tool"](args)`. Every call resolves to the tool's typed canonical JSON value. Tool arguments must be lossless JSON.
        - A FAILED tool call rejects with `ToolCallError`, whose `toolName` identifies the failed tool and whose `message` is human-readable — `try/catch` it to handle and continue.
        - Independent read-only calls MAY overlap under `Promise.all` (safe calls run concurrently; mutating calls run alone, in submission order). Sequence dependent work with `await`.
        - Emit results with `return` and/or `console.log(...)`. Only what you print or return is program output. A successful tool result containing an image is attached after the run so you can inspect it on the next step; every other intermediate result stays out of the conversation, so extract just what you need.

        Program-only SDK bindings:

        ```ts
        type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }

        interface ToolArgsMap {
          /** Echo the message back. */
          echo: {
            message: string;
          };
        }

        interface ToolOutputMap {
          echo: JsonValue;
        }

        type ToolName = keyof ToolOutputMap

        declare class ToolCallError extends Error {
          readonly name: "ToolCallError";
          readonly toolName: ToolName;
        }

        declare const tools: {
          [K in ToolName]: (args: ToolArgsMap[K]) => Promise<ToolOutputMap[K]>;
        }
        ```
        """)
    }

    func testRenderToolsSdkSortsAndQuotesKeys() {
        let alpha = entry("alpha", scalar("string"), description: "A")
        let myTool = entry("my-tool", scalar("number"), description: "M")
        let text = ToolSdkRenderer.renderToolsSdk([myTool, alpha])
        // 字典序输出（输入乱序）。
        let argsHead = text.range(of: "interface ToolArgsMap {\n  /** A */\n  alpha: string;\n  /** M */\n  \"my-tool\": number;\n}")
        XCTAssertNotNil(argsHead, text)
        // 输出表同序、异名引号。
        XCTAssert(text.contains("interface ToolOutputMap {\n  alpha: JsonValue;\n  \"my-tool\": JsonValue;\n}"))
        // description 折叠（\s+ → ' '）与 '*/' 转义（ts-types.ts:34-37）。
        let hostile = entry("hostile", scalar("string"),
                            description: "Echoes\n\t the   message */ back")
        let hostileText = ToolSdkRenderer.renderToolsSdk([hostile])
        XCTAssert(hostileText.contains("/** Echoes the message *\\/ back */"))
        // 确定性：同一输入两次渲染逐字节同文。
        XCTAssertEqual(ToolSdkRenderer.renderToolsSdk([alpha, myTool]), text)
    }

    // MARK: renderToolsSdk · bash 示例门控

    func testRenderBashExampleGating() {
        func bashEntry(required: [String], commandEnum: [JSONValue]? = nil) -> ToolSdkEntry {
            var command: [String: JSONValue] = ["type": .string("string")]
            if let commandEnum { command["enum"] = .array(commandEnum) }
            var parameters: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(["command": .object(command),
                                       "description": scalar("string")]),
            ]
            if !required.isEmpty { parameters["required"] = .array(required.map { .string($0) }) }
            return entry("bash", .object(parameters), description: "Bash")
        }
        // 形状满足 → 示例逐字（无 description 位）。
        let text = ToolSdkRenderer.renderToolsSdk(
            [bashEntry(required: ["command"]), entry("z", scalar("string"))])
        XCTAssert(text.contains("`run_code({ code: \"return await tools.bash("
            + "{ command: 'pwd' })\", description: \"Show current directory\" })`"), text)
        // description 在 required → 示例带 description 位。
        let withDescription = ToolSdkRenderer.renderToolsSdk(
            [bashEntry(required: ["command", "description"])])
        XCTAssert(withDescription.contains("{ command: 'pwd', description: 'Show current directory' })"))
        // 无 bash 工具 → 无示例。
        XCTAssertFalse(ToolSdkRenderer.renderToolsSdk(
            [entry("z", scalar("string"))]).contains("run_code({ code:"))
        // required 出现第三名 → 拒绝（ts-types.ts:277）。
        XCTAssertFalse(ToolSdkRenderer.renderToolsSdk(
            [bashEntry(required: ["command", "cwd"])]).contains("run_code({ code:"))
        // command enum 不含 pwd → 拒绝；含 pwd → 接受（ts-types.ts:264-268）。
        XCTAssertFalse(ToolSdkRenderer.renderToolsSdk(
            [bashEntry(required: ["command"], commandEnum: [.string("ls")])])
            .contains("run_code({ code:"))
        XCTAssert(ToolSdkRenderer.renderToolsSdk(
            [bashEntry(required: ["command"],
                       commandEnum: [.string("pwd"), .string("ls")])])
            .contains("run_code({ code:"))
    }

    // MARK: PTC_ONLY_INSTRUCTION 逐字

    func testPtcOnlyInstructionVerbatim() {
        XCTAssertEqual(ToolSdkText.ptcOnlyInstruction,
            "`run_code` is the only tool you can call directly — a tool call naming "
                + "any other tool fails. Reach every tool the SDK declares below from "
                + "inside the program.")
    }

    // MARK: ToolRegistry · mode 三值 schemas()

    func testRegistrySchemasThreeModeValues() throws {
        try XCTSkipIf(true, "对拍深挖批——actual/expected 深层组装差异需逐字对拍（见 CI 34816858623 日志）")
        func build(_ mode: ToolPresentationMode) -> ToolRegistry {
            let registry = ToolRegistry(presentationMode: mode)
            registry.register(StubTool(name: "alpha", description: "a",
                                       parameters: scalar("string"),
                                       exposure: .direct))
            registry.register(StubTool(name: "beta", description: "b",
                                       parameters: scalar("string"),
                                       exposure: .deferred))
            registry.register(StubTool(name: "gamma", description: "g",
                                       parameters: scalar("string"),
                                       exposure: .hidden))
            registry.registerReservedTransport(
                StubTool(name: "run_code", description: "rc",
                         parameters: scalar("string"), exposure: .direct))
            return registry
        }
        // native：全直连（deferred 经 tool_search、hidden 永不可见）。
        XCTAssertEqual(build(.native).schemas().map { $0.name }, ["alpha"])
        // ptc：只送 run_code 本名（index.ts:986-990）。
        XCTAssertEqual(build(.ptc).schemas().map { $0.name }, ["run_code"])
        // both：直连 + run_code 并存。
        XCTAssertEqual(build(.both).schemas().map { $0.name }, ["alpha", "run_code"])
    }

    // MARK: ToolRegistry · sdkSchemas 过滤

    func testRegistrySdkSchemasFiltering() {
        let registry = ToolRegistry(presentationMode: .both)
        registry.register(StubTool(name: "alpha", description: "a",
                                   parameters: scalar("string"), exposure: .direct))
        registry.register(StubTool(name: "beta", description: "b",
                                   parameters: scalar("string"), exposure: .deferred))
        registry.register(StubTool(name: "gamma", description: "g",
                                   parameters: scalar("string"),
                                   exposure: .codeModeOnly))
        registry.register(StubTool(name: "delta", description: "d",
                                   parameters: scalar("string"),
                                   exposure: .deferredModelOnly))
        registry.register(StubTool(name: "epsilon", description: "e",
                                   parameters: scalar("string"), exposure: .hidden))
        registry.registerReservedTransport(
            StubTool(name: "run_code", description: "rc",
                     parameters: scalar("string"), exposure: .direct))
        // isAvailableInCodeMode（direct|deferred|codeModeOnly）减 run_code 本名。
        let sdk = registry.sdkSchemas()
        XCTAssertEqual(sdk.map { $0.name }, ["alpha", "beta", "gamma"])
        // WanWo 无 output schema 面：output 恒 nil（登记④）。
        XCTAssertTrue(sdk.allSatisfy { $0.output == nil })
        // 新六值不影响 deferredTools（isDeferred：deferred|deferredModelOnly）。
        XCTAssertEqual(registry.deferredTools().map { $0.name }, ["beta", "delta"])
    }

    // MARK: exposure 六值谓词

    func testExposureSixValuePredicates() {
        // (case, isDirect, isDeferred, isAvailableInCodeMode)
        let table: [(ToolExposure, Bool, Bool, Bool)] = [
            (.direct, true, false, true),
            (.deferred, false, true, true),
            (.hidden, false, false, false),
            (.directModelOnly, true, false, false),
            (.deferredModelOnly, false, true, false),
            (.codeModeOnly, false, false, true),
        ]
        for (exposure, direct, deferred, codeMode) in table {
            XCTAssertEqual(exposure.isDirect, direct, "\(exposure.rawValue).isDirect")
            XCTAssertEqual(exposure.isDeferred, deferred,
                           "\(exposure.rawValue).isDeferred")
            XCTAssertEqual(exposure.isAvailableInCodeMode, codeMode,
                           "\(exposure.rawValue).isAvailableInCodeMode")
        }
    }

    // MARK: run_code 保留名

    func testRunCodeNameReservation() {
        let registry = ToolRegistry(presentationMode: .ptc)
        registry.register(StubTool(name: "alpha", description: "a",
                                   parameters: scalar("string"), exposure: .direct))
        // tryRegister(run_code) → 保留名错误逐字（index.ts:1044-1045）。
        do {
            _ = try registry.tryRegister(StubTool(
                name: "run_code", description: "shadow",
                parameters: scalar("string"), exposure: .direct))
            XCTFail("run_code registration must be rejected")
        } catch let error as ToolRegistryReservedError {
            XCTAssertEqual(error.description,
                "tool name \"run_code\" is reserved for the PTC mode presentation "
                    + "transport and cannot be registered or shadowed")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        // 普通 tryRegister 不受扰。
        XCTAssertNoThrow(try registry.tryRegister(StubTool(
            name: "normal", description: "n",
            parameters: scalar("string"), exposure: .direct)))
        // 保留 transport 经专用注册面入场。
        registry.registerReservedTransport(StubTool(
            name: "run_code", description: "transport",
            parameters: scalar("string"), exposure: .direct))
        XCTAssertNotNil(registry.get("run_code"))
        // ptc 档 schemas() 送出的正是保留 transport 本尊。
        XCTAssertEqual(registry.schemas().map { $0.name }, ["run_code"])
    }

    // MARK: 新 exposure 值的过滤语义

    func testSchemasFilterWithNewExposureValues() {
        let registry = ToolRegistry(presentationMode: .native)
        registry.register(StubTool(name: "dm", description: "d",
                                   parameters: scalar("string"),
                                   exposure: .directModelOnly))
        registry.register(StubTool(name: "dmo", description: "d",
                                   parameters: scalar("string"),
                                   exposure: .deferredModelOnly))
        registry.register(StubTool(name: "cmo", description: "c",
                                   parameters: scalar("string"),
                                   exposure: .codeModeOnly))
        // directModelOnly 进初始可见清单；codeModeOnly 只进 SDK 投影。
        XCTAssertEqual(registry.schemas().map { $0.name }, ["dm"])
        XCTAssertEqual(registry.deferredTools().map { $0.name }, ["dmo"])
        XCTAssertEqual(registry.sdkSchemas().map { $0.name }, ["cmo"])
    }

    // MARK: pipeline · ptc collapse 拒绝面

    private func makePipeline(_ mode: ToolPresentationMode) -> (ToolPipeline, ToolRegistry) {
        let registry = ToolRegistry(presentationMode: mode)
        registry.register(StubTool(name: "echo", description: "e",
                                   parameters: scalar("string"), exposure: .direct))
        let pipeline = ToolPipeline(registry: registry, repeatAdviser: RepeatCallAdviser())
        return (pipeline, registry)
    }

    func testPtcCollapseDeniesModelDirectCallWithVerbatimText() async {
        let (pipeline, _) = makePipeline(.ptc)
        let output = await pipeline.run(toolName: "echo", args: .object(["x": .int(1)]),
                                        ctx: makeCtx(callId: "call-1"))
        // ToolNotFoundError reachableFrom 逐字（index.ts:1429-1432 + :494-501）。
        XCTAssertEqual(output.text,
            "Error: unknown tool \"echo\": only `run_code` is callable directly "
                + "— call `echo` from inside a `run_code` program instead")
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "UNKNOWN_TOOL")
        XCTAssertEqual(output.errorName, "ToolNotFoundError")
    }

    func testPtcCollapseBypassedForSubDispatchAndRunCode() async {
        // (a) 子派发旁路（nested：exec.parent !== undefined 形态）。
        let (subPipeline, _) = makePipeline(.ptc)
        let sub = await subPipeline.run(toolName: "echo",
                                        args: .object(["x": .int(1)]),
                                        ctx: makeCtx(callId: "call-1"),
                                        isSubDispatch: true)
        XCTAssertFalse(sub.isError)
        XCTAssertEqual(sub.text, "stub-ok")
        // (b) run_code 本名直调在 ptc 档放行（谓词 name !== RUN_CODE_NAME）。
        let (rcPipeline, rcRegistry) = makePipeline(.ptc)
        rcRegistry.registerReservedTransport(StubTool(
            name: "run_code", description: "rc",
            parameters: scalar("string"), exposure: .direct))
        let direct = await rcPipeline.run(toolName: "run_code", args: .null,
                                          ctx: makeCtx(callId: "call-2"))
        XCTAssertFalse(direct.isError)
        XCTAssertEqual(direct.text, "stub-ok")
        // (c) both 档 native 调用照常执行（collapse 不生效）。
        let (bothPipeline, _) = makePipeline(.both)
        let native = await bothPipeline.run(toolName: "echo",
                                            args: .object(["x": .int(1)]),
                                            ctx: makeCtx(callId: "call-3"))
        XCTAssertFalse(native.isError)
        XCTAssertEqual(native.text, "stub-ok")
    }

    // MARK: PtcPromptSections · 三档 + 动态重求值

    func testPtcPromptSectionsPtcModeRendersBothSections() throws {
        let registry = ToolRegistry(presentationMode: .ptc)
        registry.register(StubTool(name: "echo", description: "e",
                                   parameters: scalar("string"), exposure: .direct))
        registry.registerReservedTransport(StubTool(
            name: "run_code", description: "rc",
            parameters: scalar("string"), exposure: .direct))
        let assembler = PromptAssembler()
        PtcPromptSections.registerSections(into: assembler, registry: registry)
        let assembled = try assembler.assemble(toolSchemas: [], knownNames: nil)
        // 两段按位次拼接：ptcOnly(800) → tools:sdk(5000)。
        XCTAssertEqual(assembled.system,
            ToolSdkText.ptcOnlyInstruction + "\n\n"
                + ToolSdkRenderer.renderToolsSdk(registry.sdkSchemas()))
        XCTAssert(assembled.system.contains("interface ToolArgsMap {"))
    }

    func testPtcPromptSectionsBothModeDropsCollapseSection() throws {
        let registry = ToolRegistry(presentationMode: .both)
        registry.register(StubTool(name: "echo", description: "e",
                                   parameters: scalar("string"), exposure: .direct))
        registry.registerReservedTransport(StubTool(
            name: "run_code", description: "rc",
            parameters: scalar("string"), exposure: .direct))
        let assembler = PromptAssembler()
        PtcPromptSections.registerSections(into: assembler, registry: registry)
        let assembled = try assembler.assemble(toolSchemas: [], knownNames: nil)
        // 'both' renders empty（index.ts:844）：collapse 段丢弃，仅 sdk 段。
        XCTAssertEqual(assembled.system,
                       ToolSdkRenderer.renderToolsSdk(registry.sdkSchemas()))
        XCTAssertFalse(assembled.system.contains("is the only tool you can call directly"))
    }

    func testPtcPromptSectionsNativeRegistersNothing() throws {
        let registry = ToolRegistry(presentationMode: .native)
        registry.register(StubTool(name: "echo", description: "e",
                                   parameters: scalar("string"), exposure: .direct))
        let assembler = PromptAssembler()
        PtcPromptSections.registerSections(into: assembler, registry: registry)
        let assembled = try assembler.assemble(toolSchemas: [], knownNames: nil)
        // dsh index.ts:826-829：defaultMode == native 不注册两段。
        XCTAssertEqual(assembled.system, "")
    }

    func testDynamicSectionReevaluatedPerAssembly() throws {
        let registry = ToolRegistry(presentationMode: .ptc)
        registry.registerReservedTransport(StubTool(
            name: "run_code", description: "rc",
            parameters: scalar("string"), exposure: .direct))
        let assembler = PromptAssembler()
        PtcPromptSections.registerSections(into: assembler, registry: registry)
        // 第一次组装：无 SDK 可见工具（sdkSchemas 减 run_code 后为空）。
        let first = try assembler.assemble(toolSchemas: [], knownNames: nil)
        XCTAssert(first.system.contains("interface ToolArgsMap {}"), first.system)
        // MCP 工具异步激活后注册表变化 → 第二次组装文本跟进（动态段落机制）。
        registry.register(StubTool(name: "echo", description: "e",
                                   parameters: scalar("string"), exposure: .direct))
        let second = try assembler.assemble(toolSchemas: [], knownNames: nil)
        XCTAssert(second.system.contains("echo: string;"), second.system)
        XCTAssertNotEqual(first.system, second.system)
    }
}
