//
//  MemoryProjectTests.swift
//  WanWoTests
//
//  【M8 批3 件 C1 单测】记忆管线项目化断言点：
//    - MemoryProjectLayout：桶解析（projectsHostRoot/wanwo-memory 同构兄弟
//      桶）、cwd 归一（尾斜杠/空白/空串）、legacy 回落（nil/非项目 cwd）、
//      候选匹配口径（projectKey 相等；双 nil = legacy 池）、管线存储面工厂
//      （项目桶清单 = 桶内隐藏文件；legacy 与 AppEnvironment 装配段同源）。
//    - 多项目桶隔离：MemoryStorage 两桶互不串扰（raw_memories/rollout_
//      summaries/清单各自独立）；桶内清单隐藏文件不入快照树。
//    - MemoryDatabase project 维度：stage1 落账 project_key、Phase2 输入
//      选取按项目过滤（NULL = legacy 池）、selected_for_phase2 重写按项目
//      收窄、Phase2 任务键按项目分行隔离、崩溃回收覆盖全部项目任务键。
//    - 全部纯同步 + 临时目录。
//

import XCTest
@testable import WanWo

final class MemoryProjectTests: XCTestCase {

    // MARK: - 桶解析（冻结契约）

    func testMemoryBucketURLResolution() {
        let cwd = "/var/wanwo/projects/p1"
        let bucket = MemoryProjectLayout.memoryBucketURL(forCwd: cwd)
        XCTAssertNotNil(bucket)
        XCTAssertEqual(bucket?.lastPathComponent, "wanwo-memory")
        // 与 projectsHostRoot 同一映射面（B3 SessionNotes wanwo-notes 兄弟桶）。
        XCTAssertEqual(
            bucket?.deletingLastPathComponent().path,
            WanWoPaths.projectsHostRoot(forGuestPath: cwd)?.path)
        // 项目子目录 cwd 同一映射面。
        let sub = MemoryProjectLayout.memoryBucketURL(forCwd: cwd + "/sub")
        XCTAssertEqual(
            sub?.deletingLastPathComponent().path,
            WanWoPaths.projectsHostRoot(forGuestPath: cwd + "/sub")?.path)
    }

