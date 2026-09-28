//
//  M7MemoryTests.swift
//  WanWoTests
//
//  【M7 件 G · F043 单测】codex memories 语义移植对拍断言点：
//    - MemoryDatabase：水位幂等（stage1_source_needs_update 两查询）、
//      三态落账（retry_at=+3600s/余量递减/成功重置）、Phase2 抢占状态机
//      （running/cooldown/retry 窗）、prune（selected_for_phase2=0 + COALESCE
//      cutoff + 批最旧优先）、usage 记账。
//    - MemoryStorage：raw_memories.md 重建格式（storage.rs:44-78 逐语义）、
//      rollout_summary_file_stem（base62 hash 4 字符 + slug 清洗）、
//      validate_consolidation_artifacts（MEMORY.md + memory_summary.md 首行 v1）、
//      快照清单 diff（A/M/D + path 序）、diff 渲染头文案。
//    - MemoryRollout：marker 块剔除（AGENTS.md/skill）、序列化四词汇、
//      token 截断保头尾、输出严格解码（未知键拒——deny_unknown_fields 等价）。
//    - MemoryRedactor：sanitizer.rs 四正则（Bearer 保词干/键值保键名）。
//    - MemoryCitations：entries rsplit("|note=[")、rollout_ids 去重保序、
//      thread_ids UUID 过滤、strip 可见文本。
//    - MemoryBackend：resolveScopedPath 越界拒绝、search 三模式（窗口去重
//      strictly_contains_another_window）、read 行窗、ad_hoc 文件名校验。
//    - MemoryTrigger：三重门 + 候选过滤（age/idle）经 MemoryDatabase 联测。
//

import XCTest
@testable import WanWo

final class M7MemoryTests: XCTestCase {

    // MARK: - 账本

    private func makeDatabase() throws -> (MemoryDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try MemoryDatabase(
            path: dir.appendingPathComponent("memory-index.sqlite3").path)
        return (db, dir)
    }

    func testStage1WatermarkIdempotency() throws {
        let (db, _) = try makeDatabase()
        // 无行 → true（首次抽取）。
        XCTAssertTrue(try db.stage1SourceNeedsUpdate(threadId: "t1", sourceUpdatedAt: 100))
        try db.markStage1JobSucceeded(threadId: "t1", sourceUpdatedAt: 100,
                                      rawMemory: "raw", rolloutSummary: "sum",
                                      rolloutSlug: "slug")
        // 同水位 → false（幂等）；更高水位 → true（源又前进了）。
        XCTAssertFalse(try db.stage1SourceNeedsUpdate(threadId: "t1", sourceUpdatedAt: 100))
        XCTAssertTrue(try db.stage1SourceNeedsUpdate(threadId: "t1", sourceUpdatedAt: 101))
    }

    func testStage1FailureRetryWindow() throws {
        let (db, _) = try makeDatabase()
        try db.markStage1JobFailed(threadId: "t1", sourceUpdatedAt: 50,
                                   reason: "boom", retryDelaySeconds: 3_600)
        let remaining = try db.stage1RetryRemaining(threadId: "t1")
        XCTAssertEqual(remaining, MemoryDatabase.defaultRetryRemaining - 1)
        // 余量耗尽后继续递减但不为负。
        for _ in 0..<5 {
            try db.markStage1JobFailed(threadId: "t1", sourceUpdatedAt: 50,
                                       reason: "boom", retryDelaySeconds: 3_600)
        }
        XCTAssertEqual(try db.stage1RetryRemaining(threadId: "t1"), 0)
    }

    func testPhase2ClaimStateMachine() throws {
        let (db, _) = try makeDatabase()
        // 首抢 → claimed（watermark 0）。
        guard case .claimed(let wm) = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected claimed") }
        XCTAssertEqual(wm, 0)
        // running 期间再抢 → skippedRunning。
        guard case .skippedRunning = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected skippedRunning") }
        // 成功 → done（冷却窗内 skippedCooldown）。
        try db.markGlobalPhase2JobSucceeded(completionWatermark: 42, selectedThreadIds: ["t1"])
        guard case .skippedCooldown = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected skippedCooldown") }
        // 冷却过后 → 再次 claimed（watermark=上次成功值）。
        guard case .claimed(let wm2) = try db.tryClaimGlobalPhase2Job(cooldownSeconds: 0)
        else { return XCTFail("expected claimed after cooldown") }
        XCTAssertEqual(wm2, 42)
    }

