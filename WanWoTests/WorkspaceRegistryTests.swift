//
//  WorkspaceRegistryTests.swift
//  WanWoTests
//
//  【M6.5（B3）测试 · workspace registry 语义矩阵（纯逻辑面必测）】
//  语义源 = dsh workspace.zh.md :12-316 契约：
//    create 幂等（同规范路径返回既有）/ 不存在路径 ENOENT 拒收 / 有序账本
//    （attach 前插）/ attach 校验（cwd 不匹配拒绝且不写）/ detach 幂等 /
//    insertBefore（DOM-insertBefore 语义）/ delete 后会话回落 Ungrouped /
//    resolveByPath / archiveSession 幂等 / 首启 bootstrap（分组 + 标记续跑）。
//  真实依赖全部缝注入：SessionDatabase（临时路径 GRDB）、headerProvider/
//  directoryExists/realpath（闭包）——零文件系统耦合。
//

import XCTest
@testable import WanWo

final class WorkspaceRegistryTests: XCTestCase {

    // MARK: - fixture

    private var dbPath: URL!
    private var registry: WorkspaceRegistry!
    private var database: SessionDatabase!
    /// 会话 header 表（headerProvider 注入源）。
    private var headers: [String: SessionHeader] = [:]
    /// 虚拟目录集合（directoryExists 注入源）。
    private var directories: Set<String> = []

