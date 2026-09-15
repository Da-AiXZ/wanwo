//
//  SidebarGroupingModelTests.swift
//  WanWoTests
//
//  【M6.6（B4）测试 · 左侧栏分组纯逻辑（§9 欠账对账面）】
//  覆盖：COLLAPSED_SESSION_LIMIT=5 + 「展开其余 N 个会话」、blank 占位不计
//  限额、deriveGroups（工作区组 + Ungrouped 桶 + 平铺）、账本序对账
//  （reconciledSessionOrder）、标题过滤、排序 tie-break。
//

import XCTest
@testable import WanWo

final class SidebarGroupingModelTests: XCTestCase {

    // MARK: - fixture

    private func summary(id: String, title: String?,
                         updated: Date = Date(), created: Date? = nil) -> SessionSummary {
        SessionSummary(id: id, title: title,
                       createdAt: created ?? updated, updatedAt: updated,
                       eventCount: 0)
    }

    private func workspace(id: String, title: String,
                           sessionIds: [String]) -> WorkspaceRecord {
        WorkspaceRecord(id: id, path: "/var/wanwo/mounts/\(id)", title: title,
                        createdAt: Date(), updatedAt: Date(), sessionIds: sessionIds)
    }

    // MARK: - 折叠限额（验收面）

    func testCollapsedLimitIsFive() {
        XCTAssertEqual(SidebarGroupingModel.collapsedSessionLimit, 5)
    }

    func testCollapseShowsFirstFiveAndCountsHidden() {
        let sessions = (1...8).map { summary(id: "s\($0)", title: "会话\($0)") }
        let ids = sessions.map(\.id)
        let view = SidebarGroupingModel.collapseView(ids: ids, sessions: sessions,
                                                     expanded: false)
        XCTAssertEqual(view.visible.count, 5)
        XCTAssertEqual(view.hiddenCount, 3)
    }

    func testBlankSessionsAlwaysVisibleAndNotCounted() {
        // 3 条 blank 占位 + 8 条有题——收起态可见 = 3 blank + 5 非blank，
        // 隐藏 = 3（blank 不占限额，dsh :43-56）。
        var sessions: [SessionSummary] = (1...3).map { summary(id: "b\($0)", title: nil) }
        sessions += (1...8).map { summary(id: "s\($0)", title: "会话\($0)") }
        let ids = sessions.map(\.id)
        let view = SidebarGroupingModel.collapseView(ids: ids, sessions: sessions,
                                                     expanded: false)
        XCTAssertEqual(Set(view.visible.prefix(3)), Set(["b1", "b2", "b3"]))
        XCTAssertEqual(view.visible.count, 8)
        XCTAssertEqual(view.hiddenCount, 3)
    }

    func testExpandedShowsAll() {
        let sessions = (1...9).map { summary(id: "s\($0)", title: "t") }
        let view = SidebarGroupingModel.collapseView(ids: sessions.map(\.id),
                                                     sessions: sessions, expanded: true)
        XCTAssertEqual(view.visible.count, 9)
        XCTAssertEqual(view.hiddenCount, 0)
    }

    // MARK: - 分组树（验收面）

