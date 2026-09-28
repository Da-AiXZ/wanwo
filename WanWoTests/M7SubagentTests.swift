//
//  M7SubagentTests.swift
//  WanWoTests
//
//  【M7 件 C · 子 agent/F045 单测】语义源对拍（analysis/dsh-upstream-m5/
//  packages/subagent/）断言点：
//    - fork-in-process :48-55 —— completedTurnPrefix：最后一条 turn/end（含）
//      前切片；无完成回合 = 空；seq===index 契约。
//    - depth.ts:28-51 —— delegationDepthOf 单调地板（max(durable, runtime)）
//      + 负值拒绝；child-agent.ts:49-58 —— resolveChildDepth parent+1 / 超
//      maxDepth 抛 SubagentDepthError。
//    - types.ts:252-266 —— stopReason 五值 + blocked→refusal（in-process-driver
//      toStopReason :50-67）。
//    - descriptor.ts —— parse 字段白名单严格 + 版本外返回 nil + fold 首条权威。
//    - run-settlement.ts:37-53 —— runOutcome 映射；tool-subagent :156-173 ——
//      stopReasonError 未知按失败。
//    - SubagentRuntime：非驻留 sendMessage → NOT_RESUMABLE（cold resume 登记
//      不实现的错误面）；provider 未注册 → PROVIDER_NOT_FOUND；spawn 无 seed /
//      fork 有 seed 的 resolved 分派。
//

import XCTest
@testable import WanWo

final class M7SubagentTests: XCTestCase {

