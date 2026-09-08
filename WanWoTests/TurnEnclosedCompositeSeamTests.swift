//
//  TurnEnclosedCompositeSeamTests.swift
//  WanWoTests
//
//  【M3 T1 单测 4/5】CompositeApprovalSeam 四步管线 + 政策短路 + 审计对只在
//  ask 路径落盘（allow 直通与 forbidden 拒不询问）。
//  出处：m3-scope-brief §二.4；dsh user-approval index.ts:261-266（'never' 在
//  dispatch 之前确定性拒绝）；06-codex-gap1 §八.2（三值判定接 pre-execute 缝）。
//

import XCTest
@testable import WanWo

@MainActor
final class TurnEnclosedCompositeSeamTests: XCTestCase {

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

    /// ① allow 直通：不询问（无呈现）、不落审计对。
    func testAllowPassesThroughWithoutAudit() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)
        let seam = CompositeApprovalSeam(
            matrix: ApprovalDecisionMatrix(sandboxMode: .workspaceWrite),
            coordinator: coordinator, policyProvider: { .ask })

        try await writer.append(.turnStart(turn: 1))
        let outcome = await seam.request(tool: "read", args: .null, callId: "c1", reason: nil)
        XCTAssertEqual(outcome, .allowedOnce)
        XCTAssertTrue(presenter.presented.isEmpty, "allow 直通不得呈现审批面板")
        XCTAssertTrue(writer.events.isEmpty, "allow 直通不落审计对（审计对只随 ask）")
    }

    /// ③ forbidden 拒：不询问、不落审计对（合成拒绝由管线完成）。
    func testForbiddenRejectedWithoutAudit() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)
        let seam = CompositeApprovalSeam(
            matrix: ApprovalDecisionMatrix(
                sandboxMode: .workspaceWrite,
                rows: [.init(matches: { tool, _ in tool == "bash" },
                             verdict: .forbidden,
                             reason: "禁令")]),
            coordinator: coordinator, policyProvider: { .ask })

        try await writer.append(.turnStart(turn: 1))
        let outcome = await seam.request(tool: "bash", args: .null, callId: "c1", reason: nil)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(presenter.presented.isEmpty, "forbidden 不得呈现审批面板")
        XCTAssertTrue(writer.events.isEmpty, "forbidden 不落审计对")
    }

    /// ④ 政策短路：'never' 在 dispatch 之前确定性拒绝（不呈现、不询问），
    /// 且不落审计对（ask 从未发生——dsh index.ts:261-266 注释语义：
    /// 'never' 拒绝的是「问」这个动作本身）。
    func testNeverPolicyShortCircuits() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)
        let seam = CompositeApprovalSeam(
            matrix: ApprovalDecisionMatrix(sandboxMode: .workspaceWrite),
            coordinator: coordinator, policyProvider: { .never })

        try await writer.append(.turnStart(turn: 1))
        let outcome = await seam.request(tool: "bash", args: .null, callId: "c1", reason: nil)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertTrue(writer.events.isEmpty)
    }

    /// ④ prompt 路径：挂起等真人，答案回流；审计对成对。
    func testPromptPathSuspendsAndResolves() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)
        let seam = CompositeApprovalSeam(
            matrix: ApprovalDecisionMatrix(sandboxMode: .workspaceWrite),
            coordinator: coordinator, policyProvider: { .ask })

        try await writer.append(.turnStart(turn: 1))
        async let outcome = seam.request(tool: "bash",
                                         args: .object(["command": .string("ls")]),
                                         callId: "c1", reason: nil)
        for _ in 0..<200 where presenter.presented.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(coordinator.answer(requestId: presenter.presented[0],
                                         outcome: .allowedOnce))
        XCTAssertEqual(try await outcome, .allowedOnce)
        let audit = writer.events.filter { $0.payload.wireType.hasPrefix("approval/") }
        XCTAssertEqual(audit.count, 2)
    }

    /// 管线拒绝消息按四值闭集自解释（F060 最小纪律）。
    func testPipelineDenialMessages() {
        XCTAssertEqual(ToolPipeline.denialMessage(tool: "bash", outcome: .rejected),
                       "tool call \"bash\" was rejected by the user")
        XCTAssertEqual(ToolPipeline.denialMessage(tool: "bash", outcome: .cancelled),
                       "approval for tool call \"bash\" was cancelled")
        XCTAssertTrue(ToolPipeline.denialMessage(tool: "bash", outcome: .unavailable)
            .contains("failing closed"))
    }
}