    func testDeriveGroupsWithWorkspacesAndUngroupedBucket() {
        let wsA = workspace(id: "ws-a", title: "项目A", sessionIds: ["s1", "s2"])
        let sessions = [
            summary(id: "s1", title: "一"),
            summary(id: "s2", title: "二"),
            summary(id: "s3", title: "三"),
        ]
        let groups = SidebarGroupingModel.deriveGroups(
            sessions: sessions, workspaces: [wsA], grouped: true,
            sort: .updatedDesc)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "项目A")
        XCTAssertEqual(groups[0].workspaceID, "ws-a")
        XCTAssertEqual(groups[0].sessionIds, ["s1", "s2"])
        // Ungrouped 桶（UNGROUPED_KEY 语义）。
        XCTAssertEqual(groups[1].id, SidebarGroupingModel.ungroupedKey)
        XCTAssertEqual(groups[1].workspaceID, nil)
        XCTAssertEqual(groups[1].sessionIds, ["s3"])
    }

    func testDeriveGroupsFlatModeIgnoresWorkspaces() {
        let wsA = workspace(id: "ws-a", title: "项目A", sessionIds: ["s1"])
        let sessions = [
            summary(id: "s1", title: "一"),
            summary(id: "s2", title: "二"),
        ]
        let groups = SidebarGroupingModel.deriveGroups(
            sessions: sessions, workspaces: [wsA], grouped: false,
            sort: .updatedDesc)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, SidebarGroupingModel.flatKey)
        XCTAssertEqual(groups[0].workspaceID, nil)
        XCTAssertEqual(groups[0].sessionIds.count, 2)
    }

    func testLedgerOrderWinsOverRecencyInsideGroup() {
        // 账本序（s2, s1）优先于 updatedAt 排序——dsh 视图序对账语义。
        let now = Date()
        let wsA = workspace(id: "ws-a", title: "A", sessionIds: ["s2", "s1"])
        let sessions = [
            summary(id: "s1", title: "一", updated: now),
            summary(id: "s2", title: "二", updated: now.addingTimeInterval(-600)),
            summary(id: "s3", title: "三", updated: now.addingTimeInterval(-300)),
        ]
        let groups = SidebarGroupingModel.deriveGroups(
            sessions: sessions, workspaces: [wsA], grouped: true,
            sort: .updatedDesc)
        XCTAssertEqual(groups[0].sessionIds, ["s2", "s1"])
        XCTAssertEqual(groups[1].sessionIds, ["s3"])
    }

    func testLedgerLeftoversAppendByRecency() {
        // 账本未记成员（先建后 attach 竞态）按 updatedAt 降序补尾。
        let now = Date()
        let wsA = workspace(id: "ws-a", title: "A", sessionIds: ["s1"])
        let sessions = [
            summary(id: "s1", title: "一", updated: now),
            summary(id: "s2", title: "二", updated: now.addingTimeInterval(-60)),
            summary(id: "s3", title: "三", updated: now.addingTimeInterval(-120)),
        ]
        let order = SidebarGroupingModel.reconciledSessionOrder(
            ledger: wsA.sessionIds, sessions: sessions)
        XCTAssertEqual(order, ["s1", "s2", "s3"])
    }

    func testLedgerIgnoresUnknownSessionIDs() {
        let order = SidebarGroupingModel.reconciledSessionOrder(
            ledger: ["s1", "ghost"], sessions: [summary(id: "s1", title: "一")])
        XCTAssertEqual(order, ["s1"])
    }

    // MARK: - 过滤与排序

    func testFilterSessionsByTitle() {
        let sessions = [
            summary(id: "s1", title: "部署文档整理"),
            summary(id: "s2", title: "写测试"),
            summary(id: "s3", title: nil),
        ]
        XCTAssertEqual(SidebarGroupingModel.filterSessions(sessions, query: "测试")
            .map(\.id), ["s2"])
        XCTAssertEqual(SidebarGroupingModel.filterSessions(sessions, query: "")
            .count, 3)
        // blank 行按「新会话」可搜（dsh blank 行语义）。
        XCTAssertEqual(SidebarGroupingModel.filterSessions(sessions, query: "新会话")
            .map(\.id), ["s3"])
    }

    func testUpdatedDescSortHasIDTieBreak() {
        let now = Date()
        let sessions = [
            summary(id: "b", title: "同刻", updated: now),
            summary(id: "a", title: "同刻", updated: now),
            summary(id: "c", title: "早", updated: now.addingTimeInterval(-100)),
        ]
        let sorted = SidebarGroupingModel.sorted(sessions, by: .updatedDesc)
        // updatedAt 降序 + id 升序 tie-break（dsh :116-121）。
        XCTAssertEqual(sorted.map(\.id), ["a", "b", "c"])
    }

    func testIsBlank() {
        XCTAssertTrue(SidebarGroupingModel.isBlank(summary(id: "x", title: nil)))
        XCTAssertTrue(SidebarGroupingModel.isBlank(summary(id: "x", title: "   ")))
        XCTAssertFalse(SidebarGroupingModel.isBlank(summary(id: "x", title: "有题")))
    }
}