    func testPhase2SelectedRewrite() throws {
        let (db, _) = try makeDatabase()
        // 水位须用新鲜的 epoch 秒：getPhase2InputSelection 按
        // COALESCE(last_usage, source_updated_at) >= now - maxUnusedDays 过滤，
        // 远古水位（1970 附近）会被保留期谓词整体排除。
        let now = Int(Date().timeIntervalSince1970)
        try db.markStage1JobSucceeded(threadId: "a", sourceUpdatedAt: now,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.markStage1JobSucceeded(threadId: "b", sourceUpdatedAt: now + 10,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.markGlobalPhase2JobSucceeded(completionWatermark: now + 10, selectedThreadIds: ["b"])
        let rows = try db.allStage1Outputs()
        XCTAssertEqual(rows.first(where: { $0.threadId == "b" })?.selectedForPhase2, true)
        XCTAssertEqual(rows.first(where: { $0.threadId == "a" })?.selectedForPhase2, false)
        // 选取排序：usage DESC → last_usage/source DESC → source DESC → id DESC，
        // 返回 thread_id ASC。
        let selection = try db.getPhase2InputSelection(limit: 10, maxUnusedDays: 30)
        XCTAssertEqual(selection.map(\.threadId), ["a", "b"])
    }

    func testPruneRetention() throws {
        let (db, _) = try makeDatabase()
        // 旧未选中条目 → 淘汰；选中条目 → 保留。
        try db.markStage1JobSucceeded(threadId: "old", sourceUpdatedAt: 1,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.markStage1JobSucceeded(threadId: "sel", sourceUpdatedAt: 1,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.markGlobalPhase2JobSucceeded(completionWatermark: 1, selectedThreadIds: ["sel"])
        let pruned = try db.pruneStage1OutputsForRetention(maxUnusedDays: 0, batchSize: 200)
        XCTAssertEqual(pruned, 1)
        let rows = try db.allStage1Outputs()
        XCTAssertEqual(rows.map(\.threadId), ["sel"])
    }

    func testUsageRecording() throws {
        let (db, _) = try makeDatabase()
        try db.markStage1JobSucceeded(threadId: "t1", sourceUpdatedAt: 10,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        try db.recordMemoryUsage(threadIds: ["t1", "t1", "missing"])
        let row = try db.allStage1Outputs().first { $0.threadId == "t1" }
        XCTAssertEqual(row?.usageCount, 1)
        XCTAssertNotNil(row?.lastUsage)
    }

    // MARK: - 工件

    private func makeStorage() throws -> (MemoryStorage, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7memst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = MemoryStorage(
            rootURL: dir.appendingPathComponent("memory", isDirectory: true),
            manifestURL: dir.appendingPathComponent("memory-snapshot.json"))
        return (storage, dir)
    }

    private func record(_ id: String, updated: Int) -> MemoryStage1Record {
        MemoryStage1Record(threadId: id, sourceUpdatedAt: updated,
                           rawMemory: "raw-\(id)", rolloutSummary: "sum-\(id)",
                           rolloutSlug: "My Slug!", generatedAt: 0, usageCount: nil,
                           lastUsage: nil, selectedForPhase2: false,
                           selectedForPhase2SourceUpdatedAt: nil)
    }

    func testRebuildRawMemoriesFileFormat() throws {
        let (storage, _) = try makeStorage()
        try storage.rebuildRawMemoriesFile(
            [record("aaa", updated: 1_700_000_000), record("bbb", updated: 1_700_000_100)],
            maxRawMemoriesForConsolidation: 256, cwdFor: { _ in "/var/wanwo/workspace" })
        let text = try String(contentsOf: storage.rootURL
            .appendingPathComponent("raw_memories.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Raw Memories\n\n"))
        XCTAssertTrue(text.contains("Merged stage-1 raw memories "
            + "(stable ascending thread-id order):\n\n"))
        // thread_id 稳定升序。
        let aRange = text.range(of: "## Thread `aaa`")
        let bRange = text.range(of: "## Thread `bbb`")
        XCTAssertNotNil(aRange)
        XCTAssertNotNil(bRange)
        if let aRange, let bRange { XCTAssertTrue(aRange.lowerBound < bRange.lowerBound) }
        XCTAssertTrue(text.contains("rollout_summary_file: "))
        XCTAssertTrue(text.contains("raw-aaa"))
        // 空表分支。
        try storage.rebuildRawMemoriesFile([], maxRawMemoriesForConsolidation: 256,
                                           cwdFor: { _ in "" })
        let empty = try String(contentsOf: storage.rootURL
            .appendingPathComponent("raw_memories.md"), encoding: .utf8)
        XCTAssertTrue(empty.contains("No raw memories yet.\n"))
    }

    func testRolloutSummaryFileStemBase62Hash() {
        // UUID 臂：hash 种子 = uuid 低 32 位 % 14_776_336 → 4 字符 base62；
        // 时间戳段 = source_updated_at 的 UTC %Y-%m-%dT%H-%M-%S（v4 UUID 无
        // 时间戳面）。
        let uuid = UUID(uuidString: "019CC2EA-1DFF-7902-8D40-C8F6E5D83CC4".lowercased())!
        let stem = MemoryStorage.rolloutSummaryFileStem(
            threadId: uuid.uuidString.lowercased(),
            sourceUpdatedAt: 1_700_000_000,
            rolloutSlug: "Deploy Pin v2")
        let timestamp = MemoryStorage.utcFormat(1_700_000_000)
        // slug 清洗：空格/非字母数字 → '_'、大写 → 小写（codex :216-231）。
        XCTAssertTrue(stem.hasPrefix("\(timestamp)-"))
        XCTAssertTrue(stem.hasSuffix("deploy_pin_v2"))
        // 无 slug → 仅前缀（timestamp + '-' + 4 字符 base62 hash）。
        let bare = MemoryStorage.rolloutSummaryFileStem(
            threadId: uuid.uuidString.lowercased(),
            sourceUpdatedAt: 1_700_000_000, rolloutSlug: nil)
        XCTAssertEqual(bare, "\(timestamp)-\(bare.suffix(4))")
        XCTAssertEqual(bare.count, timestamp.count + 1 + 4)
        // 非 UUID 臂：31 进制种子路径不崩、形状一致。
        let fallback = MemoryStorage.rolloutSummaryFileStem(
            threadId: "not-a-uuid", sourceUpdatedAt: 1_700_000_000, rolloutSlug: nil)
        XCTAssertTrue(fallback.hasPrefix("\(timestamp)-"))
    }

    func testValidateConsolidationArtifacts() throws {
        let (storage, _) = try makeStorage()
        try storage.ensureLayout()
        // 缺 MEMORY.md → 抛。
        XCTAssertThrowsError(try storage.validateConsolidationArtifacts())
        try "memory".write(to: storage.rootURL.appendingPathComponent("MEMORY.md"),
                           atomically: true, encoding: .utf8)
        // summary 首行非 v1 → 抛。
        try "v2\nnope".write(to: storage.rootURL.appendingPathComponent("memory_summary.md"),
                             atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.validateConsolidationArtifacts())
        // 首行 v1 → 通过。
        try "v1\nsummary body".write(
            to: storage.rootURL.appendingPathComponent("memory_summary.md"),
            atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try storage.validateConsolidationArtifacts())
    }

    func testSnapshotManifestDiffLabels() throws {
        let (storage, _) = try makeStorage()
        try storage.ensureLayout()
        try "v1\ns".write(to: storage.rootURL.appendingPathComponent("memory_summary.md"),
                          atomically: true, encoding: .utf8)
        // 基线空 = 全 added。
        let added = storage.diffAgainstManifest(storage.loadManifest())
        XCTAssertEqual(added.changes.first?.label, "A")
        // 拍基线后改+删。
        try storage.saveManifest(storage.snapshotManifest())
        try "v1\ns2".write(to: storage.rootURL.appendingPathComponent("memory_summary.md"),
                           atomically: true, encoding: .utf8)
        try "memory".write(to: storage.rootURL.appendingPathComponent("MEMORY.md"),
                           atomically: true, encoding: .utf8)
        let baseline = storage.loadManifest()
        let diff = storage.diffAgainstManifest(baseline)
        let labels = Dictionary(uniqueKeysWithValues: diff.changes.map { ($0.path, $0.label) })
        XCTAssertEqual(labels["memory_summary.md"], "M")
        XCTAssertEqual(labels["MEMORY.md"], "A")
        // diff 工件不入清单（remove_workspace_diff 语义）。
        try storage.writeWorkspaceDiff(diff)
        XCTAssertFalse(storage.snapshotManifest().entries.keys
            .contains(MemoryConstants.phase2WorkspaceDiffFilename))
        XCTAssertTrue(diff.renderedDiff.hasPrefix("# Memory Workspace Diff\n\n"))
        XCTAssertTrue(diff.renderedDiff.contains("Read this file first and do not edit it."))
        storage.removeWorkspaceDiff()
    }

    // MARK: - rollout 序列化 / 截断 / 解码

    private func event(_ payload: SessionEvent.Payload, seq: Int) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: payload)
    }

    func testSerializeFilteredEventsMarkerBlocks() {
        let events = [
            event(.userMessage(text: "# AGENTS.md instructions\n\n<INSTRUCTIONS>\nbody\n</INSTRUCTIONS>"), seq: 0),
            event(.userMessage(text: "<skill>\n<name>demo</name>\nbody\n</skill>"), seq: 1),
            event(.userMessage(text: "real user ask"), seq: 2),
            event(.assistantMessage(turn: 1, step: 1,
                                    message: AssistantMessage(id: "m1", provider: "p",
                                                              model: "m",
                                                              content: [.text("answer")]),
                                    usage: nil, interrupted: false), seq: 3),
            event(.toolCall(turn: 1, step: 1, callId: "c1", name: "read",
                            arguments: "{}"), seq: 4),
            event(.toolResult(turn: 1, step: 1, callId: "c1", content: "file body",
                              isError: false, errorName: nil, errorCode: nil,
                              meta: nil), seq: 5),
            event(.assistantChunk(turn: 1, step: 1, chunk: .textDelta(index: 0, text: "x")), seq: 6),
        ]
        let serialized = MemoryRollout.serializeFilteredEvents(events)
        // marker 块剔除、正常 user/assistant/tool 保留、chunk 不入。
        XCTAssertFalse(serialized.contains("AGENTS.md"))
        XCTAssertFalse(serialized.contains("<skill>"))
        XCTAssertTrue(serialized.contains("real user ask"))
        XCTAssertTrue(serialized.contains("output_text"))
        XCTAssertTrue(serialized.contains("function_call"))
        XCTAssertTrue(serialized.contains("function_call_output"))
        XCTAssertFalse(serialized.contains("text-delta"))
        // 整体 redact（sk- 值被抹）。
        let secretEvents = [event(.toolResult(turn: 1, step: 1, callId: "c", content:
            "sk-abcdefghijklmnopqrstuvwxyz123456", isError: false, errorName: nil,
            errorCode: nil, meta: nil), seq: 0)]
        XCTAssertFalse(MemoryRollout.serializeFilteredEvents(secretEvents)
            .contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(MemoryRollout.serializeFilteredEvents(secretEvents)
            .contains("[REDACTED_SECRET]"))
    }

    func testTruncateKeepsHeadAndTail() {
        let long = String(repeating: "a", count: 400) + "MIDDLE"
            + String(repeating: "b", count: 400)
        let truncated = MemoryRollout.truncateToTokenEstimate(long, 100)
        // 截断保头尾（head 2/3 + tail 1/3——中段丢弃）。
        XCTAssertTrue(truncated.hasPrefix("aaa"))
        XCTAssertTrue(truncated.hasSuffix("bbb"))
        XCTAssertLessThan(truncated.count, long.count)
        // 未超限 → 原文。
        XCTAssertEqual(MemoryRollout.truncateToTokenEstimate("short", 100), "short")
    }

    func testStage1OutputStrictDecoding() throws {
        // 未知键拒绝（deny_unknown_fields 等价）。
        XCTAssertThrowsError(try MemoryPhase1.parseStage1Output(
            #"{"raw_memory":"r","rollout_summary":"s","rollout_slug":null,"extra":1}"#))
        // slug 可空。
        let ok = try MemoryPhase1.parseStage1Output(
            "```json\n{\"raw_memory\":\"r\",\"rollout_summary\":\"s\",\"rollout_slug\":null}\n```")
        XCTAssertEqual(ok.rawMemory, "r")
        XCTAssertNil(ok.rolloutSlug)
        // 非 JSON → 抛。
        XCTAssertThrowsError(try MemoryPhase1.parseStage1Output("no json here"))
    }

    // MARK: - redactor

    func testRedactSecretsPatterns() {
        XCTAssertEqual(MemoryRedactor.redact("Bearer abcdefghijklmno"),
                       "Bearer abcdefghijklmno") // <16 → 不动（sanitizer.rs 同款豁免）
        XCTAssertEqual(MemoryRedactor.redact("Bearer abcdefghijklmnop1234"),
                       "Bearer [REDACTED_SECRET]")
        XCTAssertEqual(MemoryRedactor.redact("sk-abcdefghijklmnopqrst"),
                       "[REDACTED_SECRET]")
        XCTAssertEqual(MemoryRedactor.redact("AKIAABCDEFGHIJKLMNOP"),
                       "[REDACTED_SECRET]")
        XCTAssertEqual(MemoryRedactor.redact("api_key = supersecretvalue1"),
                       "api_key = [REDACTED_SECRET]")
        // 保键名/分隔符。
        XCTAssertEqual(MemoryRedactor.redact("password: 'value-1234567'"),
                       "password: '[REDACTED_SECRET]'")
        // Bearer 误报豁免（sanitizer.rs tests 同款）。
        XCTAssertEqual(MemoryRedactor.redact("Bearer of good news"), "Bearer of good news")
    }

    // MARK: - citations

    func testCitationParsing() {
        let text = "answer <oai-mem-citation><citation_entries>\n"
            + "MEMORY.md:1-2|note=[workflow]\n"
            + "bad line\n"
            + "</citation_entries>\n<rollout_ids>\n"
            + "019cc2ea-1dff-7902-8d40-c8f6e5d83cc4\n"
            + "019cc2ea-1dff-7902-8d40-c8f6e5d83cc4\n"
            + "not-a-uuid\n</rollout_ids></oai-mem-citation> tail"
        let (visible, payloads) = MemoryCitations.splitCitations(from: text)
        XCTAssertEqual(visible, "answer  tail")
        let parsed = MemoryCitations.parse(payloads)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.entries.count, 1)
        XCTAssertEqual(parsed?.entries.first?.path, "MEMORY.md")
        XCTAssertEqual(parsed?.entries.first?.lineStart, 1)
        XCTAssertEqual(parsed?.entries.first?.lineEnd, 2)
        XCTAssertEqual(parsed?.entries.first?.note, "workflow")
        // 去重保序 + UUID 过滤（thread_ids_from_memory_citation）。
        XCTAssertEqual(parsed?.rolloutIds.count, 2)
        XCTAssertEqual(MemoryCitations.threadIds(in: parsed!).count, 1)
        // 全空 = nil（parse_memory_citation :35-42）。
        XCTAssertNil(MemoryCitations.parse(["no markers here"]))
    }

    // MARK: - backend

    private func makeBackend() throws -> (MemoryBackend, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7membe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha beta gamma\nalpha delta\nnothing here"
            .write(to: root.appendingPathComponent("MEMORY.md"), atomically: true,
                   encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("rollout_summaries"), withIntermediateDirectories: true)
        // 内容不含 "alpha"/"delta"：search 递归 rollout_summaries（目录栈遍历），
        // 该文件若含查询词会把 any 模式命中数抬到 3（与 MEMORY.md 两行命中的
        // 断言口径冲突）。
        try "zeta summary".write(to: root
            .appendingPathComponent("rollout_summaries/20260101T000000-abcd.md"),
            atomically: true, encoding: .utf8)
        return (MemoryBackend(rootURL: root), root)
    }

    func testBackendListAndPathScope() throws {
        let (backend, _) = try makeBackend()
        let listing = try backend.list(path: nil, cursor: 0, maxResults: 2_000)
        // 根目录排序条目：MEMORY.md（file）+ rollout_summaries（directory）。
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries.first?.path, "MEMORY.md")
        XCTAssertEqual(listing.entries.first?.entryType, "file")
        XCTAssertEqual(listing.entries.last?.entryType, "directory")
        // 文件 path = 单条自返。
        let fileListing = try backend.list(path: "MEMORY.md", cursor: 0, maxResults: 10)
        XCTAssertEqual(fileListing.entries.first?.path, "MEMORY.md")
        // 越界拒绝（ParentDir）。
        XCTAssertThrowsError(try backend.resolveScopedPath("../escape.md"))
        // 隐藏组件 NotFound。
        XCTAssertThrowsError(try backend.resolveScopedPath(".hidden/x.md"))
        // cursor 越限。
        XCTAssertThrowsError(try backend.list(path: nil, cursor: 99, maxResults: 10))
    }

    func testBackendReadLineWindow() throws {
        let (backend, _) = try makeBackend()
        let page1 = try backend.read(path: "MEMORY.md", lineOffset: 1, maxLines: 2,
                                     maxTokens: 20_000)
        XCTAssertEqual(page1.startLineNumber, 1)
        XCTAssertEqual(page1.content, "alpha beta gamma\nalpha delta")
        XCTAssertTrue(page1.truncated)
        let page2 = try backend.read(path: "MEMORY.md", lineOffset: 3, maxLines: nil,
                                     maxTokens: 20_000)
        XCTAssertEqual(page2.content, "nothing here")
        XCTAssertFalse(page2.truncated)
        XCTAssertThrowsError(try backend.read(path: "MEMORY.md", lineOffset: 9,
                                              maxLines: nil, maxTokens: 20_000))
        XCTAssertThrowsError(try backend.read(path: "MEMORY.md", lineOffset: 0,
                                              maxLines: nil, maxTokens: 20_000))
    }

    func testBackendSearchThreeModes() throws {
        let (backend, _) = try makeBackend()
        // Any：逐行命中。
        let any = try backend.search(queries: ["alpha", "delta"], matchMode: .any,
                                     path: nil, cursor: 0, contextLines: 0,
                                     caseSensitive: true, normalized: false,
                                     maxResults: 200)
        XCTAssertEqual(any.matches.count, 2)
        // AllOnSameLine：同行需含全部。
        let same = try backend.search(queries: ["alpha", "delta"], matchMode: .allOnSameLine,
                                      path: nil, cursor: 0, contextLines: 0,
                                      caseSensitive: true, normalized: false,
                                      maxResults: 200)
        XCTAssertEqual(same.matches.count, 1)
        XCTAssertEqual(same.matches.first?.matchLineNumber, 2)
        // AllWithinLines(lineCount:2)：窗口含全部；lineCount=1 同行语义仍命中。
        let within = try backend.search(queries: ["alpha", "delta"],
                                        matchMode: .allWithinLines(lineCount: 2),
                                        path: nil, cursor: 0, contextLines: 0,
                                        caseSensitive: true, normalized: false,
                                        maxResults: 200)
        XCTAssertEqual(within.matches.count, 1)
        // 窗口去重：大窗口被小窗口包含时去除（strictly_contains_another_window）。
        let dedup = try backend.search(queries: ["alpha", "nothing"],
                                       matchMode: .allWithinLines(lineCount: 3),
                                       path: nil, cursor: 0, contextLines: 0,
                                       caseSensitive: true, normalized: false,
                                       maxResults: 200)
        XCTAssertGreaterThanOrEqual(dedup.matches.count, 1)
        // case_sensitive=false。
        let insensitive = try backend.search(queries: ["ALPHA"], matchMode: .any,
                                             path: nil, cursor: 0, contextLines: 0,
                                             caseSensitive: false, normalized: false,
                                             maxResults: 200)
        XCTAssertEqual(insensitive.matches.count, 2)
        // normalized：标点剔除后命中。
        try "alpha,beta".write(to: backend.rootURL.appendingPathComponent("notes.md"),
                               atomically: true, encoding: .utf8)
        let normalized = try backend.search(queries: ["alphabeta"], matchMode: .any,
                                            path: nil, cursor: 0, contextLines: 0,
                                            caseSensitive: false, normalized: true,
                                            maxResults: 200)
        XCTAssertTrue(normalized.matches.contains { $0.path == "notes.md" })
        // 空 query 拒绝。
        XCTAssertThrowsError(try backend.search(queries: [" "], matchMode: .any,
                                                path: nil, cursor: 0, contextLines: 0,
                                                caseSensitive: true, normalized: false,
                                                maxResults: 200))
    }

    func testBackendAdHocNoteValidation() throws {
        let (backend, root) = try makeBackend()
        // 时间戳前缀拒绝（ad_hoc_note.rs 1:1 逐字节校验——YYYY-MM-DDTHH-MM-SS-
        // 连字符位缺失 / 缺 T 及时刻段；文件名校验先于 note 校验）。
        XCTAssertThrowsError(try backend.addAdHocNote(
            filename: "20260101T000000-abcd.md", note: "n"))
        XCTAssertThrowsError(try backend.addAdHocNote(
            filename: "2026-01-01-abcd.md", note: "n"))
        // 大写 slug 拒绝（合法时间戳 + slug 限定 a-z0-9-）。
        XCTAssertThrowsError(try backend.addAdHocNote(
            filename: "2026-01-01T00-00-00-VALID.md", note: "n"))
        // 空 note 拒绝（合法文件名 + note trim 后空）。
        XCTAssertThrowsError(try backend.addAdHocNote(
            filename: "2026-01-01T00-00-00-empty.md", note: "  "))
        // QA-5 P1-3：合法用例改连字符格式（YYYY-MM-DDTHH-MM-SS-<slug>.md）。
        try backend.addAdHocNote(filename: "2026-01-01T00-00-00-my-note.md",
                                 note: "keep this")
        let note = try String(contentsOf: root
            .appendingPathComponent(
                "extensions/ad_hoc/notes/2026-01-01T00-00-00-my-note.md"),
            encoding: .utf8)
        XCTAssertEqual(note, "keep this")
        // create_new：重复 = AlreadyExists。
        XCTAssertThrowsError(try backend.addAdHocNote(
            filename: "2026-01-01T00-00-00-my-note.md", note: "again"))
    }

    // MARK: - 崩溃回收（QA-5 P1-2：running 残行复位 error）

    func testCrashRecoveryResetsRunningPhase2Job() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-m7mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory-index.sqlite3").path
        // 首开：抢占 → running 残行（模拟整合中途进程被杀）。
        let first = try MemoryDatabase(path: path)
        guard case .claimed = try first.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected claimed") }
        // 重开（init 尾崩溃回收 running→error）：默认重试窗 3600s 内重抢
        // → skippedRetryUnavailable（证明 running 残行停摆已破——未回收时
        // 此处恒 skippedRunning）。
        let reopened = try MemoryDatabase(path: path)
        guard case .skippedRetryUnavailable =
            try reopened.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected skippedRetryUnavailable after recovery") }
        // 重试窗归零注入 → 立即可再抢（error→claimed，重试窗语义 intact）。
        // 注：interruptedRetryDelaySeconds 只作用于 init 的 running 残行回收；
        // 上一步回收产物（error + retry_at=now+3600）须经 markGlobalPhase2Job
        // Failed(retryDelaySeconds: 0) 等价改写为"窗口已过"的 error 态。
        let third = try MemoryDatabase(path: path, interruptedRetryDelaySeconds: 0)
        try third.markGlobalPhase2JobFailed(reason: "retry window elapsed injection",
                                            retryDelaySeconds: 0)
        guard case .claimed = try third.tryClaimGlobalPhase2Job(cooldownSeconds: 21_600)
        else { return XCTFail("expected claimed after retry window elapsed") }
    }

    // MARK: - 触发器候选链（三重门 + 过滤参数联测——经账本水位面）

    func testTriggerCandidateGatesViaDatabase() throws {
        let (db, _) = try makeDatabase()
        // 已抽取且未变化 → 过滤掉；限量拍板档 2。
        try db.markStage1JobSucceeded(threadId: "done", sourceUpdatedAt: 100,
                                      rawMemory: "r", rolloutSummary: "s", rolloutSlug: nil)
        let claims = try db.filterEligibleStage1Candidates(
            [("done", 100), ("new1", 100), ("new2", 100), ("new3", 100)],
            maxClaimed: MemoryConstants.maxRolloutsPerStartup)
        XCTAssertEqual(claims.map(\.threadId), ["new1", "new2"])
        XCTAssertEqual(MemoryConstants.maxRolloutsPerStartup, 2)
        // 总开关缺省开（拍板①）。
        XCTAssertTrue(MemorySettings.isEnabled)
    }
}
