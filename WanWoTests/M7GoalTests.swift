//
//  M7GoalTests.swift
//  WanWoTests
//
//  【M7 件 B · goal/F006 单测】语义源对拍（repos/deepseek-harness-master/
//  packages/goal/）断言点：
//    - CAS（index.ts:447-470 expectCurrent 语义）：id+revision 完全匹配才放行
//      / 投影 nil → GOAL_NOT_FOUND / 不匹配 → GOAL_STALE_REVISION。
//    - 转移矩阵（index.ts:301-445）：create 仅替换 complete 旧 goal / pause
//      active→paused+disarm / resume 拒 roundsStarted≥max / complete+disarm /
//      block 仅 active / clear 墓碑 revision+1。
//    - activation 进程本地：新 GoalService 实例（session-start 等价）恒 disarmed。
//    - fold 轮次推进（fold.ts:321-331）：round===roundsStarted+1 且 ≤max。
//    - 9 错误码 + requireDirectHumanAuthority（authority.ts）。
//

import XCTest
@testable import WanWo

final class M7GoalTests: XCTestCase {

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7goal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "m7-goal",
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

    private func makeService(writer: SessionWriter) async throws -> GoalService {
        GoalEvents.register()
        // goal/change 与 goal/round 都在开放 turn 内落盘（生产路径：工具执行
        // 与轮次 admit 均在 turn 内——测试同构）。
        try await writer.append(.turnStart(turn: 0))
        return GoalService(writer: writer)
    }

    /// async throws 期望失败断言（XCTAssertThrowsError 不支持 async 闭包——
    /// 显式 do/catch 等价）。
    private func assertAsyncThrows(
        _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        do {
            try await body()
            XCTFail("expected thrown error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - create 缺省（index.ts:172-181）

    func testCreateDefaultsAndArms() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        XCTAssertEqual(goal.phase, .active)
        XCTAssertEqual(goal.revision, 1)
        XCTAssertEqual(goal.maxGoalRounds, GoalDomain.defaultMaxGoalRounds)
        XCTAssertEqual(goal.maxGoalRounds, 256)
        XCTAssertEqual(goal.activation, .armed)
        XCTAssertEqual(goal.roundsStarted, 0)
    }

    func testCreateRejectsDuplicateLiveGoal() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        _ = try await service.create(objective: "first")
        let error = await assertAsyncThrows { try await service.create(objective: "second") }
        XCTAssertEqual((error as? GoalError)?.code, .goalAlreadyExists)
    }

    // MARK: - CAS（expectCurrent 对拍）

    func testStaleRevisionRejected() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        // 旧 revision CAS → GOAL_STALE_REVISION。
        let staleRef = GoalRef(id: goal.id, revision: goal.revision)
        _ = try await service.edit(ref: staleRef, objective: "v2", maxGoalRounds: nil)
        let error = await assertAsyncThrows { try await service.edit(
            ref: staleRef, objective: "v3", maxGoalRounds: nil) }
        XCTAssertEqual((error as? GoalError)?.code, .goalStaleRevision)
    }

