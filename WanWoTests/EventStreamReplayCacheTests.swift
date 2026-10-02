//
//  EventStreamReplayCacheTests.swift
//  WanWoTests
//
//  【批6 I1】EventStreamReplayCache 失效语义单测：
//    · revision 失效回归（既有语义防回退）；
//    · stat 失效新例（源 .jsonl 增长/被删 → 查看与导出缓存失效——导出截断
//      修复，用户实证"8 轮导出后续跑 3 轮二次导出仍是旧文件"）；
//    · stat 不变命中回归（stat 引入不破坏 f② 秒开收益）；
//    · 容量 2 插入序淘汰回归。
//  stat 以临时文件实测（显式 setAttributes(.modificationDate) 定时钟——
//  不依赖文件系统 mtime 精度，CI 无抖动面）。
//

import XCTest
@testable import WanWo

@MainActor
final class EventStreamReplayCacheTests: XCTestCase {

    // MARK: - Fixture（临时目录 + 注入 stat 取样器）

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i1-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    /// 缓存实例（stat 取样指向临时目录 <id>.jsonl）。
    private func makeCache() -> EventStreamReplayCache {
        let dir = tempDir
        return EventStreamReplayCache { sessionID in
            let url = dir!.appendingPathComponent("\(sessionID).jsonl")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return .init(size: size, modificationDate: mtime)
        }
    }

    /// 定钟写文件（字节内容无意义——stat 只看 size/mtime 两维）。
    private func writeLog(_ sessionID: String, bytes: Int, mtime: Date) throws {
        let url = tempDir.appendingPathComponent("\(sessionID).jsonl")
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime],
                                              ofItemAtPath: url.path)
    }

    private func makeOutput(_ sessionID: String) -> EventStreamLoader.Output {
        .init(sessionID: sessionID, createdAtMs: 0, rows: [], rawEventCount: 0, issue: nil)
    }

    // MARK: - revision 失效（既有语义回归）

    func testRevisionMismatchInvalidatesAndClearsEntry() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)

        XCTAssertNotNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                        "同 revision 命中")
        // revision 推进（会话删除/新建）→ 失效并清条目。
        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 2),
                     "revision 推进即失效")
        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                     "过期条目已顺手清除，回落原 revision 也不再命中")
    }

    // MARK: - stat 失效（【I1】新增：源文件增长 = 查看与导出失效）

    func testSourceGrowthInvalidatesCache() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)

        XCTAssertNotNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                        "写入后首查命中")

        // 同一会话继续跑回合：.jsonl 追加（size+mtime 双变），revision 不动。
        try writeLog("s1", bytes: 40, mtime: Date(timeIntervalSince1970: 2000))

        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                     "【I1】同一会话事件增长必须失效——否则查看停旧轮次、导出旧副本")
    }

    /// 同尺寸重写（mtime 变化）也判变——mtime 维度覆盖 size 不变的 rewrite 面。
    func testSameSizeMtimeChangeInvalidatesCache() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)

        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 3000))

        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                     "mtime 变化（同尺寸重写）即失效")
    }

    /// 源文件被外部删除 → 失效（stat nil vs 基线非 nil 判变）。
    func testSourceRemovalInvalidatesCache() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)

        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("s1.jsonl"))

        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                     "源文件消失即失效")
    }

    // MARK: - 命中回归（stat 引入不破坏 f② 秒开）

    func testUnchangedStatStaysHit() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)

        let first = cache.get(sessionID: "s1", sessionsRevision: 1)
        let second = cache.get(sessionID: "s1", sessionsRevision: 1)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "文件无变化时重复 get 恒命中（多次进入页面秒开）")
        XCTAssertEqual(first?.output.sessionID, second?.output.sessionID)
    }

    /// 失效后重新 put → 重新命中（导出重制后缓存恢复）。
    func testReputAfterInvalidationRecoversHit() throws {
        try writeLog("s1", bytes: 10, mtime: Date(timeIntervalSince1970: 1000))
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)
        _ = cache.get(sessionID: "s1", sessionsRevision: 1)

        try writeLog("s1", bytes: 40, mtime: Date(timeIntervalSince1970: 2000))
        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1))

        // 未命中路径全量重放后 put 新基线。
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)
        XCTAssertNotNil(cache.get(sessionID: "s1", sessionsRevision: 1),
                        "失效后重 put（新 stat 基线）恢复命中")
    }

    // MARK: - 容量淘汰回归

    func testCapacityEvictionKeepsTwoNewest() throws {
        let mtime = Date(timeIntervalSince1970: 1000)
        try writeLog("s1", bytes: 10, mtime: mtime)
        try writeLog("s2", bytes: 10, mtime: mtime)
        try writeLog("s3", bytes: 10, mtime: mtime)
        let cache = makeCache()
        cache.put(sessionID: "s1", sessionsRevision: 1,
                  output: makeOutput("s1"), exportURL: nil)
        cache.put(sessionID: "s2", sessionsRevision: 1,
                  output: makeOutput("s2"), exportURL: nil)
        cache.put(sessionID: "s3", sessionsRevision: 1,
                  output: makeOutput("s3"), exportURL: nil)

        XCTAssertNil(cache.get(sessionID: "s1", sessionsRevision: 1), "容量 2：最旧 s1 淘汰")
        XCTAssertNotNil(cache.get(sessionID: "s2", sessionsRevision: 1))
        XCTAssertNotNil(cache.get(sessionID: "s3", sessionsRevision: 1))
    }
}
