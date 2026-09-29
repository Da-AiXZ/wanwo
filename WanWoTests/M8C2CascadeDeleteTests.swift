//
//  M8C2CascadeDeleteTests.swift
//  WanWoTests
//
//  【M8 批3 D 件测试】工作区级联删除：
//    · 账本实数计数（outcome.removedSessionIds）；
//    · lineage 子会话随父级联（threadSpawnEdges 全代）；
//    · 活写柄关闭（open writer 下级联不 sessionOpenCannotDelete）；
//    · 会话删除失败 → 注册记录保留（可重试）；
//    · 既有 delete(id:) registry-only 语义不变（孤儿清理路径零改动）。
//  纯同步（actor 面经 async test）+ 临时目录；删除全程走 SessionStore 缝。
//

import XCTest
@testable import WanWo

final class M8C2CascadeDeleteTests: XCTestCase {

    private var tempRoot: URL!
    private var sessionsRoot: URL!
    private var database: SessionDatabase!
    private var store: SessionStore!
    private var registry: WorkspaceRegistry!
    private var controller: WorkspaceController!
    /// headerProvider 注入源（与 AppEnvironment 装配同构：探针直读 jsonl 头）。
    private var headers: [String: SessionHeader] = [:]
    private var directories: Set<String> = []

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-c2-cascade-\(UUID().uuidString)", isDirectory: true)
        sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        database = try SessionDatabase(
            path: tempRoot.appendingPathComponent("idx.sqlite3").path)
        store = SessionStore(root: sessionsRoot, database: database)
        headers = [:]
        directories = []
        registry = WorkspaceRegistry(
            database: database,
            headerProvider: { [weak self] sid in self?.headers[sid] },
            directoryExists: { [weak self] path in
                self?.directories.contains(path) ?? false },
            realpath: { WorkspacePathNormalizer.lexicalNormalize($0) })
        controller = WorkspaceController(registry: registry)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 生产同构删除缝（SessionStore 级联删除缝直连）。
    private var seam: WorkspaceController.WorkspaceSessionDeletionSeam {
        WorkspaceController.WorkspaceSessionDeletionSeam(
            deleteWithDescendants: { [store] sid in
                try await store.deleteSessionWithDescendants(id: sid)
            })
    }

    /// 建会话（jsonl + 索引行 + header 表登记）。
    @discardableResult
    private func makeSession(id: String, cwd: String?) async throws -> String {
        _ = try store.createSession(withID: id, cwd: cwd)
        headers[id] = SessionHeader(
            id: id,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            cwd: cwd)
        return id
    }

    private func makeWorkspace(path: String, sessions: [String]) throws -> String {
        directories.insert(path)
        let ws = try registry.create(path: path)
        for sid in sessions {
            try registry.attachSession(sessionId: sid, to: ws.id)
        }
        return ws.id
    }

    private func jsonlExists(_ id: String) -> Bool {
        FileManager.default.fileExists(
            atPath: sessionsRoot.appendingPathComponent("\(id).jsonl").path)
    }

    // MARK: - 基本级联

    /// 账本逐会话级联：jsonl 删 + 索引行删 + 注册记录删；计数 = 账本实数。
    func testCascadeDeletesLedgerSessionsAndRecord() async throws {
        let a = try await makeSession(id: "session-a", cwd: "/projects/alpha")
        let b = try await makeSession(id: "session-b", cwd: "/projects/alpha")
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [a, b])
        XCTAssertNotNil(registry.get(wsID))

