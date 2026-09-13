//
//  SkillToolTests.swift
//  WanWoTests
//
//  【M4-D 件 D5 测试】skill 工具全契约：kebab 拒/unknown/isModelInvocable 门
//  先于加载/正文重读不缓存（改文件后生效）/invocation 复检/三段形态/8KB 截断
//  +告警/平铺与 bundle 两形态正文解析（frontmatter name≠目录名经 bodyPath 可寻）。
//  dsh skills.md:235/:194 + codex render.rs:19/:1180-1183 + extension.rs:472。
//

import XCTest
@testable import WanWo

final class SkillToolTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-tool-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBase)
    }

    // MARK: 夹具

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeRegistry() throws -> SkillRegistry {
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        return SkillRegistry(roots: [.init(source: .project, baseURL: root)])
    }

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "skill-tool-test",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "skill-tool-test"),
            spill: SpillStore(root: tempBase.appendingPathComponent("spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    private func call(_ tool: SkillTool, name: String?) async throws -> ToolOutput {
        var object: [String: JSONValue] = [:]
        if let name { object["name"] = .string(name) }
        return try await tool.execute(.object(object), makeContext())
    }

    // MARK: 参数与 kebab 校验（skills.md:85 工具入口面）

    func testMissingOrEmptyNameRejected() async throws {
        let tool = SkillTool(registry: try makeRegistry())
        let missing = try await call(tool, name: nil)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("missing required parameter"))

        let empty = try await call(tool, name: "   ")
        XCTAssertTrue(empty.isError)
        XCTAssertTrue(empty.text.contains("missing required parameter"))
    }

    func testNonKebabNameRejected() async throws {
        let tool = SkillTool(registry: try makeRegistry())
        for bad in ["Bad_Name", "-lead", "a--b", "UPPER"] {
            let output = try await call(tool, name: bad)
            XCTAssertTrue(output.isError, bad)
            XCTAssertTrue(output.text.contains("invalid skill name"), bad)
            XCTAssertTrue(output.text.contains("kebab-case"), bad)
        }
    }

    // MARK: unknown（文案形态锚定）

    func testUnknownSkillRejected() async throws {
        let tool = SkillTool(registry: try makeRegistry())
        let output = try await call(tool, name: "no-such-skill")
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("unknown or no longer available"))
    }

    // MARK: isModelInvocable 门（先于加载）

    func testUserOnlySkillRejectedBeforeLoad() async throws {
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        try write("---\nname: user-only\ndescription: d\n"
            + "disable-model-invocation: true\n---\nSECRET BODY",
                  to: root.appendingPathComponent("user-only/SKILL.md"))
        let tool = SkillTool(registry: try makeRegistry())

        let output = try await call(tool, name: "user-only")
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("not model-invocable"))
        // 门先于加载：正文不出现在结果
        XCTAssertFalse(output.text.contains("SECRET BODY"))
    }

    // MARK: 三段返回形态 + 正文重读（dsh:194 不缓存）

    func testThreeSectionShapeAndBodyRereadFreshness() async throws {
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        let bodyURL = root.appendingPathComponent("deploy/SKILL.md")
        try write("---\nname: deploy\ndescription: Deploy helper\n---\nBODY V1",
                  to: bodyURL)
        let tool = SkillTool(registry: try makeRegistry())

        // 三段形态
        let first = try await call(tool, name: "deploy")
        XCTAssertFalse(first.isError)
        XCTAssertTrue(first.text.contains("<skill_content name=\"deploy\">"))
        XCTAssertTrue(first.text.contains("BODY V1"))
        XCTAssertTrue(first.text.contains("</skill_content>"))
        XCTAssertTrue(first.text.contains("<skill_resources>"))
        // 资源段=目录路径引导（简化授权）
        XCTAssertTrue(first.text.contains(bodyURL.deletingLastPathComponent().path))
        XCTAssertTrue(first.text.contains("<skill_instructions>"))
        // 守则段：codex 五条锚词
        XCTAssertTrue(first.text.contains("Do not delegate reading, summarizing, or interpreting skill instructions to a subagent."))
        XCTAssertTrue(first.text.contains("next-best approach"))

        // 正文重读不缓存：直接改文件（不经失效通道）→ 下次调用即新正文
        try "BODY V2".write(to: bodyURL, atomically: true, encoding: .utf8)
        let second = try await call(tool, name: "deploy")
        XCTAssertTrue(second.text.contains("BODY V2"))
        XCTAssertFalse(second.text.contains("BODY V1"))
    }

    // MARK: 8KB 截断 + 文内告警（codex render.rs:19 / extension.rs:472）

    func testOverlongBodyTruncatedWithInTextWarning() async throws {
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        let longBody = String(repeating: "x", count: 20_000)
        try write("---\nname: long-body\ndescription: d\n---\n\(longBody)",
                  to: root.appendingPathComponent("long-body/SKILL.md"))
        let tool = SkillTool(registry: try makeRegistry())

        let output = try await call(tool, name: "long-body")
        XCTAssertFalse(output.isError)
        // 截断告警逐字（extension.rs:472）
        XCTAssertTrue(output.text.contains(
            "Skill `long-body` exceeded the main prompt context limit and was truncated."))
        // 正文段 ≤ 8000 字节（截断不含告警行）
        let bodyStart = try XCTUnwrap(output.text.range(of: "<skill_content name=\"long-body\">\n"))
        let bodyEnd = try XCTUnwrap(output.text.range(of: "\n\n[warning]"))
        let bodyText = String(output.text[bodyStart.upperBound..<bodyEnd.lowerBound])
        XCTAssertLessThanOrEqual(bodyText.utf8.count, SkillTool.maxSkillPromptBytes)
    }

    func testTruncationRespectsUtf8CharBoundary() {
        // 多字节字符（💡 4 字节）跨界回退：12000 字节，maxBytes=8001 →
        // utf8[8001] 为续字节 → 回退至 8000 边界 = 2000 完整字符。
        let text = String(repeating: "💡", count: 3000)  // 12000 字节
        let (truncated, didTruncate) = SkillTool.truncateToBytes(text, maxBytes: 8001)
        XCTAssertTrue(didTruncate)
        XCTAssertEqual(truncated.utf8.count, 8000)
        XCTAssertEqual(truncated.count, 2000)
        // 往返一致（截断点落在字符边界）
        XCTAssertEqual(truncated, String(decoding: truncated.utf8, as: UTF8.self))
        // 未超限不截断
        let (same, flag) = SkillTool.truncateToBytes("short", maxBytes: 8_000)
        XCTAssertEqual(same, "short")
        XCTAssertFalse(flag)
    }

    // MARK: 平铺形态正文解析（bodyPath 消除 name≠stem 缺口）

    func testFlatFormBodyFoundWhenFrontmatterNameDiffersFromStem() async throws {
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        // 平铺文件 my-note.md，frontmatter name=renamed-note
        try write("---\nname: renamed-note\ndescription: d\n---\nFLAT BODY",
                  to: root.appendingPathComponent("my-note.md"))
        let tool = SkillTool(registry: try makeRegistry())

        let output = try await call(tool, name: "renamed-note")
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("FLAT BODY"))
        // 资源段=根目录（平铺 resourceBase 语义）
        XCTAssertTrue(output.text.contains(root.path))
    }

    // MARK: 快照新鲜度（复检防线的快照面）

    func testSkillRemovedAfterLoadIsRejectedOnNextCall() async throws {
        // 复检分支（step ⑥）在单线程测试内无真实竞态窗口——真竞态由
        // write/edit 失效+快照刷新时序承载（D2 通道②测试已锚）。此处覆盖
        // 快照新鲜度等价面：技能移除+失效后 → unknown（而非读死缓存正文）。
        let root = tempBase.appendingPathComponent("skills", isDirectory: true)
        try write("---\nname: gone\ndescription: d\n---\nBODY",
                  to: root.appendingPathComponent("gone/SKILL.md"))
        let tool = SkillTool(registry: try makeRegistry())
        let loaded = try await call(tool, name: "gone")
        XCTAssertTrue(loaded.text.contains("BODY"))
        // 删除 + 失效 → 下一调用 unknown
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("gone"))
        tool.registry.invalidate()
        let after = try await call(tool, name: "gone")
        XCTAssertTrue(after.isError)
        XCTAssertTrue(after.text.contains("unknown or no longer available"))
    }

    // MARK: 并发分类与呈现面

    func testConcurrencySafeAndPresentationDefaults() throws {
        let tool = SkillTool(registry: try makeRegistry())
        XCTAssertTrue(tool.isConcurrencySafe(.null))  // 纯读取（dsh:194 重读语义）
        XCTAssertNil(tool.presentCall(.object(["name": .string("x")])))  // R4 默认 nil
        XCTAssertEqual(tool.exposure, .direct)  // 内置元工具恒 direct
    }
}
