//
//  SeedFetchDestinationTests.swift
//  WanWoTests
//
//  【M7 种子② 件 E 2026-09-28 · 单测面】fetch 产物落点解析
//  （BrowserUseTool.swift FetchDestinationResolver 纯函数缝）：
//    - 派单简报要求两例：有 resolver → projectHost/Downloads/；
//      无 resolver → 回落会话 browser 桶（fail-soft）。
//    - 对拍锚点（语义源）：
//      · 落点链 = BrowserUseManager.swift:2739-2745（WKDownload 链路已验证
//        形态）：workspacePathProvider → projectsHostRoot → +"/Downloads"；
//        未装配/解析失败 → WanWoPaths.sessionPersistentDir(bucket:"browser")。
//      · fetched_path 文案 = guest 工作区路径 + /Downloads/<file>
//        （workspacePathResolver 返回值形态——AppEnvironment.swift:514-518
//        guestWorkspacePath 注册处实证）。
//      · wanwo_url 文案 = wanwo://workspace/Downloads/<file>
//        （BrowserDownloadCenter.downloadsAgentPath :3213-3216 同款形态）。
//    - hostRoot 注入假根（projectsHostRoot 依赖 RootfsInstaller 装配态，
//      单测环境不 boot guest）。
//

import XCTest
@testable import WanWo

final class SeedFetchDestinationTests: XCTestCase {

    // MARK: ① 有 resolver 且解析成功 → projectHost/Downloads/

    func testResolveWithWorkspaceResolverLandsInProjectDownloads() {
        let fakeHost = URL(fileURLWithPath: "/tmp/seed-fake-project-host")

        let destination = FetchDestinationResolver.resolve(
            sessionId: "session-1",
            resolver: { _ in "/var/wanwo/projects/demo" },
            hostRoot: { _ in fakeHost })

        // 对拍 :2740-2742：projectHost.appendingPathComponent("Downloads")
        guard case .workspaceDownloads(let hostDir, let guestDirPath) = destination else {
            return XCTFail("expected workspaceDownloads, got \(destination)")
        }
        XCTAssertEqual(hostDir,
                       fakeHost.appendingPathComponent("Downloads", isDirectory: true),
                       "宿主落盘目录 = projectHost/Downloads/")
        XCTAssertEqual(guestDirPath, "/var/wanwo/projects/demo/Downloads",
                       "guest 落点路径 = <wsPath>/Downloads")

        // fetched_path 文案：guest 工作区路径 + /Downloads/<file>
        XCTAssertEqual(
            FetchDestinationResolver.agentFetchedPath(for: destination, filename: "report.zip"),
            "/var/wanwo/projects/demo/Downloads/report.zip")
        // wanwo_url 文案：downloadsAgentPath :3213-3216 同款形态
        XCTAssertEqual(
            FetchDestinationResolver.agentWanwoURL(for: destination, filename: "report.zip"),
            "wanwo://workspace/Downloads/report.zip")
    }

    // MARK: ② 无 resolver → 回落会话 browser 桶（fail-soft）

    func testResolveWithoutResolverFallsBackToBrowserBucket() {
        let destination = FetchDestinationResolver.resolve(
            sessionId: "session-2",
            resolver: nil,
            hostRoot: { _ in URL(fileURLWithPath: "/tmp/should-never-be-hit") })

        guard case .browserBucket(let hostDir) = destination else {
            return XCTFail("expected browserBucket, got \(destination)")
        }
        // 对拍 :2743-2744：回落 = WanWoPaths.sessionPersistentDir(bucket:"browser")
        XCTAssertEqual(hostDir,
                       WanWoPaths.sessionPersistentDir(for: "session-2", bucket: "browser"),
                       "回落目录 = 会话 browser 桶")

        // 回落文案维持旧形态：fetched_path = browser 桶 linux 路径；
        // wanwo_url = nil（execute 侧走 linuxPathToWanwoURL 旧生成面）。
        XCTAssertEqual(
            FetchDestinationResolver.agentFetchedPath(for: destination, filename: "report.zip"),
            "/var/wanwo/browser/report.zip")
        XCTAssertNil(FetchDestinationResolver.agentWanwoURL(for: destination, filename: "report.zip"))
    }

    // MARK: ③ fail-soft 族补例（同 ② 语义——解析失败各形态均回落）

    func testResolveFailSoftVariantsAllFallBackToBrowserBucket() {
        // resolver 返回空串（guestWorkspacePath 的空回落防线在注册处，
        // 解析缝仍需自防——BrowserUseManager :2740 `!wsPath.isEmpty` 同款）。
        let emptyStringCase = FetchDestinationResolver.resolve(
            sessionId: "s", resolver: { _ in "" },
            hostRoot: { _ in URL(fileURLWithPath: "/tmp/never") })
        // hostRoot 解析 nil（非 projects guest 路径——projectsHostRoot 对
        // /var/wanwo/workspace 等回落值 fail closed 返回 nil）。
        let hostRootNilCase = FetchDestinationResolver.resolve(
            sessionId: "s", resolver: { _ in "/var/wanwo/workspace" },
            hostRoot: { _ in nil })

        XCTAssertEqual(emptyStringCase, .browserBucket(
            hostDir: WanWoPaths.sessionPersistentDir(for: "s", bucket: "browser")))
        XCTAssertEqual(hostRootNilCase, .browserBucket(
            hostDir: WanWoPaths.sessionPersistentDir(for: "s", bucket: "browser")))
    }
}
