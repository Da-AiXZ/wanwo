//
//  P2InteractionTests.swift
//  WanWoTests
//
//  【P2 全段测试】覆盖纯函数层可断言面：
//    · P2-⑦ Compactor breakdown 三段计价（system/tools 取 header last-wins、
//      message = 表面折叠；无 header 两段为 0——dsh breakdown-projection 语义）。
//    · P2-⑬ 思考披露行摘要函数（dsh ReasoningRow.tsx:8-17 firstLine/latestLine
//      1:1）。
//  UI 形态项（⑧两级菜单/⑩撤顶栏/⑪四交互/⑫居中模态）为 SwiftUI 呈现缝，
//  本构建 CI 无 test action、UI 剥离测试成本高于收益——以实现处 dsh 引用 +
//  报告取证代替（与 T2.2 既定纪律一致）。
//

import XCTest
@testable import WanWo

final class P2InteractionTests: XCTestCase {

    // MARK: - P2-⑦ breakdown

    private func event(_ payload: SessionEvent.Payload, at ms: Int64) -> SessionEvent {
        SessionEvent(seq: Int(ms), timeMs: ms, payload: payload)
    }

    private func makeCompactor() -> Compactor {
        Compactor(policy: .init()) { throw LLMError(message: "unused", code: "TEST") }
    }

    func testContextBreakdownTriSectionWithHeader() {
        let compactor = makeCompactor()
        let events: [SessionEvent] = [
            event(.userMessage(text: "hello"), at: 100),
            event(.userMessage(text: "world"), at: 200),
        ]
        let header = EpochHeader(
            config: LlmCallConfig(provider: "test", model: "test-model"),
            system: "You are a helpful assistant.",
            tools: [ToolSchemaEntry(name: "bash", description: "run",
                                    parameters: .object([:]))])
        let info = compactor.pressure(events: events, model: "test-model", header: header)
        // message 段 = 表面折叠（启发式构成；本例无 usage 锚点 → usedTokens
        // 退回表面估算，两值相等——有锚点时头行=真实占用、分项=构成近似，
        // dsh projection.ts:50-57 明示不求和相等）。
        XCTAssertEqual(info.breakdown.messageTokens, Compactor.estimateSession(events))
        XCTAssertEqual(info.breakdown.messageTokens, info.usedTokens)
        // system 段 = 文本计价 + 角色开销 4（estimateSystemTokens 等义）。
        XCTAssertEqual(info.breakdown.systemTokens,
                       Compactor.estimateText("You are a helpful assistant.") + 4)
        // tools 段 = schema JSON 计价 + 4（estimateToolsTokens 等义）。
        let json = try! JSONEncoder().encode(header.tools!)
        XCTAssertEqual(info.breakdown.toolsTokens,
                       Compactor.estimateText(String(data: json, encoding: .utf8)!) + 4)
    }

    func testContextBreakdownZeroBeforeAnyRequest() {
        let compactor = makeCompactor()
        let events: [SessionEvent] = [event(.userMessage(text: "hi"), at: 100)]
        let info = compactor.pressure(events: events, model: "test-model", header: nil)
        // 无 request/header（dsh estimateSystemTokens/estimateToolsTokens：absent → 0）。
        XCTAssertEqual(info.breakdown.systemTokens, 0)
        XCTAssertEqual(info.breakdown.toolsTokens, 0)
        XCTAssertEqual(info.breakdown.messageTokens, Compactor.estimateSession(events))
        // 无 usage 锚点 → usedTokens 退回表面估算（dsh projectedTokens ?? pressure
        // 的 WanWo 形态：presented estimate fallback）。
        XCTAssertEqual(info.usedTokens, Compactor.estimateSession(events))
        XCTAssertEqual(info.estimatedTokens, Compactor.estimateSession(events))
    }

    // MARK: - T2.4 P0-2 usage 锚点投影

    private func assistantEvent(_ text: String, usage: TokenUsage, at ms: Int64) -> SessionEvent {
        event(.assistantMessage(turn: 1, step: 1,
                                message: AssistantMessage(id: UUID().uuidString,
                                                          provider: "test", model: "test-model",
                                                          content: [.text(text)]),
                                usage: usage, interrupted: false), at: ms)
    }

    /// 锚点折叠：最后一条带 usage 的事件 last wins；projected = 锚点真实占用 +
    /// 锚点之后的表面增量（dsh usage-projection :169-179 signed movement 语义）。
    func testUsageAnchorProjectedTokens() {
        let compactor = makeCompactor()
        let before = [event(.userMessage(text: "hello world"), at: 100)]
        let anchorEvent = assistantEvent(
            "a", usage: TokenUsage(inputTokens: 7_000, outputTokens: 50,
                                   cacheReadTokens: 800), at: 200)
        let after = [event(.userMessage(text: "and more surface after the sample"), at: 300)]
        let events = before + [anchorEvent] + after
        let info = compactor.pressure(events: events, model: "test-model")
        // pressureFrom = uncached input + cacheRead + cacheWrite(无桶恒 0) = 7800。
        let anchorSurface = Compactor.estimateSession(before + [anchorEvent])
        let surfaceNow = Compactor.estimateSession(events)
        XCTAssertEqual(info.usedTokens,
                       7_800 + (surfaceNow - anchorSurface))
        // 表面继续增长 → 投影随之增长（头行不再小于分项和——用户截图矛盾消除）。
        XCTAssertGreaterThan(info.usedTokens, 7_800)
        // 触发口径独立：表面估算原样保留。
        XCTAssertEqual(info.estimatedTokens, surfaceNow)
        // 锚点 last wins：第二个 usage 覆盖第一个（锚点在流尾 → 表面增量 0，
        // projected = 9000）。
        let second = assistantEvent(
            "b", usage: TokenUsage(inputTokens: 9_000, outputTokens: 10), at: 400)
        let info2 = compactor.pressure(events: events + [second], model: "test-model")
        XCTAssertEqual(info2.usedTokens, 9_000)
    }

    func testContextBreakdownEmptyToolsPricesZero() {
        let compactor = makeCompactor()
        let header = EpochHeader(
            config: LlmCallConfig(provider: "test", model: "test-model"),
            system: "sys", tools: [])
        let info = compactor.pressure(events: [], model: "test-model", header: header)
        // 空工具目录 → tools 段 0（dsh :88 header.tools.length === 0 → 0）。
        XCTAssertEqual(info.breakdown.toolsTokens, 0)
        XCTAssertEqual(info.breakdown.systemTokens,
                       Compactor.estimateText("sys") + 4)
    }

    // MARK: - P2-⑬ 思考摘要函数

    func testReasoningSummaryFirstAndLatestLine() {
        // 完成态 = 首行（ReasoningRow.tsx:8-11 firstLine）。
        XCTAssertEqual(ReasoningRowView.firstLine("one\ntwo\nthree"), "one")
        XCTAssertEqual(ReasoningRowView.firstLine("single"), "single")
        // 流式态 = 尾行（:13-17 latestLine——trimEnd 后最后一个换行之后）。
        XCTAssertEqual(ReasoningRowView.latestLine("one\ntwo\nthree"), "three")
        XCTAssertEqual(ReasoningRowView.latestLine("single"), "single")
        XCTAssertEqual(ReasoningRowView.latestLine("one\ntwo\n"), "two")
    }
}
