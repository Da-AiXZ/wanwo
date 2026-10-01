//
//  M7Fix2EngineTests.swift
//  WanWoTests
//
//  【M7Fix2 · E1 引擎三修单测】修复对拍断言（dsh 语义源：
//  repos/deepseek-harness-master/packages/{llm/llm-deepseek,goal/goal}/src）：
//    A1 纯图消息链（AgentLoop.swift:840 修法对拍 dsh InputBar image-only
//       语义）：①空文本+1图 → userMessage + E1 attachment/images 两事件都
//       落、onUserMessageAppended 带图引用；②空文本无图 → 防回归纯空不发；
//       ③带图带文形状不变。
//    A2 assistant 思考链回传（dsh serialize.ts:203-235 serializeAssistant
//       1:1）：①reasoning 非空 → wire 含 reasoning_content；②无/空 reasoning
//       → 字段不出现（encodeIfPresent）；③多 reasoning 块按序拼接（join('')）。
//    A3 goal 栅栏原子化（方案甲 · SessionWriter.appendFenced；dsh index.ts
//       :584-602 commit 同步一气呵成的 WanWo 等价）：①并发插队（diag/trace
//       面包屑同款 writer.append）下 create 仍 armed / complete 仍 disarmed；
//       ②complete 后 disarmed 稳定不回归。
//
//  测试基建照 M7FixGoalLoopTests.swift harness（最小 writer + 最小 AgentLoop；
//  makeAdapter 恒抛 = 回合确定性收敛，零网络）。
//

import XCTest
@testable import WanWo

final class M7Fix2EngineTests: XCTestCase {