    private func event(_ payload: SessionEvent.Payload, seq: Int) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: payload)
    }

    // MARK: - completedTurnPrefix（fork-in-process :48-55 对拍）

    func testCompletedTurnPrefixIncludesLastTurnEnd() {
        let events: [SessionEvent] = [
            event(.turnStart(turn: 0), seq: 0),
            event(.userMessage(text: "u1"), seq: 1),
            event(.turnEnd(turn: 0, reason: .completed), seq: 2),
            event(.turnStart(turn: 1), seq: 3),
            event(.userMessage(text: "in-flight"), seq: 4),
        ]
        let prefix = ForkInProcessProvider.completedTurnPrefix(events)
        // 最后一条 turn/end（seq 2，含）前切片；in-flight turn 排除。
        XCTAssertEqual(prefix.map(\.seq), [0, 1, 2])
    }

    func testCompletedTurnPrefixEmptyWithoutCompletedTurn() {
        let events: [SessionEvent] = [
            event(.turnStart(turn: 0), seq: 0),
            event(.userMessage(text: "in-flight"), seq: 1),
        ]
        // 无完成回合 = 空种子 = 不传 seed（:80-82）。
        XCTAssertTrue(ForkInProcessProvider.completedTurnPrefix(events).isEmpty)
    }

    // MARK: - 深度（depth.ts / child-agent.ts 对拍）

    func testDelegationDepthOfMonotonicFloor() throws {
        // 读取 = max(header, runtime) 单调地板。
        XCTAssertEqual(try SubagentDepth.delegationDepthOf(durableDepth: 1, runtimeDepth: 3), 3)
        XCTAssertEqual(try SubagentDepth.delegationDepthOf(durableDepth: 4, runtimeDepth: 2), 4)
        XCTAssertEqual(try SubagentDepth.delegationDepthOf(durableDepth: nil, runtimeDepth: nil), 0)
        // runtime 负值 = 记账损坏 → 拒绝（depth.ts:31-33）。
        XCTAssertThrowsError(try SubagentDepth.delegationDepthOf(durableDepth: 1,
                                                                 runtimeDepth: -1))
    }

    func testResolveChildDepthAndCap() throws {
        XCTAssertEqual(try SubagentDepth.resolveChildDepth(parentDepth: 0, maxDepth: 3), 1)
        XCTAssertEqual(try SubagentDepth.resolveChildDepth(parentDepth: 2, maxDepth: nil), 3)
        // parent+1 超 maxDepth → SubagentDepthError（child-agent.ts:49-58）。
        XCTAssertThrowsError(try SubagentDepth.resolveChildDepth(parentDepth: 3, maxDepth: 3)) {
            error in
            XCTAssertEqual(error as? SubagentDepthError,
                           SubagentDepthError(attemptedDepth: 4, maxDepth: 3))
        }
        // maxDepth 0 = 禁委派（0 层下任何委派都越界）。
        XCTAssertThrowsError(try SubagentDepth.resolveChildDepth(parentDepth: 0, maxDepth: 0))
        // 负 maxDepth 无法表达精确深度 → 拒绝（depth.ts:42-51）。
        XCTAssertThrowsError(try SubagentDepth.assertSubagentMaxDepth(-1))
        XCTAssertNoThrow(try SubagentDepth.assertSubagentMaxDepth(0))
        XCTAssertNoThrow(try SubagentDepth.assertSubagentMaxDepth(nil))
    }

    // MARK: - stopReason（types.ts:252-266 + in-process-driver :50-67 对拍）

    func testStopReasonMapping() {
        XCTAssertEqual(SubagentStopReason(turnEndReason: .completed).wireName, "completed")
        XCTAssertEqual(SubagentStopReason(turnEndReason: .maxTokens).wireName, "max-tokens")
        XCTAssertEqual(SubagentStopReason(turnEndReason: .aborted(cause: "user")).wireName, "aborted")
        // blocked（pre-step 拒绝）= refusal——任务被拒，不得读作完成。
        XCTAssertEqual(SubagentStopReason(turnEndReason: .blocked).wireName, "refusal")
        XCTAssertEqual(SubagentStopReason(turnEndReason: .error(LlmFailure(
            message: "x", code: "boom"))).wireName, "error")
        XCTAssertEqual(SubagentStopReason(turnEndReason: nil).wireName, "error")
    }

    // MARK: - descriptor（descriptor.ts 对拍）

    private func descriptorPayload(_ fields: [String: JSONValue]) -> JSONValue {
        .object(fields)
    }

    func testDescriptorParseWhitelistAndVersionGate() throws {
        let valid = descriptorPayload([
            "version": .int(3), "mode": .string("one-shot"),
            "provider": .string("spawn"), "label": .string("research"),
        ])
        let parsed = try SubagentDescriptor.parse(valid)
        XCTAssertEqual(parsed?.mode, .oneShot)
        XCTAssertEqual(parsed?.provider, "spawn")
        // 版本外的 descriptor 返回 nil = 本运行时不可分类（descriptor.ts:285-287）。
        var older = valid
        if case .object(var fields) = older { fields["version"] = .int(2); older = .object(fields) }
        XCTAssertNil(try SubagentDescriptor.parse(older))
        // one-shot 白名单外字段 → 抛错（字段集精确）。
        XCTAssertThrowsError(try SubagentDescriptor.parse(descriptorPayload([
            "version": .int(3), "mode": .string("one-shot"),
            "provider": .string("spawn"), "label": .string("x"),
            "persona": .string("nope"),
        ])))
        // continuable 白名单缺 provider → 抛错。
        XCTAssertThrowsError(try SubagentDescriptor.parse(descriptorPayload([
            "version": .int(3), "mode": .string("continuable"),
        ])))
    }

    func testDescriptorFoldFirstEntryWins() {
        let first = descriptorPayload([
            "version": .int(3), "mode": .string("continuable"),
            "provider": .string("fork"), "label": .string("first"),
        ])
        let second = descriptorPayload([
            "version": .int(3), "mode": .string("continuable"),
            "provider": .string("fork"), "label": .string("second"),
        ])
        let events: [SessionEvent] = [
            event(.turnStart(turn: 0), seq: 0),
            event(.extensionEvent(kind: SubagentDescriptor.eventKind, payload: first), seq: 1),
            event(.extensionEvent(kind: SubagentDescriptor.eventKind, payload: second), seq: 2),
        ]
        // 首条权威：后写不可改写已声明组合（descriptor.ts:317-323）。
        XCTAssertEqual(SubagentDescriptor.fold(events: events)?.label, "first")
    }

    // MARK: - run-settlement（run-settlement.ts:37-53 对拍）

    func testRunOutcomeMapping() {
        func result(_ reason: SubagentStopReason, diagnostic: String? = nil,
                    output: String = "final") -> SubagentResult {
            SubagentResult(output: output, structured: nil,
                           diagnostic: diagnostic, stopReason: reason)
        }
        // completed 携带终文本。
        XCTAssertEqual(SubagentSettlement.runOutcome(result(.completed)),
                       JobOutcome(status: .completed, output: "final"))
        // 本地取消（aborted 无 diagnostic）= killed。
        XCTAssertEqual(SubagentSettlement.runOutcome(result(.aborted, diagnostic: nil)),
                       JobOutcome(status: .killed))
        // provider 诊断的远端 abort = failed。
        let diagnosed = SubagentSettlement.runOutcome(result(.aborted, diagnostic: "conn reset"))
        XCTAssertEqual(diagnosed.status, .failed)
        XCTAssertTrue(diagnosed.detail?.contains("aborted") ?? false)
        // error/max-tokens/refusal = failed。
        XCTAssertEqual(SubagentSettlement.runOutcome(result(.maxTokens)).status, .failed)
        XCTAssertEqual(SubagentSettlement.runOutcome(result(.refusal)).status, .failed)
        // 未知（merge-extensible）= failed（绝不夸大成功）。
        XCTAssertEqual(SubagentSettlement.runOutcome(result(.unknown("crash"))).status, .failed)
    }

    func testStopReasonErrorTextAndPartialPreservation() {
        XCTAssertNil(SubagentSettlement.stopReasonError(SubagentResult(
            output: "done", structured: nil, diagnostic: nil, stopReason: .completed)))
        // 非 completed 的 headline + diagnostic + partial output 分离拼接
        //（tool-subagent :183-195）。
        let composed = SubagentSettlement.withDiagnosticAndPartialText(
            "subagent run failed",
            SubagentResult(output: "partial answer", structured: nil,
                           diagnostic: "boom", stopReason: .error))
        XCTAssertTrue(composed.hasPrefix("subagent run failed"))
        XCTAssertTrue(composed.contains("\nDiagnostic: boom"))
        XCTAssertTrue(composed.contains("\nPartial output before the run ended:\npartial answer"))
    }

    // MARK: - SubagentRuntime（index.ts 注册表 + 错误面对拍）

    /// 种子捕获盒（@Sendable 工厂闭包共享）。
    final class SeedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SessionEvent]?
        func note(_ value: [SessionEvent]?) {
            lock.lock(); stored = value; lock.unlock()
        }
        var value: [SessionEvent]? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    func testRuntimeRejectsUnknownProvider() async {
        let runtime = SubagentRuntime()
        do {
            _ = try await runtime.start(provider: "nope", request: SubagentStartRequest(
                prompt: "p", parentSessionId: "s", parentCwd: nil, parentDepth: 0))
            XCTFail("未知 provider 必须 PROVIDER_NOT_FOUND")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "PROVIDER_NOT_FOUND")
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    func testRuntimeStartDispatchesSpawnWithoutSeed() async throws {
        let runtime = SubagentRuntime()
        let probe = SeedBox()
        let factory: SubagentChildFactory = { resolved, seed in
            probe.note(seed)
            XCTAssertFalse(resolved.descriptor.mode == .continuable)
            XCTAssertEqual(resolved.childDepth, 1)
            return makeRunFailable(id: resolved.childId, result: SubagentResult(
                output: "ok", structured: nil, diagnostic: nil, stopReason: .completed))
        }
        await runtime.registerProvider(SpawnInProcessProvider(name: "spawn",
                                                              childFactory: factory))
        let run = try await runtime.start(provider: "spawn", request: SubagentStartRequest(
            prompt: "p", parentSessionId: "parent", parentCwd: nil, parentDepth: 0))
        // spawn = 零父上下文：seed 恒缺省（spawn-in-process :54-58）。
        XCTAssertNil(probe.value)
        let result = try await run.result.value
        XCTAssertEqual(result.output, "ok")
        await run.dispose()
    }

    func testRuntimeStartDispatchesForkWithPrefixSeed() async throws {
        let runtime = SubagentRuntime()
        let probe = SeedBox()
        let factory: SubagentChildFactory = { resolved, seed in
            probe.note(seed)
            return makeRunFailable(id: resolved.childId, result: SubagentResult(
                output: "ok", structured: nil, diagnostic: nil, stopReason: .completed))
        }
        await runtime.registerProvider(ForkInProcessProvider(name: "fork",
                                                             childFactory: factory))
        let parentLog: [SessionEvent] = [
            event(.turnStart(turn: 0), seq: 0),
            event(.userMessage(text: "u1"), seq: 1),
            event(.turnEnd(turn: 0, reason: .completed), seq: 2),
            event(.turnStart(turn: 1), seq: 3),
        ]
        _ = try await runtime.start(provider: "fork", request: SubagentStartRequest(
            prompt: "p", parentSessionId: "parent", parentCwd: nil, parentDepth: 0),
            parentLogEvents: parentLog)
        // fork 种子 = completedTurnPrefix（3 条；in-flight 排除）。
        XCTAssertEqual(probe.value?.map(\.seq), [0, 1, 2])
    }

    func testSendMessageToNonResidentChildIsNotResumable() async {
        let runtime = SubagentRuntime()
        do {
            _ = try await runtime.sendMessage(from: "parent", to: "ghost", text: "hi")
            XCTFail("非驻留子必须 NOT_RESUMABLE（cold resume 登记不实现）")
        } catch let error as SubagentError {
            XCTAssertEqual(error.code, "NOT_RESUMABLE")
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    func testListAgentsEmptyForUnknownCaller() async {
        let runtime = SubagentRuntime()
        let entries = await runtime.listAgents(callerSessionId: "nobody",
                                               includeDescendants: true)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - 终局输出选择（assistant-output.ts 文本面对拍）

    func testFinalAssistantOutputSelection() {
        let events: [SessionEvent] = [
            event(.turnStart(turn: 0), seq: 0),
            event(.assistantMessage(turn: 0, step: 0,
                                    message: AssistantMessage(
                                        id: "a1", provider: "p", model: "m",
                                        content: [.text("earlier")]),
                                    usage: nil, interrupted: false), seq: 1),
            event(.assistantMessage(turn: 0, step: 1,
                                    message: AssistantMessage(
                                        id: "a2", provider: "p", model: "m",
                                        content: [.text("final "), .toolCall(id: "t", name: "x", arguments: "{}")]),
                                    usage: nil, interrupted: false), seq: 2),
        ]
        // 最后一条 assistant 消息的 text 块拼接（toolCall 块不进文本面）。
        XCTAssertEqual(SubagentOutput.finalAssistantOutput(events), "final ")
        // 无 assistant 消息 → nil。
        XCTAssertNil(SubagentOutput.finalAssistantOutput([events[0]]))
    }

    // MARK: - continuable return guidance（continuation-messages.ts:81-97 对拍）

    func testContinuableReturnGuidanceVerbatim() {
        let guided = SubagentRuntime.withContinuableReturnGuidance(
            parentId: "parent-1", prompt: "Do the research.")
        // prompt 前置 + 指引后缀；parentId 经 JSON.stringify 等价编码（带引号）。
        XCTAssertTrue(guided.hasPrefix("Do the research.\n\n"))
        XCTAssertTrue(guided.contains("Your parent agent id is \"parent-1\"."))
        XCTAssertTrue(guided.contains(
            "send_message({ agent_id: \"parent-1\", message: \"<self-contained result>\" })"))
        XCTAssertTrue(guided.contains(
            "The parent shares your workspace but does not automatically receive your transcript"))
        XCTAssertTrue(guided.hasSuffix("sending a message does not end your turn."))
    }

    // MARK: - driver boundary×栈序组合（QA-3 P0-2 对拍）

    /// 万我 fork 子日志真实写序：lineage → descriptor → 种子（父日志副本，
    /// 含父最终 assistant 输出）→ 子自有事件。boundary 必须取"创建窗口结束
    /// 后的实际 eventCount"——旧推导 boundary=seed.count 会把父日志尾部
    /// （assistant 输出）漏进自有段：被 kill 的 fork 假 completed + 父文本
    /// 冒充子输出。
    func testDriverReadResultBoundaryAcrossStackCreationWindow() {
        // 父日志（= fork 种子来源，3 条）。
        let parentLog: [SessionEvent] = [
            event(.userMessage(text: "parent prompt"), seq: 0),
            event(.assistantMessage(turn: 0, step: 0,
                                    message: AssistantMessage(
                                        id: "p1", provider: "p", model: "m",
                                        content: [.text("parent final answer")]),
                                    usage: nil, interrupted: false), seq: 1),
            event(.turnEnd(turn: 0, reason: .completed), seq: 2),
        ]
        // 子日志：lineage(0) descriptor(1) 种子(2..4) + 子自有 turnEnd(5)。
        let childLog: [SessionEvent] = [
            event(.extensionEvent(kind: SubagentLineage.eventKind, payload: .object([
                "origin": .string("subagent"), "parentSession": .string("parent"),
                "delegationDepth": .int(1), "seeded": .bool(true)])), seq: 0),
            event(.extensionEvent(kind: SubagentDescriptor.eventKind, payload: .object([
                "version": .int(3), "mode": .string("one-shot"),
                "provider": .string("fork"), "label": .string("research")])), seq: 1),
            event(parentLog[0].payload, seq: 2),
            event(parentLog[1].payload, seq: 3),
            event(parentLog[2].payload, seq: 4),
            event(.turnEnd(turn: 0, reason: .completed), seq: 5),
        ]
        // 旧推导（boundary = seed.count = 3）：自有段误含父 assistant 输出
        // ——父文本冒充（回归对照，锁定 bug 形状）。
        let buggyOwn = Array(childLog.dropFirst(3))
        XCTAssertEqual(SubagentInProcessDriver.readResult(buggyOwn, cancelled: false).output,
                       "parent final answer")
        // 新语义（boundary = 创建窗口结束后的实际 eventCount = 6）：自有段
        // 只有子 turnEnd——无自有 assistant 输出 = 空串 + error（绝不冒充
        // 父文本、绝不假 completed）。
        let fixedOwn = Array(childLog.dropFirst(childLog.count))
        let result = SubagentInProcessDriver.readResult(fixedOwn, cancelled: false)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.stopReason, .error)
        // 取消旗标：非 completed 记录改写 aborted（:229-230）。
        let aborted = SubagentInProcessDriver.readResult(fixedOwn, cancelled: true)
        XCTAssertEqual(aborted.stopReason, .aborted)
        // 正向：子自有输出在 boundary 之后 → 唯一真源。
        var childWithOwn = childLog
        childWithOwn.append(event(.assistantMessage(turn: 0, step: 0,
                                                    message: AssistantMessage(
                                                        id: "c1", provider: "p", model: "m",
                                                        content: [.text("child answer")]),
                                                    usage: nil, interrupted: false), seq: 6))
        let ownWithOutput = Array(childWithOwn.dropFirst(6))
        XCTAssertEqual(SubagentInProcessDriver.readResult(ownWithOutput, cancelled: false).output,
                       "child answer")
    }
}

/// 测试辅助：SubagentRun 的 failable result 构造（工厂闭包 async 上下文用）。
private func makeRunFailable(id: String, result: SubagentResult) -> SubagentRun {
    SubagentRun(id: id, result: Task<SubagentResult, Error> { result }) { }
}
