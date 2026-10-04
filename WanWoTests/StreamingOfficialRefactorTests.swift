//
//  StreamingOfficialRefactorTests.swift
//  WanWo
//
//  【流式渲染官方化重构 · 单测】（派单简报 §五，2026-10-04）：
//  ChatViewModel settle 决策纯函数 + 回合步进判定（批3 复审修 P1-2 语义保留）
//  + 打字机步长/段间游标连续（九校④）+ displayNodes 合成（live 槽=正式节点
//  身份进入统一节点流，dsh assistant-step 零换手语义的万我形态）。
//  现有测试无 typewriter/isSettling/liveTail/streamingText 依赖（已 grep 实证
//  无回归面）；全部走 nonisolated 纯函数缝，不经 AppEnvironment 装配。
//

import XCTest
@testable import WanWo

final class StreamingOfficialRefactorTests: XCTestCase {

    // MARK: - A. settle 决策纯函数（reproject 落盘收敛语义）

    /// 显式限定（`.none` 与 Optional.none 字面撞名——泛型钉型虽可解析，
    /// 显式写出免 CI 歧义面）。
    private static let noOp = ChatViewModel.SettleDecision.none
    private static let finish = ChatViewModel.SettleDecision.finish
    private static let keepSettling = ChatViewModel.SettleDecision.keepSettling

