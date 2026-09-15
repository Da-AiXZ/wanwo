//
//  WorkspaceRightSidebarModelTests.swift
//  WanWoTests
//
//  【M6.6（B4）测试 · 页签容器状态机（验收单测面）】
//  覆盖：单例页签去重（重复点选 = 激活）、浏览器页签多开、容量上限、
//  关闭后邻居激活落点（前邻优先 / 无前邻取后邻 / 关非活动页签活动不变 /
//  关空）、「+」菜单候选（审查仅 git 项目可见）。
//

import XCTest
@testable import WanWo

final class WorkspaceRightSidebarModelTests: XCTestCase {

    // MARK: - open（单例去重 / 浏览器多开 / 容量）

    @MainActor
    func testOpenSingletonDeduplicatesAndActivates() {
        var tabs = [WorkspaceTab.singleton(.files)]
        let result = WorkspaceRightSidebarModel.opening(.singleton(.files), in: tabs)
        XCTAssertEqual(result.tabs.count, 1)
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.activatedID, WorkspaceTabKind.files.rawValue)
        tabs = result.tabs
        XCTAssertEqual(tabs.first?.kind, .files)
    }

    @MainActor
    func testOpenBrowserAlwaysCreatesUniqueTab() {
        let first = WorkspaceRightSidebarModel.opening(.browser(), in: [])
        XCTAssertTrue(first.created)
        let second = WorkspaceRightSidebarModel.opening(.browser(), in: first.tabs)
        XCTAssertTrue(second.created)
        XCTAssertEqual(second.tabs.count, 2)
        // id 唯一。
        XCTAssertNotEqual(first.activatedID, second.activatedID)
    }

    @MainActor
    func testOpenRespectsMaxTabs() {
        var tabs: [WorkspaceTab] = []
        for _ in 0..<WorkspaceRightSidebarModel.maxTabs {
            tabs.append(.browser())
        }
        let result = WorkspaceRightSidebarModel.opening(.terminal, in: tabs)
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.tabs.count, WorkspaceRightSidebarModel.maxTabs)
        // 容量满拒新：激活尾页签（可解释落点）。
        XCTAssertEqual(result.activatedID, tabs.last?.id)
    }

    @MainActor
    func testOpenDifferentSingletonsCoexist() {
        var tabs: [WorkspaceTab] = []
        for kind in [WorkspaceTabKind.files, .terminal, .sideChat, .review] {
            let result = WorkspaceRightSidebarModel.opening(.singleton(kind), in: tabs)
            XCTAssertTrue(result.created)
            tabs = result.tabs
        }
        XCTAssertEqual(tabs.count, 4)
    }

    // MARK: - close（邻居激活状态机）

    @MainActor
    func testCloseActiveActivatesPreviousNeighbor() {
        let tabs = [WorkspaceTab.singleton(.files),
                    WorkspaceTab.singleton(.terminal),
                    WorkspaceTab.singleton(.sideChat)]
        let result = WorkspaceRightSidebarModel.closing(
            id: WorkspaceTabKind.terminal.rawValue, tabs: tabs,
            activeID: WorkspaceTabKind.terminal.rawValue)
        XCTAssertEqual(result.newActive, WorkspaceTabKind.files.rawValue)
        XCTAssertEqual(result.tabs.count, 2)
    }

    @MainActor
    func testCloseFirstActivatesNextNeighbor() {
        let tabs = [WorkspaceTab.singleton(.files),
                    WorkspaceTab.singleton(.terminal)]
        let result = WorkspaceRightSidebarModel.closing(
            id: WorkspaceTabKind.files.rawValue, tabs: tabs,
            activeID: WorkspaceTabKind.files.rawValue)
        XCTAssertEqual(result.newActive, WorkspaceTabKind.terminal.rawValue)
    }

    @MainActor
    func testCloseInactiveKeepsActive() {
        let tabs = [WorkspaceTab.singleton(.files),
                    WorkspaceTab.singleton(.terminal)]
        let result = WorkspaceRightSidebarModel.closing(
            id: WorkspaceTabKind.terminal.rawValue, tabs: tabs,
            activeID: WorkspaceTabKind.files.rawValue)
        XCTAssertEqual(result.newActive, WorkspaceTabKind.files.rawValue)
        XCTAssertEqual(result.tabs.count, 1)
    }

    @MainActor
    func testCloseLastTabYieldsNilActive() {
        let tabs = [WorkspaceTab.singleton(.files)]
        let result = WorkspaceRightSidebarModel.closing(
            id: WorkspaceTabKind.files.rawValue, tabs: tabs,
            activeID: WorkspaceTabKind.files.rawValue)
        XCTAssertTrue(result.tabs.isEmpty)
        XCTAssertNil(result.newActive)
    }

    @MainActor
    func testCloseUnknownIDIsNoOp() {
        let tabs = [WorkspaceTab.singleton(.files)]
        let result = WorkspaceRightSidebarModel.closing(id: "nope", tabs: tabs,
                                                        activeID: WorkspaceTabKind.files.rawValue)
        XCTAssertEqual(result.tabs, tabs)
        XCTAssertEqual(result.newActive, WorkspaceTabKind.files.rawValue)
    }

    // MARK: - 菜单候选 / 审查入口

    @MainActor
    func testMenuKindsOmitReviewWhenUnavailable() {
        let model = WorkspaceRightSidebarModel()
        model.reviewAvailable = false
        let kinds = model.menuKinds()
        XCTAssertFalse(kinds.contains(.review))
        XCTAssertEqual(kinds.count, 4)
    }

    @MainActor
    func testMenuKindsLeadWithReviewWhenAvailable() {
        let model = WorkspaceRightSidebarModel()
        model.reviewAvailable = true
        XCTAssertEqual(model.menuKinds().first, .review)
    }

    @MainActor
    func testReviewAvailabilityFollowsGitDirectory() throws {
        let model = WorkspaceRightSidebarModel()
        // 无 .git 的工作区 → 不可见。
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        // 宿主根判定走 WanWoPaths.sessionPersistentDir——此处直接验证静态
        // 判据函数（ReviewTabModel.hasGitDirectory），availability 的映射
        // 由 updateReviewAvailability 经同一 FileManager 谓词。
        XCTAssertFalse(ReviewTabModel.hasGitDirectory(hostRoot: bare))
        try FileManager.default.createDirectory(
            at: bare.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertTrue(ReviewTabModel.hasGitDirectory(hostRoot: bare))
        _ = model // availability 状态机入口已由 reviewAvailable 读写覆盖。
    }
}