    override func setUp() async throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-ws-\(UUID().uuidString).sqlite3")
        database = try SessionDatabase(path: dbPath.path)
        headers = [:]
        directories = []
        makeRegistry()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dbPath)
    }

    /// 纯逻辑缝：realpath=词法规范、存在性=虚拟目录集合、header=内存表。
    private func makeRegistry() {
        registry = WorkspaceRegistry(
            database: database,
            headerProvider: { [weak self] sid in self?.headers[sid] },
            directoryExists: { [weak self] path in self?.directories.contains(path) ?? false },
            realpath: { WorkspacePathNormalizer.lexicalNormalize($0) })
    }

    /// 注册一个会话（sessionIndex 行 + header）。
    @discardableResult
    private func makeSession(id: String = UUID().uuidString,
                             cwd: String?, createdAt: Date = Date()) -> String {
        headers[id] = SessionHeader(id: id,
                                    createdAtMs: Int64(createdAt.timeIntervalSince1970 * 1000),
                                    cwd: cwd)
        database.upsert(SessionSummary(id: id, title: nil,
                                       createdAt: createdAt, updatedAt: createdAt,
                                       eventCount: 0))
        return id
    }

    private func seedDirectory(_ path: String) {
        directories.insert(WorkspacePathNormalizer.lexicalNormalize(path))
    }

    // MARK: - create

    func testCreateReturnsNewRecordWithBasenameTitle() throws {
        seedDirectory("/projects/alpha")
        let ws = try registry.create(path: "/projects/alpha")
        XCTAssertEqual(ws.path, "/projects/alpha")
        XCTAssertEqual(ws.title, "alpha")
        XCTAssertTrue(ws.sessionIds.isEmpty)
        XCTAssertNotEqual(ws.id, WorkspaceRegistry.ungroupedID)
    }

    /// create 幂等：同规范路径（拼写变体）原样返回既有实体，不改标题。
    func testCreateIsIdempotentOverCanonicalPath() throws {
        seedDirectory("/projects/alpha")
        let first = try registry.create(path: "/projects/alpha/", title: "自定义名")
        let second = try registry.create(path: "/projects/alpha/../alpha")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.title, "自定义名")
        XCTAssertEqual(registry.list().count, 1)
    }

    /// 词法规范的唯一性面：尾斜杠 / ".." / 多斜杠折叠。
    func testLexicalNormalizationSpellingVariants() throws {
        seedDirectory("/a/b")
        let first = try registry.create(path: "/a//b/")
        let second = try registry.create(path: "/a/c/../b")
        XCTAssertEqual(first.id, second.id)
    }

    /// 路径不存在 → 原样 ENOENT 语义拒收。
    func testCreateRejectsMissingPath() {
        XCTAssertThrowsError(try registry.create(path: "/no/such/dir")) { error in
            XCTAssertEqual(error as? WorkspaceRegistryError, .pathNotFound("/no/such/dir"))
        }
    }

    /// 新工作区前插到注册表序（list 首位）。
    func testCreatePrependsToRegistryOrder() throws {
        seedDirectory("/a"); seedDirectory("/b")
        _ = try registry.create(path: "/a")
        _ = try registry.create(path: "/b")
        XCTAssertEqual(registry.list().map(\.path), ["/b", "/a"])
    }

    // MARK: - attach / detach

    func testAttachRequiresHeaderCWDMatch() throws {
        seedDirectory("/projects/alpha")
        let ws = try registry.create(path: "/projects/alpha")
        let matching = makeSession(cwd: "/projects/alpha/")
        let mismatched = makeSession(cwd: "/projects/beta")
        let noCWD = makeSession(cwd: nil)

        // 匹配（规范后相等）接受；不匹配 / 缺 cwd 拒绝且不写。
        try registry.attachSession(sessionId: matching, to: ws.id)
        XCTAssertThrowsError(try registry.attachSession(sessionId: mismatched, to: ws.id)) {
            error in
            XCTAssertEqual(error as? WorkspaceRegistryError,
                           .attachRejected(sessionId: mismatched))
        }
        XCTAssertThrowsError(try registry.attachSession(sessionId: noCWD, to: ws.id))
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [matching])
    }

    /// attach 前插语义：后 attach 的会话排最前。
    func testAttachPrependsToLedger() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let s1 = makeSession(cwd: "/p", createdAt: Date(timeIntervalSince1970: 1))
        let s2 = makeSession(cwd: "/p", createdAt: Date(timeIntervalSince1970: 2))
        try registry.attachSession(sessionId: s1, to: ws.id)
        try registry.attachSession(sessionId: s2, to: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [s2, s1])
    }

    /// attach 幂等：已记账 id 原样返回，不产生重复账本行。
    func testAttachIsIdempotent() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let sid = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: sid, to: ws.id)
        try registry.attachSession(sessionId: sid, to: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [sid])
    }

    /// detach 幂等：不在账本亦不报错；在账本则移除并回落 Ungrouped。
    func testDetachIsIdempotentAndRestoresUngrouped() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let sid = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: sid, to: ws.id)
        try registry.detachSession(sessionId: sid, from: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [])
        // 归属回落 default（F073 单一事实源）。
        let row = database.listWithBaselines().first { $0.summary.id == sid }
        XCTAssertEqual(row?.summary.groupId, WorkspaceRegistry.ungroupedID)
        // 二次 detach：幂等不抛。
        try registry.detachSession(sessionId: sid, from: ws.id)
    }

    // MARK: - insertSessionBefore

    func testInsertSessionBeforeWithAnchorAndAppend() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let s1 = makeSession(cwd: "/p")
        let s2 = makeSession(cwd: "/p")
        let s3 = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: s1, to: ws.id)
        try registry.attachSession(sessionId: s2, to: ws.id)
        try registry.attachSession(sessionId: s3, to: ws.id)
        // 现序 [s3, s2, s1]。
        // 无锚 → 追加到末尾。
        try registry.insertSessionBefore(sessionId: s3, beforeSessionId: nil, in: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [s2, s1, s3])
        // 有锚 → 落锚前。
        try registry.insertSessionBefore(sessionId: s3, beforeSessionId: s2, in: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [s3, s2, s1])
    }

    func testInsertSessionBeforeRejectsUnaccountedParticipants() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let s1 = makeSession(cwd: "/p")
        let outsider = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: s1, to: ws.id)
        // 会话不在账本 → moveInvalid。
        XCTAssertThrowsError(try registry.insertSessionBefore(
            sessionId: outsider, beforeSessionId: s1, in: ws.id)) { error in
            XCTAssertEqual(error as? WorkspaceRegistryError, .moveInvalid)
        }
        // 锚不在账本 → moveInvalid。
        XCTAssertThrowsError(try registry.insertSessionBefore(
            sessionId: s1, beforeSessionId: outsider, in: ws.id)) { error in
            XCTAssertEqual(error as? WorkspaceRegistryError, .moveInvalid)
        }
        // 账本序未被破坏。
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [s1])
    }

    /// 只移动被移动的 id（DOM-insertBefore 语义核心）。
    func testInsertSessionBeforeMovesOnlyTheMovedID() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let s1 = makeSession(cwd: "/p")
        let s2 = makeSession(cwd: "/p")
        let s3 = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: s1, to: ws.id)
        try registry.attachSession(sessionId: s2, to: ws.id)
        try registry.attachSession(sessionId: s3, to: ws.id)
        // [s3, s2, s1] → s1 移到 s2 前 → [s3, s1, s2]（s3 原位不动）。
        try registry.insertSessionBefore(sessionId: s1, beforeSessionId: s2, in: ws.id)
        XCTAssertEqual(registry.get(ws.id)?.sessionIds, [s3, s1, s2])
    }

    // MARK: - delete / resolveByPath / rename

    func testDeleteRemovesRegistrationAndSessionsFallBackToUngrouped() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let sid = makeSession(cwd: "/p")
        try registry.attachSession(sessionId: sid, to: ws.id)

        XCTAssertTrue(try registry.delete(ws.id))
        XCTAssertNil(registry.get(ws.id))
        XCTAssertFalse(try registry.delete(ws.id)) // 未知 id 幂等 false
        // 会话与日志保留：索引行仍在、归属回落 Ungrouped。
        let row = database.listWithBaselines().first { $0.summary.id == sid }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.summary.groupId, WorkspaceRegistry.ungroupedID)
    }

    func testResolveByPathWithoutCreating() throws {
        seedDirectory("/p")
        XCTAssertNil(registry.resolveByPath(path: "/p")) // 未拥有 → nil
        let ws = try registry.create(path: "/p")
        XCTAssertEqual(registry.resolveByPath(path: "/p/")?.id, ws.id)
        XCTAssertNil(registry.resolveByPath(path: "/other"))
    }

    func testRenameUpdatesTitleDurably() throws {
        seedDirectory("/p")
        let ws = try registry.create(path: "/p")
        let updated = try registry.renameTitle(id: ws.id, title: "项目甲")
        XCTAssertEqual(updated.title, "项目甲")
        XCTAssertEqual(registry.get(ws.id)?.title, "项目甲")
    }

    // MARK: - archiveSession

    func testArchiveSessionIdempotentAndUnknownRejected() throws {
        let sid = makeSession(cwd: nil)
        try registry.archiveSession(sessionId: sid)
        XCTAssertTrue(registry.archivedSessionIDs().contains(sid))
        // 已归档幂等（不抛）。
        try registry.archiveSession(sessionId: sid)
        // 未知会话拒绝。
        XCTAssertThrowsError(try registry.archiveSession(sessionId: "no-such-session"))
    }

    // MARK: - 首启 bootstrap

    func testBootstrapGroupsByCanonicalCWDLatestWorkspaceFirst() throws {
        // 三个会话两个目录：alpha 组（1 新 1 旧）、beta 组（1 个）。
        let old = makeSession(cwd: "/alpha",
                              createdAt: Date(timeIntervalSince1970: 100))
        let newer = makeSession(cwd: "/alpha/",
                                createdAt: Date(timeIntervalSince1970: 300))
        let betaSession = makeSession(cwd: "/beta",
                                      createdAt: Date(timeIntervalSince1970: 200))
        seedDirectory("/alpha"); seedDirectory("/beta")

        let report = registry.bootstrapIfNeeded()
        XCTAssertEqual(report.workspacesCreated, 2)
        XCTAssertEqual(report.sessionsAttached, 3)
        XCTAssertFalse(report.alreadyInitialized)

        // 组内账本：attach 前插 ⇒ 最新会话在前。
        let alpha = registry.resolveByPath(path: "/alpha")
        XCTAssertEqual(alpha?.sessionIds, [newer, old])
        // 注册表序：组内最新会话时间倒序 ⇒ alpha(300) 先于 beta(200)。
        XCTAssertEqual(registry.list().map(\.path), ["/alpha", "/beta"])
        // 归属落位（F073 groupId 跟随工作区 id）。
        let betaWS = registry.resolveByPath(path: "/beta")
        let betaRow = database.listWithBaselines()
            .first { $0.summary.id == betaSession }
        XCTAssertEqual(betaRow?.summary.groupId, betaWS?.id)
    }

    func testBootstrapKeepsSessionsWithoutValidCWDUngrouped() throws {
        _ = makeSession(cwd: nil)
        seedDirectory("/p")
        let report = registry.bootstrapIfNeeded()
        XCTAssertEqual(report.skippedInvalidCWD, 1)
        XCTAssertEqual(report.workspacesCreated, 0)
    }

    /// 引导只发生一次：标记后重复调用 no-op；被中断的引导（无标记）安全续跑
    /// ——create 幂等合并不产生重复记录。
    func testBootstrapMarkerMakesSecondRunNoOp() throws {
        seedDirectory("/p")
        _ = makeSession(cwd: "/p")
        _ = registry.bootstrapIfNeeded()
        let second = registry.bootstrapIfNeeded()
        XCTAssertTrue(second.alreadyInitialized)
        XCTAssertEqual(second.workspacesCreated, 0)
        XCTAssertEqual(second.sessionsAttached, 0)
        XCTAssertEqual(registry.list().count, 1)
    }
}
