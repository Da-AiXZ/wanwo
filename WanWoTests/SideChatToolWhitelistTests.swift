//
//  SideChatToolWhitelistTests.swift
//  WanWoTests
//
//  【M6.6（B4）测试 · 侧聊工具白名单矩阵（安全语义，必测）】
//  覆盖：写类工具不可见（apply 后注册表不再暴露）+ preExecute fail closed
//  复核（guard 对白名单外一切工具名给拒绝理由——含晚到注册与未知名）+
//  只读白名单放行 + 管线级拒绝（ToolPipeline.run 合成 DENIED_BY_GUARD）。
//

import XCTest
@testable import WanWo

final class SideChatToolWhitelistTests: XCTestCase {

    // MARK: - fixture

    /// 最小工具桩（注册表/管线语义测试用）。
    private struct StubTool: AgentTool {
        let name: String
        let exposure: ToolExposure
        let output: ToolOutput

        init(name: String, exposure: ToolExposure = .direct,
             output: ToolOutput = .success("ok")) {
            self.name = name
            self.exposure = exposure
            self.output = output
        }

        var description: String { name }
        var parameters: JSONValue { .object([:]) }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            output
        }
    }

    private func makeContext(sessionId: String = "side-test") -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: sessionId, turn: 1, step: 1, callId: "call-1",
            workspace: WorkspaceFileAccess(
                sessionId: sessionId,
                guestRoot: FileManager.default.temporaryDirectory,
                projectSkillsRoot: FileManager.default.temporaryDirectory),
            spill: SpillStore(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("side-test-spill-\(UUID().uuidString)")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    // MARK: - 白名单矩阵（静态判定面）

    func testWriteClassToolsAreRejected() {
        // 反面矩阵（安全语义必测）：每个写类名都给拒绝理由。
        for name in SideChatToolWhitelist.writeClass {
            let reason = SideChatToolWhitelist.guardReason(name: name)
            XCTAssertNotNil(reason, "写类工具 \(name) 必须被拒绝")
            XCTAssertFalse(reason!.isEmpty)
        }
    }

    func testReadOnlyWhitelistPasses() {
        for name in SideChatToolWhitelist.allowed {
            XCTAssertNil(SideChatToolWhitelist.guardReason(name: name),
                         "只读工具 \(name) 必须放行")
        }
    }

    func testUnknownAndDynamicNamesAreFailClosed() {
        // 白名单外未知名（含 MCP 动态名形态）一律拒——fail closed 无放行路径。
        XCTAssertNotNil(SideChatToolWhitelist.guardReason(name: "mcp__server__tool"))
        XCTAssertNotNil(SideChatToolWhitelist.guardReason(name: "totally_unknown"))
        XCTAssertNotNil(SideChatToolWhitelist.guardReason(name: ""))
    }

    // MARK: - 注册表面（不可见 + guard 复核）

    func testApplyRemovesWriteToolsFromRegistry() {
        let registry = ToolRegistry()
        // 【终验修】fixture 补齐只读白名单全集：allowed 六件（read/glob/grep/
        // read_image/web_search/web_fetch）+ 写类三件（bash/write/edit）。
        // 此前只读四件（grep/read_image/web_search/web_fetch）从未注册，
        // apply 后 schemaNames={read,glob} ≠ allowed——集合不等的病根在
        // fixture 缺注册，不在产品注销语义。
        registry.register(StubTool(name: "read"))
        registry.register(StubTool(name: "glob"))
        registry.register(StubTool(name: "grep"))
        registry.register(StubTool(name: "read_image"))
        registry.register(StubTool(name: "web_search"))
        registry.register(StubTool(name: "web_fetch"))
        registry.register(StubTool(name: "bash"))
        registry.register(StubTool(name: "write"))
        registry.register(StubTool(name: "edit"))
        SideChatToolWhitelist.apply(to: registry)
        // 不可见：白名单外全部注销。
        XCTAssertNil(registry.get("bash"))
        XCTAssertNil(registry.get("write"))
        XCTAssertNil(registry.get("edit"))
        XCTAssertNotNil(registry.get("read"))
        XCTAssertNotNil(registry.get("glob"))
        XCTAssertNotNil(registry.get("grep"))
        XCTAssertNotNil(registry.get("read_image"))
        XCTAssertNotNil(registry.get("web_search"))
        XCTAssertNotNil(registry.get("web_fetch"))
        // 模型可见 schema 同步收窄。
        let schemaNames = Set(registry.schemas().map(\.name))
        XCTAssertEqual(schemaNames, SideChatToolWhitelist.allowed)
    }

    func testApplyGuardRejectsLateRegisteredTools() {
        // 晚到注册（MCP 异步激活形态）不可见性兜底：guard fail closed。
        let registry = ToolRegistry()
        registry.register(StubTool(name: "read"))
        SideChatToolWhitelist.apply(to: registry)
        registry.register(StubTool(name: "mcp__evil__delete_all"))
        // 名字仍注册成功（tryRegister 语义），但执行必被 guard 拒。
        XCTAssertNotNil(registry.get("mcp__evil__delete_all"))
        XCTAssertNotNil(SideChatToolWhitelist.guardReason(name: "mcp__evil__delete_all"))
    }

    // MARK: - 管线级（preExecute fail closed 落点）

    func testPipelineRejectsWriteToolWithGuardError() async {
        let registry = ToolRegistry()
        registry.register(StubTool(name: "bash", output: .success("ran")))
        SideChatToolWhitelist.apply(to: registry)
        let pipeline = ToolPipeline(registry: registry, repeatAdviser: RepeatCallAdviser())
        let output = await pipeline.run(toolName: "bash", args: .object([:]),
                                        ctx: makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "DENIED_BY_GUARD")
        XCTAssertTrue(output.text.contains("侧边聊天为只读探索会话"))
    }

    func testPipelineAllowsWhitelistedTool() async {
        let registry = ToolRegistry()
        registry.register(StubTool(name: "read", output: .success("file content")))
        SideChatToolWhitelist.apply(to: registry)
        let pipeline = ToolPipeline(registry: registry, repeatAdviser: RepeatCallAdviser())
        let output = await pipeline.run(toolName: "read", args: .object([:]),
                                        ctx: makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "file content")
    }
}
