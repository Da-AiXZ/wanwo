//
//  ApprovalCoordinatorTests.swift
//  WanWoTests
//
//  【M3 T1 单测 3/5】first answer wins / 桥关闭 fail closed / 审计对成对落盘。
//  出处：m3-scope-brief §二.5（resolved 标志 + 幂等防双击 + host 内存唯一裁决者
//  + 桥关闭在途待决一律 unavailable）；dsh user-approval index.ts:207-226
//  （asked+decided 审计对恒成对）、slots.ts:69-158（settled 一次性）。
//

import XCTest
@testable import WanWo

/// 测试用 presenter（记录呈现/结算调用序列；协议为 @MainActor，测试方法同域读取）。
/// internal：AskUserToolTests / TurnEnclosedCompositeSeamTests 复用。
@MainActor
final class RecordingPresenter: SessionInteractionPresenter {
    var presented: [String] = []
    var settled: [(id: String, outcome: ApprovalOutcome?)] = []
    var questionsPresented: [String] = []
    var questionsSettled: [String] = []

    func presentApproval(_ pending: PendingApprovalPresentation) {
        presented.append(pending.id)
    }

    func settleApproval(id: String, outcome: ApprovalOutcome) {
        settled.append((id, outcome))
    }

    func presentQuestion(_ pending: PendingQuestionPresentation) {
        questionsPresented.append(pending.id)
    }

    func settleQuestion(id: String, settlement: QuestionSettlement) {
        questionsSettled.append(id)
    }
}

@MainActor
final class ApprovalCoordinatorTests: XCTestCase {

    /// 临时会话写柄（真实 JSONL 落盘 + SessionWriter 校验管线）。
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

    /// turn-enclosed 前置：无开放回合的 ask fail closed（.unavailable）且不落审计。
    func testRequestOutsideOpenTurnFailsClosed() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)

        let outcome = await coordinator.request(tool: "bash", callId: "call-1", reason: nil)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(presenter.presented.isEmpty, "回合外 ask 不得呈现到 UI")
        XCTAssertTrue(writer.events.isEmpty, "回合外 ask 不得落任何审计事件")
    }

    /// 完整 ask → answer 往返：审计对成对（asked → decided），
    /// outcome 值为四值闭集原文。
    func testAuditPairAppendedOnAnswer() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)

        try await writer.append(.turnStart(turn: 1))
        async let outcome = coordinator.request(tool: "bash", callId: "call-1",
                                                reason: "需要写入系统目录")
        // 等待呈现后裁决（轮询到 presenter 收到请求为止）。
        for _ in 0..<200 where presenter.presented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(presenter.presented.count, 1)
        let requestId = presenter.presented[0]
        let accepted = coordinator.answer(requestId: requestId, outcome: .allowedOnce)
        XCTAssertTrue(accepted)
        let grantedOutcome = try await outcome
        XCTAssertEqual(grantedOutcome, .allowedOnce)

        let audit = writer.events.filter {
            $0.wireType.hasPrefix("approval/")
        }
        XCTAssertEqual(audit.count, 2, "asked + decided 恰成对")
        guard case .approvalAsked(let askedId, let tool, let reason) = audit[0].payload else {
            return XCTFail("first audit event must be approval/asked")
        }
        XCTAssertEqual(askedId, requestId)
        XCTAssertEqual(tool, "bash")
        XCTAssertEqual(reason, "需要写入系统目录")
        guard case .approvalDecided(let decidedId, let verdict) = audit[1].payload else {
            return XCTFail("second audit event must be approval/decided")
        }
        XCTAssertEqual(decidedId, requestId)
        XCTAssertEqual(verdict, "allowed-once")
        // 结算呈现已通知（composer 退位）。
        XCTAssertEqual(presenter.settled.count, 1)
        XCTAssertEqual(presenter.settled[0].outcome, .allowedOnce)
    }

    /// first answer wins：第二次 answer 幂等拒绝（防双击/竞态）。
    func testFirstAnswerWins() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)

        try await writer.append(.turnStart(turn: 1))
        async let outcome = coordinator.request(tool: "bash", callId: "call-1", reason: nil)
        for _ in 0..<200 where presenter.presented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let requestId = presenter.presented[0]
        XCTAssertTrue(coordinator.answer(requestId: requestId, outcome: .rejected))
        XCTAssertFalse(coordinator.answer(requestId: requestId, outcome: .allowedOnce),
                       "第二次 answer 必须被拒绝（resolved 一次性）")
        XCTAssertFalse(coordinator.answer(requestId: "unknown-id", outcome: .allowedOnce))
        // rogue 输入（非交互二值）拒绝。
        XCTAssertFalse(coordinator.answer(requestId: requestId, outcome: .unavailable))
        let rejectedOutcome = try await outcome
        XCTAssertEqual(rejectedOutcome, .rejected)
    }

    /// 桥关闭：在途待决一律 .unavailable（fail closed）且审计对完整。
    func testBridgeClosedResolvesUnavailable() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)

        try await writer.append(.turnStart(turn: 1))
        async let outcome = coordinator.request(tool: "bash", callId: "call-1", reason: nil)
        for _ in 0..<200 where presenter.presented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        coordinator.bridgeClosed()
        let closedOutcome = try await outcome
        XCTAssertEqual(closedOutcome, .unavailable)
        // 审计对仍完整（decided 恒随 asked——dsh index.ts:224）。
        let decided = writer.events.compactMap { event -> String? in
            if case .approvalDecided(_, let verdict) = event.payload { return verdict }
            return nil
        }
        XCTAssertEqual(decided, ["unavailable"])
        // 结算呈现已通知（面板退位）。
        XCTAssertEqual(presenter.settled.count, 1)
        XCTAssertEqual(presenter.settled[0].outcome, .unavailable)
    }
}
