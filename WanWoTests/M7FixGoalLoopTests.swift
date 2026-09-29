//
//  M7FixGoalLoopTests.swift
//  WanWoTests
//
//  【M7Fix · E1a 单测】修复对拍断言（dsh 语义源：
//  repos/deepseek-harness-master/packages/goal/goal-round-driver/src/index.ts）：
//    1. injectContexts 保留 entry.source（P0 根因：source 丢失 → goal/round
//       admitted 事件永不写入 → roundsStarted 恒 0 → goalAttempt 卡 claimed）。
//    2. goal 保留失守 reject 不 disarm（index.ts:374-383 reject 后
//       restoreOtherClaimed+requestDrive，goal 保持 armed 同轮重试，round 不跳号）。
//    3. 自动 pause / round-limit block 的大白话 .system 注记（呈现面）。
//    4. assistant 落盘 citation 剥离缝（MemoryCitations 生产接线缝；codex
//       citations.rs：可见文本剥离、citation 条目持久保留）。
//
//  测试基建照 M7SupervisorTests.swift harness（最小 writer + 最小 AgentLoop；
//  makeAdapter 恒抛/可闸 = 回合确定性收敛，零网络）。
//

import XCTest
@testable import WanWo

final class M7FixGoalLoopTests: XCTestCase {

    // MARK: - harness

    /// 可重闸（每轮回合各 hold 一次，open 释放并复位——M7SupervisorTests.Gate
    /// 的一次性语义不满足多轮 goal 回合）。
    private final class CycleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var heldFlag = false

        var held: Bool {
            lock.lock(); defer { lock.unlock() }
            return heldFlag
        }

