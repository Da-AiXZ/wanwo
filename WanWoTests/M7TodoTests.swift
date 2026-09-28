//
//  M7TodoTests.swift
//  WanWoTests
//
//  【M7 件 A · Todo/F049 单测】语义源对拍（analysis/dsh-upstream-m5/packages/
//  todo/tool-todo/src/）断言点：
//    - toTodoList 校验（index.ts:29-43,57-59,107-109）：trim 非空 / 去重 /
//      allowParallelInProgress=false 时 in_progress≤1 / canonical 化 trim。
//    - invariant（invariant.ts:16-39）：形状校验；刻意不校验 in_progress 数
//      （策略非形状）；todo/write 必须在开放 turn 内。
//    - 投影 fold（index.ts:130-145）：整表替换 last-write-wins；
//      turn/start→null 清空；turn/end→不清；counts 输出。
//

import XCTest
@testable import WanWo

final class M7TodoTests: XCTestCase {

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7todo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "m7-todo",
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

    private func makeContext(sessionId: String) -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: sessionId, turn: 0, step: 0, callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: sessionId),
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: nil)
    }

    private func item(_ content: String, _ status: TodoStatus) -> JSONValue {
        .object(["content": .string(content), "status": .string(status.rawValue)])
    }

    // MARK: - toTodoList（index.ts:91-111 对拍）

    func testToTodoListTrimsAndCanonicalizes() throws {
        let todos = try TodoTool.toTodoList([
            item("  write spec  ", .pending),
        ], allowParallelInProgress: false)
        // trim 后 canonical 化（dsh 逐条 trim 语义）。
        XCTAssertEqual(todos, [TodoItem(content: "write spec", status: .pending)])
    }

    func testToTodoListRejectsEmptyAndWhitespaceContent() {
        // 空串 / 纯空白 → 拒绝（index.ts:98 文案同源）。
        XCTAssertThrowsError(try TodoTool.toTodoList(
            [item("", .pending)], allowParallelInProgress: false))
        XCTAssertThrowsError(try TodoTool.toTodoList(
            [item("   ", .pending)], allowParallelInProgress: false))
    }

    func testToTodoListRejectsDuplicateContent() {
        XCTAssertThrowsError(try TodoTool.toTodoList(
            [item("a", .pending), item("a", .completed)],
            allowParallelInProgress: false)) { error in
            let message = (error as? TodoValidationError)?.message ?? ""
            XCTAssertTrue(message.contains("duplicate content \"a\""),
                          "dsh index.ts:101 文案对拍：got \(message)")
        }
    }

    func testToTodoListRejectsUnknownStatus() {
        XCTAssertThrowsError(try TodoTool.toTodoList(
            [.object(["content": .string("a"), "status": .string("doing")])],
            allowParallelInProgress: false))
    }

    func testParallelInProgressPolicyDefaultFalse() {
        // allowParallelInProgress=false（万我拍板档）：in_progress≤1。
        let two = [item("a", .inProgress), item("b", .inProgress)]
        XCTAssertThrowsError(try TodoTool.toTodoList(two, allowParallelInProgress: false))
        // 显式 true 档放行（dsh per-deployment 策略）。
        XCTAssertNoThrow(try TodoTool.toTodoList(two, allowParallelInProgress: true))
    }

    // MARK: - invariant（invariant.ts:16-39 对拍）

    /// todo/write 的 todos 数组载荷（invariant 校验面 = 数组本体）。
    private func todosArray(_ items: [JSONValue]) -> JSONValue { .array(items) }

    func testInvariantDeliberatelyDoesNotCheckParallelInProgressCount() {
        // 刻意不校验 in_progress 数（策略非形状——invariant.ts:16-23 注释语义：
        // 策略收紧后历史仍须可 replay）。
        let payload = todosArray([
            item("a", .inProgress), item("b", .inProgress),
        ])
        XCTAssertNil(TodoInvariants.validateTodos(payload))
    }

    func testInvariantRejectsUntrimmedAndDuplicates() {
        XCTAssertNotNil(TodoInvariants.validateTodos(todosArray([
            item(" pad ", .pending),
        ])))
        XCTAssertNotNil(TodoInvariants.validateTodos(todosArray([
            item("x", .pending), item("x", .completed),
        ])))
    }

    func testValidateRequiresOpenTurn() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        TodoEvents.register()
        // 开放 turn 外的 todo/write → 违规（invariant.ts:42-69 turnTrace）。
        try await writer.append(.extensionEvent(
            kind: TodoEvents.writeKind, payload: TodoTool.payload(for: [
                TodoItem(content: "a", status: .pending),
            ])))
        XCTAssertEqual(TodoInvariants.validate(events: writer.events),
                       "todo/write appended outside any open turn")
        // 开放 turn 内 → 合法。
        try await writer.append(.turnStart(turn: 1))
        try await writer.append(.extensionEvent(
            kind: TodoEvents.writeKind, payload: TodoTool.payload(for: [
                TodoItem(content: "a", status: .pending),
            ])))
        try await writer.append(.turnEnd(turn: 1, reason: .completed))
        XCTAssertNil(TodoInvariants.validate(events: writer.events))
    }

    // MARK: - 投影 fold（index.ts:130-145 对拍）

    func testProjectionWholeListReplacementAndTurnLifecycle() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        TodoEvents.register()
        // 首写前 = nil。
        XCTAssertNil(TodoProjection.fold(events: writer.events))
        try await writer.append(.turnStart(turn: 1))
        try await writer.append(.extensionEvent(
            kind: TodoEvents.writeKind, payload: TodoTool.payload(for: [
                TodoItem(content: "a", status: .pending),
            ])))
        // 整表替换 last-write-wins。
        try await writer.append(.extensionEvent(
            kind: TodoEvents.writeKind, payload: TodoTool.payload(for: [
                TodoItem(content: "a", status: .completed),
                TodoItem(content: "b", status: .inProgress),
            ])))
        XCTAssertEqual(TodoProjection.fold(events: writer.events), [
            TodoItem(content: "a", status: .completed),
            TodoItem(content: "b", status: .inProgress),
        ])
        // turn/end 不清（"keeps the finished checklist visible"）。
        try await writer.append(.turnEnd(turn: 1, reason: .completed))
        XCTAssertEqual(TodoProjection.fold(events: writer.events)?.count, 2)
        // turn/start 清空（"cleared by the next turn/start"）。
        try await writer.append(.turnStart(turn: 2))
        XCTAssertNil(TodoProjection.fold(events: writer.events))
    }

    // MARK: - 工具执行（index.ts:203-219 execute 对拍）

    func testExecuteAppendsEventAndReturnsCounts() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        TodoEvents.register()
        try await writer.append(.turnStart(turn: 1))
        let tool = TodoTool(writer: writer)
        let output = try await tool.execute(.object(["todos": .array([
            item("a", .pending),
            item("b", .completed),
        ])]), makeContext(sessionId: "m7-todo"))
        XCTAssertFalse(output.isError, "合法整表应成功：\(output.text)")
        // render 文案逐字（index.ts:198-201）。
        XCTAssertEqual(output.text,
                       "Updated todo list: 1 pending, 0 in progress, 1 completed.")
        // fold 回读 = 整表替换落盘。
        XCTAssertEqual(TodoProjection.fold(events: writer.events), [
            TodoItem(content: "a", status: .pending),
            TodoItem(content: "b", status: .completed),
        ])
    }

    func testExecuteRejectsPolicyViolation() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        TodoEvents.register()
        try await writer.append(.turnStart(turn: 1))
        let tool = TodoTool(writer: writer)
        let output = try await tool.execute(.object(["todos": .array([
            item("a", .inProgress), item("b", .inProgress),
        ])]), makeContext(sessionId: "m7-todo"))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "INVALID_TODOS")
        // 拒绝后无事件落盘（fail closed）。
        XCTAssertNil(TodoProjection.fold(events: writer.events))
    }
}
