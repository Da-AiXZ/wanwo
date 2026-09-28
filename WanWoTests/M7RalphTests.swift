//
//  M7RalphTests.swift
//  WanWoTests
//
//  【M7.4 件 K · F048 单测】Ralph 固定编排 + 工具防御解码（派单落点⑨断言面；
//  语义源 tool-ralph/src/index.ts 行为面）：
//    - readRunResult 四终止态（complete/blocked/budget-limited/round-failed）
//      防御解码：键集排序精确匹配 / budget-limited 须 roundsStarted==maxRounds /
//      首轮 round-failed lastReport 必须 null / 后续轮缺 lastReport 拒绝 /
//      未知 status 拒绝。
//    - 交接帽：宿主侧 oversized handoff（16384）+ 脚本侧 validateReport 帽
//      （经引擎全循环——structured 报告超帽 → 脚本 throw → run error）。
//    - requireFreshProvider 三段文案（未注册 / 缺 outputSchema 能力 / 继承
//      父上下文）。
//    - resolveMaxRounds 两支文案。
//    - 经引擎全循环：continue→complete 收敛 / budget-limited 触底 / 首轮
//      round-failed（structured 缺失 → agent() 溶 null）。
//

import XCTest
@testable import WanWo

final class M7RalphTests: XCTestCase {

    // MARK: - Harness

    /// 脚本化 provider（M7WorkflowTests 同款形态——每轮按 callIndex 交付
    /// structured 报告）。
    final class ScriptedRalphProvider: SubagentProviderProtocol, @unchecked Sendable {
        let name: String
        let capabilities: SubagentCapabilities
        let inheritsParentContext: Bool

        typealias Handler = @Sendable (_ prompt: String, _ callIndex: Int) async throws -> SubagentResult
        private let handler: Handler

        init(name: String,
             capabilities: SubagentCapabilities = SubagentCapabilities.inProcess,
             inheritsParentContext: Bool = false,
             handler: @escaping Handler) {
            self.name = name
            self.capabilities = capabilities
            self.inheritsParentContext = inheritsParentContext
            self.handler = handler
        }

        func start(_ request: SubagentResolvedRequest,
                   seed: [SessionEvent]?) async throws -> SubagentRun {
            let handler = self.handler
            let prompt = request.request.prompt
            let task = Task<SubagentResult, Error> {
                try await handler(prompt, 0)
            }
            // callIndex 无法经 actor 跨实例共享——每轮独立 provider 交付由
            // handler 闭包内计数盒承载（RoundFeed）。
            return SubagentRun(id: request.childId, result: task) {}
        }
    }

    /// 轮次供数盒（线程安全 callIndex 计数 + 逐轮交付表）。
    final class RoundFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let deliver: @Sendable (_ round: Int) -> SubagentResult

        init(deliver: @escaping @Sendable (_ round: Int) -> SubagentResult) {
            self.deliver = deliver
        }

        func next(_ prompt: String) -> SubagentResult {
            lock.lock()
            let round = count
            count += 1
            lock.unlock()
            return deliver(round)
        }

        var taken: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private struct WorkflowTestTimeout: Error {}

