//
//  SummaryBasicFallbackTests.swift
//  WanWoTests
//
//  【M8 批2 件B2】BasicFallbackSummarizer 纯同步测试（serializedEvents = B1
//  CondensationWorkingSet.serializedEvents grammar）：SYSTEM_NOTICE 回填格式、
//  typed user prompt 全保留、上轮产物冻结（参数 + 事件流旧摘要行）、命令截
//  100 字符、最近 3 条 assistant 行原样、tool result 不回填、空输入 nil
//  （派单任务 9 覆盖清单 + b1 对齐消息第 5 条空串=nil 语义）。
//

import XCTest
@testable import WanWo

final class SummaryBasicFallbackTests: XCTestCase {

    private func makeEvents() -> [String] { [
        "[seq=1] [user] 第一轮请求",
        "[seq=2] [assistant] 第一轮回答 [tool calls: read_file(c1) {\"path\":\"a.swift\"}]",
        "[seq=3] [tool result c1] 文件内容……",
        "[seq=4] [user] 第二轮请求",
        "[seq=5] [assistant] [tool calls: edit_file(c2) {\"file_path\":\"b.swift\"}]",
        "[seq=6] [assistant] [tool calls: run_command(c3) {\"cmd\":\"git status --porcelain\"}]",
        "[seq=7] [assistant] 第二轮回答",
        "[seq=8] [previous summary cond-9] 旧摘要行",
    ] }

    // MARK: fold 总装（user 全保留 / 旧摘要冻结 / tool result 不回填 / grammar 角色分类）

    func testFoldAssemblyPreservesUsersFreezesPreviousSummary() {
        let folded = BasicFallbackSummarizer.fold(
            serializedEvents: makeEvents(),
            previousSummary: "上一轮压缩产物（冻结）")
        // previousSummary 参数冻结置顶
        XCTAssertEqual(folded?.hasPrefix("上一轮压缩产物（冻结）"), true)
        // 事件流内旧摘要行冻结保留（:395-421）
        XCTAssertTrue(folded!.contains("[seq=8] [previous summary cond-9] 旧摘要行"))
        // typed user prompt 全保留（原样整行）
        XCTAssertTrue(folded!.contains("[seq=1] [user] 第一轮请求"))
        XCTAssertTrue(folded!.contains("[seq=4] [user] 第二轮请求"))
        // tool result 正文不出现
        XCTAssertFalse(folded!.contains("[tool result"))
        // SYSTEM_NOTICE 在位
        XCTAssertTrue(folded!.contains("<SYSTEM_NOTICE>"))
    }

    func testFoldKeepsLastThreeAssistantLinesVerbatim() {
        let folded = BasicFallbackSummarizer.fold(serializedEvents: makeEvents(),
                                                  previousSummary: nil)
        // 最近 3 条 assistant 行原样并入（PRESERVED_ASSISTANT_TEXT_COUNT=3；
        // 含 tool-calls 标注的行原样保留——单字符串适配，登记）
        XCTAssertTrue(folded!.contains("[seq=5] [assistant] [tool calls: edit_file(c2) {\"file_path\":\"b.swift\"}]"))
        XCTAssertTrue(folded!.contains("[seq=6] [assistant] [tool calls: run_command(c3) {\"cmd\":\"git status --porcelain\"}]"))
        XCTAssertTrue(folded!.contains("[seq=7] [assistant] 第二轮回答"))
        // 第 4 条（更早的）不在保留集
        XCTAssertFalse(folded!.contains("[seq=2] [assistant]"))
    }

    // MARK: SYSTEM_NOTICE 格式（basic-compaction.ts:81-93 语义）

    func testSystemNoticeFormat() {
        let dropped = BasicFallbackSummarizer.DroppedWork(
            filesRead: ["a.swift"], filesEdited: ["b.swift"], commands: ["git status"])
        let notice = BasicFallbackSummarizer.systemNotice(
            dropped: dropped, assistantReplies: ["[seq=7] [assistant] 回复"])
        XCTAssertEqual(notice, """
        <SYSTEM_NOTICE>
        Earlier context was compacted. Summary of your actions after the request above:
        Files read: a.swift
        Files edited: b.swift
        Commands ran: git status
        [seq=7] [assistant] 回复
        </SYSTEM_NOTICE>
        """)
    }

    func testSystemNoticeEmptyReturnsNil() {
        let dropped = BasicFallbackSummarizer.DroppedWork(
            filesRead: [], filesEdited: [], commands: [])
        XCTAssertNil(BasicFallbackSummarizer.systemNotice(dropped: dropped, assistantReplies: []))
        XCTAssertNotNil(BasicFallbackSummarizer.systemNotice(dropped: dropped,
                                                             assistantReplies: ["[seq=1] [assistant] 有回复"]))
    }

    // MARK: dropped-work 提取（× B1 终版 grammar：name(callId) {json}，" | " 分隔）

