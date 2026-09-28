//
//  AcceptanceFixBatch23Tests.swift
//  WanWoTests
//
//  【批2-3 验收修复 2026-09-27 · 单测面】六修法中可纯函数验证的三件：
//    - A1：resolveWanwoURL workspace host 项目工作区优先映射（真身=projectsHostRoot，
//      legacy 会话桶降为兜底——workspacePathResolver 注入缝）。
//    - C：@ 图片引用扫描（ChatViewModel.workspaceImageCandidates /
//      imageMediaType 纯函数；白名单扩展名/去重/字节帽/静默降级语义）。
//      C-1（AgentLoop.injectContexts cwd 注入）与 C-2 装配面属 loop/UI 集成
//      行为，非纯函数可验，随真机验收。
//    - E：globRegex `**/` 零段语义（minimatch 标准——根层文件对 `**/*` 命中）
//      + 单星后字符吞噬回归（旧 Iterator 实现丢字符 bug）。
//  不可单测面：A2（navigate/decidePolicy 的 WKWebView 运行时行为——需 WebView
//  宿主）、B（system prompt 静态文本）、D（SwiftUI 缩略图渲染）、F（下载文案）。
//

import XCTest
@testable import WanWo

final class AcceptanceFixBatch23Tests: XCTestCase {

    // MARK: - fixture

    private static let testSID = "test-accfix-\(UUID().uuidString.prefix(8))"

    private var bucketRoot: URL!

    override func setUp() async throws {
        // 会话工作区桶根（真机测试宿主容器——可写；用后清理）。
        bucketRoot = WanWoPaths.sessionPersistentDir(for: Self.testSID, bucket: "workspace")
        try FileManager.default.createDirectory(at: bucketRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let sidRoot = bucketRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: sidRoot)
        // A1 注入的 workspacePathResolver 还原（静态全局——防泄漏到其它测试）。
        await MainActor.run { BrowserUseSessionStore.workspacePathResolver = nil }
    }

