//
//  AskUserToolTests.swift
//  WanWoTests
//
//  【M3 T1 单测 5/5】ask_user_question（F063）：参数映射、BAD_INTENT 校验
//  （dsh user-questions index.ts:115-129 逐条）、回答编码回显、提问结算路径。
//  出处：dsh tool-ask-user index.ts（schema/output/render/execute 1:1）；
//  user-questions types.ts:21-30（intent 按名不按位）；2026-07-29 笔记
//  （N/M answered 计数——skipped 不计入）。
//

import XCTest
@testable import WanWo

@MainActor
final class AskUserToolTests: XCTestCase {

    private func makeService(presenter: (any SessionInteractionPresenter)?)
        -> UserQuestionService {
        UserQuestionService(presenter: presenter)
    }

    private func makeTool(_ service: UserQuestionService) -> AskUserTool {
        AskUserTool(service: service)
    }

    // MARK: 参数映射

    func testDecodeQuestions() throws {
        let args: JSONValue = .object([
            "questions": .array([
                .object([
                    "id": .string("q1"),
                    "question": .string("继续吗？"),
                    "header": .string("确认"),
                    "options": .array([
                        .object(["label": .string("是 (Recommended)"),
                                 "description": .string("继续执行")]),
                        .object(["label": .string("否")]),
                    ]),
                    "multi_select": .bool(false),
                ]),
            ]),
        ])
        let questions = try AskUserTool.decodeQuestions(args)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].id, "q1")
        XCTAssertEqual(questions[0].question, "继续吗？")
        XCTAssertEqual(questions[0].header, "确认")
        XCTAssertEqual(questions[0].options?.count, 2)
        XCTAssertEqual(questions[0].multiSelect, false)
    }

    func testDecodeQuestionsRejectsMissingRequiredFields() {
        // 缺 id / question —— schema required 的运行时复核（fail closed）。
        let missingID: JSONValue = .object(["questions": .array([
            .object(["question": .string("x")]),
        ])])
        XCTAssertThrowsError(try AskUserTool.decodeQuestions(missingID))
        let missingQuestion: JSONValue = .object(["questions": .array([
            .object(["id": .string("a")]),
        ])])
        XCTAssertThrowsError(try AskUserTool.decodeQuestions(missingQuestion))
        let missingArray: JSONValue = .object(["other": .null])
        XCTAssertThrowsError(try AskUserTool.decodeQuestions(missingArray))
    }

    // MARK: BAD_INTENT（dsh index.ts:115-129 逐条）

    func testBadIntentApproveNotInOptions() async throws {
        let presenter = RecordingPresenter()
        let service = makeService(presenter: presenter)
        do {
            _ = try await service.ask(questions: [
                AskUserQuestionItem(
                    id: "q1", question: "批准计划？", detail: "计划正文",
                    header: nil,
                    options: [AskUserQuestionOption(label: "不改", description: nil)],
                    multiSelect: nil,
                    intent: AskUserQuestionIntent(kind: "plan-review", approve: "Approve")),
            ], callId: nil)
            XCTFail("BAD_INTENT must throw")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "BAD_INTENT")
            XCTAssertTrue(error.message.contains("Approve"))
        }
        XCTAssertTrue(presenter.questionsPresented.isEmpty, "校验失败不得呈现")
    }

    func testBadIntentWithoutDetail() async throws {
        let presenter = RecordingPresenter()
        let service = makeService(presenter: presenter)
        do {
            _ = try await service.ask(questions: [
                AskUserQuestionItem(
                    id: "q1", question: "批准计划？", detail: nil, header: nil,
                    options: [AskUserQuestionOption(label: "Approve", description: nil)],
                    multiSelect: nil,
                    intent: AskUserQuestionIntent(kind: "plan-review", approve: "Approve")),
            ], callId: nil)
            XCTFail("BAD_INTENT must throw")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "BAD_INTENT")
            XCTAssertTrue(error.message.contains("detail"))
        }
        XCTAssertTrue(presenter.questionsPresented.isEmpty)
    }

    func testEmptyQuestionsRejected() async {
        let service = makeService(presenter: nil)
        do {
            _ = try await service.ask(questions: [], callId: nil)
            XCTFail("EMPTY_QUESTIONS must throw")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "EMPTY_QUESTIONS")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// 无 answerer（presenter nil）→ NO_PROVIDER fail closed（dsh :130-133）。
    func testNoProviderFailsClosed() async throws {
        let service = makeService(presenter: nil)
        do {
            _ = try await service.ask(questions: [
                AskUserQuestionItem(id: "q1", question: "？", detail: nil, header: nil,
                                    options: nil, multiSelect: nil, intent: nil),
            ], callId: nil)
            XCTFail("NO_PROVIDER must throw")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "NO_PROVIDER")
        }
    }

    // MARK: 回答路径（ask → answer 回流；编码 id 稳定回显）

    func testAskAnswerRoundTrip() async throws {
        let presenter = RecordingPresenter()
        let service = makeService(presenter: presenter)
        let questions = [
            AskUserQuestionItem(id: "q1", question: "？", detail: nil, header: nil,
                                options: nil, multiSelect: nil, intent: nil),
        ]
        async let answer = service.ask(questions: questions, callId: "call-9")
        for _ in 0..<200 where presenter.questionsPresented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(presenter.questionsPresented.count, 1)
        XCTAssertTrue(service.answer(requestId: presenter.questionsPresented[0],
                                     AskUserQuestionAnswer(answers: [
                                        AskUserQuestionAnswerItem(id: "q1",
                                                                  selected: ["是"],
                                                                  custom: "补充说明"),
                                     ])))
        let result = try await answer
        XCTAssertEqual(result.answers.count, 1)
        XCTAssertEqual(result.answers[0].id, "q1")
        XCTAssertEqual(result.answers[0].selected, ["是"])
        XCTAssertEqual(result.answers[0].custom, "补充说明")

        // 渲染：JSON 文本（dsh output.render JSON.stringify；custom 缺省省略）。
        let rendered = AskUserTool.renderAnswer(result)
        let parsed = try XCTUnwrap(JSONValue(data: Data(rendered.utf8)))
        let first = try XCTUnwrap(parsed.field("answers")?.arrayItems?.first)
        XCTAssertEqual(first.field("id")?.stringValue, "q1")
        XCTAssertEqual(first.field("custom")?.stringValue, "补充说明")
    }

    /// 用户关闭整组提问 → ASK_CANCELLED（中性结算态）。
    func testDismissCancels() async throws {
        let presenter = RecordingPresenter()
        let service = makeService(presenter: presenter)
        let questions = [
            AskUserQuestionItem(id: "q1", question: "？", detail: nil, header: nil,
                                options: nil, multiSelect: nil, intent: nil),
        ]
        async let askResult = service.ask(questions: questions, callId: nil)
        for _ in 0..<200 where presenter.questionsPresented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(service.dismiss(requestId: presenter.questionsPresented[0]))
        do {
            _ = try await askResult
            XCTFail("dismissal must throw ASK_CANCELLED")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "ASK_CANCELLED")
        }
        XCTAssertEqual(presenter.questionsSettled.count, 1, "结算呈现已通知")
    }

    // MARK: 工具执行（execute：错误码透传 / 成功 JSON 回流）

    func testExecuteSurfacesErrorCodes() async throws {
        let service = makeService(presenter: nil) // 无 answerer
        let tool = makeTool(service)
        let ctx = makeContext(callId: "call-1")
        let output = try await tool.execute(
            .object(["questions": .array([
                .object(["id": .string("q1"), "question": .string("？")]),
            ])]), ctx)
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "NO_PROVIDER")
    }

    func testPresentResultVerdicts() {
        let service = makeService(presenter: nil)
        let tool = makeTool(service)
        let args: JSONValue = .object(["questions": .array([
            .object(["id": .string("q1"), "question": .string("？")]),
            .object(["id": .string("q2"), "question": .string("？？")]),
        ])])

        // 成功：2 问 1 答（q2 skipped——空 selected 无 custom 不计入）。
        let success = ToolOutput(
            text: AskUserTool.renderAnswer(AskUserQuestionAnswer(answers: [
                AskUserQuestionAnswerItem(id: "q1", selected: ["是"], custom: nil),
                AskUserQuestionAnswerItem(id: "q2", selected: [], custom: nil),
            ])),
            isError: false, errorName: nil, errorCode: nil, meta: nil)
        XCTAssertEqual(tool.presentResult(args, success)?.title,
                       "ask_user_question · 1/2 已回答")

        // 取消 / 中断的行内语义（dsh 2026-07-29 笔记矩阵）。
        let cancelled = ToolOutput.failure("dismissed", code: "ASK_CANCELLED",
                                           name: "UserQuestionError")
        XCTAssertEqual(tool.presentResult(args, cancelled)?.title,
                       "ask_user_question · 已取消")
        let aborted = ToolOutput.failure("aborted", code: "ASK_ABORTED",
                                         name: "UserQuestionError")
        XCTAssertEqual(tool.presentResult(args, aborted)?.title,
                       "ask_user_question · 已中断")

        // 畸形结果回落通用卡（fail-closed 兜底）。
        XCTAssertNil(tool.presentResult(args, ToolOutput.success("not-json")))
        XCTAssertNil(tool.presentResult(args, ToolOutput.failure("x")))
    }

    // MARK: 工具注册面

    func testToolRegistrationSurface() {
        let tool = makeTool(makeService(presenter: nil))
        XCTAssertEqual(tool.name, "ask_user_question")
        XCTAssertEqual(tool.exposure, .direct)
        XCTAssertNil(tool.timeoutMs, "人类回答耗时不可预算，不设 deadline")
        // isConcurrencySafe 缺省 false → exclusive 屏障（审批/提问不参与并行池）。
        let registry = ToolRegistry()
        registry.register(tool)
        XCTAssertEqual(registry.executionMode(name: "ask_user_question", args: .null),
                       .exclusive)
        // schema 常驻（required: questions）。
        XCTAssertEqual(tool.parameters.field("required")?.arrayItems?.first?.stringValue,
                       "questions")
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
}
