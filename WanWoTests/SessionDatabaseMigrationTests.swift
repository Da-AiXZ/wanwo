//
//  SessionDatabaseMigrationTests.swift
//  WanWoTests
//
//  【M4-E+ P1 测试】SessionDatabase v3 迁移（M4-E+ P1 项目锚点存储半边）：
//  groups 表 + sessionIndex.groupId 列 + default 分组 seed——
//    · v2 旧库打开 → v3 自动迁移（groups 表在 + groupId 列在 + legacy 行
//      groupId NULL → 迁移器回填 'default'）
//    · 全新库直建 v3（default 行 seeded）
//    · SessionSummary.groupId 读写往返
//  v2 旧库 fixture：用 GRDB migrator 以**相同 identifier**（wanwo.sessionIndex.
//  v1/v2，复刻 SessionDatabase.swift:42-58 锚点 DDL）预记账 grdb_migrations，
//  再插入一行 v2 时代索引——SessionDatabase 打开时 v1/v2 视为已应用、只跑 v3。
//

import XCTest
import GRDB
@testable import WanWo

final class SessionDatabaseMigrationTests: XCTestCase {

    // MARK: fixture

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4e-p1-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private var dbPath: String {
        workDir.appendingPathComponent("wanwo-index.sqlite3").path
    }

    /// 复刻 v1/v2 迁移（同 identifier 记账）+ 一行 v2 时代索引行
    /// （groupId 时代之前 → v3 加列后为 NULL）。
    private func makeLegacyV2Database() throws {
        let queue = try DatabaseQueue(path: dbPath)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("wanwo.sessionIndex.v1") { db in
            try db.create(table: "sessionIndex") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("eventCount", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("wanwo.sessionIndex.v2") { db in
            try db.alter(table: "sessionIndex") { t in
                t.add(column: "fileMtime", .double)
                t.add(column: "fileSize", .integer)
            }
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessionIndex (id, title, createdAt, updatedAt, eventCount) "
                    + "VALUES (?, ?, ?, ?, ?)",
                arguments: ["legacy-1", "legacy title", Date(), Date(), 3])
        }
        try queue.close()
    }

    // MARK: v2 旧库打开 → v3 自动迁移

    func testV2DatabaseAutoMigratesToV3() throws {
        try makeLegacyV2Database()
        let db = try SessionDatabase(path: dbPath)

        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("groups"))
            let columns = try db.columns(in: "sessionIndex").map(\.name)
            XCTAssertTrue(columns.contains("groupId"), "\(columns)")
        }
        // legacy 行可读，且 groupId 读路径 NULL → default 兜底（不依赖迁移器）。
        let summaries = db.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.id, "legacy-1")
        XCTAssertEqual(summaries.first?.groupId, GroupStore.defaultGroupID)
    }

    // MARK: 全新库直建 v3（default 行 seeded）

    func testFreshDatabaseSeedsDefaultGroup() throws {
        _ = try SessionDatabase(path: dbPath)

        let queue = try DatabaseQueue(path: dbPath)
        defer { try? queue.close() }
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("groups"))
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, name, createdAtMs FROM groups")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["id"] as? String, GroupStore.defaultGroupID)
            XCTAssertEqual(rows.first?["name"] as? String, GroupStore.defaultGroupName)
            XCTAssertNotNil(rows.first?["createdAtMs"] as? Int64)
        }
    }

    // MARK: SessionSummary.groupId 读写往返

    func testSummaryGroupIdRoundtrip() throws {
        let db = try SessionDatabase(path: dbPath)
        let now = Date()
        db.upsert(SessionSummary(id: "s1", title: nil, createdAt: now,
                                 updatedAt: now, eventCount: 0,
                                 groupId: GroupStore.defaultGroupID))
        let listed = db.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "s1")
        XCTAssertEqual(listed.first?.groupId, GroupStore.defaultGroupID)
    }

    // MARK: 迁移器回填集成（v2 行 groupId NULL → 'default'）

    func testMigratorBackfillsNullGroupIDs() throws {
        try makeLegacyV2Database()
        let db = try SessionDatabase(path: dbPath)

        // 迁移前：groupId 列值为 NULL（v3 只加列不回填——回填职责在
        // GroupStoreMigrator，锚点分工）。
        let queue = try DatabaseQueue(path: dbPath)
        try queue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT groupId FROM sessionIndex WHERE id = ?",
                arguments: ["legacy-1"])
            let groupId: String? = row?["groupId"]
            XCTAssertNil(groupId)
        }
        try queue.close()

        let report = GroupStoreMigrator(base: workDir, database: db).migrate()
        XCTAssertEqual(report.backfilledRows, 1)
        XCTAssertEqual(db.list().first?.groupId, GroupStore.defaultGroupID)

        // 幂等：再次回填零行。
        let second = GroupStoreMigrator(base: workDir, database: db).migrate()
        XCTAssertEqual(second.backfilledRows, 0)
    }
}
