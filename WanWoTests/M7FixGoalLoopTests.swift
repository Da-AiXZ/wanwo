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
        let round1Held = await waitUntil { gate.held }
        XCTAssertTrue(round1Held, "轮 1 必须推进到 adapter 闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1],
                       "source 过 injectContexts 不丢——goal/round admitted 落盘")
        XCTAssertTrue(goalRoundTexts(writer).first?.contains("Round: 1/2") == true)

        // 放行 → adapter 抛错 → 轮 1 error 收尾（fence 不动 admitted attempt）
        // → goalDrive 结算消费 → 预约轮 2（round 不跳号）。
        gate.open()
        let round2Held = await waitUntil { gate.held }
        XCTAssertTrue(round2Held, "轮 2 必须再次推进到 adapter 闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1, 2], "同轮序续跑")

        // 放行 → 轮 2 error → roundsStarted(2) ≥ max(2) → block(round-limit)
        // + 大白话 .system 注记。
        gate.open()
        let blockedSeen = await waitView(service) { $0?.phase == .blocked }
        XCTAssertTrue(blockedSeen, "轮次耗尽必须 block")
        let view = try await service.get()
        XCTAssertEqual(view?.phase, .blocked)
        XCTAssertEqual(view?.blockedReason?.code, "round-limit")
        XCTAssertEqual(view?.roundsStarted, 2)
        // 注记 append 排在 service.block 之后（同函数两 await）——waitView
        // 醒来时注记可能尚在落盘，立即读 events 是竞态断言（CI 实证假红）。
        // 改轮询收敛（与 gate/attempt 用例同口径）。
        let noteSeen = await waitUntil {
            systemNotes(writer).contains(
                "目标已到轮次上限（2 轮），已自动标记为 blocked")
        }
        XCTAssertTrue(noteSeen,
                      "round-limit block 必须落用户可见注记")
        await loop.whenIdle()
    }

    // MARK: - 2【dsh 对齐】保留失守 reject 不 disarm → 同轮重预约

    /// 竞争条目插队致 stale → pre-step reject（turn aborted）→ fence 不 disarm
    /// （修复点：旧代码在此 service.disarm()，goal 掉臂后零重试）→ 下一轮
    /// goalDrive 重新注入同一 Round（index.ts:374-383 requestDrive 语义；
    /// round 不跳号：事件流轮次提示词恰为 Round 1、Round 2 连续）。
    ///
    /// CI修23 重构（原实现 CI 假红实证）：reject 触发窗 = 「goalDrive 预约
    /// (.queued) → 驱动器 claim」的 actor 调度缝——wake 先派驱动任务，竞争
    /// submit 的 actor 作业恒排其后（reserve→followup→wake 尾段无 await，
    /// 无再入窗；turnStart 落盘挂起点在 SessionWriter/JsonlEventLog 内部，
    /// 均 final/私有 init 不可测闸）。该窗口为修复语义的固有竞态（dsh 同构
    /// ——validReservation 本就是竞争窗行为），无生产缝可确定性钉住。
    /// 重构为两段：①3 次尝试命中 reject 指纹（尽力而为，命中即在该现场
    /// 全链断言）；②未命中→新建确定性现场，断言同一收敛不变量（armed 不
    /// 掉臂 → 轮 1/2 连续 admitted → round-limit block，round 不跳号）——
    /// reject 专属面（fence 无 attempt 不 disarm）由
    /// testAbortedTurnWithoutAttemptKeepsGoalArmed 确定性承接，本测试不再
    /// 因调度方差假红。
    func testCompetingEntryStaleRejectRedrivesSameRound() async throws {
        // ① 竞态指纹尝试（命中即保留现场供全链断言）。
        var hitWriter: SessionWriter?
        var hitDir: URL?
        var hitService: GoalService?
        var hitLoop: AgentLoop?
        attemptLoop: for _ in 0..<3 {
            let (writer, dir) = try await makeWriter()
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
            if turn1End == .aborted(cause: "goal round reservation invalid") {
                hitWriter = writer
                hitDir = dir
                hitService = service
                hitLoop = loop
                break attemptLoop
            }
            // 未命中：等场景自行收敛（跑完轮 1/2 后 block），弃现场重试。
            _ = await waitView(service, timeout: 10) {
                $0?.phase == .blocked || $0?.phase == .paused
            }
            await loop.whenIdle()
            try? FileManager.default.removeItem(at: dir)
        }

        // ② 全部未命中 → 新建确定性现场（收敛不变量与命中路径同断言）。
        if hitWriter == nil {
            let (writer, dir) = try await makeWriter()
            GoalEvents.register()
            let service = GoalService(writer: writer)
            let loop = makeLoop(sessionId: "m7fix-reject", writer: writer,
                                goalService: service,
                                makeAdapter: throwingAdapter())
            hitWriter = writer
            hitDir = dir
            hitService = service
            hitLoop = loop
            let goal = try await service.create(objective: "Ship M7",
                                                maxGoalRounds: 2)
            await loop.onGoalChanged(GoalChanged(operation: .create, ref: goal.ref,
                                                 goal: goal, origin: .host))
            await loop.submit("competing user input")
        }
        let writer = try XCTUnwrap(hitWriter)
        let dir = try XCTUnwrap(hitDir)
        let service = try XCTUnwrap(hitService)
        let loop = try XCTUnwrap(hitLoop)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 收敛不变量（命中与未命中路径同断言）：armed 不掉臂 → 轮 1/2 连续
        // admitted → round-limit block。
        let redriven = await waitView(service) {
            $0?.phase == .blocked && $0?.roundsStarted == 2
        }
        XCTAssertTrue(redriven,
                      "修复语义：reject 不掉臂，goal 应继续跑完轮 1/2 后 round-limit block")

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
        let firstHeld = await waitUntil { gate.held }
        XCTAssertTrue(firstHeld)

        // 运行中建 goal（armed；onChange 未接线 → 不触发驱动）。
        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 1)

        // 取消 → open 放行 → 回合 aborted(user) → fence：无 attempt 不 disarm。
        await loop.cancel(cause: .user)
        gate.open()

        // 修复语义：goal 仍 armed → idle→goalDrive 预约轮 1 → 注入 + 卡闸。
        let rearmedHeld = await waitUntil { gate.held }
        XCTAssertTrue(rearmedHeld,
                      "aborted 不掉臂：goalDrive 必须预约并推进轮 1（旧代码 disarm 后无此轮）")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1])
        let view = try await service.get()
        XCTAssertEqual(view?.phase, .active, "纯取消不得误 pause（dsh 精确围栏语义）")
        _ = goal

        // 收尾：轮 1 error → roundsStarted(1) ≥ max(1) → block 收敛（可终止）。
        gate.open()
        let fenceBlocked = await waitView(service) { $0?.phase == .blocked }
        XCTAssertTrue(fenceBlocked)
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
        let pauseRoundHeld = await waitUntil { gate.held }
        XCTAssertTrue(pauseRoundHeld, "轮 1 admitted 后卡闸")
        XCTAssertEqual(roundEvents(writer).map(\.round), [1])

        // 用户取消 + 放行 → aborted(user) → fence cancelled → goalDrive pause。
        await loop.cancel(cause: .user)
        gate.open()

        let pausedSeen = await waitView(service) { $0?.phase == .paused }
        XCTAssertTrue(pausedSeen, "围栏必须收敛为 pause（dsh agent/status idle fence）")
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
        let seal: @Sendable (String, String, Int, Int) async -> String = { text, _, _, _ in
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
        let identity: @Sendable (String, String, Int, Int) async -> String = { text, _, _, _ in text }
        let same = await AgentLoop.applyAssistantSeal(
            identity, blocks: blocks, sessionId: "s", turn: 3, step: 2)
        XCTAssertEqual(same, blocks)
    }

    // MARK: - 5【批4 G1】goal 收尾指令对用户隐藏（isMarkerMessage 新前缀）

    /// goal_complete/goal_blocked（GoalWrapup.render——dsh wrapup.ts:17-38
    /// 同族，AgentLoop 经 inject 以 userMessage 落盘）按用户 B4 裁决「给 AI
    /// 的注入纸条对用户完全隐藏」办理：
    ///   ① isMarkerMessage 命中新前缀（拦 ChatViewModel 乐观气泡路径）；
    ///   ② 投影器对 goal_complete userMessage 产零气泡（marker 过滤即 skip）；
    ///   ③ goal_round 专卡特判不受影响（只认 <goal_round>，恒产 gr 卡）；
    ///   ④ 真实用户消息照常渲染（无误伤）。
    func testMarkerPrefixesHideGoalWrapupNotices() {
        // ① 新前缀命中（IMG_2532 实证的两种落盘形态：首行即标签）。
        let complete = "<goal_complete>\nObjective: \"Ship M7\"\n…</goal_complete>"
        let blocked = "<goal_blocked>\nObjective: \"Ship M7\"\nBlocked: \"…\"\n…</goal_blocked>"
        XCTAssertTrue(ConversationProjector.isMarkerMessage(complete))
        XCTAssertTrue(ConversationProjector.isMarkerMessage(blocked))

        // ② 投影器：goal_complete userMessage 不产任何气泡。
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let hidden = ConversationProjector.project(
            events: [SessionEvent(seq: 1, timeMs: 0, payload: .userMessage(text: complete))],
            registry: nil, callArgs: &callArgs)
        XCTAssertTrue(hidden.isEmpty, "goal 收尾指令对用户隐藏（零气泡）")

        // ③ goal_round 特判不受影响：恒产 gr(seq) 专卡。
        let mixed = ConversationProjector.project(
            events: [
                SessionEvent(seq: 2, timeMs: 0, payload: .userMessage(text: complete)),
                SessionEvent(seq: 3, timeMs: 0,
                             payload: .userMessage(text: "<goal_round>\nObjective: \"Ship M7\"\n</goal_round>")),
            ],
            registry: nil, callArgs: &callArgs)
        XCTAssertEqual(mixed.count, 1)
        guard case .goalRound(let text)? = mixed.first?.kind else {
            return XCTFail("goal_round 必须仍走专卡特判")
        }
        XCTAssertTrue(text.hasPrefix("<goal_round>"))

        // ④ 真实用户消息照常渲染（新前缀无误伤）。
        let plain = ConversationProjector.project(
            events: [SessionEvent(seq: 4, timeMs: 0, payload: .userMessage(text: "帮我写个文件"))],
            registry: nil, callArgs: &callArgs)
        XCTAssertEqual(plain.count, 1)
        guard case .user(let text, _)? = plain.first?.kind else {
            return XCTFail("普通用户消息必须照常产泡")
        }
        XCTAssertEqual(text, "帮我写个文件")
    }

    // MARK: - 5b【M7-Fix2 批6 F2】team 队员回传消息对用户隐藏

    /// "Team message {id} from {sender}:"（TeamConstants.deliveryFrame——
    /// TeamTypes.swift:59-61，dsh mailbox deliveryContent :309-314 逐字）为
    /// team 驱动 → AgentLoop 经 userMessage 落账的引擎路径注入纸条。按用户
    /// 裁决（IMG_2550 实证+逐字）「team 队员回传给主 agent 不在对话里用消息
    /// 泡显示出来，后台传给主 agent 就行」办理，B4 同族偏差登记（dsh web 按
    /// 用户消息显示）：
    ///   ① isMarkerMessage 命中注入框架行（引擎路径无乐观哨兵——ChatVM:814
    ///     marker guard 同前缀拦截，双保险）；
    ///   ② 投影器对回传 userMessage 产零气泡（marker 过滤即 skip，隐藏=
    ///     不产 Bubble，exhaustive switch 无需新 case）；
    ///   ③ 真实用户消息照常渲染（无误伤）；
    ///   ④ 误伤面评估：用户手动输入以 "Team message " 开头的文本会被隐藏
    ///     （与 <system-reminder> 等既有前缀同风险等级，dsh 同构，既定取舍）。
    func testMarkerPrefixesHideTeamMemberRelayNotices() {
        // ① 注入框架行逐字命中（deliveryFrame 产物形态）。
        let relay = "Team message team-message-abc from researcher:\n组会要点已整理完毕"
        XCTAssertTrue(ConversationProjector.isMarkerMessage(relay))

        // ② 投影器：team 回传 userMessage 不产任何气泡（后台落账面不变）。
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let hidden = ConversationProjector.project(
            events: [SessionEvent(seq: 1, timeMs: 0, payload: .userMessage(text: relay))],
            registry: nil, callArgs: &callArgs)
        XCTAssertTrue(hidden.isEmpty, "team 回传纸条对用户隐藏（零气泡）")

        // ③ 真实用户消息照常渲染（新前缀无误伤）。
        let plain = ConversationProjector.project(
            events: [SessionEvent(seq: 2, timeMs: 0, payload: .userMessage(text: "帮我把 team 结论整理一下"))],
            registry: nil, callArgs: &callArgs)
        XCTAssertEqual(plain.count, 1)
        guard case .user(let text, _)? = plain.first?.kind else {
            return XCTFail("普通用户消息必须照常产泡")
        }
        XCTAssertEqual(text, "帮我把 team 结论整理一下")
    }

    // MARK: - 6【批4 G2】GoalError errorDescription 人话化

    /// dsh index.ts:373-377 1:1 的 resume 拒绝（rounds exhausted）等三类
    /// 关键语义必须以中文人话透出——修复前被 NSError 包装吞成
    /// "The operation couldn't be completed…"天书（用户复测 A2②）。
    func testGoalErrorLocalizedDescriptionCoversKeySemantics() {
        // rounds exhausted（resume 第 5 次被拒的实况 message 指纹）。
        let exhausted = GoalError(
            message: "goal \"goal-x\" exhausted 4 goal rounds; "
                + "increase maxGoalRounds before resuming",
            code: .goalInvalidTransition)
        let exhaustedText = exhausted.localizedDescription
        XCTAssertFalse(exhaustedText.isEmpty)
        XCTAssertTrue(exhaustedText.contains("轮次已用完"),
                      "rounds exhausted 必须人话化：\(exhaustedText)")
        XCTAssertTrue(exhaustedText.contains("调大轮数"),
                      "必须给出出路（编辑调大轮数）：\(exhaustedText)")

        // stale revision（CAS 失守）。
        let stale = GoalError(message: "stale goal ref", code: .goalStaleRevision)
        let staleText = stale.localizedDescription
        XCTAssertTrue(staleText.contains("目标状态已变化"),
                      "stale revision 必须人话化：\(staleText)")

        // 其余 invalid transition（phase 矩阵拒绝）。
        let transition = GoalError(
            message: "cannot pause goal \"goal-x\" from phase \"complete\"",
            code: .goalInvalidTransition)
        let transitionText = transition.localizedDescription
        XCTAssertTrue(transitionText.contains("不支持该操作"),
                      "invalid transition 必须人话化：\(transitionText)")

        // 其余错误码兜底：领域 message 原文透出（非空、非天书）。
        let fallback = GoalError(message: "no current goal", code: .goalNotFound)
        XCTAssertEqual(fallback.localizedDescription, "no current goal")
    }
}
