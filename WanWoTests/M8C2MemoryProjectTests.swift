//
//  M8C2MemoryProjectTests.swift
//  WanWoTests
//
//  【M8 批3 件 C2 测试】记忆项目分桶消费面：
//    · MemoryBucketResolver 回落口径（项目桶 / legacy 全局桶——批3 派单冻结契约）；
//    · guestBasePath（read-path 模板 base_path 位：项目 = <cwd>/wanwo-memory，
//      legacy = 全局 guest 根）；
//    · 四工具项目化（MemoryBackend rootURL=项目桶——桶隔离，跨桶互不可见）；
//    · 设置页过滤内核（MemoryStorage.listSettingEntries 按桶根列举）。
//  纯同步 + 临时目录。MemoryProjectLayout 为 C1 冻结契约消费（类型落地前
//  全工程暂不编译——c2-report 登记项 1）。
//

import XCTest
@testable import WanWo

final class M8C2MemoryProjectTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-c2-memory-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - 回落口径（MemoryBucketResolver）

    /// legacy cwd（nil / 会话桶根）→ 回落 legacy 全局桶（冻结契约：nil 回落）。
    func testFallbackLegacyGlobalBucket() {
        XCTAssertEqual(MemoryBucketResolver.bucketRoot(forCwd: nil),
                       WanWoPaths.memoryPersistentDir)
        XCTAssertEqual(
            MemoryBucketResolver.bucketRoot(forCwd: WanWoPaths.workspaceLinuxDir),
            WanWoPaths.memoryPersistentDir)
    }

    /// 项目 cwd → 项目桶（projectsHostRoot(cwd)/wanwo-memory/——与
    /// MemoryProjectLayout 契约直读一致）。
    func testProjectBucketResolution() {
        let cwd = WanWoPaths.projectsLinuxDir + "/1"
        let expected = MemoryProjectLayout.memoryBucketURL(forCwd: cwd)
        XCTAssertNotNil(expected, "项目 cwd 必须解析出项目桶（契约）")
        XCTAssertEqual(MemoryBucketResolver.bucketRoot(forCwd: cwd), expected)
        // 同根兄弟桶形状：桶目录名 = wanwo-memory。
        XCTAssertEqual(expected?.lastPathComponent, "wanwo-memory")
    }

    /// guestBasePath：项目 = <cwd>/wanwo-memory；legacy = 全局 guest 根。
    func testGuestBasePath() {
        let cwd = WanWoPaths.projectsLinuxDir + "/1"
        XCTAssertEqual(MemoryBucketResolver.guestBasePath(forCwd: cwd),
                       cwd + "/wanwo-memory")
        XCTAssertEqual(MemoryBucketResolver.guestBasePath(forCwd: nil),
                       MemoryConstants.memoryGuestPath)
        XCTAssertEqual(
            MemoryBucketResolver.guestBasePath(forCwd: WanWoPaths.workspaceLinuxDir),
            MemoryConstants.memoryGuestPath)
    }

    /// SessionNotes 同根兄弟桶（件 4 收编内核）：wanwo-notes = 项目宿主根下
    /// wanwo-memory 的兄弟目录。
    func testSessionNotesBucketIsSiblingOfMemoryBucket() {
        let cwd = WanWoPaths.projectsLinuxDir + "/1"
        let store = SessionNotesStore(sessionId: "sid", workspaceCwd: cwd)
        let memoryBucket = MemoryProjectLayout.memoryBucketURL(forCwd: cwd)
        XCTAssertEqual(store.notesDirectory.deletingLastPathComponent(),
                       memoryBucket?.deletingLastPathComponent(),
                       "notes 桶与 memory 桶必须同项目宿主根")
        XCTAssertEqual(store.notesDirectory.lastPathComponent, "wanwo-notes")
        XCTAssertTrue(store.isProjectMode)
        // legacy 回落维持 B3 会话 workspace 桶（登记项 3）。
        let legacy = SessionNotesStore(sessionId: "sid",
                                       workspaceCwd: WanWoPaths.workspaceLinuxDir)
        XCTAssertFalse(legacy.isProjectMode)
        XCTAssertEqual(legacy.notesDirectory.lastPathComponent, "wanwo-notes")
    }

    // MARK: - 四工具项目化（MemoryBackend 桶隔离）

    /// MemoryBackend rootURL=项目桶：list/read 只见本桶——跨项目桶互不可见
    /// （多项目隔离）。
    func testBackendScopedToBucketRoot() throws {
        let bucketA = tempRoot.appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("wanwo-memory", isDirectory: true)
        let bucketB = tempRoot.appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("wanwo-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: bucketA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bucketB, withIntermediateDirectories: true)
        try "A-only".write(to: bucketA.appendingPathComponent("a.md"), atomically: true,
                           encoding: .utf8)
        try "B-only".write(to: bucketB.appendingPathComponent("b.md"), atomically: true,
                           encoding: .utf8)

        let backendA = MemoryBackend(rootURL: bucketA)
        let listed = try backendA.list(path: nil, cursor: 0, maxResults: 100)
        XCTAssertEqual(listed.entries.map(\.path), ["a.md"])
        // search 跨桶不可见。
        let hits = try backendA.search(queries: ["B-only"], matchMode: .any,
                                       path: nil, cursor: 0, contextLines: 0,
                                       caseSensitive: true, normalized: false,
                                       maxResults: 10)
        XCTAssertTrue(hits.matches.isEmpty)
        // add_ad_hoc_note 落本桶 extensions/ad_hoc/notes/。
        XCTAssertNoThrow(try backendA.addAdHocNote(
            filename: "2026-09-30T00-00-00-note.md", note: "hello"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bucketA.appendingPathComponent(
                "extensions/ad_hoc/notes/2026-09-30T00-00-00-note.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bucketB.appendingPathComponent(
                "extensions/ad_hoc/notes/2026-09-30T00-00-00-note.md").path))
    }

    /// 注入项目化内核：项目桶有 memory_summary.md → 注入段注册且 base_path=
    /// 项目 guest 路径；legacy 回落桶有 summary → base_path=全局 guest 根。
    func testPromptSectionUsesBucketGuestBasePath() {
        let projectCwd = WanWoPaths.projectsLinuxDir + "/1"
        let section = MemoryPromptSection.summarySection(
            summaryText: "v1\nhello", guestBasePath: projectCwd + "/wanwo-memory")
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.text.contains(projectCwd + "/wanwo-memory"))
        // legacy：默认参数 = 全局 guest 根（既有调用面零破坏）。
        let legacy = MemoryPromptSection.summarySection(summaryText: "v1\nhello")
        XCTAssertNotNil(legacy)
        XCTAssertTrue(legacy!.text.contains(MemoryConstants.memoryGuestPath))
    }

    // MARK: - 设置页过滤内核（listSettingEntries 按桶根）

    /// 桶 A/B 各自条目仅在本桶列举（设置页按当前项目桶过滤的数据源语义）。
    func testSettingEntriesListedPerBucket() throws {
        let bucketA = tempRoot.appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("wanwo-memory", isDirectory: true)
        let bucketB = tempRoot.appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("wanwo-memory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bucketA.appendingPathComponent("rollout_summaries"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bucketB.appendingPathComponent("rollout_summaries"),
            withIntermediateDirectories: true)
        try "v1\nA summary".write(
            to: bucketA.appendingPathComponent("memory_summary.md"),
            atomically: true, encoding: .utf8)
        try "thread_id: sid-a\n\nA rollout".write(
            to: bucketA.appendingPathComponent("rollout_summaries/a.md"),
            atomically: true, encoding: .utf8)
        try "thread_id: sid-b\n\nB rollout".write(
            to: bucketB.appendingPathComponent("rollout_summaries/b.md"),
            atomically: true, encoding: .utf8)

        let entriesA = try MemoryStorage(
            rootURL: bucketA,
            manifestURL: tempRoot.appendingPathComponent("manifest.json"))
            .listSettingEntries()
        let entriesB = try MemoryStorage(
            rootURL: bucketB,
            manifestURL: tempRoot.appendingPathComponent("manifest.json"))
            .listSettingEntries()
        XCTAssertEqual(entriesA.map(\.relPath),
                       ["rollout_summaries/a.md"])
        XCTAssertEqual(entriesA.first?.sourceSession, "sid-a")
        XCTAssertEqual(entriesB.map(\.relPath),
                       ["rollout_summaries/b.md"])
        XCTAssertEqual(entriesB.first?.sourceSession, "sid-b")
    }
}