    func testUnknownGoalRejectedAsNotFound() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let error = await assertAsyncThrows { try await service.pause(
            ref: GoalRef(id: "goal-none", revision: 1)) }
        XCTAssertEqual((error as? GoalError)?.code, .goalNotFound)
    }

    // MARK: - 转移矩阵（index.ts:301-445 对拍）

    func testPauseDisarmsAndResumeReArms() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        // pause：active→paused + disarm（revision+1）。
        let paused = try await service.pause(ref: goal.ref)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.activation, .disarmed)
        XCTAssertEqual(paused.revision, goal.revision + 1)
        // resume：paused→active + arm。
        let resumed = try await service.resume(ref: GoalRef(id: goal.id,
                                                            revision: paused.revision))
        XCTAssertEqual(resumed.phase, .active)
        XCTAssertEqual(resumed.activation, .armed)
    }

    func testResumeRejectsWhenRoundsExhausted() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 1)
        // roundsStarted 推进到 1（= max）。
        try await writer.append(.extensionEvent(
            kind: GoalEvents.roundKind,
            payload: .object(["goalId": .string(goal.id),
                              "revision": .int(goal.revision),
                              "round": .int(1)])))
        let paused = try await service.pause(ref: goal.ref)
        // resume 拒绝 roundsStarted ≥ maxGoalRounds（index.ts:361-380）。
        let error = await assertAsyncThrows { try await service.resume(
            ref: GoalRef(id: goal.id, revision: paused.revision)) }
        XCTAssertEqual((error as? GoalError)?.code, .goalInvalidTransition)
        // 提高上限后 resume 放行（错误文案指示的修复路径）。
        let edited = try await service.edit(
            ref: GoalRef(id: goal.id, revision: paused.revision),
            objective: nil, maxGoalRounds: 3)
        let resumed = try await service.resume(
            ref: GoalRef(id: goal.id, revision: edited.revision))
        XCTAssertEqual(resumed.phase, .active)
    }

    func testCompleteDisarmsAndCreateReplacesCompleteGoal() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        let done = try await service.complete(ref: goal.ref)
        XCTAssertEqual(done.phase, .complete)
        XCTAssertEqual(done.activation, .disarmed)
        // create 仅替换 complete 旧 goal（index.ts:305-317）。
        let next = try await service.create(objective: "Next objective")
        XCTAssertEqual(next.phase, .active)
        XCTAssertNotEqual(next.id, goal.id)
    }

    func testBlockRequiresActiveAndCarriesReason() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        // QA-2 顺带：非法 blocked reason（code 非 kebab）→ GOAL_INVALID_BLOCK_REASON
        // （goal 仍 active——resolveBlockReason 在 phase 校验之后，须先断言）。
        let invalidReason = await assertAsyncThrows { try await service.block(
            ref: goal.ref,
            reason: GoalBlockReason(code: "Not Kebab", message: "x")) }
        XCTAssertEqual((invalidReason as? GoalError)?.code, .goalInvalidBlockReason)
        let blocked = try await service.block(
            ref: goal.ref,
            reason: GoalBlockReason(code: "missing-input",
                                    message: "needs credentials"))
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertEqual(blocked.activation, .disarmed)
        XCTAssertEqual(blocked.blockedReason?.code, "missing-input")
        // blocked 非 active → block 拒绝（index.ts:407-422）。
        let error = await assertAsyncThrows { try await service.block(
            ref: GoalRef(id: blocked.id, revision: blocked.revision),
            reason: GoalBlockReason(code: "again", message: "x")) }
        XCTAssertEqual((error as? GoalError)?.code, .goalInvalidTransition)
    }

    // MARK: - provenance 合并 + stale 守卫（QA-2 P0-3 复验对拍）

    func testNoteTurnProvenanceMergesWithinTurnAndRejectsStaleTurn() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await writer.append(.turnStart(turn: 0))
        let service = GoalService(writer: writer)

        // step0 claim：用户输入建立人类权威。
        await service.noteTurnProvenance(turn: 0, directHuman: true, goalRound: nil)
        // QA-2 关键 bug 形状：step1 空 claim（工具结果步，injected 空 →
        // directHuman=false）——同回合合并，人类权威不丢失。
        await service.noteTurnProvenance(turn: 0, directHuman: false, goalRound: nil)
        do {
            let authority = try await service.completionAuthority(turn: 0)
            guard case .directHuman = authority else {
                XCTFail("step1 空 claim 后 directHuman 权威丢失（合并语义未生效）")
            }
        } catch {
            XCTFail("合并语义下 completionAuthority 应放行 directHuman：\(error)")
        }
        // goalRound 非空才更新（合并进同回合记录）；directHuman OR 合并仍 true。
        await service.noteTurnProvenance(turn: 0, directHuman: false,
                                         goalRound: GoalRef.Round(
                                             goalId: "g", revision: 1, round: 1))
        do {
            let authority = try await service.completionAuthority(turn: 0)
            guard case .directHuman = authority else {
                XCTFail("goalRound 更新不应抹掉 directHuman")
            }
        } catch {
            XCTFail("OR 合并后 completionAuthority 应仍放行：\(error)")
        }

        // stale 跨回合守卫（防御 fence 失效）：turn 0 记录残留到 turn 1 开放
        // 时被拒绝——turn 1 的权威判定恒拒（provenance.turn != ctx.turn 兜底）。
        try await writer.append(.turnEnd(turn: 0, reason: .completed))
        try await writer.append(.turnStart(turn: 1))
        await service.noteTurnProvenance(turn: 1, directHuman: true, goalRound: nil)
        let staleError = await assertAsyncThrows {
            try await service.completionAuthority(turn: 1)
        }
        XCTAssertNotNil(staleError)

        // fence 清账后新回合正常登记（生产路径：turnEnd fence clearTurnProvenance）。
        await service.clearTurnProvenance()
        await service.noteTurnProvenance(turn: 1, directHuman: true, goalRound: nil)
        do {
            let authority = try await service.completionAuthority(turn: 1)
            guard case .directHuman = authority else {
                XCTFail("fence 清账后新回合登记应生效")
            }
        } catch {
            XCTFail("清账后 completionAuthority 应放行：\(error)")
        }
    }

    func testClearLeavesTombstoneWithBumpedRevision() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7")
        let tombstone = try await service.clear(ref: goal.ref)
        XCTAssertEqual(tombstone.id, goal.id)
        XCTAssertEqual(tombstone.revision, goal.revision + 1)
        // 投影 nil（墓碑后无活性 goal）。
        let projected = try await service.get()
        XCTAssertNil(projected)
        // 旧 ref 的 CAS 在墓碑上失守（revision 已 bump）。
        let error = await assertAsyncThrows { try await service.complete(ref: goal.ref) }
        XCTAssertEqual((error as? GoalError)?.code, .goalStaleRevision)
    }

    // MARK: - activation 进程本地（types.ts:70-71 对拍）

    func testFreshServiceInstanceStartsDisarmed() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        _ = try await service.create(objective: "Ship M7")
        // 新实例 = session-start 语义：durable 投影保留，activation 恒 disarmed。
        let restarted = GoalService(writer: writer)
        let view = try await restarted.get()
        XCTAssertEqual(view?.phase, .active)
        XCTAssertEqual(view?.activation, .disarmed)
    }

    // MARK: - fold 轮次推进（fold.ts:321-331 对拍）

    func testFoldAdvancesRoundsOnlyForConsecutiveRounds() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = try await makeService(writer: writer)
        let goal = try await service.create(objective: "Ship M7", maxGoalRounds: 2)
        try await writer.append(.extensionEvent(
            kind: GoalEvents.roundKind,
            payload: .object(["goalId": .string(goal.id),
                              "revision": .int(goal.revision),
                              "round": .int(1)])))
        let view = try await service.get()
        XCTAssertEqual(view?.roundsStarted, 1)
        // round 3 跳跃（≠ roundsStarted+1）：严格 fold 违例 → 软失败（failure
        // 保留首个违例；宿主访问拒绝——index.ts:137-159 对拍）。
        try await writer.append(.extensionEvent(
            kind: GoalEvents.roundKind,
            payload: .object(["goalId": .string(goal.id),
                              "revision": .int(goal.revision),
                              "round": .int(3)])))
        let error = await assertAsyncThrows { _ = try await service.get() }
        XCTAssertEqual((error as? GoalError)?.code, .goalInvalidTransition)
    }

    // MARK: - authority（tool-goal authority.ts 对拍）

    func testRequireDirectHumanAuthorityGatesSubagents() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await writer.append(.turnStart(turn: 0))
        // 子 agent 会话：恒拒绝（isTopLevel=false）。
        let child = GoalService(writer: writer, isTopLevel: false)
        let childError = await assertAsyncThrows {
            try await child.requireDirectHumanAuthority(turn: 0)
        }
        XCTAssertEqual((childError as? GoalToolError)?.code, "GOAL_TOOL_AUTHORITY_REQUIRED")
        // 顶层无 provenance → 拒绝；directHuman provenance → 放行。
        let top = GoalService(writer: writer)
        let noProvenance = await assertAsyncThrows {
            try await top.requireDirectHumanAuthority(turn: 0)
        }
        XCTAssertNotNil(noProvenance)
        await top.noteTurnProvenance(turn: 0, directHuman: true, goalRound: nil)
        do {
            try await top.requireDirectHumanAuthority(turn: 0)
        } catch {
            XCTFail("directHuman provenance 应放行：\(error)")
        }
    }

    // MARK: - prompt 文案（goal-round-driver prompt.ts 对拍）

    func testGoalRoundPromptShape() {
        let goal = GoalView(id: "goal-1", revision: 1, objective: "Ship M7",
                            phase: .active, blockedReason: nil, maxGoalRounds: 5,
                            roundsStarted: 2, createdAt: 0, updatedAt: 0,
                            activation: .armed)
        let text = GoalRoundPrompt.render(goal: goal, round: 3)
        XCTAssertTrue(text.hasPrefix("<goal_round>\n"))
        XCTAssertTrue(text.contains("Round: 3/5\n"))
        XCTAssertTrue(text.contains("Objective: \"Ship M7\"\n"))
        XCTAssertTrue(text.contains("Continue working toward the objective"))
        XCTAssertTrue(text.hasSuffix("</goal_round>"))
    }
}
