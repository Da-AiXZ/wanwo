//
//  SummaryStructuredTests.swift
//  WanWoTests
//
//  【M8 批2 件B2】结构化摘要器纯同步测试：11 字段 Codable 往返、tool schema 形状、
//  tool_call 参数解析/坏 JSON 兜底、analysis 剥离、增量折叠拼接、Files 提取、
//  锚点消息逐字（派单任务 9 覆盖清单）。
//

import XCTest
@testable import WanWo

final class SummaryStructuredTests: XCTestCase {

    // MARK: StateSummary Codable 往返（11 字段，snake_case 键）

    func testStateSummaryCodableRoundtrip() throws {
        var summary = StateSummary()
        summary.userIntent = "修复压缩链"
        summary.techContext = "Swift 5.9, URLSession"
        summary.filesAndCode = "OpenAICompatAdapter.swift"
        summary.errorsAndFixes = "EMPTY_RESPONSE -> 关 thinking"
        summary.problemSolving = "tool_choice 缺缝"
        summary.userMessages = "[1] 做压缩 [2] 加兜底"
        summary.pendingTasks = "合并缝需求"
        summary.currentWork = "写测试"
        summary.nextStep = "跑 build"
        summary.securityConstraints = "密钥不落盘（verbatim）"
        summary.otherContext = "无"

        let data = try JSONEncoder().encode(summary)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // snake_case 键（tool_call arguments 直解码契约）
        XCTAssertTrue(json.contains("\"user_intent\""))
        XCTAssertTrue(json.contains("\"security_constraints\""))
        XCTAssertTrue(json.contains("\"other_context\""))

        let decoded = try JSONDecoder().decode(StateSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testStateSummaryDecodeMissingFieldsDefaultEmpty() throws {
        // OpenHands default '' 语义：模型漏字段不炸解码。
        let json = #"{"user_intent":"x","pending_tasks":"y","current_work":"z"}"#
        let decoded = try JSONDecoder().decode(StateSummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.userIntent, "x")
        XCTAssertEqual(decoded.pendingTasks, "y")
        XCTAssertEqual(decoded.currentWork, "z")
        XCTAssertEqual(decoded.techContext, "")
        XCTAssertEqual(decoded.filesAndCode, "")
        XCTAssertEqual(decoded.securityConstraints, "")
        XCTAssertEqual(decoded.otherContext, "")
    }

    // MARK: tool schema（SSS:101-126 语义）

    func testToolSchemaShape() {
        let schema = StateSummary.makeToolSchema()
        XCTAssertEqual(schema.name, "create_state_summary")
        XCTAssertTrue(schema.description.contains("You must include non-empty values for "
            + "user_intent, pending_tasks, and current_work"))

        guard case .object(let parameters) = schema.parameters else {
            return XCTFail("parameters must be object")
        }
        guard case .string(let type) = parameters["type"] else { return XCTFail("type") }
        XCTAssertEqual(type, "object")
        guard case .array(let required) = parameters["required"] else { return XCTFail("required") }
        XCTAssertEqual(required.compactMap { if case .string(let v) = $0 { return v }; return nil },
                       ["user_intent", "pending_tasks", "current_work"])
        guard case .object(let properties) = parameters["properties"] else {
            return XCTFail("properties")
        }
        XCTAssertEqual(properties.count, 11)
        let keys = ["user_intent", "tech_context", "files_and_code", "errors_and_fixes",
                    "problem_solving", "user_messages", "pending_tasks", "current_work",
                    "next_step", "security_constraints", "other_context"]
        for key in keys {
            guard case .object(let field)? = properties[key] else {
                return XCTFail("missing field \(key)")
            }
            XCTAssertEqual(field["type"], .string("string"), key)
            XCTAssertTrue(field["description"] != nil, key)
        }
    }

    // MARK: tool_call 参数解析 / 坏 JSON 兜底（OpenHands :264-293）

    func testParseReplyToolCallPath() {
        let arguments = #"{"user_intent":"修 bug","pending_tasks":"回归","current_work":"验证"}"#
        let reply = SummaryLLMReply(
            text: "",
            toolCalls: [SummaryLLMToolCall(name: "create_state_summary", arguments: arguments)])
        guard case .structured(let summary) = StructuredSummarizer.parseReply(reply) else {
            return XCTFail("expected structured")
        }
        XCTAssertEqual(summary.userIntent, "修 bug")
        XCTAssertEqual(summary.pendingTasks, "回归")
        XCTAssertEqual(summary.currentWork, "验证")
    }

    func testParseReplyIgnoresForeignToolCall() {
        let reply = SummaryLLMReply(
            text: "<summary>正文</summary>",
            toolCalls: [SummaryLLMToolCall(name: "other_tool", arguments: "{}")])
        guard case .textSummary(let text) = StructuredSummarizer.parseReply(reply) else {
            return XCTFail("expected text path (foreign tool call ignored)")
        }
        XCTAssertEqual(text, "正文")
    }

    func testParseReplyBadJSONFallsBackEmpty() {
        let reply = SummaryLLMReply(
            text: "",
            toolCalls: [SummaryLLMToolCall(name: "create_state_summary", arguments: "{bad json")])
        guard case .fallbackEmpty(let reason) = StructuredSummarizer.parseReply(reply) else {
            return XCTFail("expected fallback")
        }
        XCTAssertTrue(reason.contains("bad create_state_summary arguments JSON"))
    }

    func testParseReplyNoContentFallsBackEmpty() {
        let reply = SummaryLLMReply(text: "   \n", toolCalls: [])
        guard case .fallbackEmpty = StructuredSummarizer.parseReply(reply) else {
            return XCTFail("expected fallback")
        }
    }

    // MARK: <analysis> 剥离（claudecode §②a）

    func testSummaryTextStripsAnalysisKeepsSummaryBlock() {
        let raw = "<analysis>草稿：时间线走查……</analysis>\n<summary>1. Primary Request and Intent (user_intent): 修 bug</summary>"
        let text = StructuredSummarizer.summaryText(from: raw)
        XCTAssertEqual(text, "1. Primary Request and Intent (user_intent): 修 bug")
    }

    func testSummaryTextUnclosedAnalysisTruncated() {
        let raw = "<analysis>被截断的草稿"
        XCTAssertEqual(StructuredSummarizer.summaryText(from: raw), nil)
    }

    func testSummaryTextWithoutTagsPassesThrough() {
        XCTAssertEqual(StructuredSummarizer.summaryText(from: "纯文本摘要"), "纯文本摘要")
    }

    // MARK: 增量折叠拼接（Cline :139-151 + buildSummaryRequest :669-703）

    func testUserPromptAssemblyWithPreviousSummary() {
        let prompt = SummaryPrompt.userPrompt(
            previousSummary: "旧摘要正文",
            serializedEvents: ["[User]: 做压缩", "[Bot]: 好的"])
        // NO_TOOLS_PREAMBLE 首尾双声明
        XCTAssertTrue(prompt.hasPrefix(SummaryPrompt.noToolsPreamble))
        XCTAssertEqual(prompt.components(separatedBy: SummaryPrompt.noToolsPreamble).count - 1, 2)
        // 9 板块指令 + 字段括注在位
        XCTAssertTrue(prompt.contains("1. Primary Request and Intent (user_intent):"))
        XCTAssertTrue(prompt.contains("9. Optional Next Step (next_step):"))
        XCTAssertTrue(prompt.contains("10. Security Constraints (security_constraints):"))
        // 增量折叠段
        XCTAssertTrue(prompt.contains("Previous summary:\n旧摘要正文"))
        XCTAssertTrue(prompt.hasSuffix("Conversation:\n[User]: 做压缩\n\n[Bot]: 好的"))
        // system 逐字
        XCTAssertEqual(SummaryPrompt.systemPrompt,
                       "You are a helpful AI assistant tasked with summarizing conversations.")
    }

    func testUserPromptEmptyEventsAndNoPreviousSummary() {
        let prompt = SummaryPrompt.userPrompt(previousSummary: nil, serializedEvents: [])
        XCTAssertFalse(prompt.contains("Previous summary:"))
        XCTAssertTrue(prompt.hasSuffix("Conversation:\n(empty)"))
    }

    // MARK: Files 段兜底提取（Cline extractFileOps :424-461 裁剪 × B1 终版 grammar）

    func testToolCallEntriesParsesB1Grammar() {
        // 终版：name(callId) {json}，" | " 分隔；arguments = 首个 { 起的 JSON
        let line = "[seq=7] [assistant] 说明文本 [tool calls: read_file(c1) {\"path\":\"a.swift\"} | shell(c2) {\"cmd\":\"ls -la\"}]"
        let entries = StructuredSummarizer.toolCallEntries(fromLine: line)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "read_file")
        XCTAssertEqual(entries[0].arguments, "{\"path\":\"a.swift\"}")
        XCTAssertEqual(entries[1].name, "shell")
        XCTAssertEqual(entries[1].arguments, "{\"cmd\":\"ls -la\"}")
        // 旧形态纯 callId（无 {）→ arguments 为空
        let bare = StructuredSummarizer.toolCallEntries(
            fromLine: "[seq=1] [assistant] [tool calls: read_file(c1)]")
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].name, "read_file")
        XCTAssertEqual(bare[0].arguments, "")
        // JSON 内含 "]"：段收尾取行尾最后一个 "]"，不切早
        let bracket = StructuredSummarizer.toolCallEntries(
            fromLine: "[seq=2] [assistant] [tool calls: read_file(c1) {\"files\":[\"a.swift\"]}]")
        XCTAssertEqual(bracket[0].arguments, "{\"files\":[\"a.swift\"]}")
    }

    func testExtractFileOpsReadAndEditKeys() {
        let events = [
            "[seq=1] [user] 读文件",
            "[seq=2] [assistant] reading [tool calls: read_file(c1) {\"path\":\"a.swift\"}]",
            "[seq=3] [assistant] editing [tool calls: edit_file(c2) {\"file_path\":\"b.swift\",\"old_string\":\"x\"} | apply_patch(c3) {\"files\":[\"c.swift\",\"d.swift\"]}]",
            "[seq=4] [tool result call_9] ls 输出",
        ]
        let ops = StructuredSummarizer.extractFileOps(events)
        XCTAssertEqual(ops.read, ["a.swift"])
        XCTAssertEqual(ops.edited, ["b.swift", "c.swift", "d.swift"])
    }

    func testExtractFileOpsBareCallIDYieldsNoPaths() {
        // 旧形态纯 callId（无 JSON args）→ 兜底为空（不误收）
        let events = ["[seq=3] [assistant] hi [tool calls: read_file(c1) | edit_file(c2)]"]
        let ops = StructuredSummarizer.extractFileOps(events)
        XCTAssertEqual(ops.read, [])
        XCTAssertEqual(ops.edited, [])
    }

    func testExtractFileOpsDedupesPreservingOrder() {
        let events = [
            "[seq=1] [assistant] [tool calls: read_file(c1) {\"path\":\"a.swift\"}]",
            "[seq=2] [assistant] [tool calls: read_file(c2) {\"path\":\"a.swift\"}]",
        ]
        XCTAssertEqual(StructuredSummarizer.extractFileOps(events).read, ["a.swift"])
    }

    func testFilesSectionTextAndEnsureFilesSection() {
        XCTAssertEqual(
            StructuredSummarizer.filesSectionText(read: ["a.swift"], edited: []),
            "Read: a.swift\nEdited: none")
        let base = "摘要正文"
        let withFiles = StructuredSummarizer.ensureFilesSection(
            base, read: ["a.swift"], edited: ["b.swift"])
        XCTAssertTrue(withFiles.hasSuffix("## Files\nRead: a.swift\nEdited: b.swift"))
        // 已有 Files 段不重复追加
        XCTAssertEqual(StructuredSummarizer.ensureFilesSection(withFiles, read: [], edited: []),
                       withFiles)
    }

    // MARK: Markdown 渲染（__str__ 分组标题语义）

    func testRenderMarkdownGroupsSkipsEmptyFields() {
        var summary = StateSummary()
        summary.userIntent = "意图"
        summary.filesAndCode = "文件"
        summary.securityConstraints = "约束"
        let markdown = summary.renderMarkdown()
        XCTAssertTrue(markdown.hasPrefix("# State Summary"))
        XCTAssertTrue(markdown.contains("## Core Information"))
        XCTAssertTrue(markdown.contains("## Code Changes"))
        XCTAssertTrue(markdown.contains("## Security Constraints"))
        XCTAssertFalse(markdown.contains("## Optional Next Step"))
        XCTAssertFalse(markdown.contains("user_messages"))
        XCTAssertEqual(markdown, summary.renderMarkdown()) // 确定性
    }

    // MARK: 边界锚点（claudecode §②d 逐字）

    func testContinuationAnchorMessageVerbatim() {
        let anchor = continuationAnchorMessage(summary: "SUMMARY-BODY")
        XCTAssertEqual(anchor,
            "This session is being continued from a previous conversation that ran out of context. "
            + "The summary below covers the earlier portion of the conversation."
            + "\n\nSUMMARY-BODY\n\n"
            + "Please continue the conversation from where we left off without asking the user any "
            + "further questions. Continue with the last task that you were asked to work on.")
        // 常量本身逐字（防漂移）
        XCTAssertEqual(ContextSummarizerAnchor.prefix,
            "This session is being continued from a previous conversation that ran out of context. "
            + "The summary below covers the earlier portion of the conversation.")
        XCTAssertEqual(ContextSummarizerAnchor.suffix,
            "Please continue the conversation from where we left off without asking the user any "
            + "further questions. Continue with the last task that you were asked to work on.")
    }

    // MARK: 锚点承载装饰器（b1-report §五/偏差 #4：锚点由 summarize 返回值承载）

    private struct StubSummarizer: ContextSummarizer {
        let result: String?
        func summarize(serializedEvents: [String], previousSummary: String?) async -> String? {
            result
        }
    }

    func testAnchorCarryingSummarizerAutoWrapsWithDirective() async {
        let auto = AnchorCarryingSummarizer(
            base: StubSummarizer(result: "正文"), includeContinuationDirective: true)
        let wrapped = await auto.summarize(serializedEvents: [], previousSummary: nil)
        XCTAssertEqual(wrapped, continuationAnchorMessage(summary: "正文"))
        XCTAssertTrue(wrapped!.hasSuffix(ContextSummarizerAnchor.suffix))
        // 失败透传 nil（B1 熔断计数不受装饰影响）
        let failing = AnchorCarryingSummarizer(
            base: StubSummarizer(result: nil), includeContinuationDirective: true)
        let failed = await failing.summarize(serializedEvents: [], previousSummary: nil)
        XCTAssertNil(failed)
    }

    func testAnchorCarryingSummarizerManualOmitsDirective() async {
        // manual 场景：只带 prefix，无 "Please continue…" 追加句（§②d 语义）
        let manual = AnchorCarryingSummarizer(
            base: StubSummarizer(result: "正文"), includeContinuationDirective: false)
        let wrapped = await manual.summarize(serializedEvents: [], previousSummary: nil)
        XCTAssertEqual(wrapped, ContextSummarizerAnchor.prefix + "\n\n正文")
        XCTAssertFalse(wrapped!.contains("Please continue the conversation"))
    }
}
