//
//  TrajectoryLedgerTests.swift
//  WanWoTests
//
//  【批2 2C】轨迹页签台账版纯函数面断言：
//    · buildDirect——turn 分组 / step 二级分组 / 序外事件落 0 桶 /
//      配对时长（tool call→result、stepStart→message）/ 轮次 token 汇总
//    · filter——查询命中重整、空查询直通、无匹配空集
//    · makeRecord——tool/call 参数 pretty 化、tool/result 错误身份
//

import XCTest
@testable import WanWo

final class TrajectoryLedgerTests: XCTestCase {

    // MARK: - 事件构造助手

    private func event(_ seq: Int, _ timeMs: Int64,
                       _ payload: SessionEvent.Payload) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: timeMs, payload: payload)
    }

    private func assistantMessage(_ turn: Int, _ step: Int,
                                  usage: TokenUsage?) -> SessionEvent.Payload {
        let message = AssistantMessage(id: UUID().uuidString,
                                       provider: "test", model: "test-model",
                                       content: [.text("回答正文")])
        return .assistantMessage(turn: turn, step: step, message: message,
                                 usage: usage, interrupted: false)
    }

    // MARK: - buildDirect

    func testGroupsByTurnAndStep() {
        let events = [
            event(0, 0, .turnStart(turn: 1)),
            event(1, 10, .userMessage(text: "问")),
            event(2, 20, .stepStart(turn: 1, step: 1)),
            event(3, 30, .toolCall(turn: 1, step: 1, callId: "c1",
                                   name: "bash", arguments: "{\"cmd\":\"ls\"}")),
            event(4, 130, .toolResult(turn: 1, step: 1, callId: "c1",
                                      content: "ok", isError: false,
                                      errorName: nil, errorCode: nil, meta: nil)),
            event(5, 200, assistantMessage(1, 1, usage: TokenUsage(
                inputTokens: 100, outputTokens: 20, cacheReadTokens: 300))),
            event(6, 500, .turnEnd(turn: 1, reason: .completed)),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        XCTAssertEqual(groups.count, 1)
        let turn1 = groups[0]
        XCTAssertEqual(turn1.id, 1)
        // 无 step 归属：turnStart + userMessage + turnEnd。
        XCTAssertEqual(turn1.records.count, 3)
        XCTAssertEqual(turn1.stepGroups.count, 1)
        XCTAssertEqual(turn1.eventCount, 6)
        XCTAssertEqual(turn1.runMs, 500)
        XCTAssertEqual(turn1.tokenSummary?.billed, 400)   // 100 + 300
        XCTAssertEqual(turn1.tokenSummary?.output, 20)

        let step1 = turn1.stepGroups[0]
        XCTAssertEqual(step1.turn, 1)
        XCTAssertEqual(step1.step, 1)
        XCTAssertEqual(step1.records.count, 3)            // call/result/message
        XCTAssertEqual(step1.usage?.billedInputTokens, 400)
        XCTAssertEqual(step1.usage?.outputTokens, 20)
    }

    func testPairedDurations() {
        let events = [
            event(0, 0, .stepStart(turn: 1, step: 1)),
            event(1, 100, .toolCall(turn: 1, step: 1, callId: "c9",
                                    name: "bash", arguments: "{}")),
            event(2, 350, .toolResult(turn: 1, step: 1, callId: "c9",
                                      content: "done", isError: false,
                                      errorName: nil, errorCode: nil, meta: nil)),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        let records = groups.flatMap { $0.stepGroups.flatMap { $0.records } }
        let result = records.first { $0.wireType == "tool/result" }
        XCTAssertEqual(result?.durationMs, 250)
        // step 组无 stepEnd → durationMs = nil。
        XCTAssertNil(groups[0].stepGroups.first?.durationMs)
    }

    func testOrphanEventsLandInBucketZero() {
        // 无 turnStart 的散事件（旧流/异常流兜底）→ turn 0 桶。
        let events = [
            event(0, 0, .userMessage(text: "散消息")),
            event(1, 10, .system(note: "注记")),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, 0)
        XCTAssertEqual(groups[0].records.count, 2)
    }

    func testZeroTokenTurnSummaryDropped() {
        // 全零 token 汇总 → tokenSummary nil（dsh 无数据组缺席）。
        let events = [
            event(0, 0, .turnStart(turn: 1)),
            event(1, 0, .userMessage(text: "问")),
            event(2, 10, assistantMessage(1, 1, usage: nil)),
            event(3, 20, .turnEnd(turn: 1, reason: .completed)),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        XCTAssertNil(groups[0].tokenSummary)
    }

    // MARK: - filter

    func testFilterByWireTypeSubstring() {
        let events = [
            event(0, 0, .turnStart(turn: 1)),
            event(1, 0, .userMessage(text: "跑一下测试")),
            event(2, 0, .toolCall(turn: 1, step: 1, callId: "c1",
                                  name: "bash", arguments: "{}")),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        let hit = TrajectoryLedger.filter(groups: groups, query: "tool")
        // tool/call 在 step 组里。
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit[0].stepGroups.count, 1)
        XCTAssertEqual(hit[0].stepGroups[0].records.count, 1)
        // 无匹配 → 空集。
        XCTAssertTrue(TrajectoryLedger.filter(groups: groups, query: "不存在的词").isEmpty)
        // 空查询直通。
        XCTAssertEqual(TrajectoryLedger.filter(groups: groups, query: "  ").count, 1)
    }

    func testFilterByContentSubstring() {
        let events = [
            event(0, 0, .userMessage(text: "检查部署状态")),
        ]
        let groups = TrajectoryLedger.buildDirect(events: events)
        let hit = TrajectoryLedger.filter(groups: groups, query: "部署")
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit[0].records.count, 1)
    }

    // MARK: - makeRecord（检查器四面）

    func testToolCallRecordCarriesPrettyParams() {
        let event = event(1, 0, .toolCall(turn: 1, step: 1, callId: "c1",
                                          name: "write",
                                          arguments: #"{"path":"a.swift"}"#))
        let record = TrajectoryLedger.makeRecord(event)
        XCTAssertEqual(record.wireType, "tool/call")
        // pretty 化含换行（prettyPrinted）。
        XCTAssertTrue(record.paramsText?.contains("\n") ?? false)
        XCTAssertNil(record.resultText)
        XCTAssertFalse(record.isError)
    }

    func testToolResultRecordCarriesErrorIdentity() {
        let event = event(2, 0, .toolResult(turn: 1, step: 1, callId: "c1",
                                            content: "", isError: true,
                                            errorName: "ApprovalError",
                                            errorCode: "NOT_APPROVED", meta: nil))
        let record = TrajectoryLedger.makeRecord(event)
        XCTAssertTrue(record.isError)
        XCTAssertTrue(record.summary.contains("ApprovalError/NOT_APPROVED"))
    }

    func testAssistantMessageRecordCarriesBodyAndUsage() {
        let event = event(3, 0, assistantMessage(1, 1, usage: TokenUsage(
            inputTokens: 10, outputTokens: 5)))
        let record = TrajectoryLedger.makeRecord(event)
        XCTAssertEqual(record.wireType, "assistant/message")
        XCTAssertEqual(record.resultText, "回答正文")
        XCTAssertTrue(record.summary.contains("in 10 out 5"))
    }
}
