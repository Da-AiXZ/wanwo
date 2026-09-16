//
//  WorkspaceNavigatorTests.swift
//  WanWoTests
//
//  【UI 对齐批 1 · D 单测】会话创建流 workspace 驱动（dsh navigation.ts 1:1）：
//    · connectWorkspace 复用扫描四条件矩阵（blank / cwd 匹配 / 账本内 /
//      归档各组合）+ 并发合并（navigation.ts:96-97,109-110）；
//    · startSession 目标解析（显式 / 当前会话所在 / 最近 / 无工作区 no-op）；
//    · recentWorkspace（updatedAt max / 空工作区 createdAt 回退）；
//    · watchNavigation 启动语义（就绪后自动连接最近工作区 / 归档清空选择 /
//      ready 门）。
//  全程缝注入（Seams 闭包桩），不触 AppEnvironment/GRDB/文件系统。
//

import XCTest
@testable import WanWo

@MainActor
final class WorkspaceNavigatorTests: XCTestCase {

    // MARK: - fixture

    private func summary(id: String, title: String? = "有题",
                         updated: Date = Date()) -> SessionSummary {
        SessionSummary(id: id, title: title,
                       createdAt: updated, updatedAt: updated,
                       eventCount: 0)
    }

    private func workspace(id: String, path: String,
                           sessionIds: [String],
                           createdAt: Date = Date()) -> WorkspaceRecord {
        WorkspaceRecord(id: id, path: path, title: id,
                        createdAt: createdAt, updatedAt: createdAt,
                        sessionIds: sessionIds)
    }

    /// 锁保护的可变 fixture（seams 闭包捕获；MainActor 域内读写）。
    private final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var _workspaces: [WorkspaceRecord] = []
        var _sessions: [SessionSummary] = []
        var _current: String?
        var _opened: [String] = []
        var _cleared = 0
        var _createdIn: [String] = []
        var _archived: Set<String> = []
        var _probes: [String: SessionNavProbeResult] = [:]
        var _ready = true

