//
//  SessionNotesTests.swift
//  WanWoTests
//
//  【M8 批2 件 B3 单测】常驻笔记（Cline Memory Bank 内核化）纯同步断言：
//    - 桶解析（workspace → 目录映射：项目模式/legacy/非项目路径 fail closed）；
//    - 空文件起步（五文件各只含固定头标记一行，幂等不覆写）；
//    - 注入截断（activeContext/progress 各 2000 字符 + 尾注记；全空 = 零扰动）；
//    - 更新 API（全文重写 + 头标记保留校验——头行被删拒绝写入）；
//    - 多项目隔离（两 workspace 互不串）。
//

import XCTest
@testable import WanWo

final class SessionNotesTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-notes-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    private func makeStore(_ name: String) -> SessionNotesStore {
        let dir = tmpRoot.appendingPathComponent(name, isDirectory: true)
        return SessionNotesStore(notesDirectory: dir,
                                 guestNotesPath: "/var/wanwo/projects/\(name)/wanwo-notes")
    }

    // MARK: - 桶解析（workspace → 目录映射）

    func testBucketResolutionProjectMode() throws {
        let store = SessionNotesStore(sessionId: "s1",
                                      workspaceCwd: "/var/wanwo/projects/demo")
        let hostRoot = try XCTUnwrap(
            WanWoPaths.projectsHostRoot(forGuestPath: "/var/wanwo/projects/demo"))
        XCTAssertEqual(store.notesDirectory,
                       hostRoot.appendingPathComponent("wanwo-notes",
                                                       isDirectory: true))
        XCTAssertEqual(store.guestNotesPath, "/var/wanwo/projects/demo/wanwo-notes")
        XCTAssertTrue(store.isProjectMode)
    }

    func testBucketResolutionLegacyFallback() {
        // cwd 缺省（legacy 会话）→ 会话 workspace 桶派生（与 WorkspaceFileAccess
        // legacy rootURL 同源——登记）。
        let store = SessionNotesStore(sessionId: "s2", workspaceCwd: nil)
        XCTAssertEqual(
            store.notesDirectory,
            WanWoPaths.sessionPersistentDir(for: "s2", bucket: "workspace")
                .appendingPathComponent("wanwo-notes", isDirectory: true))
        XCTAssertEqual(store.guestNotesPath,
                       "/var/wanwo/workspace/wanwo-notes")
        XCTAssertFalse(store.isProjectMode)

        // 非 projects guest 路径 → projectsHostRoot fail closed → legacy 回落
        // （/var/wanwo/workspace 本身在 projects 根外，WorkspaceAdoptionTests
        // 已证 nil 映射）。
        let legacyCwdStore = SessionNotesStore(
            sessionId: "s3", workspaceCwd: WanWoPaths.workspaceLinuxDir)
        XCTAssertFalse(legacyCwdStore.isProjectMode)
    }

    // MARK: - 空文件起步

    func testEnsureBucketCreatesEmptyFilesWithHeaderOnly() {
        let store = makeStore("bucket")
        store.ensureBucket()
        for file in SessionNoteFile.allCases {
            let url = store.notesDirectory.appendingPathComponent(file.fileName)
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertEqual(raw, SessionNotesHeader.marker(for: file) + "\n",
                           "\(file.fileName) 应只含固定头标记一行")
        }
        // 空文件 = 注入数据面 nil（零扰动）。
        XCTAssertNil(store.readBody(.activeContext))
        XCTAssertNil(store.readBody(.progress))
        // 幂等：再次 ensure 不覆写已有内容。
        try? store.applyNoteUpdate(file: .projectbrief, content:
            SessionNotesHeader.marker(for: .projectbrief) + "\n用户手编内容")
        store.ensureBucket()
        XCTAssertEqual(store.readBody(.projectbrief), "用户手编内容")
    }

    // MARK: - 注入截断

    func testInjectionTruncatesWithTailNote() throws {
        let store = makeStore("inject")
        let long = String(repeating: "甲", count: 5_000)
        try store.applyNoteUpdate(file: .activeContext, content:
            SessionNotesHeader.marker(for: .activeContext) + "\n" + long)
        try store.applyNoteUpdate(file: .progress, content:
            SessionNotesHeader.marker(for: .progress) + "\n短进度")

        let text = try XCTUnwrap(SessionNotesInjection.sectionText(from: store))
        XCTAssertTrue(text.contains("短进度"))
        // activeContext 截到 2000 字符 + 尾注记指向 guest 全文路径。
        XCTAssertTrue(text.contains(String(repeating: "甲", count: 2_000)))
        XCTAssertFalse(text.contains(String(repeating: "甲", count: 2_001)))
        XCTAssertTrue(text.contains(
            "/var/wanwo/projects/inject/wanwo-notes/activeContext.md"))
    }

    func testInjectionZeroDisturbanceWhenEmpty() {
        // 五文件全空（仅头标记）→ 段文本 nil（assemble 空段落丢弃同语义）。
        let store = makeStore("empty")
        store.ensureBucket()
        XCTAssertNil(SessionNotesInjection.sectionText(from: store))
        // 动态段落 provider 同语义：空 → ""。
        let section = SessionNotesInjection.dynamicSection(store: store)
        XCTAssertEqual(section.name, SessionNotesConstants.sectionName)
        XCTAssertEqual(section.order, SECTION_ORDERS.sessionNotes)
        XCTAssertEqual(section.provider(), "")
    }

    // MARK: - 更新 API（全文重写 + 头标记校验）

    func testApplyNoteUpdateFullRewrite() throws {
        let store = makeStore("update")
        store.ensureBucket()
        try store.applyNoteUpdate(file: .activeContext, content:
            SessionNotesHeader.marker(for: .activeContext) + "\n第一版焦点")
        XCTAssertEqual(store.readBody(.activeContext), "第一版焦点")
        // 第二次全文重写覆盖旧文（最新态语义）。
        try store.applyNoteUpdate(file: .activeContext, content:
            SessionNotesHeader.marker(for: .activeContext) + "\n第二版焦点")
        XCTAssertEqual(store.readBody(.activeContext), "第二版焦点")
        // 他文件不受扰。
        XCTAssertNil(store.readBody(.progress))
    }

    func testApplyNoteUpdateRejectsMissingHeader() throws {
        let store = makeStore("guard")
        store.ensureBucket()
        // 头行被删 → 拒绝写入，文件保持原样（防格式漂移——万我增强）。
        XCTAssertThrowsError(try store.applyNoteUpdate(file: .activeContext,
                                                       content: "无头标记内容")) {
            error in
            guard case SessionNotesError.headerMarkerMissing(let file) = error else {
                return XCTFail("应为 headerMarkerMissing：\(error)")
            }
            XCTAssertEqual(file, .activeContext)
        }
        XCTAssertNil(store.readBody(.activeContext))
        // 头行被改（他文件的头标记张冠李戴）→ 同样拒绝。
        XCTAssertThrowsError(try store.applyNoteUpdate(file: .progress, content:
            SessionNotesHeader.marker(for: .activeContext) + "\n错配头标记"))
        XCTAssertNil(store.readBody(.progress))
    }

    // MARK: - 多项目隔离

    func testMultiProjectIsolation() throws {
        let alpha = makeStore("alpha")
        let beta = makeStore("beta")
        alpha.ensureBucket()
        beta.ensureBucket()
        try alpha.applyNoteUpdate(file: .activeContext, content:
            SessionNotesHeader.marker(for: .activeContext) + "\nalpha 专属焦点")
        XCTAssertEqual(alpha.readBody(.activeContext), "alpha 专属焦点")
        // beta 桶不受 alpha 写入影响（互不串）。
        XCTAssertNil(beta.readBody(.activeContext))
        // 桶目录互异。
        XCTAssertNotEqual(alpha.notesDirectory, beta.notesDirectory)
    }

    // MARK: - 钩子实现函数（b/c 缝——不接生产，函数面直测）

    func testCompactionHookRewritesActiveContext() throws {
        let recorder = SessionNotesRecorder(store: makeStore("compact"))
        recorder.store.ensureBucket()
        try recorder.sessionNotesDidCompact(summary: "Goal: 修压缩。\nNext: 接线缝")
        XCTAssertEqual(store_body(recorder), "Goal: 修压缩。\nNext: 接线缝")
        // 头标记仍在（写入闸单点保格式）。
        let raw = try String(contentsOf: recorder.store.notesDirectory
            .appendingPathComponent(SessionNoteFile.activeContext.fileName),
            encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix(SessionNotesHeader.marker(for: .activeContext)))
    }

    func testTurnHookAppendsObservation() throws {
        let recorder = SessionNotesRecorder(store: makeStore("turn"))
        recorder.store.ensureBucket()
        try recorder.sessionNotesOnTurnEnd(SessionNotesTurnObservation(
            assistantReplyDigest: "已完成桶解析", filesTouched: ["/a.swift", "/b.swift"]))
        let first = try XCTUnwrap(recorder.store.readBody(.activeContext))
        XCTAssertTrue(first.contains("已完成桶解析"))
        XCTAssertTrue(first.contains("/a.swift, /b.swift"))
        // 二次追加：旧观察保留（追加式小更新）。
        try recorder.sessionNotesOnTurnEnd(SessionNotesTurnObservation(
            assistantReplyDigest: nil, filesTouched: []))
        // 全空观察 → 不写入（避免空块噪音）。
        XCTAssertEqual(recorder.store.readBody(.activeContext), first)
        try recorder.sessionNotesOnTurnEnd(SessionNotesTurnObservation(
            assistantReplyDigest: "第二轮", filesTouched: []))
        let second = try XCTUnwrap(recorder.store.readBody(.activeContext))
        XCTAssertTrue(second.contains("已完成桶解析") && second.contains("第二轮"))
    }

    private func store_body(_ recorder: SessionNotesRecorder) -> String? {
        recorder.store.readBody(.activeContext)
    }
}
