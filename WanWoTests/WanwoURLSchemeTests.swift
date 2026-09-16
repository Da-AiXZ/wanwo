//
//  WanwoURLSchemeTests.swift
//  WanWoTests
//
//  【M6.5（B3）测试 · wanwo:// 深链面】URL 双解码容错（vendored WanwoURLPathDecoding
//  原件语义）/ linuxPathToWanwoURL 生成面（OpenMinis linuxPathToMinisURL 1:1）/
//  resolveWanwoURL 实体：单/双编码命中、路径穿越拒绝（fail closed）、未知桶返回 nil。
//

import XCTest
@testable import WanWo

final class WanwoURLSchemeTests: XCTestCase {

    // MARK: - fixture

    private var bucketRoot: URL!

    override func setUp() async throws {
        // 会话工作区桶根（真机测试宿主容器——可写；用后清理）。
        bucketRoot = WanWoPaths.sessionPersistentDir(for: Self.testSID, bucket: "workspace")
        try FileManager.default.createDirectory(at: bucketRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // 清掉整个测试会话桶（不触碰其它数据）。
        let sidRoot = bucketRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: sidRoot)
    }

    private static let testSID = "test-scheme-\(UUID().uuidString.prefix(8))"

    // MARK: - 双解码容错（MinisURLPathDecoding 原件语义）

    func testSubPathCandidatesSingleEncodedKeepsOneCandidate() throws {
        // 正确形态：文件名单层编码（空格 %20）。
        let url = try XCTUnwrap(URL(string: "wanwo://workspace/hello%20world.html"))
        let candidates = WanwoURLPathDecoding.subPathCandidates(for: url)
        XCTAssertEqual(candidates, ["hello world.html"])
    }