    private func withDeadline<T: Sendable>(_ seconds: Double,
                                           _ op: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WorkflowTestTimeout()
            }
            guard let first = try await group.next() else {
                throw WorkflowTestTimeout()
            }
            group.cancelAll()
            return first
        }
    }

    /// continue 形状报告（JSONValue 面——脚本 validateReport 的输入）。
    private func continueReport(summary: String = "working") -> JSONValue {
        .object([
            "status": .string("continue"),
            "summary": .string(summary),
            "evidence": .array([]),
            "nextSteps": .array([.string("keep going")]),
            "blocker": .string(""),
        ])
    }

    private func completeReport() -> JSONValue {
        .object([
            "status": .string("complete"),
            "summary": .string("done"),
            "evidence": .array([.string("verified")]),
            "nextSteps": .array([]),
            "blocker": .string(""),
        ])
    }

    private func blockedReport() -> JSONValue {
        .object([
            "status": .string("blocked"),
            "summary": .string("stuck"),
            "evidence": .array([]),
            "nextSteps": .array([]),
            "blocker": .string("need human input"),
        ])
    }

    private static func makeEngine(runtime: SubagentRuntime,
                                   providerName: String = "scripted") -> WorkflowEngine {
        var config = WorkflowEngineConfig()
        config.provider = providerName
        return WorkflowEngine(config: config, runtime: runtime)
    }

    /// 经引擎跑 Ralph 脚本到终值（绕过工具 execute 的会话面——脚本/参数组装
    /// 与工具 execute 同源：maxTotalAgents=maxRounds + 三字段 args）。
    private static func runRalph(feed: RoundFeed, maxRounds: Int,
                                 maxHandoffChars: Int = 16_384) async throws
        -> (result: WorkflowResult, feed: RoundFeed) {
        let runtime = SubagentRuntime()
        let feedBox = feed
        await runtime.registerProvider(ScriptedRalphProvider(name: "scripted") { _, _ in
            feedBox.next("")
        })
        let engine = makeEngine(runtime: runtime)
        let handle = try await engine.start(WorkflowStartRequest(
            script: RalphTool.script,
            meta: RalphTool.meta,
            args: .object([
                "objective": .string("test objective"),
                "maxRounds": .int(maxRounds),
                "maxHandoffChars": .int(maxHandoffChars),
            ]),
            subagentProvider: "scripted",
            maxTotalAgents: maxRounds,
            parent: WorkflowParent(sessionId: "test-parent", depth: 0, cwd: nil)))
        let result = await handle.result.value
        await handle.dispose()
        return (result, feed)
    }

    // MARK: 经引擎全循环（四终止态中的三支 + 脚本侧帽）

    func testRalphLoopCompleteAfterContinue() async throws {
        let feed = RoundFeed { round in
            switch round {
            case 0: return SubagentResult(output: "", structured: Self.continueReportValue0(),
                                          diagnostic: nil, stopReason: .completed)
            default: return SubagentResult(output: "", structured: Self.completeReportValue(),
                                           diagnostic: nil, stopReason: .completed)
            }
        }
        let (result, _) = try await withDeadline(15) {
            await Self.runRalph(feed: feed, maxRounds: 3)
        }

        XCTAssertEqual(result.stopReason, .completed)
        let decoded = try RalphTool.readRunResult(result.value, maxRounds: 3,
                                                  maxHandoffChars: 16_384)
        guard case .run(let run) = decoded else {
            return XCTFail("expected run terminal, got \(decoded)")
        }
        XCTAssertEqual(run.status, .complete)
        XCTAssertEqual(run.roundsStarted, 2)
        XCTAssertEqual(run.report.evidence, ["verified"])
        XCTAssertEqual(feed.taken, 2)
    }

    func testRalphLoopBudgetLimited() async throws {
        let feed = RoundFeed { _ in
            SubagentResult(output: "", structured: Self.continueReportValue0(),
                           diagnostic: nil, stopReason: .completed)
        }
        let (result, _) = try await withDeadline(15) {
            await Self.runRalph(feed: feed, maxRounds: 2)
        }

        XCTAssertEqual(result.stopReason, .completed)
        let decoded = try RalphTool.readRunResult(result.value, maxRounds: 2,
                                                  maxHandoffChars: 16_384)
        guard case .run(let run) = decoded else {
            return XCTFail("expected run terminal, got \(decoded)")
        }
        // budget-limited 以 continue 形状承载（roundsStarted == maxRounds）。
        XCTAssertEqual(run.status, .`continue`)
        XCTAssertEqual(run.roundsStarted, 2)
        XCTAssertEqual(feed.taken, 2)
    }

    func testRalphRoundFailedFirstRoundHasNullHandoff() async throws {
        // structured 缺失 → schema 场景 "completed without a structured value
        // is a child failure" → agent() 溶 null → round-failed。
        let feed = RoundFeed { _ in
            SubagentResult(output: "plain text", structured: nil,
                           diagnostic: nil, stopReason: .completed)
        }
        let (result, _) = try await withDeadline(15) {
            await Self.runRalph(feed: feed, maxRounds: 3)
        }

        XCTAssertEqual(result.stopReason, .completed)
        let decoded = try RalphTool.readRunResult(result.value, maxRounds: 3,
                                                  maxHandoffChars: 16_384)
        guard case .roundFailed(let failure) = decoded else {
            return XCTFail("expected round-failed terminal, got \(decoded)")
        }
        XCTAssertEqual(failure.roundsStarted, 1)
        XCTAssertNil(failure.lastReport)
        // 渲染面：无前次交接文案（index.ts:387 逐字）。
        let rendered = RalphTool.renderRoundFailure(failure, maxChars: 16_384)
        XCTAssertTrue(rendered.contains("Ralph round 1 child failed before producing a structured report."))
        XCTAssertTrue(rendered.contains("No previous handoff was available."))
    }

    func testRalphScriptSideHandoffCap() async throws {
        // 脚本侧 validateReport 帽：20000 字符 summary > 16384 → throw →
        // run error（"Ralph round report exceeds maxHandoffChars (N > M)"）。
        let oversized = String(repeating: "x", count: 20_000)
        let feed = RoundFeed { _ in
            SubagentResult(output: "", structured: Self.continueReport(summary: oversized),
                           diagnostic: nil, stopReason: .completed)
        }
        let (result, _) = try await withDeadline(15) {
            await Self.runRalph(feed: feed, maxRounds: 2)
        }

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertTrue(result.error?.contains("exceeds maxHandoffChars") ?? false,
                      "error: \(result.error ?? "nil")")
        XCTAssertTrue(result.error?.contains("16384") ?? false)
    }

    // MARK: readRunResult 防御解码（宿主侧纯函数面）

    private static func continueReportValue0() -> JSONValue { continueReportValue() }
    private static func continueReportValue() -> JSONValue {
        .object([
            "status": .string("continue"),
            "summary": .string("working"),
            "evidence": .array([]),
            "nextSteps": .array([.string("keep going")]),
            "blocker": .string(""),
        ])
    }
    private static func completeReportValue() -> JSONValue {
        .object([
            "status": .string("complete"),
            "summary": .string("done"),
            "evidence": .array([.string("verified")]),
            "nextSteps": .array([]),
            "blocker": .string(""),
        ])
    }
    private static func blockedReportValue() -> JSONValue {
        .object([
            "status": .string("blocked"),
            "summary": .string("stuck"),
            "evidence": .array([]),
            "nextSteps": .array([]),
            "blocker": .string("need human input"),
        ])
    }

    private static func terminal(status: String, roundsStarted: Int,
                                 report: JSONValue) -> JSONValue {
        .object([
            "status": .string(status),
            "roundsStarted": .int(roundsStarted),
            "report": report,
        ])
    }

    func testReadRunResultAcceptsAllRunShapes() throws {
        // complete。
        let complete = try RalphTool.readRunResult(
            Self.terminal(status: "complete", roundsStarted: 2,
                          report: Self.completeReportValue()),
            maxRounds: 5, maxHandoffChars: 16_384)
        guard case .run(let run) = complete else {
            return XCTFail("expected run")
        }
        XCTAssertEqual(run.status, .complete)
        XCTAssertEqual(run.roundsStarted, 2)
        XCTAssertEqual(run.report.blocker, "")

        // blocked。
        let blocked = try RalphTool.readRunResult(
            Self.terminal(status: "blocked", roundsStarted: 1,
                          report: Self.blockedReportValue()),
            maxRounds: 5, maxHandoffChars: 16_384)
        guard case .run(let blockedRun) = blocked else {
            return XCTFail("expected run")
        }
        XCTAssertEqual(blockedRun.status, .blocked)
        XCTAssertEqual(blockedRun.report.blocker, "need human input")

        // budget-limited：roundsStarted == maxRounds 才合法。
        let budget = try RalphTool.readRunResult(
            Self.terminal(status: "budget-limited", roundsStarted: 4,
                          report: Self.continueReportValue()),
            maxRounds: 4, maxHandoffChars: 16_384)
        guard case .run(let budgetRun) = budget else {
            return XCTFail("expected run")
        }
        XCTAssertEqual(budgetRun.status, .`continue`)
        XCTAssertEqual(budgetRun.roundsStarted, 4)
    }

    func testReadRunResultBudgetLimitedBeforeLimitRejected() {
        XCTAssertThrowsError(try RalphTool.readRunResult(
            Self.terminal(status: "budget-limited", roundsStarted: 2,
                          report: Self.continueReportValue()),
            maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("budget-limited before the round limit"))
        }
    }

    func testReadRunResultRoundFailedShapes() throws {
        // 首轮：lastReport 必须 null。
        let first = try RalphTool.readRunResult(
            .object([
                "status": .string("round-failed"),
                "roundsStarted": .int(1),
                "lastReport": .null,
            ]),
            maxRounds: 5, maxHandoffChars: 16_384)
        guard case .roundFailed(let firstFailure) = first else {
            return XCTFail("expected round-failed")
        }
        XCTAssertEqual(firstFailure.roundsStarted, 1)
        XCTAssertNil(firstFailure.lastReport)

        // 首轮带 report → 拒绝（:313-316）。
        XCTAssertThrowsError(try RalphTool.readRunResult(
            .object([
                "status": .string("round-failed"),
                "roundsStarted": .int(1),
                "lastReport": Self.continueReportValue(),
            ]),
            maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("invalid first-round failure"))
        }

        // 后续轮：lastReport 缺失（null）→ 拒绝（:319-321）。
        XCTAssertThrowsError(try RalphTool.readRunResult(
            .object([
                "status": .string("round-failed"),
                "roundsStarted": .int(3),
                "lastReport": .null,
            ]),
            maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("without its last handoff"))
        }

        // 后续轮带 continue 交接 → 合法。
        let later = try RalphTool.readRunResult(
            .object([
                "status": .string("round-failed"),
                "roundsStarted": .int(3),
                "lastReport": Self.continueReportValue(),
            ]),
            maxRounds: 5, maxHandoffChars: 16_384)
        guard case .roundFailed(let laterFailure) = later else {
            return XCTFail("expected round-failed")
        }
        XCTAssertEqual(laterFailure.roundsStarted, 3)
        XCTAssertNotNil(laterFailure.lastReport)
    }

    func testReadRunResultMalformedShapes() {
        // 未知 status。
        XCTAssertThrowsError(try RalphTool.readRunResult(
            Self.terminal(status: "mystery", roundsStarted: 1,
                          report: Self.completeReportValue()),
            maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("unknown terminal status"))
        }
        // 键集多余字段。
        var extra = Self.terminal(status: "complete", roundsStarted: 1,
                                  report: Self.completeReportValue())
        guard case .object(var fields) = extra else {
            return XCTFail("unreachable")
        }
        fields["extra"] = .int(1)
        extra = .object(fields)
        XCTAssertThrowsError(try RalphTool.readRunResult(
            extra, maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("malformed terminal result"))
        }
        // roundsStarted 越界。
        XCTAssertThrowsError(try RalphTool.readRunResult(
            Self.terminal(status: "complete", roundsStarted: 6,
                          report: Self.completeReportValue()),
            maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("malformed terminal result"))
        }
        // 非 object。
        XCTAssertThrowsError(try RalphTool.readRunResult(
            .string("nope"), maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("malformed terminal result"))
        }
    }

    func testHostSideHandoffCap() {
        // 宿主侧 16384 帽：readReport oversized 拒绝（:273-276 文案）。
        let oversized = String(repeating: "x", count: 20_000)
        let report = Self.terminal(status: "complete", roundsStarted: 1,
                                   report: Self.continueReport(summary: oversized))
        XCTAssertThrowsError(try RalphTool.readRunResult(
            report, maxRounds: 5, maxHandoffChars: 16_384)) { error in
            XCTAssertTrue("\(error)".contains("oversized handoff"))
        }
    }

    // MARK: requireFreshProvider / resolveMaxRounds（文案逐字）

    func testRequireFreshProviderTexts() async throws {
        let runtime = SubagentRuntime()
        await runtime.registerProvider(ScriptedRalphProvider(
            name: "forkish", inheritsParentContext: true) { _, _ in
            SubagentResult(output: "", structured: nil, diagnostic: nil,
                           stopReason: .completed)
        })

        // 未注册。
        do {
            _ = try await RalphTool.requireFreshProvider(runtime, name: "ghost")
            XCTFail("expected not-registered")
        } catch {
            XCTAssertEqual("\(error)",
                           "Ralph subagent provider \"ghost\" is not registered")
        }
        // 继承父上下文。
        do {
            _ = try await RalphTool.requireFreshProvider(runtime, name: "forkish")
            XCTFail("expected inherits-parent rejection")
        } catch {
            XCTAssertEqual("\(error)",
                           "Ralph subagent provider \"forkish\" inherits parent context; Ralph requires a fresh provider")
        }
        // 合格 fresh provider（缺省 capabilities.outputSchema=true）通过。
        await runtime.registerProvider(ScriptedRalphProvider(name: "fresh") { _, _ in
            SubagentResult(output: "", structured: nil, diagnostic: nil,
                           stopReason: .completed)
        })
        XCTAssertNoThrow(try await RalphTool.requireFreshProvider(runtime, name: "fresh"))
    }

    func testResolveMaxRoundsTexts() {
        // 缺省 → ceiling。
        XCTAssertEqual(try? RalphTool.resolveMaxRounds(nil, ceiling: 256), 256)
        do {
            _ = try RalphTool.resolveMaxRounds(0, ceiling: 256)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual("\(error)", "Ralph maxRounds must be a positive safe integer")
        }
        do {
            _ = try RalphTool.resolveMaxRounds(300, ceiling: 256)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual("\(error)",
                           "Ralph maxRounds 300 exceeds the deployment ceiling 256")
        }
    }

    // MARK: 渲染面（boundResult / stopReasonError）

    func testBoundResultTruncation() {
        XCTAssertEqual(RalphTool.boundResult("short", maxChars: 100), "short")
        // 边界：maxChars ≤ notice 长度 → notice 前缀。
        XCTAssertEqual(RalphTool.boundResult("long text", maxChars: 3), "\n… ")
        // 正常截断：保留包络 + 截断标记。
        let text = String(repeating: "a", count: 50)
        let bounded = RalphTool.boundResult(text, maxChars: 20)
        XCTAssertEqual(bounded.count, 20)
        XCTAssertTrue(bounded.hasSuffix("\n… [truncated]"))
    }

    func testRalphStopReasonErrorTexts() {
        XCTAssertEqual(RalphTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .completed, error: nil, agentsStarted: 0)), nil)
        XCTAssertEqual(RalphTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .cancelled, error: nil, agentsStarted: 0)),
            "Ralph workflow was cancelled")
        XCTAssertEqual(RalphTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .cancelled, error: "reason", agentsStarted: 0)),
            "Ralph workflow was cancelled (reason)")
        XCTAssertEqual(RalphTool.stopReasonError(WorkflowResult(
            value: .null, stopReason: .error, error: "boom", agentsStarted: 0)),
            "Ralph workflow failed: boom")
    }

    func testRalphScriptAndMetaAnchors() {
        // 固定编排逐字锚点（内嵌面防漂移）。
        XCTAssertTrue(RalphTool.script.contains("const reportSchema = {"))
        XCTAssertTrue(RalphTool.script.contains("'continue', 'complete', 'blocked'"))
        XCTAssertTrue(RalphTool.script.contains("exceeds maxHandoffChars"))
        XCTAssertTrue(RalphTool.script.contains("phase('Fresh-agent rounds')"))
        XCTAssertTrue(RalphTool.script.contains("'Ralph round ' + round"))
        XCTAssertTrue(RalphTool.script.contains("return { status: 'budget-limited', roundsStarted: args.maxRounds, report: previous }"))
        XCTAssertEqual(RalphTool.meta.name, "ralph-loop")
        XCTAssertEqual(RalphTool.meta.phases?.first?.title, "Fresh-agent rounds")
        XCTAssertTrue(RalphTool.description.contains("Use only when the direct human explicitly asks for Ralph"))
    }
}
