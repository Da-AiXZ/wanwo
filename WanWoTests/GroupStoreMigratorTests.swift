//
//  GroupStoreMigratorTests.swift
//  WanWoTests
//
//  【M4-E+ P1 测试 · 项目锚点存储半边】迁移器（临时目录真实 FS fixture）：
//  空状态 no-op / 旧 JSONL 搬迁 / UUID 桶目录搬迁（四 bucket 子目录完整性）/
//  非 UUID 目录与 config 等不动 / 幂等二次运行零改动 / 目标同名冲突不删源且
//  其余继续 / SessionStore root 指向分组维度路径后 createSession/listSessions/
//  fileURL 语义不变。（GRDB 回填集成测试见 SessionDatabaseMigrationTests——
//  v2 旧库 fixture 需 GRDB import。）
//

import XCTest
@testable import WanWo

final class GroupStoreMigratorTests: XCTestCase {

    // MARK: fixture

    /// 以 workDir 充当 persistentBase 形状的迁移根。
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4e-p1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeDatabase() throws -> SessionDatabase {
        try SessionDatabase(
            path: base.appendingPathComponent("wanwo-index.sqlite3").path)
    }

    private func writeLegacyJSONL(_ name: String,
                                  content: String = "{\"t\":1}\n") throws {
        let dir = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func makeLegacyBucketDir(sid: String = UUID().uuidString) throws -> URL {
        let dir = base.appendingPathComponent(sid, isDirectory: true)
        for bucket in GroupStore.knownBuckets {
            let bucketDir = dir.appendingPathComponent(bucket, isDirectory: true)
            try FileManager.default.createDirectory(at: bucketDir,
                                                    withIntermediateDirectories: true)
            try "x".write(to: bucketDir.appendingPathComponent("payload.txt"),
                          atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: 空状态 no-op

    func testEmptyStateIsNoOp() throws {
        let db = try makeDatabase()
        let report = GroupStoreMigrator(base: base, database: db).migrate()
        XCTAssertEqual(report, GroupStoreMigrator.Report())
        // 目标骨架已建（先建后搬），但无任何搬移痕迹。
        XCTAssertTrue(exists(GroupStore.groupSessionsRoot(
            base: base, groupID: GroupStore.defaultGroupID)))
    }

    // MARK: 旧 JSONL 搬迁

    func testLegacyJSONLMovedIntoDefaultGroup() throws {
        try writeLegacyJSONL("aaaa-bbbb.jsonl")
        try writeLegacyJSONL("cccc-dddd.jsonl")
        // 非 jsonl 文件不搬。
        let stray = base.appendingPathComponent("sessions")
            .appendingPathComponent("notes.txt")
        try "n".write(to: stray, atomically: true, encoding: .utf8)

        let db = try makeDatabase()
        let report = GroupStoreMigrator(base: base, database: db).migrate()

        XCTAssertEqual(report.movedJSONLFiles, 2)
        let targetRoot = GroupStore.groupSessionsRoot(
            base: base, groupID: GroupStore.defaultGroupID)
        XCTAssertTrue(exists(targetRoot.appendingPathComponent("aaaa-bbbb.jsonl")))
        XCTAssertTrue(exists(targetRoot.appendingPathComponent("cccc-dddd.jsonl")))
        XCTAssertFalse(exists(base.appendingPathComponent("sessions")
            .appendingPathComponent("aaaa-bbbb.jsonl")))
        // 非 jsonl 留在原地。
        XCTAssertTrue(exists(stray))
    }

    // MARK: UUID 桶目录搬迁（四 bucket 子目录完整性）

    func testUUIDBucketDirMovedWithAllBucketsIntact() throws {
        let sid = UUID().uuidString
        try makeLegacyBucketDir(sid: sid)

        let db = try makeDatabase()
        let report = GroupStoreMigrator(base: base, database: db).migrate()

        XCTAssertEqual(report.movedBucketDirs, 1)
        let target = GroupStore.groupRoot(base: base,
                                          groupID: GroupStore.defaultGroupID)
            .appendingPathComponent(sid, isDirectory: true)
        for bucket in GroupStore.knownBuckets {
            XCTAssertTrue(exists(target
                .appendingPathComponent(bucket, isDirectory: true)
                .appendingPathComponent("payload.txt")), bucket)
        }
        XCTAssertFalse(exists(base.appendingPathComponent(sid)))
    }

    // MARK: 非 UUID 目录 / 非 bucket UUID 目录绝不触碰

    func testNonUUIDPathsUntouched() throws {
        // config 族（R3 基线）。
        let configDir = base.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir,
                                                withIntermediateDirectories: true)
        try "{}".write(to: configDir.appendingPathComponent("providers.json"),
                       atomically: true, encoding: .utf8)
        // 全局桶 skills。
        let skillsDir = base.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir,
                                                withIntermediateDirectories: true)
        // UUID 形状但不含已知 bucket 的目录（如 spill/<sid>）不认定为会话桶。
        let uuidNoBuckets = base.appendingPathComponent(UUID().uuidString,
                                                        isDirectory: true)
        try FileManager.default.createDirectory(
            at: uuidNoBuckets.appendingPathComponent("spills", isDirectory: true),
            withIntermediateDirectories: true)

        let db = try makeDatabase()
        _ = GroupStoreMigrator(base: base, database: db).migrate()

        XCTAssertTrue(exists(configDir.appendingPathComponent("providers.json")))
        XCTAssertTrue(exists(skillsDir))
        XCTAssertTrue(exists(uuidNoBuckets.appendingPathComponent("spills")))
    }

    // MARK: 幂等（二次运行零改动）

    func testSecondRunIsIdempotentNoOp() throws {
        try writeLegacyJSONL("sess-1.jsonl")
        try makeLegacyBucketDir()
        let db = try makeDatabase()

        let first = GroupStoreMigrator(base: base, database: db).migrate()
        XCTAssertEqual(first.movedJSONLFiles, 1)
        XCTAssertEqual(first.movedBucketDirs, 1)

        let second = GroupStoreMigrator(base: base, database: db).migrate()
        XCTAssertEqual(second, GroupStoreMigrator.Report())
    }

    // MARK: 目标同名冲突 → 不删源、不覆盖目标、其余继续

    func testTargetConflictSkipsAndKeepsSourceAndRestProceed() throws {
        try writeLegacyJSONL("clash.jsonl", content: "legacy\n")
        try writeLegacyJSONL("ok.jsonl")
        // 目标已存在同名（已迁移场景）→ 跳过，源保留，内容零覆盖。
        let targetRoot = GroupStore.groupSessionsRoot(
            base: base, groupID: GroupStore.defaultGroupID)
        try FileManager.default.createDirectory(at: targetRoot,
                                                withIntermediateDirectories: true)
        try "already-migrated\n".write(
            to: targetRoot.appendingPathComponent("clash.jsonl"),
            atomically: true, encoding: .utf8)

        let db = try makeDatabase()
        let report = GroupStoreMigrator(base: base, database: db).migrate()

        XCTAssertEqual(report.skippedConflicts, 1)
        XCTAssertEqual(report.failedItems, 0)
        XCTAssertEqual(report.movedJSONLFiles, 1)
        // 源与目标内容均原样（零丢失、零覆盖）。
        XCTAssertEqual(read(base.appendingPathComponent("sessions")
            .appendingPathComponent("clash.jsonl")), "legacy\n")
        XCTAssertEqual(read(targetRoot.appendingPathComponent("clash.jsonl")),
                       "already-migrated\n")
        // 无冲突文件照常搬（单项失败/跳过不阻塞其余）。
        XCTAssertTrue(exists(targetRoot.appendingPathComponent("ok.jsonl")))
    }

    // MARK: SessionStore root 指向分组维度路径后语义不变

    func testSessionStoreAtGroupedRootUnchangedSemantics() async throws {
        let db = try makeDatabase()
        let sessionsRoot = GroupStore.groupSessionsRoot(
            base: base, groupID: GroupStore.defaultGroupID)
        let store = SessionStore(root: sessionsRoot, database: db)

        let summary = try await store.createSession(cwd: nil)
        XCTAssertEqual(summary.groupId, GroupStore.defaultGroupID)

        // fileURL 语义不变：root/<sid>.jsonl（锚点 SessionStore.swift:86）。
        let expectedFile = sessionsRoot.appendingPathComponent("\(summary.id).jsonl")
        XCTAssertTrue(exists(expectedFile))

        let list = await store.listSessions()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, summary.id)
        XCTAssertEqual(list.first?.groupId, GroupStore.defaultGroupID)
    }
}