        func hold() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                heldFlag = true
                waiters.append(cont)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            heldFlag = false
            let waiters = self.waiters
            self.waiters = []
            lock.unlock()
            for cont in waiters { cont.resume() }
        }
    }

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "m7-fix",
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
                          goalService: GoalService?,
                          makeAdapter: @escaping @Sendable () async throws
                              -> OpenAICompatAdapter) -> AgentLoop {
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
            makeAdapter: makeAdapter,
            callbacks: .init(),
            sandboxModeProvider: { .workspaceWrite },
            escalationApprover: nil,
            goalService: goalService))
    }

    /// 闸式 adapter：构造点 hold（runStep 起点=注入+goal/round 落盘之后——
    /// 确定性断言锚），放行后抛错收敛回合。
    private func gatedAdapter(_ gate: CycleGate)
        -> @Sendable () async throws -> OpenAICompatAdapter {
        return {
            await gate.hold()
            throw LLMError(message: "gated adapter released", code: "TEST")
        }
    }

    private func throwingAdapter()
        -> @Sendable () async throws -> OpenAICompatAdapter {
        return { throw LLMError(message: "adapter always fails", code: "TEST") }
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

    private func waitView(_ service: GoalService, timeout: TimeInterval = 5,
                          until match: (GoalView?) -> Bool) async -> Bool {
        await waitUntil(timeout: timeout) {
            let view = (try? await service.get()) ?? nil
            return match(view)
        }
    }

    // MARK: - 事件投影助手

    private func roundEvents(_ writer: SessionWriter) -> [GoalRef.Round] {
        writer.events.compactMap { event in
            if case .extensionEvent(let kind, let payload) = event.payload,
               kind == GoalEvents.roundKind {
                return GoalCodec.decodeRound(payload)
            }
            return nil
        }
    }

    private func goalRoundTexts(_ writer: SessionWriter) -> [String] {
        writer.events.compactMap { event in
            if case .userMessage(let text) = event.payload,
               text.contains("<goal_round>") {
                return text
            }
            return nil
        }
    }

    private func systemNotes(_ writer: SessionWriter) -> [String] {
        writer.events.compactMap { event in
            if case .system(let note) = event.payload { return note }
            return nil
        }
    }

    // MARK: - 1【P0】injectContexts 保留 entry.source

    /// goal 轮次条目过 claim→injectContexts→落盘后，goal/round admitted
    /// extensionEvent 必须出现（source 丢失则 :806 判定恒假、该事件不存在、
    /// roundsStarted 不推进）——同测试顺走到 round-limit block 收尾，断言
    /// block 呈现注记（任务 3）。
    func testInjectContextsPreservesGoalSource() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        GoalEvents.register()
        let service = GoalService(writer: writer)
        let gate = CycleGate()
        let loop = makeLoop(sessionId: "m7fix-src", writer: writer,
                            goalService: service,
                            makeAdapter: gatedAdapter(gate))

        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 2)
        XCTAssertEqual(goal.activation, .armed)
        await loop.onGoalChanged(GoalChanged(operation: .create, ref: goal.ref,
                                             goal: goal, origin: .host))

        // 轮 1：claim → injectContexts → goal/round(1) 落盘 → 卡在 adapter 闸。
        XCTAssertTrue(await waitUntil { gate.held }, "轮 1 必须推进到 adapter 闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1],
                       "source 过 injectContexts 不丢——goal/round admitted 落盘")
        XCTAssertTrue(goalRoundTexts(writer).first?.contains("Round: 1/2") == true)

        // 放行 → adapter 抛错 → 轮 1 error 收尾（fence 不动 admitted attempt）
        // → goalDrive 结算消费 → 预约轮 2（round 不跳号）。
        gate.open()
        XCTAssertTrue(await waitUntil { gate.held }, "轮 2 必须再次推进到 adapter 闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1, 2], "同轮序续跑")

        // 放行 → 轮 2 error → roundsStarted(2) ≥ max(2) → block(round-limit)
        // + 大白话 .system 注记。
        gate.open()
        XCTAssertTrue(await waitView(service) { $0?.phase == .blocked },
                      "轮次耗尽必须 block")
        let view = try await service.get()
        XCTAssertEqual(view?.phase, .blocked)
        XCTAssertEqual(view?.blockedReason?.code, "round-limit")
        XCTAssertEqual(view?.roundsStarted, 2)
        XCTAssertTrue(systemNotes(writer).contains(
            "目标已到轮次上限（2 轮），已自动标记为 blocked"),
            "round-limit block 必须落用户可见注记")
        await loop.whenIdle()
    }

    // MARK: - 2【dsh 对齐】保留失守 reject 不 disarm → 同轮重预约

    /// 竞争条目插队致 stale → pre-step reject（turn aborted）→ fence 不 disarm
    /// （修复点：旧代码在此 service.disarm()，goal 掉臂后零重试）→ 下一轮
    /// goalDrive 重新注入同一 Round（index.ts:374-383 requestDrive 语义；
    /// round 不跳号：事件流轮次提示词恰为 Round 1、Round 2 连续）。
    ///
    /// 竞态注：竞争 submit 须落在「goalDrive 预约之后、驱动器 claim 之前」
    /// 窗口——驱动器 claim 前的第一个挂起点是 turnStart 落盘的 await
    /// （writer gate/文件 I/O 真实挂起），测试紧随 onGoalChanged 返回即
    /// submit，作业在该挂起点交错（actor 再入语义）。为免疫残余调度方差，
    /// 整场景最多重试 3 次（以 turn 1 的 reject 指纹为命中判据）。
    func testCompetingEntryStaleRejectRedrivesSameRound() async throws {
        for _ in 0..<3 {
            let (writer, dir) = try await makeWriter()
            defer { try? FileManager.default.removeItem(at: dir) }
            GoalEvents.register()
            let service = GoalService(writer: writer)
            let loop = makeLoop(sessionId: "m7fix-reject", writer: writer,
                                goalService: service,
                                makeAdapter: throwingAdapter())

            let goal = try await service.create(objective: "Ship M7",
                                                maxGoalRounds: 2)
            await loop.onGoalChanged(GoalChanged(operation: .create, ref: goal.ref,
                                                 goal: goal, origin: .host))
            // 竞争条目插队（真实用户输入；预学期内插入 → attempt.stale=true）。
            await loop.submit("competing user input")

            // 判据：turn 1 以保留失守 reject 收尾（命中 = 竞态窗口拿下）。
            let turn1End = writer.events.compactMap { event -> TurnEndReason? in
                if case .turnEnd(let turn, let reason) = event.payload,
                   turn == 1 {
                    return reason
                }
                return nil
            }.first
            guard turn1End == .aborted(cause: "goal round reservation invalid") else {
                // 未命中：等场景自行收敛（旧形态会跑完轮 1/2 后 block），
                // 再换新现场重试（防旧 loop 尾任务与目录清理竞态）。
                _ = await waitView(service, timeout: 10) {
                    $0?.phase == .blocked || $0?.phase == .paused
                }
                continue
            }

            // reject 收尾后 goal 仍 armed（修复点）→ 后续 goalDrive 自动重预约。
            XCTAssertTrue(await waitView(service) {
                $0?.phase == .blocked && $0?.roundsStarted == 2
            }, "修复语义：reject 不掉臂，goal 应继续跑完轮 1/2 后 round-limit block")

            let view = try await service.get()
            XCTAssertEqual(view?.phase, .blocked)
            XCTAssertEqual(view?.blockedReason?.code, "round-limit")
            // round 不跳号：admitted 轮恰为 1、2（index.ts:174 round =
            // roundsStarted+1；旧代码 reject 掉臂 → 事件流零 goal/round）。
            XCTAssertEqual(roundEvents(writer).map(\.round), [1, 2])
            let texts = goalRoundTexts(writer)
            XCTAssertEqual(texts.count, 2, "同轮重注入恰一次（reject 轮不落盘）")
            XCTAssertEqual(texts.first?.contains("Round: 1/2"), true)
            XCTAssertEqual(texts.last?.contains("Round: 2/2"), true)
            XCTAssertFalse(texts.contains(where: { $0.contains("Round: 3/") }),
                           "round 不跳号")
            await loop.whenIdle()
            return
        }
        XCTFail("3 次尝试均未触发保留失守 reject（调度竞态未命中）")
    }

    /// fence 免疫竞态的确定性对拍：armed goal + 无 attempt 的 aborted 回合
    /// （纯用户轮被取消）不再 disarm——kick 收敛后 goalDrive 照常预约轮 1
    /// （旧代码在此 disarm，goalDrive 恒 no-op、零轮次注入）。
    func testAbortedTurnWithoutAttemptKeepsGoalArmed() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        GoalEvents.register()
        let service = GoalService(writer: writer)
        let gate = CycleGate()
        let loop = makeLoop(sessionId: "m7fix-fence", writer: writer,
                            goalService: service,
                            makeAdapter: gatedAdapter(gate))

        // 先起一个普通用户回合并卡在 adapter 闸（attempt 尚不存在）。
        await loop.submit("hello")
        XCTAssertTrue(await waitUntil { gate.held })

        // 运行中建 goal（armed；onChange 未接线 → 不触发驱动）。
        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 1)

        // 取消 → open 放行 → 回合 aborted(user) → fence：无 attempt 不 disarm。
        await loop.cancel(cause: .user)
        gate.open()

        // 修复语义：goal 仍 armed → idle→goalDrive 预约轮 1 → 注入 + 卡闸。
        XCTAssertTrue(await waitUntil { gate.held },
                      "aborted 不掉臂：goalDrive 必须预约并推进轮 1（旧代码 disarm 后无此轮）")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1])
        let view = try await service.get()
        XCTAssertEqual(view?.phase, .active, "纯取消不得误 pause（dsh 精确围栏语义）")
        _ = goal

        // 收尾：轮 1 error → roundsStarted(1) ≥ max(1) → block 收敛（可终止）。
        gate.open()
        XCTAssertTrue(await waitView(service) { $0?.phase == .blocked })
        await loop.whenIdle()
    }

    // MARK: - 3【呈现】自动 pause 落大白话注记

    /// 已 admitted 的 goal 轮被用户取消 → fence 置 cancelled → goalDrive
    /// 精确围栏 pause（dsh index.ts:268-279 对拍）+ 注记（修复前用户只见
    /// "对话突然暂停"无解释）。
    func testAutoPauseEmitsSystemNote() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        GoalEvents.register()
        let service = GoalService(writer: writer)
        let gate = CycleGate()
        let loop = makeLoop(sessionId: "m7fix-pause", writer: writer,
                            goalService: service,
                            makeAdapter: gatedAdapter(gate))

        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 5)
        await loop.onGoalChanged(GoalChanged(operation: .create, ref: goal.ref,
                                             goal: goal, origin: .host))
        XCTAssertTrue(await waitUntil { gate.held }, "轮 1 admitted 后卡闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1])

        // 用户取消 + 放行 → aborted(user) → fence cancelled → goalDrive pause。
        await loop.cancel(cause: .user)
        gate.open()

        XCTAssertTrue(await waitView(service) { $0?.phase == .paused },
                      "围栏必须收敛为 pause（dsh agent/status idle fence）")
        let view = try await service.get()
        XCTAssertEqual(view?.phase, .paused)
        XCTAssertEqual(view?.activation, .disarmed)
        XCTAssertTrue(systemNotes(writer).contains(
            "目标已自动暂停（续轮条件在回合结束时未满足），回复「继续」可恢复"),
            "自动 pause 必须落用户可见注记")
        await loop.whenIdle()
    }

    // MARK: - 4【citation 缝】assistant 落盘剥离

    /// codex citations.rs 语义双侧断言：可见文本剥离（seal 返回值替换 text 块）
    /// + citation 条目持久保留（接线侧在返回前可完整解析载荷）；reasoning/
    /// toolCall 块原位；nil 缝与恒等缝零扰动。
    func testAssistantSealStripsCitationsAndPreservesOtherBlocks() async {
        let original = "答案 A <oai-mem-citation><rollout_ids>r-1</rollout_ids>"
            + "</oai-mem-citation> 答案 B"
        let blocks: [ContentBlock] = [
            .reasoning("思考"),
            .text(original),
            .toolCall(id: "call-1", name: "read", arguments: "{}"),
        ]

        // 剥离闭包 = 接线侧用法示例：先消费载荷（条目持久保留），再返回可见文本。
        let seal: @Sendable (text: String, sessionId: String, turn: Int, step: Int)
            async -> String = { text, _, _, _ in
                let payload = MemoryCitations.extractCitations(from: text)
                XCTAssertNotNil(payload, "接线侧必须拿得到 citation 载荷")
                return MemoryCitations.splitCitations(from: text).visible
            }
        let sealed = await AgentLoop.applyAssistantSeal(
            seal, blocks: blocks, sessionId: "s", turn: 3, step: 2)
        XCTAssertEqual(sealed.count, 3)
        guard case .reasoning(let reasoning) = sealed[0] else {
            return XCTFail("reasoning 块必须原位保留")
        }
        XCTAssertEqual(reasoning, "思考")
        guard case .text(let visible) = sealed[1] else {
            return XCTFail("text 块必须被剥离后文本替换")
        }
        XCTAssertEqual(visible, "答案 A  答案 B", "可见文本剥离 citation 标记")
        guard case .toolCall(let callId, let name, let arguments) = sealed[2] else {
            return XCTFail("toolCall 块必须原位保留")
        }
        XCTAssertEqual(callId, "call-1")
        XCTAssertEqual(name, "read")
        XCTAssertEqual(arguments, "{}")

        // 载荷持久保留：同文本在剥离前可完整解析（条目不进落盘正文，归接线侧）。
        XCTAssertEqual(MemoryCitations.extractCitations(from: original)?.rolloutIds,
                       ["r-1"])

        // nil 缝 = 原样落盘（零扰动）。
        let untouched = await AgentLoop.applyAssistantSeal(
            nil, blocks: blocks, sessionId: "s", turn: 3, step: 2)
        XCTAssertEqual(untouched, blocks)

        // 恒等缝（返回原文）= 原样落盘（零扰动）。
        let identity: @Sendable (text: String, sessionId: String, turn: Int,
                                 step: Int) async -> String = { $0 }
        let same = await AgentLoop.applyAssistantSeal(
            identity, blocks: blocks, sessionId: "s", turn: 3, step: 2)
        XCTAssertEqual(same, blocks)
    }
}