    func testMemoryBucketURLLegacyFallbackNil() {
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(forCwd: nil))
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(forCwd: ""))
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(forCwd: "   "))
        // legacy 全局工作区/记忆根/任意非项目 guest 路径 → nil（fail closed）。
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(
            forCwd: WanWoPaths.workspaceLinuxDir))
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(
            forCwd: MemoryConstants.memoryGuestPath))
        XCTAssertNil(MemoryProjectLayout.memoryBucketURL(forCwd: "/var/wanwo/attachments"))
    }

    func testProjectKeyNormalization() {
        // 尾斜杠/空白归一后同键。
        XCTAssertEqual(MemoryProjectLayout.projectKey(forCwd: "/var/wanwo/projects/p1"),
                       MemoryProjectLayout.projectKey(forCwd: "/var/wanwo/projects/p1/"))
        XCTAssertEqual(MemoryProjectLayout.projectKey(forCwd: " /var/wanwo/projects/p1 "),
                       "/var/wanwo/projects/p1")
        // 不同项目异键。
        XCTAssertNotEqual(MemoryProjectLayout.projectKey(forCwd: "/var/wanwo/projects/p1"),
                          MemoryProjectLayout.projectKey(forCwd: "/var/wanwo/projects/p2"))
        // 不可解析 → nil。
        XCTAssertNil(MemoryProjectLayout.projectKey(forCwd: nil))
        // workspaceLinuxDir 是普通可归一化路径（非空非 /）→ 键 = 路径本身
        // （实现口径：projectKey = 归一化 cwd；"projects 根外"的回落判定在
        // memoryBucketURL/projectsHostRoot 层，不在键层）。
        XCTAssertEqual(MemoryProjectLayout.projectKey(forCwd: WanWoPaths.workspaceLinuxDir),
                       "/var/wanwo/workspace")
    }

    // MARK: - 候选匹配口径

    func testCandidateProjectMatching() {
        let p1 = "/var/wanwo/projects/p1"
        let p2 = "/var/wanwo/projects/p2"
        // 同项目（含子目录 cwd）→ 候选。
        XCTAssertTrue(MemoryProjectLayout.isCandidate(sessionCwd: p1, currentCwd: p1))
        XCTAssertTrue(MemoryProjectLayout.isCandidate(sessionCwd: p1 + "/sub",
                                                      currentCwd: p1 + "/sub"))
        // 异项目 → 排除。
        XCTAssertFalse(MemoryProjectLayout.isCandidate(sessionCwd: p2, currentCwd: p1))
        // legacy 池（双方均无项目键）→ 候选。
        XCTAssertTrue(MemoryProjectLayout.isCandidate(sessionCwd: nil, currentCwd: nil))
        // 同为 legacy 工作区（同键）→ 候选。
        XCTAssertTrue(MemoryProjectLayout.isCandidate(
            sessionCwd: WanWoPaths.workspaceLinuxDir, currentCwd: WanWoPaths.workspaceLinuxDir))
        // legacy 工作区 vs 项目上下文 → 键异 → 排除。
        XCTAssertFalse(MemoryProjectLayout.isCandidate(
            sessionCwd: WanWoPaths.workspaceLinuxDir, currentCwd: p1))
        // 项目会话 vs 无键上下文 → 排除。
        XCTAssertFalse(MemoryProjectLayout.isCandidate(sessionCwd: p1, currentCwd: nil))
    }

    // MARK: - 管线存储面（legacy 回落 + 桶内清单）

    func testPipelineStorageFactoryProjectBucket() {
        let storage = MemoryProjectLayout.storage(forCwd: "/var/wanwo/projects/p1")
        XCTAssertEqual(storage.rootURL.lastPathComponent, "wanwo-memory")
        // 清单 = 桶内隐藏文件（登记：三面豁免，随桶同生共灭）。
        XCTAssertEqual(storage.manifestURL.lastPathComponent, ".memory-snapshot.json")
        XCTAssertEqual(storage.manifestURL.deletingLastPathComponent()
            .standardizedFileURL.path, storage.rootURL.standardizedFileURL.path)
    }

    func testPipelineStorageFactoryLegacyFallback() {
        // cwd 不可解析 → legacy 全局桶（与 AppEnvironment 装配段同源）。
        for cwd in [nil as String?, "", WanWoPaths.workspaceLinuxDir] {
            let storage = MemoryProjectLayout.storage(forCwd: cwd)
            XCTAssertEqual(storage.rootURL, WanWoPaths.memoryPersistentDir)
            XCTAssertEqual(storage.manifestURL,
                           WanWoPaths.configPersistentDir
                               .appendingPathComponent(
                                   MemoryProjectLayout.legacyManifestFilename))
        }
        XCTAssertEqual(MemoryProjectLayout.storage(forCwd: nil).rootURL,
                       MemoryProjectLayout.legacyStorage.rootURL)
    }

    func testBucketGuestPath() {
        XCTAssertEqual(MemoryProjectLayout.memoryBucketGuestPath(
            forCwd: "/var/wanwo/projects/p1"), "/var/wanwo/projects/p1/wanwo-memory")
        XCTAssertNil(MemoryProjectLayout.memoryBucketGuestPath(
            forCwd: WanWoPaths.workspaceLinuxDir))
        XCTAssertNil(MemoryProjectLayout.memoryBucketGuestPath(forCwd: nil))
    }

    // MARK: - 多项目桶隔离（纯同步 + 临时目录）

    private func makeBuckets() throws -> (MemoryStorage, MemoryStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-memproj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func bucket(_ name: String) -> MemoryStorage {
            let url = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("wanwo-memory", isDirectory: true)
            return MemoryStorage(
                rootURL: url,
                manifestURL: url.appendingPathComponent(
                    MemoryProjectLayout.bucketManifestFilename))
        }
        return (bucket("p1"), bucket("p2"), root)
    }

    private func record(_ threadId: String, raw: String, summary: String) -> MemoryStage1Record {
        MemoryStage1Record(threadId: threadId, sourceUpdatedAt: 100,
                           rawMemory: raw, rolloutSummary: summary, rolloutSlug: nil,
                           generatedAt: 100, usageCount: nil, lastUsage: nil,
                           selectedForPhase2: false,
                           selectedForPhase2SourceUpdatedAt: nil)
    }

    func testMultiProjectBucketIsolation() throws {
        let (storageA, storageB, _) = try makeBuckets()
        let recordA = record("t-a", raw: "raw A", summary: "sum A")
        let recordB = record("t-b", raw: "raw B", summary: "sum B")

        try storageA.rebuildRawMemoriesFile([recordA], maxRawMemoriesForConsolidation: 256,
                                            cwdFor: { _ in "/var/wanwo/projects/p1" })
        try storageA.syncRolloutSummaries([recordA], maxRawMemoriesForConsolidation: 256,
                                          cwdFor: { _ in "/var/wanwo/projects/p1" })
        try storageB.rebuildRawMemoriesFile([recordB], maxRawMemoriesForConsolidation: 256,
                                            cwdFor: { _ in "/var/wanwo/projects/p2" })

        let rawA = try String(contentsOf: storageA.rootURL
            .appendingPathComponent(MemoryConstants.rawMemoriesFilename), encoding: .utf8)
        XCTAssertTrue(rawA.contains("t-a"))
        XCTAssertFalse(rawA.contains("t-b"))
        let rawB = try String(contentsOf: storageB.rootURL
            .appendingPathComponent(MemoryConstants.rawMemoriesFilename), encoding: .utf8)
        XCTAssertTrue(rawB.contains("t-b"))
        XCTAssertFalse(rawB.contains("t-a"))

        // rollout_summaries 桶内隔离：A 的摘要文件不在 B。
        let summariesB = try FileManager.default.contentsOfDirectory(
            atPath: storageB.rootURL
                .appendingPathComponent(MemoryConstants.rolloutSummariesSubdir).path)
        XCTAssertTrue(summariesB.allSatisfy { !$0.contains("t-a") })

        // 清单按桶独立：A 拍基线后 B 的 diff 不受影响（B 全量 added）。
        try storageA.saveManifest(storageA.snapshotManifest())
        let diffB = storageB.diffAgainstManifest(storageB.loadManifest())
        XCTAssertTrue(diffB.hasChanges)
        let diffA = storageA.diffAgainstManifest(storageA.loadManifest())
        XCTAssertFalse(diffA.hasChanges)
    }

    func testBucketManifestHiddenFileExcludedFromSnapshot() throws {
        let (storageA, _, _) = try makeBuckets()
        try storageA.ensureLayout()
        // 写入 MEMORY.md + memory_summary.md + 清单。
        try Data("# memory\n".utf8).write(
            to: storageA.rootURL.appendingPathComponent("MEMORY.md"))
        try Data("v1\nsummary\n".utf8).write(
            to: storageA.rootURL.appendingPathComponent("memory_summary.md"))
        try storageA.saveManifest(MemorySnapshotManifest(entries: ["x": "y"]))
        // 清单隐藏文件不入快照树（skipsHiddenFiles 豁免——登记）。
        let snapshot = storageA.snapshotManifest()
        XCTAssertNil(snapshot.entries[MemoryProjectLayout.bucketManifestFilename])
        XCTAssertTrue(snapshot.entries.keys.contains("MEMORY.md"))
    }

    // MARK: - 账本 project 维度

    private func makeDatabase() throws -> (MemoryDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-memproj-db-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try MemoryDatabase(
            path: dir.appendingPathComponent("memory-index.sqlite3").path)
        return (db, dir)
    }

    func testStage1ProjectKeyRoundtripAndScopedSelection() throws {
        let (db, _) = try makeDatabase()
        let p1 = "/var/wanwo/projects/p1"
        let p2 = "/var/wanwo/projects/p2"
        // sourceUpdatedAt 必须取当前附近（getPhase2InputSelection 带
        // max_unused_days 淘汰：COALESCE(last_usage, source_updated_at) >= now-30d
        // ——1970 时间戳会被当作"30 天未使用"淘汰，与生产候选口径一致）。
        let fresh = Int(Date().timeIntervalSince1970)
        try db.markStage1JobSucceeded(threadId: "p1-t", sourceUpdatedAt: fresh,
                                      rawMemory: "r", rolloutSummary: "s",
                                      rolloutSlug: nil, projectKey: p1)
        try db.markStage1JobSucceeded(threadId: "p2-t", sourceUpdatedAt: fresh,
                                      rawMemory: "r", rolloutSummary: "s",
                                      rolloutSlug: nil, projectKey: p2)
        try db.markStage1JobSucceeded(threadId: "legacy-t", sourceUpdatedAt: fresh,
                                      rawMemory: "r", rolloutSummary: "s",
                                      rolloutSlug: nil)

        // Phase2 输入选取按项目过滤（`IS ?`——nil = legacy 池）。
        XCTAssertEqual(try db.getPhase2InputSelection(limit: 10, maxUnusedDays: 30,
                                                      projectKey: p1).map(\.threadId),
                       ["p1-t"])
        XCTAssertEqual(try db.getPhase2InputSelection(limit: 10, maxUnusedDays: 30,
                                                      projectKey: p2).map(\.threadId),
                       ["p2-t"])
        XCTAssertEqual(try db.getPhase2InputSelection(limit: 10, maxUnusedDays: 30)
            .map(\.threadId), ["legacy-t"])
        // 全量读面同口径。
        XCTAssertEqual(try db.allStage1Outputs(projectKey: p1).map(\.threadId), ["p1-t"])
        XCTAssertEqual(try db.allStage1Outputs().map(\.threadId), ["legacy-t"])
        XCTAssertEqual(try db.listEntries(projectKey: p2).map(\.threadId), ["p2-t"])
    }

    func testSelectedForPhase2RewriteScopedToProject() throws {
        let (db, _) = try makeDatabase()
        let p1 = "/var/wanwo/projects/p1"
        let p2 = "/var/wanwo/projects/p2"
        try db.markStage1JobSucceeded(threadId: "p1-t", sourceUpdatedAt: 100,
                                      rawMemory: "r", rolloutSummary: "s",
                                      rolloutSlug: nil, projectKey: p1)
        try db.markStage1JobSucceeded(threadId: "p2-t", sourceUpdatedAt: 100,
                                      rawMemory: "r", rolloutSummary: "s",
                                      rolloutSlug: nil, projectKey: p2)
        // p1 整合成功选中 p1-t——p2 行零扰动（跨项目隔离关键面）。
        try db.markGlobalPhase2JobSucceeded(completionWatermark: 100,
                                            selectedThreadIds: ["p1-t"],
                                            projectKey: p1)
        let rows = try db.allStage1Outputs(projectKey: p1)
            + (try db.allStage1Outputs(projectKey: p2))
        let selectedByID = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.threadId, $0.selectedForPhase2) })
        XCTAssertEqual(selectedByID["p1-t"], true)
        XCTAssertEqual(selectedByID["p2-t"], false)
    }

    func testPhase2JobIsolationPerProject() throws {
        let (db, _) = try makeDatabase()
        let p1Key = MemoryDatabase.phase2JobKey(forProjectKey: "/var/wanwo/projects/p1")
        // p1 抢占 → running；'global'（legacy）不受影响，仍可抢占。
        guard case .claimed = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600,
                                                             jobKey: p1Key)
        else { return XCTFail("expected p1 claimed") }
        guard case .claimed = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected global claimed") }
        // 同项目 running 期间再抢 → skippedRunning。
        guard case .skippedRunning = try db.tryClaimGlobalPhase2Job(
            cooldownSeconds: 21_600, jobKey: p1Key)
        else { return XCTFail("expected p1 skippedRunning") }
        // p1 成功落账（done + 冷却）；global 冷却窗互不影响。
        try db.markGlobalPhase2JobSucceeded(completionWatermark: 7,
                                            selectedThreadIds: [], projectKey:
                                                "/var/wanwo/projects/p1")
        guard case .skippedCooldown = try db.tryClaimGlobalPhase2Job(
            cooldownSeconds: 21_600, jobKey: p1Key)
        else { return XCTFail("expected p1 cooldown") }
        // global 无成功记录 → 非冷却。
        guard case .skippedRunning = try db.tryClaimGlobalPhase2Job(
            cooldownSeconds: 21_600)
        else { return XCTFail("expected global still running") }
        // 状态行按任务键读取。
        XCTAssertEqual(try db.lastPhase2SuccessDate(jobKey: p1Key) != nil, true)
        XCTAssertEqual(try db.lastPhase2SuccessDate(), nil)
    }

    func testRecoverInterruptedPhase2AcrossProjectKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-memproj-rec-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory-index.sqlite3").path

        // 两个项目 + legacy 各留一个 running 残行。
        do {
            let db = try MemoryDatabase(path: path)
            guard case .claimed = try db.tryClaimGlobalPhase2Job(
                cooldownSeconds: 21_600, jobKey: "p1") else {
                return XCTFail("expected p1 claimed")
            }
            guard case .claimed = try db.tryClaimGlobalPhase2Job(
                cooldownSeconds: 21_600, jobKey: "p2") else {
                return XCTFail("expected p2 claimed")
            }
            guard case .claimed = try db.tryClaimGlobalPhase2Job(
                cooldownSeconds: 21_600) else {
                return XCTFail("expected global claimed")
            }
        }
        // 重开账本（init 崩溃回收）：全部 running 残行复位 error——不再
        // skippedRunning（进入重试窗 skippedRetryUnavailable）。
        let reopened = try MemoryDatabase(path: path)
        for jobKey in ["p1", "p2", "global"] {
            guard case .skippedRetryUnavailable = try reopened.tryClaimGlobalPhase2Job(
                cooldownSeconds: 21_600, jobKey: jobKey) else {
                return XCTFail("expected \(jobKey) recovered into retry window")
            }
        }
    }
}
