//
//  CondensationTests.swift
//  WanWoTests
//
//  【M8 批2 · B1 件9】压缩地基单测（纯同步断言为主——工作集投影是纯函数重点测；
//  引擎面用确定性 stub 顺序 await，禁并发竞态构造）。断言点对拍：
//    - tombstone 应用/撤销语义（OpenHands sdk view/view.py:111-160：
//      过滤 forgottenSeqs + summaryOffset 插入派生摘要条目；丢弃 tombstone
//      即恢复全量；派生条目不落盘）
//    - 原子边界（tool-call↔tool-result 对不拆 + 受保护前缀永不忘）
//    - 触发三源分级（sdk llm_summarizing_condenser.py:136-203）
//    - 序列化（seq 标注 + 字符上限）与掩码（窗口外旧工具结果占位）
//    - 熔断（连续 3 次失败停自动压缩，成功复位）+ hard reset ×0.8 递减
//

import XCTest
@testable import WanWo

final class CondensationTests: XCTestCase {

    // MARK: - 工具

    private let nowMs: Int64 = 1_700_000_000_000

    private func event(_ seq: Int, _ payload: SessionEvent.Payload) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: nowMs, payload: payload)
    }

    private func user(_ seq: Int, _ text: String) -> SessionEvent {
        event(seq, .userMessage(text: text))
    }

    private func assistant(_ seq: Int, callId: String? = nil,
                           arguments: String = "{}") -> SessionEvent {
        var content: [ContentBlock] = [.text("a\(seq)")]
        if let callId {
            content.append(.toolCall(id: callId, name: "read_file", arguments: arguments))
        }
        let message = AssistantMessage(id: "m\(seq)", provider: "test",
                                       model: "test", content: content)
        return event(seq, .assistantMessage(turn: 1, step: 1, message: message,
                                            usage: nil, interrupted: false))
    }

    private func result(_ seq: Int, _ callId: String, content: String = "r",
                        isError: Bool = false) -> SessionEvent {
        event(seq, .toolResult(turn: 1, step: 1, callId: callId, content: content,
                               isError: isError, errorName: nil, errorCode: nil,
                               meta: nil))
    }

    private func tombstoneEvent(_ seq: Int, _ record: CondensationRecord) -> SessionEvent {
        event(seq, .extensionEvent(kind: CondensationEvents.condensationKind,
                                   payload: record.payload))
    }

    private func requestEvent(_ seq: Int,
                              _ reason: CondensationRequestMeta.Reason = .manual) -> SessionEvent {
        event(seq, .extensionEvent(kind: CondensationEvents.requestKind,
                                   payload: CondensationRequestMeta(
                                       reason: reason, requestedAtMs: nowMs).payload))
    }

    private func makeRecord(forgotten: [Int], summary: String?, offset: Int?) -> CondensationRecord {
        CondensationRecord(id: "cond-test-\(forgotten.first ?? 0)", forgottenSeqs: forgotten,
                           summary: summary, summaryOffset: offset, llmResponseID: nil,
                           tokensBefore: nil, tokensAfter: nil, createdAtMs: nowMs)
    }

    /// append 收集器（引擎/门面测试用；NSLock 纪律同 App 侧）。
    private final class PayloadCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(payload: SessionEvent.Payload, ignorable: Bool)] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        func append(_ payload: SessionEvent.Payload, _ ignorable: Bool) {
            lock.lock(); items.append((payload, ignorable)); lock.unlock()
        }
        func snapshot() -> [(payload: SessionEvent.Payload, ignorable: Bool)] {
            lock.lock(); defer { lock.unlock() }; return items
        }
        func makeAppend() -> (SessionEvent.Payload, Bool) async throws -> Void {
            { [collector = self] payload, ignorable in
                collector.append(payload, ignorable)
            }
        }
    }

    /// 脚本化摘要器（按序取值；nil = 失败；记录输入规模与 previousSummary）。
    private final class ScriptedSummarizer: ContextSummarizer {
        private let lock = NSLock()
        private var script: [String?]
        private(set) var inputSizes: [Int] = []
        private(set) var previousSummaries: [String?] = []

        init(_ script: [String?]) { self.script = script }

        func summarize(serializedEvents: [String], previousSummary: String?) async -> String? {
            lock.lock(); defer { lock.unlock() }
            previousSummaries.append(previousSummary)
            inputSizes.append(serializedEvents.joined().utf8.count)
            guard !script.isEmpty else { return nil }
            return script.removeFirst()
        }
    }

    // MARK: - 件1a：载荷编解码往返

    func testCondensationRecordPayloadRoundtrip() {
        let full = CondensationRecord(id: "cond-1", forgottenSeqs: [3, 4, 7],
                                      summary: "摘要正文", summaryOffset: 3,
                                      llmResponseID: "resp-9", tokensBefore: 1200,
                                      tokensAfter: 500, createdAtMs: nowMs)
        let decoded = CondensationRecord.decode(full.payload)
        XCTAssertEqual(decoded, full)

        // 可选字段缺席
        let minimal = CondensationRecord(id: "cond-2", forgottenSeqs: [1],
                                         summary: nil, summaryOffset: nil,
                                         llmResponseID: nil, tokensBefore: nil,
                                         tokensAfter: nil, createdAtMs: nowMs)
        XCTAssertEqual(CondensationRecord.decode(minimal.payload), minimal)

        // 坏载荷 fail closed
        XCTAssertNil(CondensationRecord.decode(.string("junk")))
        XCTAssertNil(CondensationRecord.decode(.object(["forgottenSeqs": .array([.int(1)])])))
        XCTAssertNil(CondensationRecord.decode(.object(
            ["id": .string("x"), "forgottenSeqs": .array([.string("bad")])])))
    }

    func testCondensationRequestPayloadRoundtrip() {
        let meta = CondensationRequestMeta(reason: .overflow, requestedAtMs: nowMs)
        XCTAssertEqual(CondensationRequestMeta.decode(meta.payload), meta)
        let manual = CondensationRequestMeta(reason: .manual, requestedAtMs: nowMs)
        XCTAssertEqual(CondensationRequestMeta.decode(manual.payload), manual)
        // 非法 reason（schema 值域同款）
        XCTAssertNil(CondensationRequestMeta.decode(.object(
            ["reason": .string("weird"), "requestedAtMs": .int(1)])))
    }

    // MARK: - 件1b：注册（GoalEvents 同款幂等）

    func testEventRegistrationIdempotent() {
        CondensationEvents.register()
        CondensationEvents.register()
        XCTAssertTrue(ExtensionEventRegistry.shared.isRegistered(
            CondensationEvents.condensationKind))
        XCTAssertTrue(ExtensionEventRegistry.shared.isRegistered(
            CondensationEvents.requestKind))
        // 投影规则：logOnly（模型可见面由派生摘要条目承载）
        XCTAssertEqual(ExtensionEventRegistry.shared.projectionRule(
            for: CondensationEvents.condensationKind), .logOnly)
    }

    // MARK: - 件1c：工作集投影（应用/撤销 + 派生条目不落盘）

    func testProjectionAppliesTombstone() {
        let events = [
            user(0, "u0"),
            assistant(1, callId: "c1"),
            result(2, "c1"),
            user(3, "u3"),
        ]
        let record = makeRecord(forgotten: [1, 2], summary: "此前摘要", offset: 1)
        let withTomb = events + [tombstoneEvent(4, record)]

        let workingSet = CondensationWorkingSet.projected(withTomb)
        // 遗忘 seq 被过滤
        XCTAssertFalse(workingSet.contains { $0.seq == 1 })
        XCTAssertFalse(workingSet.contains { $0.seq == 2 })
        // 未遗忘事件保留
        XCTAssertTrue(workingSet.contains { $0.seq == 0 })
        XCTAssertTrue(workingSet.contains { $0.seq == 3 })
        // 派生摘要条目在 summaryOffset 位置（合成负 seq + compaction/summary 载荷）
        guard let synthetic = workingSet.first(where: { $0.seq < 0 }) else {
            return XCTFail("expected synthetic summary entry")
        }
        guard case .compactionSummary(let compactionId, let summary, let start, _, let seqs, _)
            = synthetic.payload else {
            return XCTFail("expected synthetic compactionSummary payload")
        }
        XCTAssertEqual(compactionId, record.id)
        XCTAssertEqual(summary, "此前摘要")
        XCTAssertEqual(start, 1)
        XCTAssertTrue(seqs.isEmpty, "派生条目不得再声明影子 seq")
        // 插入位置：在首个幸存的后缀事件（seq 3）之前
        let syntheticIndex = workingSet.firstIndex { $0.seq < 0 } ?? -1
        let survivorIndex = workingSet.firstIndex { $0.seq == 3 } ?? -1
        XCTAssertTrue(syntheticIndex < survivorIndex)
        // 输入未变（纯函数）
        XCTAssertEqual(events.count, 4)
    }

    func testProjectionWithoutTombstoneIsIdentity() {
        // 撤销语义：丢弃 tombstone 即恢复全量（无 tombstone 投影恒等）
        let events = [user(0, "u0"), assistant(1), result(2, "c"), user(3, "u3")]
        XCTAssertEqual(CondensationWorkingSet.projected(events), events)
    }

    func testProjectionMultipleTombstonesInOrder() {
        let events = (0..<6).map { user($0, "u\($0)") }
        let first = makeRecord(forgotten: [0, 1], summary: "第一批", offset: 0)
        let second = makeRecord(forgotten: [3, 4], summary: "第二批", offset: 3)
        let withTombs = events + [tombstoneEvent(6, first), tombstoneEvent(7, second)]
        let workingSet = CondensationWorkingSet.projected(withTombs)
        let survivors = workingSet.filter { $0.seq >= 0 }.map { $0.seq }
        XCTAssertEqual(survivors, [2, 5])
        let summaries = workingSet.filter { $0.seq < 0 }
        XCTAssertEqual(summaries.count, 2)
        // 第一批条目在第二批之前
        guard case .compactionSummary(_, let s1, _, _, _, _) = summaries[0].payload,
              case .compactionSummary(_, let s2, _, _, _, _) = summaries[1].payload else {
            return XCTFail("expected two synthetic summaries")
        }
        XCTAssertEqual(s1, "第一批")
        XCTAssertEqual(s2, "第二批")
    }

    func testUnhandledRequestClearsOnTombstone() {
        let events = [user(0, "u0"), requestEvent(1)]
        XCTAssertNotNil(CondensationWorkingSet.unhandledRequest(in: events))
        // tombstone 晚于 request → 清位
        let withTomb = events + [tombstoneEvent(2, makeRecord(forgotten: [0],
                                                              summary: "s", offset: 0))]
        XCTAssertNil(CondensationWorkingSet.unhandledRequest(in: withTomb))
        // 早于 request 的旧 tombstone 不清位
        let staleTombFirst = [tombstoneEvent(0, makeRecord(forgotten: [], summary: nil, offset: nil)),
                              user(1, "u1"), requestEvent(2)]
        XCTAssertNotNil(CondensationWorkingSet.unhandledRequest(in: staleTombFirst))
    }

    // MARK: - 件2：原子边界（配对区间）

    func testAlignmentKeepsToolPairTogether() {
        let events = [
            user(0, "u0"),
            assistant(1, callId: "c1"),
            result(2, "c1"),
            result(3, "c1"),
            user(4, "u4"),
        ]
        // 遗忘 {2}（对中段）→ 对内其余端在保留区 → 整对挤回保留区 → 遗忘集空
        let aligned = CondensationWorkingSet.alignForgotten([2], keepProtected: [0],
                                                            in: events)
        XCTAssertTrue(aligned.isEmpty, "整对挤回后无可遗忘，实际 \(aligned)")
        // 边界收缩方向：遗忘 {1,2}（3 在保留区）→ 整对拉回 → 同样为空，
        // 不产生孤立 result
        let aligned2 = CondensationWorkingSet.alignForgotten([1, 2], keepProtected: [0],
                                                             in: events)
        XCTAssertTrue(aligned2.isEmpty)
        // 对整体都在候选遗忘区 → 保持完整遗忘
        let aligned3 = CondensationWorkingSet.alignForgotten([1, 2, 3],
                                                             keepProtected: [0],
                                                             in: events)
        XCTAssertEqual(aligned3, [1, 2, 3])
    }

    func testAlignmentProtectsPrefixPair() {
        // 助手在保护前缀、结果在候选遗忘区 → 结果被拉回保留区（对完整）
        let events = [
            assistant(0, callId: "c1"),
            result(1, "c1"),
            user(2, "u2"),
            user(3, "u3"),
        ]
        let aligned = CondensationWorkingSet.alignForgotten([1, 2, 3],
                                                            keepProtected: [0],
                                                            in: events)
        XCTAssertFalse(aligned.contains(1), "保护前缀助手的结果不得被遗忘")
        XCTAssertTrue(aligned.contains(2) && aligned.contains(3))
    }

    // MARK: - 件3：触发三源分级

    private let smallPolicy = CondensationWorkingSet.Policy(
        keepFirst: 2, maxSize: 4, attentionWindow: 0, maxEventChars: 10_000,
        minimumProgress: 0.1, tokenBudgetRatio: 0.9)

    func testTriggerTokensIsHard() {
        let events = [user(0, String(repeating: "x", count: 900))]
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: 1_000, tokenBudget: 500, policy: smallPolicy)
        XCTAssertEqual(decision.reasons, [.tokens])
        XCTAssertEqual(decision.requirement, .hard)
    }

    func testTriggerEventsIsSoft() {
        // 5 个模型可见事件 > maxSize 4 → 仅 EVENTS → SOFT
        let events = (0..<5).map { user($0, "u\($0)") }
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: 10, tokenBudget: 500, policy: smallPolicy)
        XCTAssertEqual(decision.reasons, [.events])
        XCTAssertEqual(decision.requirement, .soft)
    }

    func testTriggerRequestIsHard() {
        let events = [user(0, "u0"), requestEvent(1)]
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: 10, tokenBudget: 500, policy: smallPolicy)
        XCTAssertEqual(decision.reasons, [.request])
        XCTAssertEqual(decision.requirement, .hard)
        XCTAssertEqual(decision.requestReason, .manual)
    }

    func testTriggerMultiReasonTakesStrictest() {
        // tokens + events → hard（tokens 主导）；request 也在 → hard
        let events = (0..<5).map { user($0, "u\($0)") } + [requestEvent(5)]
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: 1_000, tokenBudget: 500, policy: smallPolicy)
        XCTAssertEqual(decision.reasons, [.tokens, .events, .request])
        XCTAssertEqual(decision.requirement, .hard)
    }

    func testTriggerNoReason() {
        let events = [user(0, "u0")]
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: 10, tokenBudget: 500, policy: smallPolicy)
        XCTAssertTrue(decision.reasons.isEmpty)
    }

    // MARK: - 遗忘集选择（多原因取最严 + 守门）

    func testSelectionRespectsKeepFirstAndTailTarget() {
        let events = (0..<6).map { user($0, "u\($0)") }
        // REQUEST：目标规模 len//2 = 3；尾留 = 3 - keepFirst(2) - 1 = 0
        let forgotten = CondensationWorkingSet.selectForgottenSeqs(
            events: events, reasons: [.request], tokenBudget: 1_000_000, policy: smallPolicy)
        XCTAssertEqual(forgotten, [2, 3, 4, 5])
    }

    func testSelectionTokensStrictest() {
        // tokens 原因：尾节点占总量过半 → 尾留 1 → candidateEnd = 3-1 = 2 =
        // keepFirst → 无候选 → nil（NoCondensationAvailable）
        let events = [user(0, "a"), user(1, "b"),
                      user(2, String(repeating: "x", count: 30_000))]
        let forgotten = CondensationWorkingSet.selectForgottenSeqs(
            events: events, reasons: [.tokens], tokenBudget: 10_000, policy: smallPolicy)
        XCTAssertNil(forgotten)
    }

    func testSelectionMinimumProgressGuard() {
        // 10 个节点、REQUEST 尾留 = 10//2-2-1 = 2 → 候选 6 个 ≥ 10×0.1 —— 通过；
        // 构造收益太小：3 节点 + tailKeep 0 → 候选 1 个 = 3×0.1=0.3 → 1 ≥ 0.3 通过。
        // 用 attentionWindow=0/keepFirst=2 + 4 节点：尾留 = 4//2-3 = -1 → 0，
        // 候选 2 个 ≥ 0.4 通过。改用 minimumProgress=0.9 挡：候选 2 < 4×0.9 → nil。
        let policy = CondensationWorkingSet.Policy(
            keepFirst: 2, maxSize: 4, attentionWindow: 0, maxEventChars: 10_000,
            minimumProgress: 0.9, tokenBudgetRatio: 0.9)
        let events = (0..<4).map { user($0, "u\($0)") }
        let forgotten = CondensationWorkingSet.selectForgottenSeqs(
            events: events, reasons: [.request], tokenBudget: 1_000_000, policy: policy)
        XCTAssertNil(forgotten, "收益小于 minimum_progress 应视为无可压缩")
    }

    func testSelectionExcludesSyntheticAndProtected() {
        // 已有 tombstone：派生摘要条目（负 seq）不得进入遗忘集
        let base = (0..<6).map { user($0, "u\($0)") }
        let record = makeRecord(forgotten: [0, 1], summary: "旧摘要", offset: 0)
        let events = base + [tombstoneEvent(6, record), requestEvent(7)]
        let forgotten = CondensationWorkingSet.selectForgottenSeqs(
            events: events, reasons: [.request], tokenBudget: 1_000_000,
            policy: smallPolicy)
        XCTAssertNotNil(forgotten)
        XCTAssertTrue(forgotten?.allSatisfy { $0 >= 0 } ?? true, "派生条目冻结不重折")
        XCTAssertFalse(forgotten?.contains(0) ?? true, "旧 tombstone 遗忘集仍被过滤")
    }

    // MARK: - 序列化（seq 标注 + 截断 + previous summary 语境行）

    func testSerializedEventsSeqAnnotationAndCap() {
        let events = [
            user(0, "u0"),
            assistant(1, callId: "c1", arguments: "{\"file_path\":\"a.swift\"}"),
            result(2, "c1", content: String(repeating: "r", count: 500)),
        ]
        let lines = CondensationWorkingSet.serializedEvents(
            events, capChars: 100, policy: smallPolicy)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("[seq=0] [user] u0"))
        XCTAssertTrue(lines[1].hasPrefix("[seq=1] [assistant]"))
        // arguments 在位（B2 gap 裁决：Files/命令兜底提取的料源）
        XCTAssertTrue(lines[1].contains(
            "[tool calls: read_file(c1) {\"file_path\":\"a.swift\"}]"),
            "实际 \(lines[1])")
        XCTAssertTrue(lines[2].hasPrefix("[seq=2] [tool result c1] "))
        // 截断：单事件 ≤ cap + 标注前缀
        XCTAssertLessThanOrEqual(lines[2].count, "[seq=2] [tool result c1] ".count + 100)
    }

    func testSerializedToolCallArgumentsGrammar() {
        // B2 gap 裁决实证：arguments 在位 + " | " 分隔 + 换行归一 + 2000 截断。
        let longArgs = String(repeating: "x", count: 3_000)
        let message = AssistantMessage(
            id: "m1", provider: "test", model: "test",
            content: [
                .toolCall(id: "c1", name: "read_file", arguments: "{\n  \"path\": \"a.swift\"\n}"),
                .toolCall(id: "c2", name: "shell", arguments: longArgs),
            ])
        let events = [event(0, .assistantMessage(turn: 1, step: 1, message: message,
                                                 usage: nil, interrupted: false))]
        let lines = CondensationWorkingSet.serializedEvents(
            events, capChars: 10_000, policy: smallPolicy)
        XCTAssertEqual(lines.count, 1)
        // " | " 分隔（JSON 内逗号不构成调用定界符）
        XCTAssertTrue(lines[0].contains("read_file(c1) {"), "实际 \(lines[0])")
        XCTAssertTrue(lines[0].contains("\"path\": \"a.swift\" } | shell(c2) "),
                      "实际 \(lines[0])")
        // 换行归一（单行 JSON 形态，\n→空格后与既有缩进空格并存）
        XCTAssertFalse(lines[0].contains("\n"))
        XCTAssertFalse(lines[0].contains("\t"))
        // 单 arguments 截 2000（c2 的 x 序列）
        let c2Segment = lines[0].split(separator: "|")[1]
        let xCount = c2Segment.filter { $0 == "x" }.count
        XCTAssertEqual(xCount, 2_000)
    }

    func testSerializedEventsForgottenSubsetAndPreviousSummary() {
        let base = (0..<5).map { user($0, "u\($0)") }
        let record = makeRecord(forgotten: [0, 1], summary: "旧摘要", offset: 0)
        let events = base + [tombstoneEvent(5, record)]
        // 只序列化第二批遗忘子集 {2,3}
        let lines = CondensationWorkingSet.serializedEvents(
            events, forgottenSeqs: [2, 3], capChars: 10_000, policy: smallPolicy)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("u2"))
        XCTAssertTrue(lines[1].contains("u3"))
        // 全量（含 previous summary 语境行）
        let all = CondensationWorkingSet.serializedEvents(
            events, capChars: 10_000, policy: smallPolicy)
        XCTAssertTrue(all.contains { $0.contains("[previous summary") && $0.contains("旧摘要") },
                      "旧摘要作 previous summary 语境行（增量折叠），实际 \(all)")
    }

    // MARK: - 掩码（件6：零 LLM 第一级）

    func testMaskReplacesOldToolResultsOutsideWindow() {
        let events = [
            result(0, "c0", content: "BIG0"),
            result(1, "c1", content: "BIG1", isError: true),
            result(2, "c2", content: "BIG2"),
            result(3, "c3", content: "BIG3"),
            user(4, "u4"),
        ]
        let policy = CondensationWorkingSet.Policy(
            keepFirst: 2, maxSize: 240, attentionWindow: 2, maxEventChars: 10_000,
            minimumProgress: 0.1, tokenBudgetRatio: 0.9)
        let masked = CondensationWorkingSet.projected(events, policy: policy)
        func payload(of seq: Int) -> SessionEvent.Payload? {
            masked.first(where: { $0.seq == seq })?.payload
        }
        func content(_ seq: Int) -> String? {
            guard case .toolResult(_, _, _, let content, _, _, _, _)? = payload(of: seq)
            else { return nil }
            return content
        }
        // 窗口 = 最后 2 个模型可见事件（result3 + user4）→ 窗口外掩码
        XCTAssertEqual(content(0), CondensationWorkingSet.maskPlaceholder)
        XCTAssertEqual(content(2), CondensationWorkingSet.maskPlaceholder)
        XCTAssertEqual(content(3), "BIG3", "窗口内不掩码")
        // 错误结果保留（万我登记偏差）
        XCTAssertEqual(content(1), "BIG1")
        // callId/turn/step 保持（配对不受扰）
        guard case .toolResult(let turn, let step, let callId, _, let isError, _, _, _)? =
            payload(of: 0) else {
            return XCTFail("masked toolResult payload shape changed")
        }
        XCTAssertEqual(callId, "c0")
        XCTAssertEqual(turn, 1)
        XCTAssertEqual(step, 1)
        XCTAssertFalse(isError)
    }

    // MARK: - 引擎：正常压缩 + 熔断（件7）

    private let enginePolicy = CondensationWorkingSet.Policy(
        keepFirst: 2, maxSize: 240, attentionWindow: 0, maxEventChars: 10_000,
        minimumProgress: 0.1, tokenBudgetRatio: 0.9)

    private func makeEngineEvents() -> [SessionEvent] {
        (0..<5).map { user($0, "u\($0)") } + [requestEvent(5)]
    }

    private func makeDecision() -> CondensationWorkingSet.TriggerDecision {
        CondensationWorkingSet.TriggerDecision(reasons: [.request],
                                               requirement: .hard,
                                               requestReason: .manual)
    }

    func testEngineLandsTombstoneWithMetrics() async throws {
        let engine = CondensationEngine()
        let collector = PayloadCollector()
        let summarizer = ScriptedSummarizer(["MANUAL-SUM"])
        let record = try await engine.condense(
            events: makeEngineEvents(), decision: makeDecision(),
            tokenBudget: 1_000_000, policy: enginePolicy, summarizer: summarizer,
            estimate: { Compactor.estimateSession($0) },
            append: collector.makeAppend())
        guard let record else { return XCTFail("expected tombstone") }
        XCTAssertEqual(record.forgottenSeqs, [2, 3, 4])
        XCTAssertEqual(record.summary, "MANUAL-SUM")
        XCTAssertEqual(record.summaryOffset, 2)
        XCTAssertGreaterThanOrEqual(record.tokensBefore ?? 0, 0)
        XCTAssertLessThan(record.tokensAfter ?? Int.max, record.tokensBefore ?? 0,
                          "压缩后工作集必须变小")
        // 增量折叠：首轮无旧摘要
        if let firstPrevious = summarizer.previousSummaries.first {
            XCTAssertNil(firstPrevious)
        }
        // 落盘 = tombstone（condensation/v1）
        XCTAssertEqual(collector.count, 1)
        guard case .extensionEvent(let kind, let payload) = collector.snapshot()[0].payload,
              kind == CondensationEvents.condensationKind else {
            return XCTFail("expected condensation/v1 tombstone append")
        }
        XCTAssertEqual(CondensationRecord.decode(payload), record)
        // 成功复位熔断
        XCTAssertFalse(engine.autoCompactionDisabled)
    }

    func testEngineFailureIncrementsBreaker() async throws {
        let engine = CondensationEngine()
        let collector = PayloadCollector()
        // 摘要器缺席：attemptNormal 每次调用恰计一次失败（HARD 路径 summarizer
        // 缺席不再进 hard reset——引擎 guard 直返）。
        for _ in 0..<3 {
            let record = try await engine.condense(
                events: makeEngineEvents(), decision: makeDecision(),
                tokenBudget: 1_000_000, policy: enginePolicy, summarizer: nil,
                estimate: { Compactor.estimateSession($0) },
                append: collector.makeAppend())
            XCTAssertNil(record, "摘要器缺席 → nil")
        }
        XCTAssertEqual(collector.count, 0, "失败不落 tombstone")
        XCTAssertTrue(engine.autoCompactionDisabled, "连续 3 次失败 → 熔断")
        XCTAssertEqual(engine.failureCount, 3)
        // 摘要失败（返回 nil）继续累计；hard reset 5 次全失败再计一次
        _ = try await engine.condense(
            events: makeEngineEvents(), decision: makeDecision(),
            tokenBudget: 1_000_000, policy: enginePolicy,
            summarizer: ScriptedSummarizer([nil]),
            estimate: { Compactor.estimateSession($0) },
            append: collector.makeAppend())
        XCTAssertEqual(engine.failureCount, 5, "attemptNormal + hardReset 各计一次")
        XCTAssertTrue(engine.autoCompactionDisabled)
        // 成功复位
        let ok = try await engine.condense(
            events: makeEngineEvents(), decision: makeDecision(),
            tokenBudget: 1_000_000, policy: enginePolicy,
            summarizer: ScriptedSummarizer(["RECOVERED"]),
            estimate: { Compactor.estimateSession($0) },
            append: collector.makeAppend())
        XCTAssertNotNil(ok)
        XCTAssertFalse(engine.autoCompactionDisabled, "成功复位")
        XCTAssertEqual(engine.failureCount, 0)
    }

    func testEngineHardResetScalesEventCapBy0_8() async throws {
        // 正常压缩无候选（尾节点占总量过半）→ HARD 走 hard reset；
        // 摘要器在 cap=10_000 时失败、cap=8_000 时成功 → ×0.8 递减实证。
        let engine = CondensationEngine()
        let collector = PayloadCollector()
        let summarizer = ScriptedSummarizer([nil, "RESET-SUM"])
        let events: [SessionEvent] = [
            user(0, "a"), user(1, "b"),
            user(2, String(repeating: "x", count: 30_000)),
            requestEvent(3),
        ]
        let decision = CondensationWorkingSet.TriggerDecision(
            reasons: [.tokens], requirement: .hard, requestReason: nil)
        let record = try await engine.condense(
            events: events, decision: decision, tokenBudget: 10_000,
            policy: enginePolicy, summarizer: summarizer,
            estimate: { Compactor.estimateSession($0) },
            append: collector.makeAppend())
        XCTAssertNotNil(record, "hard reset 应在第二次尝试（cap×0.8）成功")
        XCTAssertEqual(record?.summary, "RESET-SUM")
        XCTAssertEqual(record?.forgottenSeqs, [2], "hard reset 遗忘保护前缀之外全部")
        XCTAssertEqual(summarizer.inputSizes.count, 2)
        XCTAssertLessThan(summarizer.inputSizes[1], summarizer.inputSizes[0],
                          "第二次尝试的输入必须更小（cap ×0.8）")
    }

    // MARK: - 门面：/compact 手动链（请求事件 + HARD）

    func testCompactorCompactNowLandsRequestAndTombstone() async throws {
        CondensationEvents.register()
        let compactor = Compactor { throw LLMError(message: "no adapter in test",
                                                   code: "UNKNOWN") }
        compactor.setSummarizer(ScriptedSummarizer(["COMPACT-SUM"]))
        let collector = PayloadCollector()
        let events = (0..<5).map { user($0, "u\($0)") }
        let ok = try await compactor.compactNow(events: events, model: "test-model",
                                                append: collector.makeAppend())
        XCTAssertTrue(ok)
        let payloads = collector.snapshot()
        XCTAssertEqual(payloads.count, 2)
        guard case .extensionEvent(let firstKind, _) = payloads[0].payload,
              case .extensionEvent(let secondKind, let tombPayload) = payloads[1].payload else {
            return XCTFail("expected request + tombstone appends")
        }
        XCTAssertEqual(firstKind, CondensationEvents.requestKind)
        XCTAssertEqual(secondKind, CondensationEvents.condensationKind)
        let tomb = CondensationRecord.decode(tombPayload)
        XCTAssertEqual(tomb?.forgottenSeqs, [2, 3, 4])
        XCTAssertEqual(tomb?.summary, "COMPACT-SUM")
    }

    func testCompactorCompactIfNeededNoTrigger() async throws {
        let compactor = Compactor { throw LLMError(message: "no adapter in test",
                                                   code: "UNKNOWN") }
        let collector = PayloadCollector()
        let events = [user(0, "u0"), user(1, "u1"), user(2, "u2")]
        let ok = await compactor.compactIfNeeded(events: events, model: "test-model",
                                                 append: collector.makeAppend())
        XCTAssertFalse(ok)
        XCTAssertEqual(collector.count, 0)
    }

    // MARK: - 写侧门（注册 schema 校验 fail closed）

    func testWriterRejectsMalformedTombstonePayload() async throws {
        CondensationEvents.register()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-cond-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = SessionHeader(id: "cond", createdAtMs: nowMs, cwd: nil)
        let log = try JsonlEventLog.create(header: header,
                                           at: dir.appendingPathComponent("session.jsonl"))
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite3").path)
        let writer = try await SessionWriter(id: header.id, header: header,
                                             log: log, database: database)
        // 合法 tombstone（required: id + forgottenSeqs）
        let record = makeRecord(forgotten: [0], summary: "s", offset: 0)
        _ = try await writer.append(.extensionEvent(
            kind: CondensationEvents.condensationKind, payload: record.payload))
        // 缺 id → SchemaViolation（写侧门 fail closed）
        do {
            _ = try await writer.append(.extensionEvent(
                kind: CondensationEvents.condensationKind,
                payload: .object(["forgottenSeqs": .array([.int(1)])])))
            XCTFail("expected schema violation")
        } catch let error as ExtensionEventRegistry.SchemaViolation {
            XCTAssertEqual(error.kind, CondensationEvents.condensationKind)
        }
        // 非法 reason → SchemaViolation（值域）
        do {
            _ = try await writer.append(.extensionEvent(
                kind: CondensationEvents.requestKind,
                payload: .object(["reason": .string("weird"),
                                  "requestedAtMs": .int(1)])))
            XCTFail("expected schema violation")
        } catch let error as ExtensionEventRegistry.SchemaViolation {
            XCTAssertEqual(error.kind, CondensationEvents.requestKind)
        }
    }
}
