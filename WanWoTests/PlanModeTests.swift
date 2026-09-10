//
//  PlanModeTests.swift
//  WanWoTests
//
//  【M3 T3 单测】计划模式：plan/mode 折叠恢复（last wins / 无记录 inactive）+
//  commit noop/changed + 叙述消息 + plan:policy 段落门控（{{plan_policy}} 变量）
//  + exit_plan_mode 四段守卫（非 plan mode / 无 # 标题 / 无通道 / 落盘失败）
//  + 批准路径（双事件：extension + narration 不注入）+ keep-planning 逐字反馈
//  + ASK_CANCELLED 特判 + firstHeading 词法。
//  出处：dsh plan-mode index.ts（execute/set/fold 1:1）+ user-questions BAD_INTENT。
//

import XCTest
@testable import WanWo

@MainActor
final class PlanModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ExtensionEventRegistry.shared.resetForTests()
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: PlanModeController.modeEventKind,
            requiredFields: [ExtensionFieldSchema("active", .bool)],
            projection: .logOnly,
            pairing: .none))
    }

    override func tearDown() {
        ExtensionEventRegistry.shared.resetForTests()
        super.tearDown()
    }

    // MARK: - 助手

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "test-session",
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

    private func makeController(_ writer: SessionWriter) -> PlanModeController {
        PlanModeController(writer: writer, assembler: PromptAssembler())
    }

    private func makeTool(_ controller: PlanModeController,
                          _ service: UserQuestionService) -> ExitPlanModeTool {
        ExitPlanModeTool(controller: controller, service: service)
    }

    private func makeContext(callId: String) -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test", turn: 1, step: 1, callId: callId,
            workspace: WorkspaceFileAccess(sessionId: "test"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: nil)
    }

    private func planArgs(_ plan: String) -> JSONValue {
        .object(["plan": .string(plan)])
    }

    /// 等待 presenter 收到提问（ask 在后台任务呈现——轮询至登记出现）。
    private func waitForPresentation(_ presenter: RecordingPresenter) async throws {
        for _ in 0..<200 where presenter.questionsPresented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let samplePlan = "# Ship it\n\n1. do the thing"

    // MARK: - 折叠恢复（resume/fork；dsh plan projection fold）

    func testFoldLastWinsAndDefaultsInactive() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 无记录 → inactive（dsh：a log with none folds to inactive）。
        let cold = makeController(writer)
        XCTAssertFalse(cold.isActive)

        _ = try await writer.append(.extensionEvent(
            kind: PlanModeController.modeEventKind, payload: .object(["active": .bool(true)])))
        _ = try await writer.append(.extensionEvent(
            kind: PlanModeController.modeEventKind, payload: .object(["active": .bool(false)])))
        _ = try await writer.append(.extensionEvent(
            kind: PlanModeController.modeEventKind, payload: .object(["active": .bool(true)])))
        let restored = makeController(writer)
        XCTAssertTrue(restored.isActive, "last wins 整值替换")

        _ = try await writer.append(.extensionEvent(
            kind: PlanModeController.modeEventKind, payload: .object(["active": .bool(false)])))
        XCTAssertFalse(makeController(writer).isActive)
        _ = cold
    }

    // MARK: - commit（noop / changed / 叙述 / 落盘先于内存）

    func testCommitNoopAndChangedWithNarration() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        let baseline = writer.events.count

        // noop：已是目标态 → 不落任何事件。
        let noop = try await controller.commit(false, narrate: true)
        XCTAssertFalse(noop)
        XCTAssertEqual(writer.events.count, baseline)

        // changed：extension 事件 + 叙述 user 消息（narrate=true）。
        let changed = try await controller.commit(true, narrate: true)
        XCTAssertTrue(changed)
        XCTAssertTrue(controller.isActive, "落盘成功后内存推进")
        let newEvents = Array(writer.events.dropFirst(baseline))
        XCTAssertEqual(newEvents.count, 2)
        guard case .extensionEvent(PlanModeController.modeEventKind, let payload) =
            newEvents[0].payload else {
            return XCTFail("首条应为 plan/mode 扩展事件")
        }
        XCTAssertEqual(payload.field("active")?.boolValue, true)
        guard case .userMessage(let narration) = newEvents[1].payload else {
            return XCTFail("次条应为叙述 user 消息")
        }
        XCTAssertEqual(narration,
                       PlanModeController.narrationPrefix + "\n"
                           + "The user switched this session to plan mode.")

        // 重复 commit(true) → noop。
        let again = try await controller.commit(true, narrate: false)
        XCTAssertFalse(again)
        XCTAssertEqual(writer.events.count, baseline + 2)

        // exit 工具路径：narrate=false（工具结果已叙述）。
        let exitCommit = try await controller.commit(false, narrate: false)
        XCTAssertTrue(exitCommit)
        XCTAssertEqual(writer.events.count, baseline + 3, "narrate=false 只落 extension 事件")
        if case .userMessage? = writer.events.last?.payload {
            XCTFail("narrate=false 不得产生叙述 user 消息")
        }
    }

    // MARK: - plan:policy 段落门控（{{plan_policy}} 变量）

    func testPlanPolicySectionGating() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assembler = PromptAssembler()
        let controller = PlanModeController(writer: writer, assembler: assembler)

        // inactive：变量为空 → plan:policy 段落被丢弃 → system 为空。
        var assembled = try assembler.assemble(toolSchemas: [])
        XCTAssertEqual(assembled.system, "")

        _ = try await controller.commit(true, narrate: false)
        assembled = try assembler.assemble(toolSchemas: [])
        XCTAssertTrue(assembled.system.contains(
            "You are in plan mode. Stay in plan mode until exit_plan_mode succeeds"),
            "active 时 PLAN_POLICY 原文进 system")
        XCTAssertTrue(assembled.system.contains("Make the plan decision-complete"),
                      "六段守则完整渲染")
        // 段落 order=500（dsh PLAN_POLICY 布局位）。
        let order = SECTION_ORDERS.planPolicy
        XCTAssertEqual(order, 500)
    }

    // MARK: - exit_plan_mode 守卫（fail closed 四段）

    func testExitRejectedWhenNotInPlanMode() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        let tool = makeTool(controller, UserQuestionService(presenter: nil))
        let output = try await tool.execute(planArgs(Self.samplePlan),
                                            makeContext(callId: "c1"))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "NOT_IN_PLAN_MODE")
        XCTAssertTrue(output.text.contains("only available in plan mode"))
        XCTAssertEqual(writer.events.count, 0, "守卫拒绝不落任何事件")
    }

    func testExitRejectedWithoutTopLevelHeading() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        _ = try await controller.commit(true, narrate: false)
        let tool = makeTool(controller, UserQuestionService(presenter: nil))
        // 无标题 / 空计划 / 缺 plan 参数——同一拒绝口径（dsh :94-96）。
        for bad in ["1. do the thing", "   ", "## only sub-heading"] {
            let output = try await tool.execute(planArgs(bad), makeContext(callId: "c1"))
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.errorCode, "INVALID_PLAN")
            XCTAssertTrue(output.text.contains("non-empty markdown plan"))
        }
        let missing = try await tool.execute(.object([:]), makeContext(callId: "c1"))
        XCTAssertEqual(missing.errorCode, "INVALID_PLAN")
    }

    func testExitRejectedWithoutReviewChannel() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        _ = try await controller.commit(true, narrate: false)
        let tool = makeTool(controller, UserQuestionService(presenter: nil))
        let output = try await tool.execute(planArgs(Self.samplePlan),
                                            makeContext(callId: "c1"))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "NO_REVIEW_CHANNEL")
        XCTAssertTrue(output.text.contains(
            "no user-questions channel is available to review the plan"))
        XCTAssertTrue(controller.isActive, "拒绝后计划模式保持生效")
    }

    // MARK: - 审阅裁决（恰好一个 Approve 且无 custom）

    func testExitApprovedCommitsInactive() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let controller = makeController(writer)
        _ = try await controller.commit(true, narrate: false)
        let tool = makeTool(controller, UserQuestionService(presenter: presenter))
        let baseline = writer.events.count

        async let output = tool.execute(planArgs(Self.samplePlan), makeContext(callId: "c1"))
        try await waitForPresentation(presenter)
        let accepted = presenter.questionsPresented.count == 1
            && tool.service.answer(requestId: presenter.questionsPresented[0],
                                   AskUserQuestionAnswer(answers: [
                                       AskUserQuestionAnswerItem(
                                           id: ExitPlanModeTool.reviewID,
                                           selected: [ExitPlanModeTool.approveLabel],
                                           custom: nil),
                                   ]))
        XCTAssertTrue(accepted, "提问已呈现且回答已受理")
        let result = try await output
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text,
                       "Plan approved — plan mode exited; carry out the plan "
                           + "starting with your next step.")
        XCTAssertFalse(controller.isActive, "批准后立即退出计划模式")
        // 双事件：extension plan/mode{active:false}；无叙述（narrate=false）。
        let newEvents = Array(writer.events.dropFirst(baseline))
        XCTAssertEqual(newEvents.count, 1)
        guard case .extensionEvent(PlanModeController.modeEventKind, let payload) =
            newEvents[0].payload else {
            return XCTFail("应为 plan/mode 扩展事件")
        }
        XCTAssertEqual(payload.field("active")?.boolValue, false)
    }

    func testExitKeepPlanningCarriesVerbatimFeedback() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        _ = try await controller.commit(true, narrate: false)
        let presenter = RecordingPresenter()
        let tool = makeTool(controller, UserQuestionService(presenter: presenter))

        // custom 反馈 → 逐字回传（dsh :139-141）。
        async let withFeedback = tool.execute(planArgs(Self.samplePlan),
                                              makeContext(callId: "c1"))
        try await waitForPresentation(presenter)
        _ = tool.service.answer(requestId: presenter.questionsPresented[0],
                                AskUserQuestionAnswer(answers: [
                                    AskUserQuestionAnswerItem(
                                        id: ExitPlanModeTool.reviewID,
                                        selected: [ExitPlanModeTool.keepPlanningLabel],
                                        custom: "add rollback tests"),
                                ]))
        var output = try await withFeedback
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "PLAN_REJECTED")
        XCTAssertEqual(output.text,
                       "Error: The user chose to keep planning; their feedback: add rollback tests")
        XCTAssertTrue(controller.isActive, "keep planning 保持计划模式")

        // 无 custom → 固定文案。
        async let withoutFeedback = tool.execute(planArgs(Self.samplePlan),
                                                 makeContext(callId: "c2"))
        for _ in 0..<200 where presenter.questionsPresented.count < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = tool.service.answer(requestId: presenter.questionsPresented.last!,
                                AskUserQuestionAnswer(answers: [
                                    AskUserQuestionAnswerItem(
                                        id: ExitPlanModeTool.reviewID,
                                        selected: [ExitPlanModeTool.keepPlanningLabel],
                                        custom: nil),
                                ]))
        output = try await withoutFeedback
        XCTAssertEqual(output.text,
                       "Error: The user chose to keep planning; revise the plan and present it again.")
        XCTAssertEqual(writer.events.filter {
            if case .extensionEvent(PlanModeController.modeEventKind, _) = $0.payload {
                return true
            }
            return false
        }.count, 1, "拒绝路径不落 plan/mode 事件（仅进入时一条）")
    }

    func testExitDismissedReviewStaysInPlanMode() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        _ = try await controller.commit(true, narrate: false)
        let presenter = RecordingPresenter()
        let tool = makeTool(controller, UserQuestionService(presenter: presenter))

        async let output = tool.execute(planArgs(Self.samplePlan), makeContext(callId: "c1"))
        try await waitForPresentation(presenter)
        XCTAssertTrue(tool.service.dismiss(requestId: presenter.questionsPresented[0]))
        let result = try await output
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorCode, "ASK_CANCELLED")
        XCTAssertEqual(result.text,
                       "Error: The user dismissed the plan review to speak instead; "
                           + "stay in plan mode, stop here, and wait for their message.")
        XCTAssertTrue(controller.isActive, "驳回≠失败：留在计划模式等待用户消息")
    }

    // MARK: - 词法与呈现

    func testFirstHeadingLexing() {
        XCTAssertEqual(ExitPlanModeTool.firstHeading("# Title one"), "Title one")
        XCTAssertEqual(ExitPlanModeTool.firstHeading("intro\n## Sub  "),
                       "Sub", "任意层级首个标题 + 尾随空白剥离")
        XCTAssertNil(ExitPlanModeTool.firstHeading("no heading here"))
        XCTAssertNil(ExitPlanModeTool.firstHeading("#nospace"))
        XCTAssertTrue(ExitPlanModeTool.hasTopLevelHeading("  # ok\nbody  "))
        XCTAssertFalse(ExitPlanModeTool.hasTopLevelHeading("##sub only"))
        XCTAssertFalse(ExitPlanModeTool.hasTopLevelHeading("#"))
    }

    func testPresentCallAndResult() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        let tool = makeTool(controller, UserQuestionService(presenter: nil))
        let call = tool.presentCall(planArgs("# My plan\nbody"))
        XCTAssertEqual(call?.title, "My plan")
        XCTAssertEqual(call?.detail, "# My plan\nbody")
        XCTAssertEqual(tool.presentCall(planArgs("no heading"))?.title, "Plan")
        let done = tool.presentResult(planArgs(Self.samplePlan),
                                      .success("Plan approved — plan mode exited."))
        XCTAssertEqual(done?.title, "Plan review")
        XCTAssertEqual(done?.detail, "Plan approved — plan mode exited.")
    }

    // MARK: - 注册面（常驻注册 / interaction 分类免双重审批）

    func testToolRegistrationSurface() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(writer)
        let tool = makeTool(controller, UserQuestionService(presenter: nil))
        XCTAssertEqual(tool.name, "exit_plan_mode")
        XCTAssertEqual(tool.exposure, .direct)
        XCTAssertNil(tool.timeoutMs, "人类审阅不设 deadline")
        XCTAssertEqual(tool.parameters.field("required")?.arrayItems?.first?.stringValue,
                       "plan")
        // P1-3：exit_plan_mode 无 sandbox_permissions schema（人机交互工具
        // 结构上不可能触发审批——免双重审批死锁的语义归宿）。
        XCTAssertNil(tool.parameters.field("properties")?.field("sandbox_permissions"))
        XCTAssertNil(tool.parameters.field("properties")?.field("justification"))
        let registry = ToolRegistry()
        registry.register(tool)
        XCTAssertEqual(registry.executionMode(name: "exit_plan_mode", args: .null),
                       .exclusive)
    }
}
