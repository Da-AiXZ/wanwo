//
//  ConversationProjectorB2Tests.swift
//  WanWoTests
//
//  【批2 2B】对话区缺件的投影纯函数面断言：
//    · 件3 foldTurnProcess——连续 tool/reasoning 游程折叠（≥2 折叠、单卡平铺、
//      计数与成员、空游程无组、user/assistant 文本断开游程）
//    · 件4 turnUsage——turnStart→assistantMessage(usage)→turnEnd 折叠发射
//      （分项汇总、billed/total 口径、零用量不发射、runMs 计算）
//    · 件5 prettyJSON——可解析 pretty 化、非法 JSON 原样兜底
//

import XCTest
@testable import WanWo

final class ConversationProjectorB2Tests: XCTestCase {

    // MARK: - 事件构造助手

    private func event(_ seq: Int, _ timeMs: Int64,
                       _ payload: SessionEvent.Payload) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: timeMs, payload: payload)
    }

    private func userEvent(_ seq: Int, _ timeMs: Int64 = 0) -> SessionEvent {
        event(seq, timeMs, .userMessage(text: "问"))
    }

    private func assistantEvent(_ seq: Int, _ timeMs: Int64, turn: Int,
                                usage: TokenUsage?) -> SessionEvent {
        let message = AssistantMessage(id: UUID().uuidString,
                                       provider: "test", model: "test-model",
                                       content: [.text("答")])
        return event(seq, timeMs, .assistantMessage(turn: turn, step: 1,
                                                    message: message,
                                                    usage: usage,
                                                    interrupted: false))
    }

    private func toolCall(_ seq: Int, callId: String) -> SessionEvent {
        event(seq, 0, .toolCall(turn: 1, step: 1, callId: callId,
                                name: "bash", arguments: "{\"cmd\":\"ls\"}"))
    }

    private func toolResult(_ seq: Int, callId: String) -> SessionEvent {
        event(seq, 0, .toolResult(turn: 1, step: 1, callId: callId,
                                  content: "ok", isError: false,
                                  errorName: nil, errorCode: nil, meta: nil))
    }

    private func reasoningBubble(_ id: String) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: .reasoning("想"))
    }

    private func toolBubble(_ id: String) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: .tool(
            ConversationProjector.ToolCard(callId: "c-\(id)", name: "bash",
                                           title: "bash", detail: nil)))
    }

    private func userBubble(_ id: String) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: .user("问", []))
    }

    // MARK: - 件3：foldTurnProcess

    func testFoldGroupsConsecutiveToolAndReasoningRuns() {
        let bubbles = [
            userBubble("u1"),
            reasoningBubble("a1"),
            toolBubble("tc1"),
            toolBubble("tc2"),
            toolBubble("tc3"),
            ConversationProjector.Bubble(id: "a2", kind: .assistant("答")),
        ]
        let nodes = ConversationProjector.foldTurnProcess(bubbles)
        // 平铺：u1 + a2；折叠组 ×1。
        XCTAssertEqual(nodes.filter {
            if case .plain = $0 { return true }; return false
        }.count, 2)
        let groups = nodes.compactMap { node -> ConversationProjector.TurnProcessGroup? in
            if case .process(let g) = node { return g }
            return nil
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].toolCallCount, 3)
        XCTAssertEqual(groups[0].messageCount, 1)
        XCTAssertEqual(groups[0].bubbles.count, 4)
        XCTAssertEqual(groups[0].id, "tp-a1")
    }

    func testSingleToolCardStaysPlain() {
        // 游程 =1 不折叠（偏差拍板：单卡平铺，登记报告）。
        let bubbles = [userBubble("u1"), toolBubble("tc1")]
        let nodes = ConversationProjector.foldTurnProcess(bubbles)
        XCTAssertEqual(nodes.count, 2)
        for node in nodes {
            if case .process = node { XCTFail("单卡不应折叠") }
        }
    }

    func testReasoningOnlyRunFoldsToThoughtLabel() {
        // 仅 reasoning 游程（计数段全空 → 视图层回落「思考了一会儿」）。
        let bubbles = [reasoningBubble("r1"), reasoningBubble("r2")]
        let nodes = ConversationProjector.foldTurnProcess(bubbles)
        let groups = nodes.compactMap { node -> ConversationProjector.TurnProcessGroup? in
            if case .process(let g) = node { return g }
            return nil
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].toolCallCount, 0)
        XCTAssertEqual(groups[0].messageCount, 2)
    }

    func testEmptyStreamYieldsNoNodes() {
        XCTAssertTrue(ConversationProjector.foldTurnProcess([]).isEmpty)
    }

    // MARK: - 件4：turnUsage 投影

    func testTurnUsageSummaryEmittedAtTurnEnd() {
        let events = [
            event(0, 1_000, .turnStart(turn: 1)),
            userEvent(1, 1_100),
            assistantEvent(2, 2_000, turn: 1,
                           usage: TokenUsage(inputTokens: 300, outputTokens: 50,
                                             cacheReadTokens: 700,
                                             reasoningTokens: 20)),
            event(3, 2_500, .turnEnd(turn: 1, reason: .completed)),
        ]
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let bubbles = ConversationProjector.project(events: events, registry: nil,
                                                    callArgs: &callArgs)
        let usageBubbles = bubbles.compactMap { bubble -> ConversationProjector.TurnUsageSummary? in
            if case .turnUsage(let s) = bubble.kind { return s }
            return nil
        }
        XCTAssertEqual(usageBubbles.count, 1)
        let s = usageBubbles[0]
        XCTAssertEqual(s.inputTokens, 300)
        XCTAssertEqual(s.outputTokens, 50)
        XCTAssertEqual(s.cacheReadTokens, 700)
        XCTAssertEqual(s.reasoningTokens, 20)
        XCTAssertEqual(s.billedInputTokens, 1_000)          // 300 + 700
        XCTAssertEqual(s.totalTokens, 1_050)                // billed + output
        XCTAssertEqual(s.runMs, 1_500)                      // turnEnd(2500) − turnStart(1000)
        XCTAssertEqual(bubbles.last?.id, "tu-1")
    }

    func testZeroUsageTurnEmitsNoPill() {
        let events = [
            event(0, 0, .turnStart(turn: 1)),
            userEvent(1),
            // 无 assistantMessage usage 的空轮。
            event(2, 100, .turnEnd(turn: 1, reason: .completed)),
        ]
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let bubbles = ConversationProjector.project(events: events, registry: nil,
                                                    callArgs: &callArgs)
        XCTAssertFalse(bubbles.contains { if case .turnUsage = $0.kind { return true }; return false })
    }

    func testMultiStepUsageAccumulates() {
        let events = [
            event(0, 0, .turnStart(turn: 2)),
            userEvent(1),
            assistantEvent(2, 100, turn: 2,
                           usage: TokenUsage(inputTokens: 100, outputTokens: 10)),
            assistantEvent(3, 200, turn: 2,
                           usage: TokenUsage(inputTokens: 200, outputTokens: 30,
                                             cacheReadTokens: 50)),
            event(4, 300, .turnEnd(turn: 2, reason: .completed)),
        ]
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let bubbles = ConversationProjector.project(events: events, registry: nil,
                                                    callArgs: &callArgs)
        let summaries = bubbles.compactMap { bubble -> ConversationProjector.TurnUsageSummary? in
            if case .turnUsage(let s) = bubble.kind { return s }
            return nil
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].inputTokens, 300)
        XCTAssertEqual(summaries[0].outputTokens, 40)
        XCTAssertEqual(summaries[0].cacheReadTokens, 50)
        XCTAssertNil(summaries[0].reasoningTokens)
    }

    // MARK: - 件5：prettyJSON

    func testPrettyJSONFormatsParsableInput() {
        let out = ConversationProjector.prettyJSON(#"{"b":1,"a":"x"}"#)
        XCTAssertTrue(out.contains("\n"))
        XCTAssertTrue(out.contains(#""a" : "x""#) || out.contains(#""a": "x""#))
    }

    func testPrettyJSONFallsBackToRawOnInvalidJSON() {
        let raw = "不是 JSON 的原文"
        XCTAssertEqual(ConversationProjector.prettyJSON(raw), raw)
    }

    // MARK: - ToolCard 件5 字段随行

    func testToolCardCarriesArgsRawAndErrorIdentity() {
        let events = [
            userEvent(1),
            toolCall(2, callId: "c1"),
            toolResult(3, callId: "c1"),
        ]
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let bubbles = ConversationProjector.project(events: events, registry: nil,
                                                    callArgs: &callArgs)
        let card = bubbles.compactMap { bubble -> ConversationProjector.ToolCard? in
            if case .tool(let c) = bubble.kind { return c }
            return nil
        }.first
        XCTAssertEqual(card?.argsRaw, "{\"cmd\":\"ls\"}")
        XCTAssertNil(card?.errorName)
        XCTAssertFalse(card?.isError ?? true)
    }
}