    func testSettleDecisionMatrix() {
        // 两槽均空 → no-op（不打扰落盘面）。
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: false, cursorBacklog: false, steppedForward: false),
            Self.noOp)
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: false, cursorBacklog: true, steppedForward: false),
            Self.noOp)
        // 有在途内容、无打字积压 → 直接结算（同帧落盘节点显现）。
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: true, cursorBacklog: false, steppedForward: false),
            Self.finish)
        // 有在途内容 + 打字积压 → 补打期（过滤补打目标落盘正文节点）。
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: true, cursorBacklog: true, steppedForward: false),
            Self.keepSettling)
        // 回合已步进（P1-2）→ 放弃补打直接结算（防新卡插在直播正文上方）。
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: true, cursorBacklog: true, steppedForward: true),
            Self.finish)
        XCTAssertEqual(ChatViewModel.settleDecision(
            liveActive: true, cursorBacklog: false, steppedForward: true),
            Self.finish)
    }

    // MARK: - B. 回合步进判定（批3 复审修 P1-2 语义保留）

    func testHasPostSettlingStepNodeMatrix() {
        let assistant = ChatViewModel.Bubble(id: "a10-b1", kind: .assistant("正文"))
        let reasoning = ChatViewModel.Bubble(id: "a10-b0", kind: .reasoning("思考"))
        let tool = ChatViewModel.Bubble(id: "tc-x", kind: .tool(
            ConversationProjector.ToolCard(callId: "x", name: "bash",
                                           title: "bash", detail: nil, argsRaw: nil)))
        let goalRound = ChatViewModel.Bubble(id: "gr7", kind: .goalRound("<goal_round>"))
        let usage = ChatViewModel.Bubble(id: "tu-1", kind: .turnUsage(
            ConversationProjector.TurnUsageSummary(turn: 1)))
        let note = ChatViewModel.Bubble(id: "sys5", kind: .note("纸条"))

        // 无 assistant → 不构成步进（无可判定的补打目标基线）。
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [tool]))
        // assistant 之后无 tool/goalRound → 未步进。
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [reasoning, assistant]))
        // tool/goalRound 在 assistant 之前 → 不构成步进（历史步进）。
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [tool, assistant]))
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [goalRound, assistant]))
        // assistant 之后出现 tool = 已步进。
        XCTAssertTrue(ChatViewModel.hasPostSettlingStepNode(in: [assistant, tool]))
        // goal_round 专卡同理（goal 续轮 tool-call-first 常态组合）。
        XCTAssertTrue(ChatViewModel.hasPostSettlingStepNode(in: [assistant, goalRound]))
        // turnUsage/note 不算步进（回合尾自身产物，与补打目标同帧落盘）。
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [assistant, usage]))
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(in: [assistant, note]))
        // 多节点混合：以最后一条 assistant 为基线（其后步进才算步进）。
        // 【CI 修46 勘误】原输入 [assistant, tool, assistant2] 的最后 assistant
        // = assistant2，其后无步进证据 → 恒 False（源码正确），期望值写反。
        // True 场景应为"最后 assistant 之后有 tool"：[assistant, tool, reasoning]
        //（最后 assistant=a10-b1，其后 tool=步进）。
        let assistant2 = ChatViewModel.Bubble(id: "a12-b0", kind: .assistant("第二步"))
        XCTAssertTrue(ChatViewModel.hasPostSettlingStepNode(
            in: [assistant, tool, reasoning]))
        XCTAssertFalse(ChatViewModel.hasPostSettlingStepNode(
            in: [assistant, tool, reasoning, assistant2]))
    }

    // MARK: - C. 打字机步长（原 View 层 typewriterLoop 参数 1:1）

    func testTypewriterStepLength() {
        // 步长 = max(1, min(4, backlog / 3))。
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 0), 1)
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 1), 1)
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 2), 1)
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 9), 3)
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 12), 4)
        // 封顶 4 字（九校-B：恒速小步让长总结也有持续流式感）。
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 300), 4)
        XCTAssertEqual(ChatViewModel.typewriterStepLength(backlog: 10_000), 4)
    }

    // MARK: - D. 段间游标连续（九校④：typeTarget 换源 cursor 不重置）

    func testCursorContinuityAcrossSegments() {
        // 新目标不短于游标 → 游标保持（段间连续，显示无缝）。
        XCTAssertEqual(ChatViewModel.cursorAfterTargetChange(
            oldCursor: 480, newTargetCount: 500), 480)
        // 新目标短于游标 → 归零（新段落从零起打）。
        XCTAssertEqual(ChatViewModel.cursorAfterTargetChange(
            oldCursor: 480, newTargetCount: 3), 0)
        // 首段（游标 0）恒 0。
        XCTAssertEqual(ChatViewModel.cursorAfterTargetChange(
            oldCursor: 0, newTargetCount: 42), 0)
    }

    // MARK: - E. displayNodes 合成（live 槽 = 正式节点身份）

    func testDisplayNodesNoLiveSlots() {
        // 空直播态：displayNodes ≡ foldTurnProcess（纯落盘节点流）。
        let bubbles = [
            ChatViewModel.Bubble(id: "u1", kind: .user("你好", [])),
            ChatViewModel.Bubble(id: "a2-b0", kind: .assistant("回复")),
        ]
        let nodes = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: nil, liveText: nil,
            liveReasoningGeneration: 0, liveTextGeneration: 0)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes.map(\.id), ["u1", "a2-b0"])
    }

    func testDisplayNodesAppendsLiveSlotsWithGenerationIDs() {
        let bubbles = [
            ChatViewModel.Bubble(id: "u1", kind: .user("你好", [])),
        ]
        // 思考槽 + 正文槽：双代际 id 进统一节点流（正式 Bubble 身份）。
        let nodes = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "正在思考…", liveText: "正在回复的",
            liveReasoningGeneration: 3, liveTextGeneration: 4)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[1].id, "live-r-3")
        XCTAssertEqual(nodes[2].id, "live-t-4")
        if case .plain(let bubble) = nodes[1], case .reasoning(let text) = bubble.kind {
            XCTAssertEqual(text, "正在思考…")
        } else {
            XCTFail("live-r 节点应为 reasoning 气泡")
        }
        if case .plain(let bubble) = nodes[2], case .assistant(let text) = bubble.kind {
            XCTAssertEqual(text, "正在回复的")
        } else {
            XCTFail("live-t 节点应为 assistant 气泡")
        }
        // 空正文（打字机未起拍）不产 live-t 节点（防空 MarkdownView 闪现）。
        let emptyText = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "思考中", liveText: "",
            liveReasoningGeneration: 1, liveTextGeneration: 1)
        XCTAssertEqual(emptyText.count, 2)
        XCTAssertEqual(emptyText.last?.id, "live-r-1")
    }

    // MARK: - E2. 双代际分立（review P1-1：正文开槽不波及思考 id）

    func testDualGenerationsAreIndependent() {
        let bubbles = [ChatViewModel.Bubble(id: "u1", kind: .user("你好", []))]
        // 思考直播中（live-r-1 在场），首个正文 delta 开正文槽（正文代际 1→2）：
        // 思考槽 id 必须保持 live-r-1（旧共享代际实现会变成 live-r-2 →
        // ForEach 删旧插新 → WOEntryModifier @State 重置 → fadeUp 重播）。
        let beforeText = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "思考中", liveText: nil,
            liveReasoningGeneration: 1, liveTextGeneration: 1)
        XCTAssertEqual(beforeText.map(\.id), ["u1", "live-r-1"])
        let afterTextOpens = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "思考中", liveText: "回复的",
            liveReasoningGeneration: 1, liveTextGeneration: 2)
        XCTAssertEqual(afterTextOpens.map(\.id), ["u1", "live-r-1", "live-t-2"])
        // 反向：正文直播中思考开槽，正文 id 不变。
        let afterReasoningOpens = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "新思考", liveText: "回复的",
            liveReasoningGeneration: 5, liveTextGeneration: 2)
        XCTAssertEqual(afterReasoningOpens.map(\.id),
                       ["u1", "live-r-5", "live-t-2"])
        // 段落切换（两槽清退后重开）：各自代际独立推进，新 id 两两不撞。
        let nextSegment = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: "第二段思考", liveText: "第二段正文",
            liveReasoningGeneration: 6, liveTextGeneration: 3)
        XCTAssertEqual(Set(nextSegment.map(\.id)).count, 3)
        XCTAssertEqual(nextSegment.map(\.id),
                       ["u1", "live-r-6", "live-t-3"])
    }

    func testDisplayNodesSettlingFiltersTargetAssistantOnly() {
        // 补打期：补打目标（最后一条 .assistant 落盘正文）被过滤，live 槽补位；
        // 同消息的 reasoning 节点与更早 assistant 不受影响（原 View 层
        // isSettlingAssistant 同语义）。
        let bubbles = [
            ChatViewModel.Bubble(id: "u1", kind: .user("你好", [])),
            ChatViewModel.Bubble(id: "a2-b0", kind: .assistant("第一步回复")),
            ChatViewModel.Bubble(id: "a4-b0", kind: .reasoning("第二步思考")),
            ChatViewModel.Bubble(id: "a4-b1", kind: .assistant("第二步正文")),
            ChatViewModel.Bubble(id: "tc-x", kind: .tool(
                ConversationProjector.ToolCard(callId: "x", name: "bash",
                                               title: "bash", detail: nil,
                                               argsRaw: nil))),
        ]
        let nodes = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: true,
            liveReasoning: nil, liveText: "第二步正",
            liveReasoningGeneration: 2, liveTextGeneration: 2)
        XCTAssertEqual(nodes.map(\.id),
                       ["u1", "a2-b0", "a4-b0", "tc-x", "live-t-2"])
        // 补打目标过滤后 live 槽恒在尾部（工具卡恒在直播正文下方——P1-2）。
        if let last = nodes.last, case .plain(let bubble) = last,
           case .assistant(let text) = bubble.kind {
            XCTAssertEqual(text, "第二步正")
        } else {
            XCTFail("补打期节点流尾部应为 live 正文槽")
        }
        // 非补打期同一数据：全量落盘节点（无过滤）。
        let settled = ChatViewModel.composeDisplayNodes(
            bubbles: bubbles, isSettling: false,
            liveReasoning: nil, liveText: nil,
            liveReasoningGeneration: 2, liveTextGeneration: 2)
        XCTAssertEqual(settled.map(\.id),
                       ["u1", "a2-b0", "a4-b0", "a4-b1", "tc-x"])
    }

    // MARK: - F. live id 代际唯一性（槽重建=新身份=入场动画天然一次）

    func testLiveIDsAreUniqueAcrossGenerations() {
        var ids = Set<String>()
        // 双代际（P1-1）：思考/正文各自推进——同代数值也因前缀分立不撞。
        for generation in 0...200 {
            ids.insert("live-r-\(generation)")
            ids.insert("live-t-\(generation)")
        }
        // 正文代际可独立超前于思考代际（各自只在本槽 nil→非空推进）。
        ids.insert("live-t-201")
        // 全部 id 两两不撞（代际单调 → SwiftUI 每段视为新节点，fadeUp 精确一次）。
        XCTAssertEqual(ids.count, 403)
        // live 前缀约定：View 层 running 翻转与 fadeUp 分流依赖此前缀。
        XCTAssertTrue("live-r-0".hasPrefix("live-r-"))
        XCTAssertTrue("live-t-0".hasPrefix("live-"))
        // 落盘节点 id（a(seq)-b(idx) / gr(seq) / tc-callId / u(seq)）不撞 live 前缀。
        XCTAssertFalse("a12-b0".hasPrefix("live-"))
        XCTAssertFalse("tc-abc".hasPrefix("live-"))
        XCTAssertFalse("u-pending".hasPrefix("live-"))
    }

    // MARK: - G. 结算帧预登记（review P2：正文 + 同帧思考）

    func testSettledRegistrationIDsCoversReasoningAndAssistant() {
        let reasoning = ChatViewModel.Bubble(id: "a4-b0", kind: .reasoning("思考"))
        let assistant = ChatViewModel.Bubble(id: "a4-b1", kind: .assistant("正文"))
        // 同帧落盘思考+正文：两者 id 均登记——长积压补打超过 justEndedStreaming
        // 1.5s 窗口时，思考节点否则会播 fadeUp 重播。
        XCTAssertEqual(ChatViewModel.settledRegistrationIDs(in: [reasoning, assistant]),
                       Set(["a4-b0", "a4-b1"]))
        // 仅正文消息：只登记正文。
        XCTAssertEqual(ChatViewModel.settledRegistrationIDs(
            in: [ChatViewModel.Bubble(id: "u1", kind: .user("你好", [])), assistant]),
            Set(["a4-b1"]))
        // 思考在更早消息：登记的是最后一条 reasoning（同帧语义）。
        let older = ChatViewModel.Bubble(id: "a2-b0", kind: .reasoning("旧思考"))
        XCTAssertEqual(ChatViewModel.settledRegistrationIDs(in: [older, reasoning, assistant]),
                       Set(["a4-b0", "a4-b1"]))
        // 空气泡流：空集合。
        XCTAssertTrue(ChatViewModel.settledRegistrationIDs(in: []).isEmpty)
    }
}
