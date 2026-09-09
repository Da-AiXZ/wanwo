//
//  T23P0SettlementTests.swift
//  WanWoTests
//
//  【T2.3 P0 单测】提问卡结算回归：ask 全时序恰呈现一次（双重呈现回归——
//  根因：UserQuestionService.ask 与 awaitAnswer 各呈现一次，同一 presentation
//  双份入 UI 队列，settleQuestion 只移除 firstIndex 一份 → 残留卡死 composer）；
//  answered/.cancelled/.aborted 三结算路径；同 id 重放副本替换（dsh 2026-07-23
//  笔记 :19 "replaces replay duplicates"）；第二轮提问不被旧卡遮挡。
//

import XCTest
@testable import WanWo

/// 结算记录型 presenter（比 RecordingPresenter 多记 settlement 值）。
@MainActor
private final class SettlementRecordingPresenter: SessionInteractionPresenter {
    var presentedApprovals: [String] = []
    var settledApprovals: [String] = []
    var questionsPresented: [String] = []
    var questionSettlements: [(id: String, settlement: QuestionSettlement)] = []

    func presentApproval(_ pending: PendingApprovalPresentation) {
        presentedApprovals.append(pending.id)
    }

    func settleApproval(id: String, outcome: ApprovalOutcome) {
        settledApprovals.append(id)
    }

    func presentQuestion(_ pending: PendingQuestionPresentation) {
        questionsPresented.append(pending.id)
    }

    func settleQuestion(id: String, settlement: QuestionSettlement) {
        questionSettlements.append((id, settlement))
    }
}

@MainActor
final class T23P0SettlementTests: XCTestCase {

    private func makeService(presenter: SessionInteractionPresenter?) -> UserQuestionService {
        UserQuestionService(presenter: presenter)
    }

    private func makeQuestion(_ id: String) -> AskUserQuestionItem {
        AskUserQuestionItem(id: id, question: "？", detail: nil, header: nil,
                            options: nil, multiSelect: nil, intent: nil)
    }

    /// 等待首个呈现落地（与 AskUserToolTests 同款轮询）。
    private func waitForFirstPresent(_ presenter: SettlementRecordingPresenter) async throws {
        for _ in 0..<200 where presenter.questionsPresented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: 双重呈现回归（根因断言）

    func testAskPresentsExactlyOnce() async throws {
        let presenter = SettlementRecordingPresenter()
        let service = makeService(presenter: presenter)
        let askTask = Task { try await service.ask(questions: [makeQuestion("q1")],
                                                   callId: nil) }
        try await waitForFirstPresent(presenter)
        // 双重呈现是竞速外的必然两次——短暂静置后仍须恰 1 次。
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(presenter.questionsPresented.count, 1,
                       "dsh ask() 全时序仅呈现一次；双份入列是 P0 根因")
        _ = service.dismiss(requestId: presenter.questionsPresented[0])
        _ = try? await askTask.value
    }

    // MARK: answered 路径（提交 → 结算 → 第二轮不被遮挡）

    func testAnswerSettlesAnsweredAndSecondQuestionNotBlocked() async throws {
        let presenter = SettlementRecordingPresenter()
        let service = makeService(presenter: presenter)

        // 第一轮：呈现 → 回答 → ask 返回 + .answered 结算。
        let firstAsk = Task { try await service.ask(questions: [makeQuestion("q1")],
                                                    callId: nil) }
        try await waitForFirstPresent(presenter)
        XCTAssertTrue(service.answer(
            requestId: presenter.questionsPresented[0],
            AskUserQuestionAnswer(answers: [
                AskUserQuestionAnswerItem(id: "q1", selected: ["是"], custom: nil)])))
        let firstAnswer = try await firstAsk
        XCTAssertEqual(firstAnswer.answers.first?.selected, ["是"])
        XCTAssertEqual(presenter.questionSettlements.count, 1)
        if case .answered = presenter.questionSettlements[0].settlement {} else {
            XCTFail("answered 结算缺失：\(presenter.questionSettlements)")
        }
        XCTAssertEqual(presenter.questionSettlements[0].id,
                       presenter.questionsPresented[0], "结算 id 与呈现 id 配对")

        // 第二轮：旧卡已清，新提问可正常呈现并回答（不叠加不遮挡）。
        let secondAsk = Task { try await service.ask(questions: [makeQuestion("q2")],
                                                     callId: nil) }
        for _ in 0..<200 where presenter.questionsPresented.count < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(presenter.questionsPresented.count, 2)
        XCTAssertTrue(service.answer(
            requestId: presenter.questionsPresented[1],
            AskUserQuestionAnswer(answers: [
                AskUserQuestionAnswerItem(id: "q2", selected: ["否"], custom: nil)])))
        let secondAnswer = try await secondAsk
        XCTAssertEqual(secondAnswer.answers.first?.id, "q2")
        XCTAssertEqual(presenter.questionSettlements.count, 2)
        if case .answered = presenter.questionSettlements[1].settlement {} else {
            XCTFail("第二轮 answered 结算缺失")
        }
    }

    // MARK: ×（dismiss → ASK_CANCELLED 中性结算）

    func testDismissSettlesCancelled() async throws {
        let presenter = SettlementRecordingPresenter()
        let service = makeService(presenter: presenter)
        let askTask = Task { try await service.ask(questions: [makeQuestion("q1")],
                                                   callId: nil) }
        try await waitForFirstPresent(presenter)
        XCTAssertTrue(service.dismiss(requestId: presenter.questionsPresented[0]))
        do {
            _ = try await askTask.value
            XCTFail("dismiss 必须抛 ASK_CANCELLED")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "ASK_CANCELLED")
        }
        XCTAssertEqual(presenter.questionSettlements.count, 1)
        if case .cancelled = presenter.questionSettlements[0].settlement {} else {
            XCTFail("× 须 .cancelled 中性结算：\(presenter.questionSettlements)")
        }
    }

