//
//  SidebarOrderAccountsTests.swift
//  WanWoTests
//
//  【UI 对齐批 1 · D 单测】排序账户（dsh WorkspaceBrowser.tsx:96-161/847-872）：
//    · reconciledSessionOrder 对账（stored 保持序 + 新成员补尾）；
//    · updated 活动提升（新活动会话一次性置顶，二次不重排）；
//    · 切到 updated 全量重排（sortByRecency）；
//    · retainAccountKeys（删除的工作区账户回收）；
//    · promotedBlank 双账户置顶。
//

import XCTest
@testable import WanWo

final class SidebarOrderAccountsTests: XCTestCase {

    // MARK: - fixture

    private func summary(id: String, updated: Date) -> SessionSummary {
        SessionSummary(id: id, title: "会话-\(id)",
                       createdAt: updated, updatedAt: updated,
                       eventCount: 0)
    }

    private func sessions(_ order: (String, Double)...) -> [SessionSummary] {
        order.map { id, ts in
            summary(id: id, updated: Date(timeIntervalSince1970: ts))
        }
    }

    // MARK: - 对账（reconciledSessionOrder :97-113）

    func testReconciledOrderKeepsStoredAndAppendsNew() {
        let order = SidebarOrderAccounts.reconciledOrder(
            stored: ["s2", "s1"], within: ["s1", "s3", "s2"])
        XCTAssertEqual(order, ["s2", "s1", "s3"], "stored 命中保持序，新成员补尾")
    }

    func testReconciledOrderDropsGoneAndDeduplicates() {
        let order = SidebarOrderAccounts.reconciledOrder(
            stored: ["s1", "ghost", "s1"], within: ["s1", "s2"])
        XCTAssertEqual(order, ["s1", "s2"], "消失成员剔除、stored 内去重")
    }

    func testOrderForFallbackWithoutStored() {
        var accounts = SidebarOrderAccounts()
        XCTAssertEqual(accounts.order(for: "ws1", fallback: ["a", "b"]), ["a", "b"])
        accounts.setOrder(["b", "a"], for: "ws1")
        XCTAssertEqual(accounts.order(for: "ws1", fallback: ["a", "b"]), ["b", "a"])
    }

    // MARK: - 活动提升（:137-149）与全量重排（:305,323）

    func testActivityPromotionMovesNewlyActiveSessionToTopOnce() {
        var accounts = SidebarOrderAccounts()
        let base = sessions(("s1", 100), ("s2", 90), ("s3", 80))

        // 首轮（previousUpdatedAt 缺失）= 全员提升 → 按 recency 排定基线。
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2", "s3"],
                           sessions: base, activityPromotion: true, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s1", "s2", "s3"])

        // s3 获得新活动（updatedAt 前进）→ 一次性置顶。
        var updated = base
        updated[2] = summary(id: "s3", updated: Date(timeIntervalSince1970: 200))
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2", "s3"],
                           sessions: updated, activityPromotion: true, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s3", "s1", "s2"],
                       "新活动会话一次性置顶（提升者内部按 recency）")

        // 无新活动 → 不再重排。
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2", "s3"],
                           sessions: updated, activityPromotion: true, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s3", "s1", "s2"])
    }

    func testNewMemberIsPromotedOnJoin() {
        var accounts = SidebarOrderAccounts()
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1"],
                           sessions: sessions(("s1", 100)),
                           activityPromotion: true, fullResort: false)
        // 新成员（previousUpdatedAt 缺失）加入 → 置顶。
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2"],
                           sessions: sessions(("s1", 100), ("s2", 50)),
                           activityPromotion: true, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s2", "s1"])
    }

    func testSwitchToUpdatedTriggersFullResort() {
        var accounts = SidebarOrderAccounts()
        accounts.setOrder(["s3", "s2", "s1"], for: "ws1")
        // fullResort（切到 updated）→ 全量按 updatedAt 降序 + id 升序。
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2", "s3"],
                           sessions: sessions(("s1", 300), ("s2", 200), ("s3", 100)),
                           activityPromotion: true, fullResort: true)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s1", "s2", "s3"])
    }

    func testFullResortSortUsesIDTieBreak() {
        let same = Date(timeIntervalSince1970: 42)
        var accounts = SidebarOrderAccounts()
        accounts.reconcile(accountKey: "ws1",
                           sessionIds: ["b", "a"],
                           sessions: [summary(id: "b", updated: same),
                                      summary(id: "a", updated: same)],
                           activityPromotion: true, fullResort: true)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["a", "b"],
                       "updatedAt 同刻 → id 升序 tie-break（dsh :116-121）")
    }

    func testManualModeKeepsAccountOrderUntouched() {
        var accounts = SidebarOrderAccounts()
        accounts.setOrder(["s2", "s1"], for: "ws1")
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2"],
                           sessions: sessions(("s1", 200), ("s2", 100)),
                           activityPromotion: false, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s2", "s1"],
                       "manual 语义：无提升无重排，视图序保持")
    }

    // MARK: - retainAccountKeys（:865-872）

    func testRetainAccountKeysRecyclesDeletedWorkspaceAccounts() {
        var accounts = SidebarOrderAccounts()
        accounts.setOrder(["s1"], for: "ws1")
        accounts.setOrder(["s2"], for: "ws2")
        accounts.setOrder(["s3"], for: SidebarGroupingModel.ungroupedKey)
        accounts.setOrder(["s4"], for: SidebarGroupingModel.flatKey)

        accounts.retain(keys: ["ws2", SidebarGroupingModel.ungroupedKey,
                               SidebarGroupingModel.flatKey])
        XCTAssertNil(accounts.ordersSnapshot["ws1"], "已删工作区账户回收")
        XCTAssertEqual(accounts.ordersSnapshot["ws2"], ["s2"])
    }

    // MARK: - promotedBlank（:847-864）

    func testPromotedBlankGoesToTopOfBothAccounts() {
        var accounts = SidebarOrderAccounts()
        accounts.setOrder(["s1", "s2", "s3"], for: "ws1")
        accounts.setOrder(["s1", "s2", "s3"], for: SidebarGroupingModel.flatKey)

        accounts.promoteSessionToTop(
            "s2", accountKeys: ["ws1", SidebarGroupingModel.flatKey])
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s2", "s1", "s3"])
        XCTAssertEqual(accounts.ordersSnapshot[SidebarGroupingModel.flatKey],
                       ["s2", "s1", "s3"], "当前 blank 在其账户 + flat 账户双置顶")
    }

    func testPromotedBlankIsIdempotent() {
        var accounts = SidebarOrderAccounts()
        accounts.setOrder(["s1"], for: "ws1")
        accounts.promoteSessionToTop("s1", accountKeys: ["ws1"])
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], ["s1"])
    }

    // MARK: - changed 门

    func testReconcileOnlyWritesWhenChanged() {
        var accounts = SidebarOrderAccounts()
        let base = sessions(("s1", 100), ("s2", 90))
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2"],
                           sessions: base, activityPromotion: true, fullResort: false)
        let before = accounts.ordersSnapshot["ws1"]
        // 相同输入重跑 → 状态不变（引用相等判定）。
        accounts.reconcile(accountKey: "ws1", sessionIds: ["s1", "s2"],
                           sessions: base, activityPromotion: true, fullResort: false)
        XCTAssertEqual(accounts.ordersSnapshot["ws1"], before)
    }
}
