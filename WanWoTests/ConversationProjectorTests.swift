//
//  ConversationProjectorTests.swift
//  WanWoTests
//
//  【M3 E2】live/replay 统一投影的纯函数断言：
//    · 工具卡按事件时间序落 tool/call 位置（先文本后卡片，dsh assembler
//      startSeq 排序语义的 WanWo 形态）
//    · 思考/回复按块分立（逐消息独立气泡）
//    · 气泡 id 稳定（前缀事件追加不改既有 id）
//    · 瞬态字段（liveOutput/statusNote）按 callId 续接
//    · NOT_APPROVED 结算琥珀行
//    · 注入/标记消息过滤
//

import XCTest
@testable import WanWo

final class ConversationProjectorTests: XCTestCase {

    // MARK: - 事件构造助手

    private func userEvent(_ seq: Int, _ text: String) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: .userMessage(text: text))
    }

    private func assistantEvent(_ seq: Int,
                                _ blocks: [ContentBlock]) -> SessionEvent {
        let message = AssistantMessage(id: UUID().uuidString,
                                       provider: "test", model: "test-model",
                                       content: blocks)
        return SessionEvent(seq: seq, timeMs: 0,
                            payload: .assistantMessage(turn: 1, step: 1,
                                                       message: message,
                                                       usage: nil,
                                                       interrupted: false))
    }

    private func toolCallEvent(_ seq: Int, callId: String, name: String,
                               arguments: String = "{}") -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0,
                     payload: .toolCall(turn: 1, step: 1, callId: callId,
                                        name: name, arguments: arguments))
    }

    private func toolResultEvent(_ seq: Int, callId: String, content: String,
                                 isError: Bool = false,
                                 errorCode: String? = nil) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0,
                     payload: .toolResult(turn: 1, step: 1, callId: callId,
                                          content: content, isError: isError,
                                          errorName: isError ? "E" : nil,
                                          errorCode: errorCode, meta: nil))
    }

    private func project(_ events: [SessionEvent],
                         previousCards: [ConversationProjector.ToolCard] = [])
        -> ([ConversationProjector.Bubble],
            [String: (name: String, args: JSONValue)]) {
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let carried = Dictionary(uniqueKeysWithValues:
            previousCards.map { ($0.callId, $0) })
        let bubbles = ConversationProjector.project(
            events: events, registry: nil,
            callArgs: &callArgs, previousCards: carried)
        return (bubbles, callArgs)
    }

    private func toolCard(_ bubble: ConversationProjector.Bubble)
        -> ConversationProjector.ToolCard? {
        if case .tool(let card) = bubble.kind { return card }
        return nil
    }

    // MARK: 工具卡按事件时间序落 tool/call 位置

    func testToolCardLandsAtEventTimeOrderAfterPrecedingText() {
        let events = [
            userEvent(1, "帮我跑一下"),
            assistantEvent(2, [.reasoning("想想"), .text("好的，执行")]),
            toolCallEvent(3, callId: "c1", name: "bash"),
            toolResultEvent(4, callId: "c1", content: "done"),
        ]
        let (bubbles, _) = project(events)
        // 事件序：user → reasoning → text → toolCard（结算态）。
        XCTAssertEqual(bubbles.count, 4)
        guard bubbles.count == 4 else { return }  // 下标防御：数量不符即止（越界会崩掉 runner）
        guard case .user(let userText, let images) = bubbles[0].kind else {
            return XCTFail("bubble[0] 应为 user：\(bubbles[0].kind)")
        }
        // T2.8 起 user 气泡携带附件位（ConversationProjector.swift:47）——
        // 无附件 user 事件 → 空表。
        XCTAssertEqual(userText, "帮我跑一下")
        XCTAssertTrue(images.isEmpty)
        guard case .reasoning(let reasoning) = bubbles[1].kind else {
            return XCTFail("bubble[1] 应为 reasoning：\(bubbles[1].kind)")
        }
        XCTAssertEqual(reasoning, "想想")
        guard case .assistant(let text) = bubbles[2].kind else {
            return XCTFail("bubble[2] 应为 assistant text：\(bubbles[2].kind)")
        }
        XCTAssertEqual(text, "好的，执行")
        let card = toolCard(bubbles[3])
        XCTAssertEqual(card?.callId, "c1")
        XCTAssertEqual(card?.isRunning, false)
        XCTAssertEqual(card?.resultText, "done")
        XCTAssertEqual(card?.statusNote, nil)
    }

    // MARK: 思考/回复按块分立（跨步各自独立气泡）

    func testBlocksSeparatedPerMessageAroundToolCall() {
        let events = [
            userEvent(1, "go"),
            assistantEvent(2, [.text("第一步文本")]),
            toolCallEvent(3, callId: "c1", name: "read"),
            toolResultEvent(4, callId: "c1", content: "file-body"),
            assistantEvent(5, [.reasoning("第二步思考"), .text("第二步文本")]),
        ]
        let (bubbles, _) = project(events)
        // 事件序：user, text(第一步), card, reasoning(第二步), text(第二步)。
        XCTAssertEqual(bubbles.count, 5)
        guard bubbles.count == 5 else { return }  // 下标防御
        guard case .assistant(let first) = bubbles[1].kind else {
            return XCTFail("bubble[1] 应为第一步文本")
        }
        XCTAssertEqual(first, "第一步文本")
        XCTAssertEqual(toolCard(bubbles[2])?.callId, "c1")
        guard case .reasoning(let reasoning) = bubbles[3].kind else {
            return XCTFail("bubble[3] 应为第二步思考（分立气泡）")
        }
        XCTAssertEqual(reasoning, "第二步思考")
        guard case .assistant(let second) = bubbles[4].kind else {
            return XCTFail("bubble[4] 应为第二步文本")
        }
        XCTAssertEqual(second, "第二步文本")
        // 两步文本各自成泡，不粘连。
        XCTAssertNotEqual(first, second)
    }

    // MARK: 气泡 id 稳定（前缀追加不改既有 id）

    func testBubbleIDsStableAcrossEventAppends() {
        let prefix = [
            userEvent(1, "go"),
            assistantEvent(2, [.text("A")]),
            toolCallEvent(3, callId: "c1", name: "bash"),
        ]
        let full = prefix + [
            toolResultEvent(4, callId: "c1", content: "ok"),
            assistantEvent(5, [.text("B")]),
        ]
        let (prefixBubbles, _) = project(prefix)
        let (fullBubbles, _) = project(full)
        XCTAssertEqual(prefixBubbles.count, 3)
        XCTAssertEqual(fullBubbles.count, 4)
        // 前缀投影的 id 序列 == 全量投影的前缀 id 序列（身份稳定→差分不抖）。
        for (index, bubble) in prefixBubbles.enumerated() {
            XCTAssertEqual(bubble.id, fullBubbles[index].id,
                           "id 在事件追加后漂移：\(bubble.id)")
        }
        // 卡 id 锚定 callId（live/replay 同 id）。
        XCTAssertTrue(prefixBubbles[2].id.hasPrefix("tc-c1"))
    }

    // MARK: 瞬态字段续接（dsh current map 语义）

    func testTransientCarryOverForRunningCard() {
        let previous = ConversationProjector.ToolCard(
            callId: "c1", name: "bash", title: "bash", detail: nil,
            liveOutput: "line1\nline2", statusNote: "等待审批")
        let events = [
            toolCallEvent(1, callId: "c1", name: "bash"),
        ]
        let (bubbles, _) = project(events, previousCards: [previous])
        XCTAssertEqual(bubbles.count, 1)
        guard bubbles.count == 1 else { return }  // 下标防御
        let card = toolCard(bubbles[0])
        XCTAssertEqual(card?.liveOutput, "line1\nline2", "liveOutput 应续接")
        XCTAssertEqual(card?.statusNote, "等待审批", "statusNote 应续接")
        XCTAssertEqual(card?.isRunning, true)
    }

    func testTransientNoteClearedOnSuccessfulSettle() {
        let previous = ConversationProjector.ToolCard(
            callId: "c1", name: "bash", title: "bash", detail: nil,
            liveOutput: "out", statusNote: "等待审批")
        let events = [
            toolCallEvent(1, callId: "c1", name: "bash"),
            toolResultEvent(2, callId: "c1", content: "done"),
        ]
        let (bubbles, _) = project(events, previousCards: [previous])
        // E2 语义：tool/result 结算到卡片本体，不另产泡——toolCall+toolResult
        // 与 toolCall-only 同为 1 泡（对照 testTransientCarryOverForRunningCard）。
        XCTAssertEqual(bubbles.count, 1)
        guard bubbles.count == 1, let card = toolCard(bubbles[0]) else {
            return XCTFail("预期 count=1 且 [0]=卡片，实际 count=\(bubbles.count)")
        }
        XCTAssertEqual(card.isRunning, false)
        XCTAssertEqual(card.statusNote, nil, "成功结算应清空瞬态等待行")
        XCTAssertEqual(card.liveOutput, "out", "liveOutput 仍续接")
    }

    // MARK: NOT_APPROVED 结算琥珀行

    func testNotApprovedResultCarriesAmberNote() {
        let events = [
            toolCallEvent(1, callId: "c1", name: "bash"),
            toolResultEvent(2, callId: "c1",
                            content: "Error: 未获批准，工具未执行。",
                            isError: true, errorCode: "NOT_APPROVED"),
        ]
        let (bubbles, _) = project(events)
        // E2 语义：结算琥珀行走卡片本体（同上：1 泡，卡在 [0]）。
        XCTAssertEqual(bubbles.count, 1)
        guard bubbles.count == 1, let card = toolCard(bubbles[0]) else {
            return XCTFail("预期 count=1 且 [0]=卡片，实际 count=\(bubbles.count)")
        }
        XCTAssertEqual(card.statusNote, "未获批准")
        XCTAssertEqual(card.isError, true)
    }

    // MARK: 注入/标记消息过滤

    func testMarkerMessagesNotRendered() {
        let events = [
            userEvent(1, "<runtime-context>{\"workspace\":\"/w\"}"),
            userEvent(2, "真实消息"),
            userEvent(3, "<compaction-summary>摘要"),
        ]
        let (bubbles, _) = project(events)
        XCTAssertEqual(bubbles.count, 1)
        guard case .user(let text, let images) = bubbles[0].kind else {
            return XCTFail("唯一气泡应为真实用户消息")
        }
        XCTAssertEqual(text, "真实消息")
        XCTAssertTrue(images.isEmpty)
    }

    // MARK: callArgs 缓存随投影累积（presentResult 复现数据源）

    func testCallArgsCachePopulatedByProjection() {
        let events = [
            toolCallEvent(1, callId: "c1", name: "bash",
                          arguments: "{\"command\":\"ls\"}"),
        ]
        let (_, callArgs) = project(events)
        XCTAssertEqual(callArgs["c1"]?.name, "bash")
        XCTAssertEqual(callArgs["c1"]?.args,
                       .object(["command": .string("ls")]))
    }
}