    // MARK: abort（任务取消 → ASK_ABORTED）

    func testTaskCancellationSettlesAborted() async throws {
        let presenter = SettlementRecordingPresenter()
        let service = makeService(presenter: presenter)
        let askTask = Task { try await service.ask(questions: [makeQuestion("q1")],
                                                   callId: nil) }
        try await waitForFirstPresent(presenter)
        askTask.cancel()
        do {
            _ = try await askTask.value
            XCTFail("取消必须抛 ASK_ABORTED")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error.code, "ASK_ABORTED")
        }
        XCTAssertEqual(presenter.questionSettlements.count, 1)
        if case .aborted = presenter.questionSettlements[0].settlement {} else {
            XCTFail("abort 须 .aborted 结算（工具卡琥珀 stopped 行）"
                + "：\(presenter.questionSettlements)")
        }
    }

    // MARK: 重放副本替换（dsh 笔记 :19 纯函数）

    func testUpsertReplacesReplayDuplicateKeepingPosition() {
        let first = PendingQuestionPresentation(
            id: "ask-a", questions: [makeQuestion("q1")], callId: nil)
        let second = PendingQuestionPresentation(
            id: "ask-b", questions: [makeQuestion("q2")], callId: nil)
        let queue = PendingQuestionMirror.upsert(
            PendingQuestionMirror.upsert([], first), second)
        XCTAssertEqual(queue.map(\.id), ["ask-a", "ask-b"])
        // 同 id 重放：替换原位，不追加。
        let replayed = PendingQuestionPresentation(
            id: "ask-a", questions: [makeQuestion("q1"), makeQuestion("q1b")],
            callId: "call-1")
        let updated = PendingQuestionMirror.upsert(queue, replayed)
        XCTAssertEqual(updated.count, 2, "重放副本不得叠加")
        XCTAssertEqual(updated[0].id, "ask-a", "替换保位（FIFO 呈现序稳定）")
        XCTAssertEqual(updated[0].questions.count, 2, "以重放内容替换")
        XCTAssertEqual(updated[0].callId, "call-1")
    }
}
