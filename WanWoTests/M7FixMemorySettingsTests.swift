//
//  M7FixMemorySettingsTests.swift
//  WanWoTests
//
//  【M7 修复 E2 · 落点⑧⑩补测】：
//    - stripCitations 端到端样例：多段 citation 剥离 + 载荷解析 + thread_ids
//      过滤 → MemoryDatabase.recordMemoryUsage 账本回写（usage_count/last_usage/
//      未命中行不动；同次调用内重复 id Set 去重 = 只 +1）。
//    - 设置页条目列表数据源纯函数：findDocumentBlocks（MEMORY.md "# Task
//      Group:" / raw_memories "## Thread \`"）、replacingBlock/removingBlock
//      拼接往返、metadataFieldValue/metadataFieldInline/parseMemoryTimestamp。
//    - MemoryStorage.listSettingEntries / updateSettingEntry /
//      deleteSettingEntry：四类条目枚举、区块编辑回写、单条删除、失效索引报错。
//

import XCTest
@testable import WanWo

final class M7FixMemorySettingsTests: XCTestCase {

    // MARK: - stripCitations 端到端（落点⑧补测）

    func testStripCitationsEndToEndAndUsageWriteBack() throws {
        // 1) 模型回复含两段 citation（跨段 rollout_ids 去重保序 + 非 UUID 过滤）。
        let text = "先答一半 <oai-mem-citation><citation_entries>\n"
            + "MEMORY.md:10-12|note=[deploy flow]\n"
            + "</citation_entries>\n<rollout_ids>\n"
            + "019cc2ea-1dff-7902-8d40-c8f6e5d83cc4\n"
            + "not-a-uuid\n</rollout_ids></oai-mem-citation>"
            + " 再答另一半 <oai-mem-citation><rollout_ids>\n"
            + "019cc2ea-1dff-7902-8d40-c8f6e5d83cc4\n"
            + "019cc2ea-1dff-7902-8d40-c8f6e5d83cc5\n"
            + "</rollout_ids></oai-mem-citation> 收尾"
        let (visible, payloads) = MemoryCitations.splitCitations(from: text)
        // 可见文本 = 两段标记整段剥离、首尾文本保留。
        XCTAssertEqual(visible, "先答一半  再答另一半  收尾")
        XCTAssertEqual(payloads.count, 2)

        // 2) 载荷解析 + thread_ids 过滤（UUID 子集、跨段去重保序）。
        let payload = try XCTUnwrap(MemoryCitations.extractCitations(from: text))
        XCTAssertEqual(payload.entries.count, 1)
        XCTAssertEqual(payload.entries.first?.path, "MEMORY.md")
        XCTAssertEqual(payload.entries.first?.lineStart, 10)
        XCTAssertEqual(payload.entries.first?.lineEnd, 12)
        let threadIds = MemoryCitations.threadIds(in: payload)
        XCTAssertEqual(threadIds,
                       ["019cc2ea-1dff-7902-8d40-c8f6e5d83cc4",
                        "019cc2ea-1dff-7902-8d40-c8f6e5d83cc5"])

        // 3) 未闭合尾段 = 保留原样（终态防御，citation.rs 非 auto-close 面）。
        let unterminated = "abc <oai-mem-citation>dangling"
        XCTAssertEqual(MemoryCitations.splitCitations(from: unterminated).visible,
                       unterminated)
        XCTAssertNil(MemoryCitations.extractCitations(from: unterminated))

        // 4) 账本回写：两条 stage1 行，citation 命中其一 + 同次调用重复 id。
        let (db, _) = try makeDatabase()
        let cited = "019cc2ea-1dff-7902-8d40-c8f6e5d83cc4"
        let uncited = "019cc2ea-1dff-7902-8d40-c8f6e5d83cc6"
        try db.markStage1JobSucceeded(threadId: cited, sourceUpdatedAt: 100,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.markStage1JobSucceeded(threadId: uncited, sourceUpdatedAt: 200,
                                      rawMemory: "r2", rolloutSummary: "s2", rolloutSlug: nil)
        try db.recordMemoryUsage(threadIds: [cited, cited]) // Set 去重 → 只 +1
        let rows = try db.allStage1Outputs()
        let citedRow = try XCTUnwrap(rows.first { $0.threadId == cited })
        let uncitedRow = try XCTUnwrap(rows.first { $0.threadId == uncited })
        XCTAssertEqual(citedRow.usageCount, 1)
        XCTAssertNotNil(citedRow.lastUsage)
        XCTAssertNil(uncitedRow.usageCount)
        XCTAssertNil(uncitedRow.lastUsage)
    }

    // MARK: - 区块定位/拼接纯函数（落点⑩数据源）

    private static let memoryMD = """
    # Task Group: deploy

    scope: deployment flow
    ## Task 1: ship it

    - rollout_summaries/x.md (updated_at=2026-09-01T00:00:00Z, thread_id=id-1)

    # Task Group: test

    scope: testing flow
    """

    func testFindDocumentBlocksMemoryMD() {
        let blocks = MemoryStorage.findDocumentBlocks(in: Self.memoryMD,
                                                      headerPrefix: "# Task Group:")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].headerLine, "# Task Group: deploy")
        XCTAssertEqual(blocks[1].headerLine, "# Task Group: test")
        // 区块体不含下一块头；"## Task 1:" 子头不触发切分。
        let body0 = String(Self.memoryMD[blocks[0].range])
        XCTAssertTrue(body0.contains("## Task 1: ship it"))
        XCTAssertFalse(body0.contains("# Task Group: test"))
    }

    func testReplaceAndRemoveBlockRoundTrip() {
        var doc = Self.memoryMD
        var blocks = MemoryStorage.findDocumentBlocks(in: doc, headerPrefix: "# Task Group:")
        // 原文替换回同文 = 全文不变（splice 零损耗）。
        doc = MemoryStorage.replacingBlock(in: doc, block: blocks[0],
                                           with: String(doc[blocks[0].range]))
        XCTAssertEqual(doc, Self.memoryMD)
        // 编辑：替换首块（新文无尾换行 → 归一化为单换行，不吞下一块头）。
        doc = MemoryStorage.replacingBlock(in: doc, block: blocks[0],
                                           with: "# Task Group: deploy2\n\nscope: new\n")
        XCTAssertFalse(doc.contains("# Task Group: deploy\n"))
        XCTAssertTrue(doc.contains("# Task Group: deploy2"))
        XCTAssertTrue(doc.contains("# Task Group: test"))
        // 删除：块边界干净（尾随空行归属被删块，不残留双空行残骸在前块位置）。
        blocks = MemoryStorage.findDocumentBlocks(in: doc, headerPrefix: "# Task Group:")
        doc = MemoryStorage.removingBlock(in: doc, block: blocks[0])
        XCTAssertEqual(MemoryStorage.findDocumentBlocks(in: doc,
                                                        headerPrefix: "# Task Group:").count, 1)
        XCTAssertTrue(doc.contains("# Task Group: test"))
        XCTAssertFalse(doc.contains("deploy"))
    }

    func testFindDocumentBlocksRawMemoriesAndMetadata() {
        let raw = """
        # Raw Memories

        Merged stage-1 raw memories (stable ascending thread-id order):

        ## Thread `tid-1`
        updated_at: 2026-09-01T02:03:04Z
        cwd: /repo
        body one

        ## Thread `tid-2`
        updated_at: 2026-09-02T02:03:04Z
        body two
        """
        let blocks = MemoryStorage.findDocumentBlocks(in: raw, headerPrefix: "## Thread `")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].headerLine, "## Thread `tid-2`")
        let body1 = String(raw[blocks[0].range])
        XCTAssertEqual(MemoryStorage.metadataFieldValue(body1, field: "updated_at"),
                       "2026-09-01T02:03:04Z")
        XCTAssertEqual(MemoryStorage.metadataFieldValue(body1, field: "cwd"), "/repo")
        XCTAssertNil(MemoryStorage.metadataFieldValue(body1, field: "git_branch"))
        // RFC3339 与 UTC dashed 双格式。
        XCTAssertEqual(MemoryStorage.parseMemoryTimestamp("2026-09-01T02:03:04Z"),
                       MemoryStorage.parseMemoryTimestamp("2026-09-01T02-03-04"))
    }

    func testMetadataFieldInline() {
        let bullet = "- rollout_summaries/f.md (cwd=/repo, updated_at=2026-09-01T00:00:00Z,"
            + " thread_id=tid-9, ok)"
        XCTAssertEqual(MemoryStorage.metadataFieldInline(bullet, field: "thread_id"), "tid-9")
        XCTAssertEqual(MemoryStorage.metadataFieldInline(bullet, field: "updated_at"),
                       "2026-09-01T00:00:00Z")
        XCTAssertNil(MemoryStorage.metadataFieldInline(bullet, field: "rollout_slug"))
    }

    // MARK: - listSettingEntries / 编辑 / 删除

    private func makeStorage() throws -> MemoryStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7fixset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MemoryStorage(
            rootURL: dir.appendingPathComponent("memory", isDirectory: true),
            manifestURL: dir.appendingPathComponent("config/memory-snapshot.json"))
    }

    func testListEntriesAcrossFourKinds() throws {
        let storage = try makeStorage()
        try storage.ensureLayout()
        try Self.memoryMD.write(
            to: storage.rootURL.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)
        try "## Thread `tid-1`\nupdated_at: 2026-09-01T02:03:04Z\nbody\n\n"
            .write(to: storage.rootURL.appendingPathComponent("raw_memories.md"),
                   atomically: true, encoding: .utf8)
        try "thread_id: tid-1\nupdated_at: 2026-09-01T02:03:04Z\n\nsummary\n"
            .write(to: storage.rootURL
                .appendingPathComponent("rollout_summaries/20260901T020304-abcd.md"),
                atomically: true, encoding: .utf8)
        try "note body\n".write(to: storage.rootURL
            .appendingPathComponent("extensions/ad_hoc/notes/20260901T020304-note.md"),
            atomically: true, encoding: .utf8)

        let entries = try storage.listSettingEntries()
        XCTAssertEqual(entries.map(\.kind),
                       [.memoryBlock, .memoryBlock, .rawMemory,
                        .rolloutSummary, .adHocNote])
        // MEMORY.md 区块：标题取头行余文；thread_id/updated_at 内联解析。
        let block0 = entries[0]
        XCTAssertEqual(block0.title, "deploy")
        XCTAssertEqual(block0.sourceSession, "id-1")
        XCTAssertNotNil(block0.date)
        XCTAssertEqual(block0.blockIndex, 0)
        // raw_memories 条目：id 从头行反引号内提取。
        XCTAssertEqual(entries[2].sourceSession, "tid-1")
        XCTAssertEqual(entries[2].blockIndex, 0)
        // rollout summary：thread_id 行解析；ad-hoc note：标题 = 文件名去扩展。
        XCTAssertEqual(entries[3].sourceSession, "tid-1")
        XCTAssertEqual(entries[4].title, "20260901T020304-note")
    }

    func testUpdateEntryBlockSpliceAndFileRewrite() throws {
        let storage = try makeStorage()
        try storage.ensureLayout()
        try Self.memoryMD.write(
            to: storage.rootURL.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)
        try "old note\n".write(to: storage.rootURL
            .appendingPathComponent("extensions/ad_hoc/notes/n.md"),
            atomically: true, encoding: .utf8)

        // 文档型：区块编辑回写（另一块不受影响）。
        let blocks = try storage.listSettingEntries().filter { $0.kind == .memoryBlock }
        try storage.updateSettingEntry(blocks[0], newText: "# Task Group: deploy\n\nscope: edited\n")
        let doc = try String(contentsOf: storage.rootURL.appendingPathComponent("MEMORY.md"),
                             encoding: .utf8)
        XCTAssertTrue(doc.contains("scope: edited"))
        XCTAssertTrue(doc.contains("# Task Group: test"))
        XCTAssertFalse(doc.contains("## Task 1: ship it"))

        // 文件型：整文重写。
        let note = try XCTUnwrap(try storage.listSettingEntries()
            .first { $0.kind == .adHocNote })
        try storage.updateSettingEntry(note, newText: "new note\n")
        let noteText = try String(contentsOf: storage.rootURL
            .appendingPathComponent("extensions/ad_hoc/notes/n.md"), encoding: .utf8)
        XCTAssertEqual(noteText, "new note\n")
    }

    func testDeleteEntryRemovesBlockAndFile() throws {
        let storage = try makeStorage()
        try storage.ensureLayout()
        try Self.memoryMD.write(
            to: storage.rootURL.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)
        try "thread_id: tid-1\nsummary\n"
            .write(to: storage.rootURL
                .appendingPathComponent("rollout_summaries/a.md"),
                atomically: true, encoding: .utf8)

        try storage.deleteSettingEntry(try XCTUnwrap(try storage.listSettingEntries()
            .first { $0.kind == .rolloutSummary }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.rootURL
            .appendingPathComponent("rollout_summaries/a.md").path))

        try storage.deleteSettingEntry(try XCTUnwrap(try storage.listSettingEntries()
            .first { $0.kind == .memoryBlock }))
        let doc = try String(contentsOf: storage.rootURL.appendingPathComponent("MEMORY.md"),
                             encoding: .utf8)
        XCTAssertFalse(doc.contains("# Task Group: deploy"))
        XCTAssertTrue(doc.contains("# Task Group: test"))
    }

    func testStaleBlockIndexThrows() throws {
        let storage = try makeStorage()
        try storage.ensureLayout()
        try Self.memoryMD.write(
            to: storage.rootURL.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)
        let entries = try storage.listSettingEntries()
        // 文档已被外部改写（区块数缩水）→ 旧 blockIndex 失效 → 抛错不静默。
        try "# Task Group: only\n".write(
            to: storage.rootURL.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.updateSettingEntry(entries[1], newText: "x"))
        XCTAssertThrowsError(try storage.deleteSettingEntry(entries[1]))
    }
}