    func testDroppedWorkFromB1GrammarLines() {
        let dropped = BasicFallbackSummarizer.summarizeToolActivity(toolCallLines: [
            "[seq=2] [assistant] [tool calls: read_file(c1) {\"path\":\"a.swift\"}]",
            "[seq=5] [assistant] [tool calls: edit_file(c2) {\"file_path\":\"b.swift\"}]",
            "[seq=6] [assistant] [tool calls: run_command(c3) {\"command\":\"git status --porcelain\"}]",
        ])
        XCTAssertEqual(dropped.filesRead, ["a.swift"])
        XCTAssertEqual(dropped.filesEdited, ["b.swift"])
        // 命令表抽值口径（B1 拍板；键名事实源 ShellTool.swift:65,71）：JSON 可解析
        // 且有 `command` 键 → 取值截 100
        XCTAssertEqual(dropped.commands, ["git status --porcelain"])
    }

    func testCommandFallbackWhenCommandKeyMissing() {
        // 解析成功但无 `command` 键（如 {"cmd":…}）→ 回落 arguments 原文截 100
        let dropped = BasicFallbackSummarizer.summarizeToolActivity(toolCallLines: [
            "[seq=1] [assistant] [tool calls: run_command(c1) {\"cmd\":\"git status\"}]",
            // 解析失败（2000 cap 截断切尾，B1 序列化仍补收尾 `]`）→ 同样回落原文
            "[seq=2] [assistant] [tool calls: shell(c2) {\"command\":\"ls -la\"]",
        ])
        XCTAssertEqual(dropped.commands, ["{\"cmd\":\"git status\"}",
                                          "{\"command\":\"ls -la"])
    }

    func testCommandTextExtraction() {
        XCTAssertEqual(BasicFallbackSummarizer.commandText(
            fromArguments: "{\"command\":\"ls -la\",\"timeout_ms\":900000}"), "ls -la")
        XCTAssertNil(BasicFallbackSummarizer.commandText(fromArguments: "{\"cmd\":\"x\"}"))
        XCTAssertNil(BasicFallbackSummarizer.commandText(fromArguments: "{\"command\":\"  \"}"))
        XCTAssertNil(BasicFallbackSummarizer.commandText(fromArguments: "call_42"))
        XCTAssertNil(BasicFallbackSummarizer.commandText(fromArguments: "{bad json"))
    }

    func testBareCallIDNotPollutesCommands() {
        // 旧形态纯 callId（无 JSON args）→ 不入命令表
        let dropped = BasicFallbackSummarizer.summarizeToolActivity(toolCallLines: [
            "[seq=1] [assistant] [tool calls: run_command(c1) | run_command(c2)]",
        ])
        XCTAssertEqual(dropped.commands, [])
    }

    // MARK: 命令截 100 字符（Cline :464, :492-497）

    func testCommandTruncatedTo100Chars() {
        let commandValue = String(repeating: "x", count: 250) + " tail"
        let dropped = BasicFallbackSummarizer.summarizeToolActivity(toolCallLines: [
            "[seq=1] [assistant] [tool calls: run_command(c1) {\"command\":\"\(commandValue)\"}]",
        ])
        XCTAssertEqual(dropped.commands, [String(repeating: "x", count: 100)])
    }

    // MARK: 空输入 nil（Cline :635-637 skipped 语义；b1 对齐第 5 条：空串按 nil）

    func testFoldEmptyReturnsNil() {
        XCTAssertNil(BasicFallbackSummarizer.fold(serializedEvents: [],
                                                  previousSummary: nil))
        XCTAssertNil(BasicFallbackSummarizer.fold(serializedEvents: [],
                                                  previousSummary: "  "))
        // 只有 tool result / 未知空行 → nil（不产空串）
        XCTAssertNil(BasicFallbackSummarizer.fold(serializedEvents: [
            "[seq=1] [tool result call_1] 只有结果",
            "  ",
        ], previousSummary: nil))
        // 只有旧摘要 → 冻结原样返回（不折叠、不丢）
        XCTAssertEqual(BasicFallbackSummarizer.fold(serializedEvents: [],
                                                    previousSummary: "旧摘要"),
                       "旧摘要")
    }

    // MARK: grammar 角色解析

    func testRoleTokenParsing() {
        XCTAssertEqual(BasicFallbackSummarizer.roleToken(of: "[seq=1] [user] hi"), "user")
        XCTAssertEqual(BasicFallbackSummarizer.roleToken(of: "[seq=2] [assistant] x"), "assistant")
        XCTAssertEqual(BasicFallbackSummarizer.roleToken(of: "[seq=3] [tool result c1] y"),
                       "tool result c1")
        XCTAssertEqual(BasicFallbackSummarizer.roleToken(of: "[seq=4] [previous summary s] z"),
                       "previous summary s")
        XCTAssertNil(BasicFallbackSummarizer.roleToken(of: "自由文本行"))
    }
}