    func testSubPathCandidatesRecoversDoubleEncodedName() throws {
        // 双重编码：%20 被再编码为 %2520。
        let url = try XCTUnwrap(URL(string: "wanwo://workspace/hello%2520world.html"))
        let candidates = WanwoURLPathDecoding.subPathCandidates(for: url)
        // 第一候选 = 单层解码（仍含字面 %20），第二候选 = 双层解码恢复真名。
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0], "hello%20world.html")
        XCTAssertEqual(candidates[1], "hello world.html")
    }

    func testSubPathCandidatesLegitPercentNameNotDoubleDecoded() throws {
        // 文件名合法含 % 的场景：单层解码即真名，不再追加第二候选（磁盘存在性
        // 由调用方判定——原件 disambiguator 语义）。
        let url = try XCTUnwrap(URL(string: "wanwo://workspace/report%25final.md"))
        let candidates = WanwoURLPathDecoding.subPathCandidates(for: url)
        XCTAssertEqual(candidates, ["report%final.md"])
    }

    // MARK: - linuxPathToWanwoURL 生成面

    func testLinuxPathToWanwoURLEncodesFilenameOnce() {
        XCTAssertEqual(
            WanwoURLSchemeHandler.linuxPathToWanwoURL("/var/wanwo/workspace/hello world.html"),
            "wanwo://workspace/hello%20world.html")
        XCTAssertEqual(
            WanwoURLSchemeHandler.linuxPathToWanwoURL("/var/wanwo/shared/data/report.pdf"),
            "wanwo://shared/data/report.pdf")
    }

    func testLinuxPathToWanwoURLRejectsOutsideVarWanwo() {
        XCTAssertNil(WanwoURLSchemeHandler.linuxPathToWanwoURL("/etc/hosts"))
        XCTAssertNil(WanwoURLSchemeHandler.linuxPathToWanwoURL("/var/wanwo"))
        XCTAssertNil(WanwoURLSchemeHandler.linuxPathToWanwoURL("relative/path"))
    }

    // MARK: - resolveWanwoURL 实体

    private func makeFile(_ relative: String, in base: URL) throws -> URL {
        let target = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: target)
        return target
    }

    func testResolveWanwoURLHitsSessionBucketWithInjectedSession() throws {
        let file = try makeFile("index.html", in: bucketRoot)
        let url = try XCTUnwrap(URL(string: "wanwo://workspace/index.html"))
        let resolved = WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: Self.testSID)
        XCTAssertEqual(resolved?.path, file.path)
    }

    /// 双编码恢复：磁盘上只有真名文件，双编码 URL 经第二候选命中。
    func testResolveWanwoURLRecoversDoubleEncodedName() throws {
        _ = try makeFile("笔记 A.html", in: bucketRoot)
        // 单层编码形态（%20 = 空格）直接命中。
        let single = try XCTUnwrap(URL(string: "wanwo://workspace/%E7%AC%94%E8%AE%B0%20A.html"))
        XCTAssertEqual(
            WanwoURLSchemeHandler.resolveWanwoURL(single, sessionID: Self.testSID)?
                .lastPathComponent, "笔记 A.html")
        // 双重编码形态（%2520）经第二候选命中。
        let double = try XCTUnwrap(URL(string: "wanwo://workspace/%E7%AC%94%E8%AE%B0%2520A.html"))
        XCTAssertEqual(
            WanwoURLSchemeHandler.resolveWanwoURL(double, sessionID: Self.testSID)?
                .lastPathComponent, "笔记 A.html")
    }

    /// 路径穿越拒绝（fail closed）：显式 ".."、双重编码 "%2e%2e"、规范化逃逸
    /// 一律 nil。
    func testResolveWanwoURLRejectsPathTraversal() throws {
        _ = try makeFile("index.html", in: bucketRoot)
        let explicit = try XCTUnwrap(URL(string: "wanwo://workspace/../../../etc/passwd"))
        XCTAssertNil(WanwoURLSchemeHandler.resolveWanwoURL(explicit, sessionID: Self.testSID))
        let encoded = try XCTUnwrap(URL(string: "wanwo://workspace/%2e%2e/%2e%2e/etc/passwd"))
        XCTAssertNil(WanwoURLSchemeHandler.resolveWanwoURL(encoded, sessionID: Self.testSID))
        // 未命中文件且首选候选含穿越组件 → 不返回逃逸目标（宁 nil 不逃）。
        let deep = try XCTUnwrap(URL(string: "wanwo://workspace/sub/../../../../tmp/x"))
        XCTAssertNil(WanwoURLSchemeHandler.resolveWanwoURL(deep, sessionID: Self.testSID))
    }

    /// 未知桶（host 不在四桶/全局族）→ nil；scheme 不符 → nil。
    func testResolveWanwoURLRejectsUnknownHostAndScheme() throws {
        let url = try XCTUnwrap(URL(string: "wanwo://unknown-bucket/x.html"))
        XCTAssertNil(WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: Self.testSID))
        let http = try XCTUnwrap(URL(string: "https://workspace/index.html"))
        XCTAssertNil(WanwoURLSchemeHandler.resolveWanwoURL(http, sessionID: Self.testSID))
    }

    /// 全局桶：shared 命中（真实 sharedPersistentDir——测试宿主容器内落文件）。
    func testResolveWanwoURLHitsGlobalSharedBucket() throws {
        let sharedDir = WanWoPaths.sharedPersistentDir
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let file = try makeFile("scheme-test-\(Self.testSID).txt", in: sharedDir)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = try XCTUnwrap(
            URL(string: "wanwo://shared/scheme-test-\(Self.testSID).txt"))
        XCTAssertEqual(
            WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: nil)?.path, file.path)
    }

    /// MIME 表：常见扩展（WKURLSchemeHandler 服务面的响应头依据）。
    func testMimeTable() {
        XCTAssertEqual(WanwoURLSchemeHandler.mimeType(for: "html"), "text/html")
        XCTAssertEqual(WanwoURLSchemeHandler.mimeType(for: "PNG"), "image/png")
        XCTAssertEqual(WanwoURLSchemeHandler.mimeType(for: "weird"), "application/octet-stream")
    }
}