        let outcome = try await controller.deleteCascade(id: wsID, sessionDeletion: seam)
        XCTAssertTrue(outcome.deleted)
        XCTAssertEqual(outcome.removedSessionIds.count, 2)
        XCTAssertEqual(Set(outcome.removedSessionIds), ["session-a", "session-b"])
        XCTAssertFalse(jsonlExists("session-a"))
        XCTAssertFalse(jsonlExists("session-b"))
        XCTAssertTrue(await store.listSessions().isEmpty, "索引行必须随删（单一删除缝）")
        // 残余成员回落 Ungrouped（未分组成员清理——此处账本已空，校验无悬挂）。
        XCTAssertEqual(registry.list().count, 0)
    }

    /// lineage 子会话随父级联（threadSpawnEdges 全代）。
    func testLineageDescendantsDeletedWithParent() async throws {
        let parent = try await makeSession(id: "parent", cwd: "/projects/alpha")
        let child = try await makeSession(id: "child", cwd: "/projects/alpha")
        let grandchild = try await makeSession(id: "grandchild", cwd: "/projects/alpha")
        try database.upsertThreadSpawnEdge(parent: parent, child: child, status: .open)
        try database.upsertThreadSpawnEdge(parent: child, child: grandchild, status: .closed)
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [parent])

        let outcome = try await controller.deleteCascade(id: wsID, sessionDeletion: seam)
        XCTAssertTrue(outcome.deleted)
        // 账本只有父会话 1 行，实际删除 = 父 + 子 + 孙（级联实数）。
        XCTAssertEqual(Set(outcome.removedSessionIds),
                       Set([parent, child, grandchild]))
        XCTAssertFalse(jsonlExists("parent"))
        XCTAssertFalse(jsonlExists("child"))
        XCTAssertFalse(jsonlExists("grandchild"))
        XCTAssertTrue(await store.listSessions().isEmpty)
    }

    /// 活写柄关闭：open writer 下级联删除不 sessionOpenCannotDelete。
    func testCascadeClosesLiveWriters() async throws {
        let a = try await makeSession(id: "session-a", cwd: "/projects/alpha")
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [a])
        // 活写柄（排他写所有权已开放——deleteSession 直接删会抛）。
        _ = try await store.openWriter(id: a)

        let outcome = try await controller.deleteCascade(id: wsID, sessionDeletion: seam)
        XCTAssertTrue(outcome.deleted)
        XCTAssertEqual(outcome.removedSessionIds, [a])
        XCTAssertFalse(jsonlExists(a))
        // 写柄登记表已释放（活写柄关闭）。
        XCTAssertNil(await store.liveWriter(id: a))
    }

    // MARK: - 失败纪律

    /// 会话删除失败 → 级联中止，注册记录保留（可重试）。
    func testCascadeAbortsOnSessionFailureKeepsRecord() async throws {
        let a = try await makeSession(id: "session-a", cwd: "/projects/alpha")
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [a])
        let failing = WorkspaceController.WorkspaceSessionDeletionSeam(
            deleteWithDescendants: { _ in throw SessionStore.StoreError.sessionNotFound("x") })

        XCTAssertThrowsError(try await controller.deleteCascade(
            id: wsID, sessionDeletion: failing))
        XCTAssertNotNil(registry.get(wsID), "会话删除失败时注册记录必须保留")
        XCTAssertTrue(jsonlExists(a))
    }

    /// 既有 delete(id:) 语义不变：只删注册记录，会话回落 Ungrouped。
    func testLegacyDeleteKeepsSessions() async throws {
        let a = try await makeSession(id: "session-a", cwd: "/projects/alpha")
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [a])
        let deleted = try controller.delete(id: wsID)
        XCTAssertTrue(deleted)
        XCTAssertTrue(jsonlExists(a), "registry-only 删除不碰会话（孤儿清理路径零改动）")
        let summaries = await store.listSessions()
        XCTAssertTrue(summaries.contains(where: { $0.id == a }))
        XCTAssertEqual(summaries.first?.groupId,
                       WorkspaceRegistry.ungroupedID, "成员回落 Ungrouped")
    }

    /// 未知 id：deleteCascade 幂等（deleted=false，账本不误删）。
    func testCascadeUnknownIdIsNoop() async throws {
        let a = try await makeSession(id: "session-a", cwd: "/projects/alpha")
        let wsID = try makeWorkspace(path: "/projects/alpha", sessions: [a])
        let outcome = try await controller.deleteCascade(
            id: "no-such-workspace", sessionDeletion: seam)
        XCTAssertFalse(outcome.deleted)
        XCTAssertTrue(outcome.removedSessionIds.isEmpty)
        XCTAssertTrue(jsonlExists(a))
    }
}