    private func makeFile(_ relative: String, in base: URL) throws -> URL {
        let target = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: target)
        return target
    }

    // MARK: - A1：workspace host 项目工作区优先映射

    /// workspace host 命中项目工作区文件（真身=projectsHostRoot）：A1 分支优先于
    /// legacy 桶链——cwd 经 workspacePathResolver 注入，legacy 桶不建同名文件，
    /// 命中必经项目分支。文件名含中文（真机病灶原样：AI 对中文文件名glob 误诊）。
    func testResolveWanwoURLWorkspaceHostPrefersProjectWorkspace() throws {
        let guestCwd = "/var/wanwo/projects/wanwo-accfix-\(Self.testSID)"
        let projectHost = try XCTUnwrap(
            WanWoPaths.projectsHostRoot(forGuestPath: guestCwd))
        let file = try makeFile("你好.txt", in: projectHost)
        defer { try? FileManager.default.removeItem(at: projectHost) }

        await MainActor.run {
            BrowserUseSessionStore.workspacePathResolver = { [guestCwd] sid in
                sid == Self.testSID ? guestCwd : nil
            }
        }

        let url = try XCTUnwrap(URL(string: "wanwo://workspace/%E4%BD%A0%E5%A5%BD.txt"))
        let resolved = WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: Self.testSID)
        XCTAssertEqual(resolved?.path, file.path)

        // base 锚（A2 loadFileURL 旁路的 allowingReadAccessTo 消费面）= 项目根。
        let withBase = WanwoURLSchemeHandler.resolveWanwoURLWithBase(
            url, sessionID: Self.testSID)
        XCTAssertEqual(withBase?.base.standardizedFileURL.path,
                       projectHost.standardizedFileURL.path)
        XCTAssertEqual(withBase?.file.path, file.path)
    }

    /// 项目工作区未命中 → 落回既有链（会话 legacy 桶兜底——A1 存在优先语义：
    /// `first(where: exists) ?? first`；旧桶文件仍可达）。
    func testResolveWanwoURLWorkspaceHostFallsBackToLegacyBucket() throws {
        let guestCwd = "/var/wanwo/projects/wanwo-accfix-\(Self.testSID)"
        let projectHost = try XCTUnwrap(
            WanWoPaths.projectsHostRoot(forGuestPath: guestCwd))
        defer { try? FileManager.default.removeItem(at: projectHost) }

        await MainActor.run {
            BrowserUseSessionStore.workspacePathResolver = { [guestCwd] sid in
                sid == Self.testSID ? guestCwd : nil
            }
        }

        // legacy 桶建文件（项目目录为空）——唯一命中面=legacy 桶。
        let file = try makeFile("legacy-only.html", in: bucketRoot)
        let url = try XCTUnwrap(URL(string: "wanwo://workspace/legacy-only.html"))
        XCTAssertEqual(
            WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: Self.testSID)?.path,
            file.path)
    }

    // MARK: - C：@ 图片引用扫描

    /// 白名单扩展名 → mediaType（大小写不敏感；非白名单 nil）。
    func testImageMediaTypeForExtension() {
        XCTAssertEqual(ChatViewModel.imageMediaType(forExtension: "png"), .png)
        XCTAssertEqual(ChatViewModel.imageMediaType(forExtension: "JPG"), .jpeg)
        XCTAssertEqual(ChatViewModel.imageMediaType(forExtension: "jpeg"), .jpeg)
        XCTAssertEqual(ChatViewModel.imageMediaType(forExtension: "WebP"), .webp)
        XCTAssertEqual(ChatViewModel.imageMediaType(forExtension: "gif"), .gif)
        XCTAssertNil(ChatViewModel.imageMediaType(forExtension: "txt"))
        XCTAssertNil(ChatViewModel.imageMediaType(forExtension: ""))
    }

    /// 扫描主体：图片 token 入选（顺序保持）、文本/未知扩展/不存在文件跳过、
    /// 同 token 去重、name=磁盘真名。
    func testWorkspaceImageCandidatesScansAndFilters() throws {
        let png = try makeFile("IMG_1.png", in: bucketRoot)
        let jpg = try makeFile("photo.JPG", in: bucketRoot)
        _ = try makeFile("notes.txt", in: bucketRoot)
        let workspace = WorkspaceFileAccess(sessionId: Self.testSID)

        let candidates = ChatViewModel.workspaceImageCandidates(
            in: "看 @IMG_1.png 和 @photo.JPG，@notes.txt 是文本，@missing.png 不存在，"
                + "再看看 @IMG_1.png（重复引用）",
            workspace: workspace, quota: 20,
            maxImageBytes: 20 * 1024 * 1024,
            aggregateBytes: 200 * 1024 * 1024)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].mediaType, .png)
        XCTAssertEqual(candidates[0].data, try Data(contentsOf: png))
        XCTAssertEqual(candidates[0].name, "IMG_1.png")
        XCTAssertEqual(candidates[1].mediaType, .jpeg)
        XCTAssertEqual(candidates[1].name, "photo.JPG")
    }

    /// 字节帽与 quota：超单图帽跳过（不占位，后续 token 照扫）；聚合帽触顶
    /// 即停；quota 封顶即停；无 @ 短路。
    func testWorkspaceImageCandidatesCapsAndShortCircuit() throws {
        let big = try makeFile("big.png", in: bucketRoot)
        try Data(repeating: 0xFF, count: 64).write(to: big)
        let small1 = try makeFile("small1.png", in: bucketRoot)
        try Data(repeating: 0x01, count: 6).write(to: small1)
        let small2 = try makeFile("small2.png", in: bucketRoot)
        try Data(repeating: 0x02, count: 6).write(to: small2)
        let workspace = WorkspaceFileAccess(sessionId: Self.testSID)

        // 单图帽：big(64B) 超帽跳过且不占位——small1 照常入选。
        let singleCap = ChatViewModel.workspaceImageCandidates(
            in: "@big.png @small1.png", workspace: workspace, quota: 2,
            maxImageBytes: 32, aggregateBytes: 1 << 20)
        XCTAssertEqual(singleCap.count, 1)
        XCTAssertEqual(singleCap.first?.name, "small1.png")

        // 聚合帽：small1(6B) 入选后 usedBytes=6，small2(6B) 6+6>10 → break。
        let aggregateCap = ChatViewModel.workspaceImageCandidates(
            in: "@small1.png @small2.png", workspace: workspace, quota: 5,
            maxImageBytes: 32, aggregateBytes: 10)
        XCTAssertEqual(aggregateCap.count, 1)
        XCTAssertEqual(aggregateCap.first?.name, "small1.png")

        // quota 封顶：两图都合规但 quota=1 → 只取首个。
        let quotaCap = ChatViewModel.workspaceImageCandidates(
            in: "@small1.png @small2.png", workspace: workspace, quota: 1,
            maxImageBytes: 32, aggregateBytes: 1 << 20)
        XCTAssertEqual(quotaCap.count, 1)
        XCTAssertEqual(quotaCap.first?.name, "small1.png")

        // 无 @：短路空数组。
        let empty = ChatViewModel.workspaceImageCandidates(
            in: "plain text", workspace: workspace, quota: 5,
            maxImageBytes: 1 << 20, aggregateBytes: 1 << 20)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - P0-2：markerPrefixes 带参形态匹配（M3 埋雷 C-1 后首爆）

    /// `<file path="...">` 带参注入块必须命中过滤器（旧 marker "<file>" 用
    /// hasPrefix 恒不匹配 → 注入块被当用户气泡渲染——批A-F 验收③真机实证）。
    func testMarkerMessageMatchesParameterizedFileBlock() {
        XCTAssertTrue(ConversationProjector.isMarkerMessage(
            "<file path=\"analysis/analyze_png.py\">\nimport zlib\n</file>"))
        XCTAssertTrue(ConversationProjector.isMarkerMessage("<file>"))
        XCTAssertTrue(ConversationProjector.isMarkerMessage(
            "<runtime-context>\nworkspace: /var/wanwo/projects/2\n</runtime-context>"))
        XCTAssertTrue(ConversationProjector.isMarkerMessage(
            "<skill name=\"demo\">body</skill>"))
        XCTAssertFalse(ConversationProjector.isMarkerMessage("在工作区写一个 index.html"))
        XCTAssertFalse(ConversationProjector.isMarkerMessage(
            "看看 <file 这个词出现在句中不触发"))
    }

    // MARK: - P2-2：wanwo:// 资源分流判定（cc-haha 分流语义万我版）

    /// HTML → 浏览器（"要运行的"）；workspace 内其它文件 → 文件页签
    /// （文本在文件里打开——用户拍板）；非 workspace 桶维持浏览器。
    func testRouteTargetSplitsWorkspaceFilesFromBrowser() throws {
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://workspace/index.html"))),
            .browser)
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://workspace/myapp/index.htm"))),
            .browser)
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://workspace/report.md"))),
            .workspaceFile(relativePath: "report.md"))
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://workspace/Downloads/data.bin"))),
            .workspaceFile(relativePath: "Downloads/data.bin"))
        // 中文文件名（percent-encoded → url.path 单层解码还原）。
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://workspace/%E4%BD%A0%E5%A5%BD.txt"))),
            .workspaceFile(relativePath: "你好.txt"))
        // 其它桶（browser 截图桶/attachments）维持浏览器。
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://browser/screenshot_1.jpg"))),
            .browser)
        XCTAssertEqual(
            WanwoURLRouter.routeTarget(for: try XCTUnwrap(URL(string: "wanwo://attachments/a.png"))),
            .browser)
    }

    // MARK: - P2-1c：保序切分（图片跟随 AI 叙述位置——修5）

    /// "图1：→图1、图2：→图2、尾段"的顺序保持（真机实证堆尾部形态的反例）。
    func testSplitAgentSegmentsPreservesOrder() {
        let text = "图1：\n\n![a](wanwo://browser/1.jpg)\n\n图2：\n\n![b](wanwo://browser/2.jpg)\n\n收尾文字"
        let segments = WOChatView.splitAgentSegments(text)
        XCTAssertEqual(segments.map { $0.image?.absoluteString ?? "text" },
                       ["text", "wanwo://browser/1.jpg",
                        "text", "wanwo://browser/2.jpg", "text"])
        XCTAssertTrue(segments[0].text.contains("图1："))
        XCTAssertTrue(segments[2].text.contains("图2："))
        XCTAssertTrue(segments[4].text.contains("收尾文字"))
    }

    /// 无图 → 单段原文；连续图片 → 空文本段跳过；空串 → 空数组。
    func testSplitAgentSegmentsEdges() {
        XCTAssertEqual(WOChatView.splitAgentSegments("plain text").count, 1)
        XCTAssertTrue(WOChatView.splitAgentSegments("").isEmpty)

        let consecutive = "![a](wanwo://browser/1.jpg)\n\n![b](wanwo://browser/2.jpg)"
        let segments = WOChatView.splitAgentSegments(consecutive)
        XCTAssertEqual(segments.compactMap(\.image).count, 2)
        XCTAssertTrue(segments.filter { $0.text.isEmpty }.count >= 2)
    }

    // MARK: - E：globRegex 零段语义

    private func matches(_ pattern: String, _ path: String) -> Bool {
        guard let rx = FsGlobTool.globRegex(pattern: pattern) else { return false }
        return rx.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// minimatch 标准：`**/` 匹配零层或多层——根层文件对 `**/*` 必须命中
    /// （真机病灶：AI glob `**/*` 漏根层 你好.txt，误诊"中文文件名失效"）。
    func testGlobRegexDoubleStarZeroSegment() {
        XCTAssertTrue(matches("**/*", "你好.txt"), "根层文件对 **/* 必须命中（零段）")
        XCTAssertTrue(matches("**/*", "sub/dir/file.txt"), "深层文件照常命中")
        XCTAssertTrue(matches("**/*.jpg", "photo.jpg"), "根层图对 **/*.jpg 命中（真机病灶）")
        XCTAssertTrue(matches("**/*.jpg", "a/b/c.jpg"))
        XCTAssertFalse(matches("**/*.jpg", "photo.png"))
        // 注：glob 的"结果面只有文件没有目录"由 recursiveFiles 排除，不归
        // regex 管——regex 形状上 "sub" 对 **/* 命中是正确行为，不在此断言。
    }

    /// 单星单段语义不变 + 单星后字符吞噬回归（旧 Iterator 无 peek 丢字符：
    /// `a*b` 旧译后丢 b——现 Array+index 重写根治）。
    func testGlobRegexSingleStarSemantics() {
        XCTAssertTrue(matches("*", "file.txt"))
        XCTAssertFalse(matches("*", "sub/file.txt"), "单星不跨段")
        XCTAssertTrue(matches("*.md", "note.md"))
        XCTAssertFalse(matches("*.md", "sub/note.md"))
        XCTAssertTrue(matches("a*b", "axxb"), "单星后字面字符不被吞")
        XCTAssertTrue(matches("a*b", "ab"), "单星可零宽")
        XCTAssertTrue(matches("a?c", "abc"))
        XCTAssertFalse(matches("a?c", "ac"))
        XCTAssertTrue(matches("**", "any/depth/file"), "独立 ** 跨任意层")
    }
}