        var workspaces: [WorkspaceRecord] { lock.lock(); defer { lock.unlock() }; return _workspaces }
        var sessions: [SessionSummary] { lock.lock(); defer { lock.unlock() }; return _sessions }
        var current: String? { lock.lock(); defer { lock.unlock() }; return _current }
        var opened: [String] { lock.lock(); defer { lock.unlock() }; return _opened }
        var cleared: Int { lock.lock(); defer { lock.unlock() }; return _cleared }
        var createdIn: [String] { lock.lock(); defer { lock.unlock() }; return _createdIn }
        var archived: Set<String> { lock.lock(); defer { lock.unlock() }; return _archived }
        var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    }

    private func makeNavigator(_ fixture: Fixture,
                               createDelayNs: UInt64 = 0) -> WorkspaceNavigator {
        WorkspaceNavigator(seams: .init(
            workspaces: { fixture.workspaces },
            sessions: { fixture.sessions },
            currentSessionID: { fixture.current },
            clearSelection: {
                fixture.lock.lock(); fixture._cleared += 1; fixture._current = nil
                fixture.lock.unlock()
            },
            openSession: { id in
                fixture.lock.lock(); fixture._opened.append(id); fixture._current = id
                fixture.lock.unlock()
            },
            createSessionInWorkspace: { workspaceID in
                self.fixture.lock.lock()
                self.fixture._createdIn.append(workspaceID)
                let created = self.summary(id: "created-\(self.fixture._createdIn.count)")
                self.fixture._sessions.append(created)
                self.fixture.lock.unlock()
                if createDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: createDelayNs)
                }
                return created
            },
            archivedSessionIDs: { fixture.archived },
            probeSession: { id in
                fixture.lock.lock(); defer { fixture.lock.unlock() }
                return fixture._probes[id]
            },
            isReady: { fixture.ready }))
    }

    /// startSession 为火忘语义——等待其内部 Task 落地。
    private func waitTick() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // MARK: - connectWorkspace：复用扫描四条件矩阵（简报 D.1）

    func testConnectWorkspaceReusesBlankSessionMatchingAllFourConditions() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: ["s1"])]
        fixture._sessions = [summary(id: "s1", title: nil)]
        fixture._probes = ["s1": SessionNavProbeResult(isBlank: true, cwd: "/ws/a")]
        let navigator = makeNavigator(fixture)

        let result = try await navigator.connectWorkspace("ws1")
        XCTAssertEqual(result, "s1")
        XCTAssertTrue(fixture.createdIn.isEmpty, "四条件全命中必须复用，不建新会话")
    }

    func testConnectWorkspaceCreatesWhenSessionNotBlank() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: ["s1"])]
        fixture._sessions = [summary(id: "s1", title: "有题")]
        fixture._probes = ["s1": SessionNavProbeResult(isBlank: false, cwd: "/ws/a")]
        let navigator = makeNavigator(fixture)

        let result = try await navigator.connectWorkspace("ws1")
        XCTAssertNotEqual(result, "s1")
        XCTAssertEqual(fixture.createdIn, ["ws1"])
    }

    func testConnectWorkspaceCreatesWhenCWDMismatch() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: ["s1"])]
        fixture._sessions = [summary(id: "s1", title: nil)]
        fixture._probes = ["s1": SessionNavProbeResult(isBlank: true, cwd: "/ws/other")]
        let navigator = makeNavigator(fixture)

        _ = try await navigator.connectWorkspace("ws1")
        XCTAssertEqual(fixture.createdIn, ["ws1"])
    }

    func testConnectWorkspaceCreatesWhenSessionNotInLedger() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: [])]
        fixture._sessions = [summary(id: "s1", title: nil)]
        fixture._probes = ["s1": SessionNavProbeResult(isBlank: true, cwd: "/ws/a")]
        let navigator = makeNavigator(fixture)

        _ = try await navigator.connectWorkspace("ws1")
        XCTAssertEqual(fixture.createdIn, ["ws1"])
    }

    func testConnectWorkspaceCreatesWhenSessionArchived() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: ["s1"])]
        fixture._sessions = [summary(id: "s1", title: nil)]
        fixture._probes = ["s1": SessionNavProbeResult(isBlank: true, cwd: "/ws/a")]
        fixture._archived = ["s1"]
        let navigator = makeNavigator(fixture)

        _ = try await navigator.connectWorkspace("ws1")
        XCTAssertEqual(fixture.createdIn, ["ws1"])
    }

    func testConnectWorkspaceThrowsForUnknownWorkspace() async {
        let fixture = Fixture()
        let navigator = makeNavigator(fixture)
        do {
            _ = try await navigator.connectWorkspace("ghost")
            XCTFail("未知工作区必须抛 unknownWorkspace")
        } catch let error as WorkspaceNavigator.NavigatorError {
            XCTAssertEqual(error, .unknownWorkspace("ghost"))
        } catch {
            XCTFail("非预期错误类型：\(error)")
        }
    }

    // MARK: - connectWorkspace：并发合并（dsh connecting map）

    func testConnectWorkspaceMergesConcurrentConnects() async throws {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: [])]
        let navigator = makeNavigator(fixture, createDelayNs: 60_000_000)

        async let first = navigator.connectWorkspace("ws1")
        async let second = navigator.connectWorkspace("ws1")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b, "同 workspaceId 的在飞连接共享同一 Task")
        XCTAssertEqual(fixture.createdIn.count, 1, "并发连接只创建一次")
    }

    // MARK: - startSession 目标解析（简报 D.2）

    func testStartSessionUsesExplicitTarget() async {
        let fixture = Fixture()
        fixture._workspaces = [
            workspace(id: "ws1", path: "/ws/a", sessionIds: []),
            workspace(id: "ws2", path: "/ws/b", sessionIds: []),
        ]
        let navigator = makeNavigator(fixture)

        navigator.startSession("ws2")
        await waitTick()
        XCTAssertEqual(fixture.createdIn, ["ws2"])
        XCTAssertEqual(fixture.opened.last, "created-1")
    }

    func testStartSessionInheritsCurrentSessionWorkspace() async {
        let fixture = Fixture()
        fixture._workspaces = [
            workspace(id: "ws1", path: "/ws/a", sessionIds: ["cur"]),
            workspace(id: "ws2", path: "/ws/b", sessionIds: []),
        ]
        fixture._sessions = [summary(id: "cur")]
        fixture._current = "cur"
        let navigator = makeNavigator(fixture)

        navigator.startSession()
        await waitTick()
        XCTAssertEqual(fixture.createdIn, ["ws1"], "target = 当前会话所在工作区")
    }

    func testStartSessionFallsBackToRecentWorkspace() async {
        let fixture = Fixture()
        fixture._workspaces = [
            workspace(id: "ws-old", path: "/ws/a", sessionIds: [],
                      createdAt: Date(timeIntervalSince1970: 1)),
            workspace(id: "ws-new", path: "/ws/b", sessionIds: [],
                      createdAt: Date(timeIntervalSince1970: 2)),
        ]
        let navigator = makeNavigator(fixture)

        navigator.startSession()
        await waitTick()
        XCTAssertEqual(fixture.createdIn, ["ws-new"], "target = recentWorkspace")
    }

    func testStartSessionWithNoWorkspacesClearsSelectionWithoutCreating() async {
        let fixture = Fixture()
        fixture._current = "orphan"
        let navigator = makeNavigator(fixture)

        navigator.startSession()
        await waitTick()
        XCTAssertEqual(fixture.cleared, 1, "无任何工作区 → sessions.clear()（不创建）")
        XCTAssertTrue(fixture.createdIn.isEmpty, "不产生游离会话")
    }

    // MARK: - recentWorkspace（简报 D.3）

    func testRecentWorkspacePicksMaxMemberUpdatedAt() {
        let now = Date()
        let workspaces = [
            workspace(id: "ws1", path: "/a", sessionIds: ["s1"],
                      createdAt: now.addingTimeInterval(-1000)),
            workspace(id: "ws2", path: "/b", sessionIds: ["s2"],
                      createdAt: now.addingTimeInterval(-2000)),
        ]
        let sessions = [
            summary(id: "s1", updated: now.addingTimeInterval(-600)),
            summary(id: "s2", updated: now.addingTimeInterval(-100)),
        ]
        XCTAssertEqual(WorkspaceNavigator.recentWorkspace(workspaces, sessions: sessions),
                       "ws2", "组内成员最新 updatedAt 最大者胜出")
    }

    func testRecentWorkspaceFallsBackToCreatedAtForEmptyWorkspace() {
        let workspaces = [
            workspace(id: "ws-empty", path: "/a", sessionIds: [],
                      createdAt: Date(timeIntervalSince1970: 500)),
            workspace(id: "ws-old", path: "/b", sessionIds: ["s1"],
                      createdAt: Date(timeIntervalSince1970: 100)),
        ]
        let sessions = [summary(id: "s1", updated: Date(timeIntervalSince1970: 200))]
        XCTAssertEqual(WorkspaceNavigator.recentWorkspace(workspaces, sessions: sessions),
                       "ws-empty", "空工作区用 createdAt（navigation.ts:226）")
    }

    func testRecentWorkspaceTieBreaksByHostOrder() {
        let same = Date(timeIntervalSince1970: 42)
        let workspaces = [
            workspace(id: "first", path: "/a", sessionIds: [], createdAt: same),
            workspace(id: "second", path: "/b", sessionIds: [], createdAt: same),
        ]
        XCTAssertEqual(WorkspaceNavigator.recentWorkspace(workspaces, sessions: []),
                       "first", "并列取 Host 工作区序先者（严格大于比较）")
    }

    // MARK: - watchNavigation 启动语义（简报 A.3）

    func testReconcileAutoConnectsRecentAndOpensWhenNoSelection() async {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: [])]
        let navigator = makeNavigator(fixture)

        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertEqual(fixture.createdIn, ["ws1"])
        XCTAssertEqual(fixture.opened.last, "created-1")
        // 对账只跑一次（initial done）——再触发不重复连接。
        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertEqual(fixture.createdIn.count, 1)
    }

    func testReconcileClearsArchivedCurrentSelection() async {
        let fixture = Fixture()
        fixture._current = "s1"
        fixture._archived = ["s1"]
        let navigator = makeNavigator(fixture)

        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertEqual(fixture.cleared, 1, "当前选中被归档 → 清空选择（:202-209）")
        XCTAssertTrue(fixture.createdIn.isEmpty)
    }

    func testReconcileWaitsUntilReady() async {
        let fixture = Fixture()
        fixture._workspaces = [workspace(id: "ws1", path: "/ws/a", sessionIds: [])]
        fixture._ready = false
        let navigator = makeNavigator(fixture)

        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertTrue(fixture.createdIn.isEmpty, "未就绪不连接（phase !== 'ready'）")

        fixture.lock.lock()
        fixture._ready = true
        fixture.lock.unlock()
        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertEqual(fixture.createdIn, ["ws1"])
    }

    func testReconcileStaysEmptyWhenNoWorkspaces() async {
        let fixture = Fixture()
        let navigator = makeNavigator(fixture)

        navigator.reconcileNavigation()
        await waitTick()
        XCTAssertTrue(fixture.createdIn.isEmpty, "无工作区不创建——主区停留空态页")
        XCTAssertEqual(fixture.cleared, 0)
    }
}
