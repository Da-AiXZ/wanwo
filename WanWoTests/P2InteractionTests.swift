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
        // message 段 = 表面折叠（与 usedTokens 同一折叠——dsh breakdown 语义）。
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