    // MARK: - harness（M7FixGoalLoopTests 同款）

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7fix2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "m7-fix2",
                                   createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                   cwd: nil)
        let log = try JsonlEventLog.create(header: header,
                                           at: dir.appendingPathComponent("session.jsonl"))
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite3").path)
        let writer = try await SessionWriter(id: header.id, header: header,
                                             log: log, database: database)
        return (writer, dir)
    }

    private func makeLoop(sessionId: String,
                          writer: SessionWriter,
                          goalService: GoalService? = nil,
                          callbacks: AgentLoop.Callbacks = .init()) -> AgentLoop {
        let registry = ToolRegistry()
        let pipeline = ToolPipeline(registry: registry,
                                    repeatAdviser: RepeatCallAdviser())
        return AgentLoop(deps: AgentLoop.Dependencies(
            sessionId: sessionId,
            writer: writer,
            assembler: PromptAssembler(),
            registry: registry,
            pipeline: pipeline,
            compactor: Compactor(policy: .init()) {
                throw LLMError(message: "unused", code: "TEST")
            },
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            injector: ContextInjector(),
            makeAdapter: {
                throw LLMError(message: "adapter always fails", code: "TEST")
            },
            callbacks: callbacks,
            sandboxModeProvider: { .workspaceWrite },
            escalationApprover: nil,
            goalService: goalService))
    }

    /// 轮询等待（deadline 内条件成立即返回；最终再判一次）。
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// 线程安全回调收集器（onUserMessageAppended 从 loop actor 后台发射）。
    private final class UserMessageCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(text: String, images: [ImageAttachmentRef])] = []
        func append(_ text: String, _ images: [ImageAttachmentRef]) {
            lock.lock(); items.append((text, images)); lock.unlock()
        }
        var all: [(text: String, images: [ImageAttachmentRef])] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    /// 测试图片引用（形状完整即可——A1 只验证引用集落盘与回调随行）。
    private func makeRef(_ id: String) -> ImageAttachmentRef {
        ImageAttachmentRef(attachmentId: "sha256:\(id)", mediaType: .png,
                           bytes: 8, width: 2, height: 2, name: nil,
                           originalDimensions: nil)
    }

    private func userMessages(_ writer: SessionWriter) -> [String] {
        writer.events.compactMap { event in
            if case .userMessage(let text) = event.payload { return text }
            return nil
        }
    }

    /// E1 attachment/images 事件解析产物（seq + refs）。
    private func imageEvents(_ writer: SessionWriter)
        -> [(seq: Int, refs: [ImageAttachmentRef])] {
        writer.events.compactMap { event in
            if case .extensionEvent(let kind, let payload) = event.payload,
               kind == AttachmentStore.imagesEventKind {
                return AttachmentStore.refsFromPayload(payload)
            }
            return nil
        }
    }

    private func turnEnds(_ writer: SessionWriter) -> [(turn: Int, reason: TurnEndReason)] {
        writer.events.compactMap { event in
            if case .turnEnd(let turn, let reason) = event.payload {
                return (turn, reason)
            }
            return nil
        }
    }

    // MARK: - A1 纯图消息链

    /// A1-①：空文本 + 1 图 → userMessage（text=""）+ E1 attachment/images
    /// 两事件都落盘、引用归属 seq 正确、回调带 refs（真机 bug1 前半：
    /// 旧实现 `where !entry.text.isEmpty` 整条被吞——UI 无泡、模型收空轮次）。
    func testImageOnlyEntryPersistsUserMessageAndAttachmentEvent() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 注册 attachment/images E1 schema（appendOnce 写侧门校验需要）。
        _ = AttachmentStore(root: dir.appendingPathComponent("attachments"))
        let collector = UserMessageCollector()
        var callbacks = AgentLoop.Callbacks()
        callbacks.onUserMessageAppended = { text, images in
            collector.append(text, images)
        }
        let loop = makeLoop(sessionId: "m7fix2-img", writer: writer,
                            callbacks: callbacks)

        let ref = makeRef("a1")
        await loop.submit("", images: [ref])
        // 回合收敛（adapter 恒抛 → error 收尾）后再断言落盘面。
        let settled = await waitUntil { !self.turnEnds(writer).isEmpty }
        XCTAssertTrue(settled, "回合必须收敛（adapter 抛错收尾）")

        let emptyTexts = userMessages(writer).filter { $0.isEmpty }
        XCTAssertEqual(emptyTexts.count, 1,
                       "空文本+图条目必须落 userMessage（旧实现整条被吞）")
        let events = imageEvents(writer)
        XCTAssertEqual(events.count, 1, "E1 attachment/images 必须紧随落盘")
        XCTAssertEqual(events.first?.refs, [ref], "引用集必须完整随行")
        // 载荷声明的归属 seq == 该 userMessage 的 seq（DeriveFold/投影器挂接锚）。
        let userMessageSeq = writer.events.first { event in
            if case .userMessage(let text) = event.payload { return text.isEmpty }
            return false
        }?.seq
        XCTAssertEqual(events.first?.seq, userMessageSeq,
                       "E1 载荷归属 seq 必须指向空文本 userMessage")

        let received = collector.all
        XCTAssertEqual(received.count, 1, "onUserMessageAppended 必须恰发一次")
        XCTAssertEqual(received.first?.text, "")
        XCTAssertEqual(received.first?.images, [ref], "回调必须带图引用（乐观气泡带图上屏）")
        await loop.whenIdle()
    }

    /// A1-②：空文本无图 → 防回归：纯空条目不落 userMessage、不发回调
    ///（修法条件 `!text.isEmpty || !images.isEmpty` 的右支不得放大到纯空）。
    func testEmptyEntryWithoutImagesStaysSuppressed() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = AttachmentStore(root: dir.appendingPathComponent("attachments"))
        let collector = UserMessageCollector()
        var callbacks = AgentLoop.Callbacks()
        callbacks.onUserMessageAppended = { text, images in
            collector.append(text, images)
        }
        let loop = makeLoop(sessionId: "m7fix2-empty", writer: writer,
                            callbacks: callbacks)

        await loop.submit("")
        let settled = await waitUntil { !self.turnEnds(writer).isEmpty }
        XCTAssertTrue(settled, "回合必须收敛")

        XCTAssertEqual(userMessages(writer).filter { $0.isEmpty }.count, 0,
                       "纯空条目不得落盘（防回归）")
        XCTAssertEqual(imageEvents(writer).count, 0, "无图不得落 E1 事件")
        XCTAssertEqual(collector.all.count, 0, "纯空条目不得发回调")
        await loop.whenIdle()
    }

    /// A1-③：带图带文形状不变（回归守卫）——userMessage 文本原样 + E1 事件
    /// + 回调 (text, refs)。
    func testTextWithImagesEntryShapeUnchanged() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = AttachmentStore(root: dir.appendingPathComponent("attachments"))
        let collector = UserMessageCollector()
        var callbacks = AgentLoop.Callbacks()
        callbacks.onUserMessageAppended = { text, images in
            collector.append(text, images)
        }
        let loop = makeLoop(sessionId: "m7fix2-both", writer: writer,
                            callbacks: callbacks)

        let ref = makeRef("a1b")
        await loop.submit("看这张图", images: [ref])
        let settled = await waitUntil { !self.turnEnds(writer).isEmpty }
        XCTAssertTrue(settled)

        XCTAssertTrue(userMessages(writer).contains("看这张图"),
                      "带图带文：文本原样落盘")
        let events = imageEvents(writer)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.refs, [ref])
        let received = collector.all
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.text, "看这张图")
        XCTAssertEqual(received.first?.images, [ref])
        await loop.whenIdle()
    }

    // MARK: - A2 assistant 思考链回传

    /// wire JSON 断言助手（JSONEncoder → 字典）。
    private func wireJSON(_ message: WireMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    /// A2-①：assistant 带 reasoning → wire 含 reasoning_content（dsh
    /// serialize.ts:233 非空即回传——DeepSeek thinking 模式官方规则：
    /// tool-call 轮必须回传，否则 400
    /// "The 'reasoning_content' in the thinking mode must be passed back"）。
    func testAssistantReasoningContentPassedBackOnWire() throws {
        let message = ChatMessage(
            role: .assistant, content: "答案",
            toolCalls: [ToolCallSpec(id: "call-1", name: "read", arguments: "{}")],
            reasoning: "先想一想")
        let json = try wireJSON(OpenAICompatAdapter.assistantWireMessage(for: message))
        XCTAssertEqual(json["reasoning_content"] as? String, "先想一想",
                       "思考链必须随 assistant 轮回传")
        XCTAssertEqual(json["content"] as? String, "答案")
        // tool-call 轮：tool_calls 与 reasoning_content 并存（dsh :233-234
        // 两个独立扩展，互不排斥——官方规则恰好要求 tool-call 轮回传）。
        XCTAssertNotNil(json["tool_calls"])
    }

    /// A2-②：无 reasoning / 空串 reasoning → 字段不出现（encodeIfPresent；
    /// dsh `reasoning.length > 0 ? {...} : {}` 1:1）。
    func testAssistantWithoutReasoningOmitsWireField() throws {
        let plain = ChatMessage(role: .assistant, content: "你好")
        let plainJSON = try wireJSON(OpenAICompatAdapter.assistantWireMessage(for: plain))
        XCTAssertNil(plainJSON["reasoning_content"],
                     "无思考链不得出现 reasoning_content 字段")

        let blank = ChatMessage(role: .assistant, content: "你好", reasoning: "")
        let blankJSON = try wireJSON(OpenAICompatAdapter.assistantWireMessage(for: blank))
        XCTAssertNil(blankJSON["reasoning_content"],
                     "空串思考链视为缺席（dsh 非空即回传口径）")
    }

    /// A2-③：多 reasoning 块按块序直接拼接（dsh serialize.ts:205-208
    /// join('')——DeriveFold 折叠侧口径）。
    func testDeriveFoldJoinsMultipleReasoningBlocksInOrder() throws {
        let message = AssistantMessage(
            id: "am-1", provider: "deepseek", model: "deepseek-chat",
            content: [.reasoning("因为"), .reasoning("所以"), .text("答案")])
        let events = [
            SessionEvent(seq: 0, timeMs: 1, payload: .userMessage(text: "问")),
            SessionEvent(seq: 1, timeMs: 2, payload: .assistantMessage(
                turn: 0, step: 1, message: message, usage: nil, interrupted: false)),
        ]
        let messages = DeriveFold(events).messages
        XCTAssertEqual(messages.count, 2)
        let assistant = messages[1]
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.content, "答案")
        XCTAssertEqual(assistant.reasoning, "因为所以",
                       "多块按序拼接（join('')，非空才承载）")
        // 折叠产物即请求输入：assistantWireMessage 直接消费 ChatMessage.reasoning。
        let json = try wireJSON(OpenAICompatAdapter.assistantWireMessage(for: assistant))
        XCTAssertEqual(json["reasoning_content"] as? String, "因为所以")
    }

    // MARK: - A3 goal 栅栏原子化

    /// A3-①：并发插队下 create 仍 armed / complete 仍 disarmed。
    /// 模拟真机病灶：diag/trace 面包屑（独立 Task 的 writer.append）与
    /// goal commit 交错——旧实现在 gate 外读 eventCount，async 缝被插队后
    /// `event.seq != expectedSeq` → armed 被误杀 disarmed（真机实证 seq1027
    /// 面包屑插队在 goal/change seq1028 之前）。方案甲 appendFenced 把 seq
    /// 快照移进 gate 临界区，插队窗口结构性消失。
    func testCreateStaysArmedUnderConcurrentInterleaving() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        GoalEvents.register()
        let service = GoalService(writer: writer)

        // 面包屑风暴（与 AppEnvironment 引擎面包屑同款通道：独立 Task
        // writer.append .system / extensionEvent——不与 goal commit 同 actor）。
        let spam = Task {
            for index in 0..<240 {
                if Task.isCancelled { break }
                _ = try? await writer.append(.system(note: "diag-crumb-\(index)"))
                await Task.yield()
            }
        }

        // create(armed) → complete(disarmed) 交替 ×8——栅栏双向都过。
        for iteration in 0..<8 {
            let created = try await service.create(
                objective: "交替目标 \(iteration)", maxGoalRounds: 4)
            XCTAssertEqual(created.activation, .armed,
                           "插队风暴下 create 第 \(iteration) 次必须 armed（旧实现被误杀 disarmed）")
            XCTAssertEqual(created.phase, .active)
            let completed = try await service.complete(ref: created.ref)
            XCTAssertEqual(completed.activation, .disarmed,
                           "插队风暴下 complete 第 \(iteration) 次必须 disarmed")
        }
        spam.cancel()
        await spam.value

        // 终态收敛：最后一个 complete 后恒 disarmed；goal/change 事件 16 条
        // 全部落盘（风暴不丢 commit）。
        let view = try await service.get()
        XCTAssertEqual(view?.activation, .disarmed)
        XCTAssertEqual(view?.phase, .complete)
        let changeCount = writer.events.filter { event in
            if case .extensionEvent(let kind, _) = event.payload {
                return kind == GoalEvents.changeKind
            }
            return false
        }.count
        XCTAssertEqual(changeCount, 16, "8×(create+complete) 全部落盘")
    }

    /// A3-②：complete 后 disarmed 稳定（防御回归：原子化修复不得改变
    /// 转移矩阵语义——commit 栅栏正常路径恒 fenced=true，activation 落
    /// 意图值；pause/resume/complete/block/clear 全走同一 commit）。
    func testCompleteDisarmsDurably() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        GoalEvents.register()
        let service = GoalService(writer: writer)

        let created = try await service.create(objective: "收尾目标",
                                               maxGoalRounds: 3)
        XCTAssertEqual(created.activation, .armed)
        // get() 复读 = 进程内 armed 态稳定承载（dsh view activation 语义）。
        let armedView = try await service.get()
        XCTAssertEqual(armedView?.activation, .armed)

        let completed = try await service.complete(ref: created.ref)
        XCTAssertEqual(completed.activation, .disarmed)
        XCTAssertEqual(completed.phase, .complete)
        let disarmedView = try await service.get()
        XCTAssertEqual(disarmedView?.activation, .disarmed)
        XCTAssertEqual(disarmedView?.phase, .complete)

        // pause/resume 同链抽验：resume（complete 不可恢复，走 blocked→resume）。
        // complete 后无 current 可 pause——这里验证 blocked 链：新建 → block
        // → resume，确认 armed 恢复（同一 commit 通道）。
        // （complete 墓碑不可复用，直接开第二个目标前须 clear。）
        let tombstone = try await service.clear(ref: created.ref)
        XCTAssertEqual(tombstone.revision, created.revision + 1)
        let second = try await service.create(objective: "第二目标", maxGoalRounds: 3)
        XCTAssertEqual(second.activation, .armed)
        let blocked = try await service.block(
            ref: second.ref,
            reason: GoalBlockReason(code: "test-block", message: "单测阻断"),
            origin: .host)
        XCTAssertEqual(blocked.activation, .disarmed)
        let resumed = try await service.resume(ref: second.ref)
        XCTAssertEqual(resumed.activation, .armed,
                       "block→resume 经同一 commit，armed 必须恢复")
    }
}
