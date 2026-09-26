//
//  WOWorkspaceStoreTests.swift
//  WanWo
//
//  【批12+右栏重构批1（2026-09-27）】工作台状态机语义测试——语义源 cc-haha
//  workspaceStore（按会话作用域/复用规则/真删+undo/激活落点/AI 页签跟随）。
//  旧 WorkspaceRightSidebarModelTests（自创底座 opening/closing 纯函数面）
//  随底座退役，断言面按新语义重写。
//

import XCTest
@testable import WanWo

@MainActor
final class WOWorkspaceStoreTests: XCTestCase {

    private func freshStore() -> WOWorkspaceStore { WOWorkspaceStore() }

    // MARK: 打开/复用

    func testOpenSingletonActivatesExisting() {
        let store = freshStore()
        let first = store.openTarget(sessionId: "s1", target: .singleton(.terminal))
        store.openTarget(sessionId: "s1", target: .singleton(.review))
        let second = store.openTarget(sessionId: "s1", target: .singleton(.terminal))
        XCTAssertEqual(first, second, "单例 kind 重复打开=激活既有（cc-haha 复用规则）")
        XCTAssertEqual(store.tabs(for: "s1").count, 2)
    }

    func testOpenBrowserAlwaysCreates() {
        let store = freshStore()
        store.openTarget(sessionId: "s1", target: .browser(url: nil))
        store.openTarget(sessionId: "s1", target: .browser(url: nil))
        XCTAssertEqual(store.tabs(for: "s1").filter { $0.kind == .browser }.count, 2)
    }

    func testFirstOpenActivatesWhenNoActive() {
        // cc-haha insertTab :326-331：无激活签时后台打开也继承激活位
        // （防"页签条有签、内容区空白"）。
        let store = freshStore()
        let id = store.openTarget(sessionId: "s1", target: .singleton(.files),
                                  options: .init(background: true))
        XCTAssertEqual(store.state(for: "s1").activeTabID, id)
    }

    func testCapacityGuardActivatesTailInsteadOfCrashing() {
        let store = freshStore()
        for _ in 0..<10 {
            store.openTarget(sessionId: "s1", target: .browser(url: nil))
        }
        // 上限 8：第 9 枚被拒后激活尾签（不崩、可解释——既有裁决语义）。
        XCTAssertLessThanOrEqual(store.tabs(for: "s1").count, 8)
        XCTAssertNotNil(store.state(for: "s1").activeTabID)
    }

    // MARK: 关闭

    func testCloseActivatesRightNeighbourFirst() {
        // cc-haha nextActiveAfterClose：右邻优先，无右邻取左邻。
        let store = freshStore()
        let a = store.openTarget(sessionId: "s1", target: .singleton(.files))!
        let b = store.openTarget(sessionId: "s1", target: .singleton(.terminal))!
        let c = store.openTarget(sessionId: "s1", target: .singleton(.review))!
        store.activateTab(sessionId: "s1", tabId: b)
        store.closeTabs(sessionId: "s1", tabId: b)
        XCTAssertEqual(store.state(for: "s1").activeTabID, c, "关中签激活右邻")
        store.closeTabs(sessionId: "s1", tabId: c)
        XCTAssertEqual(store.state(for: "s1").activeTabID, a, "关末签回退左邻")
    }

    func testCloseLastTabCollapsesPanel() {
        // cc-haha :296-297：关最后一签=该会话右栏收起（空态合法）。
        let store = freshStore()
        let id = store.openTarget(sessionId: "s1", target: .singleton(.files))!
        store.closeTabs(sessionId: "s1", tabId: id)
        XCTAssertEqual(store.layout(for: "s1"), .hidden)
        XCTAssertTrue(store.tabs(for: "s1").isEmpty)
    }

    func testCloseOthersScope() {
        let store = freshStore()
        let a = store.openTarget(sessionId: "s1", target: .singleton(.files))!
        let b = store.openTarget(sessionId: "s1", target: .singleton(.terminal))!
        let c = store.openTarget(sessionId: "s1", target: .singleton(.review))!
        store.closeTabs(sessionId: "s1", tabId: b, scope: .others)
        XCTAssertEqual(store.tabs(for: "s1").map(\.id), [a, c].compactMap { $0 })
    }

    // MARK: undo（方式 B 数据面）

    func testReopenLastClosedRestoresTab() {
        let store = freshStore()
        let a = store.openTarget(sessionId: "s1", target: .singleton(.files))!
        store.openTarget(sessionId: "s1", target: .singleton(.terminal))
        store.closeTabs(sessionId: "s1", tabId: "terminal")
        XCTAssertEqual(store.tabs(for: "s1").count, 1)
        let restored = store.reopenLastClosed(sessionId: "s1")
        XCTAssertEqual(restored, "terminal", "单例恢复=同 id 重建")
        XCTAssertEqual(store.tabs(for: "s1").count, 2)
        XCTAssertNotNil(store.state(for: "s1").activeTabID)
        XCTAssertEqual(store.state(for: "s1").activeTabID, a == nil ? nil : "terminal")
    }

    func testReopenBrowserGetsFreshIdentity() {
        // cc-haha :819-820：browser 恢复=新资源 id（url 保留）。
        let store = freshStore()
        let url = URL(string: "https://example.com")!
        store.openTarget(sessionId: "s1", target: .browser(url: url))
        let originalID = store.state(for: "s1").activeTabID
        store.closeTabs(sessionId: "s1", tabId: originalID!)
        let restored = store.reopenLastClosed(sessionId: "s1")
        XCTAssertNotEqual(restored, originalID, "browser 恢复=新 UI id（资源新开）")
        XCTAssertEqual(store.activeTab(for: "s1")?.url, url, "url 保留")
    }

    func testUndoStackBounded() {
        let store = freshStore()
        for _ in 0..<20 {
            let id = store.openTarget(sessionId: "s1", target: .browser(url: nil))!
            store.closeTabs(sessionId: "s1", tabId: id)
        }
        XCTAssertLessThanOrEqual(store.state(for: "s1").closed.count, 12,
                                 "undo 栈上限 12（cc-haha UNDO_STACK_LIMIT）")
    }

    // MARK: AI 页签（用户裁决"单活动页签跟随"）

    func testAgentBrowserFollowsSingleTab() {
        let store = freshStore()
        let u1 = URL(string: "https://a.com")!
        let u2 = URL(string: "https://b.com")!
        store.openAgentBrowser(sessionId: "s1", url: u1, openSidebar: true)
        store.openAgentBrowser(sessionId: "s1", url: u2, openSidebar: false)
        let browserTabs = store.tabs(for: "s1").filter { $0.kind == .browser }
        XCTAssertEqual(browserTabs.count, 1, "AI 换页=同页签跟随不新建")
        XCTAssertEqual(browserTabs.first?.url, u2)
    }

    func testAgentNavigationWithoutSidebarDoesNotCreateTab() {
        let store = freshStore()
        store.openAgentBrowser(sessionId: "s1",
                               url: URL(string: "https://a.com")!,
                               openSidebar: false)
        XCTAssertTrue(store.tabs(for: "s1").isEmpty, "AI 自主干活不建签不打扰")
        XCTAssertNotNil(store.agentNavigation, "轻提示事实源已广播")
    }

    func testAgentTabCloseClearsFlag() {
        let store = freshStore()
        store.openAgentBrowser(sessionId: "s1",
                               url: URL(string: "https://a.com")!,
                               openSidebar: true)
        let tabID = store.state(for: "s1").agentBrowserTabID
        XCTAssertNotNil(tabID)
        store.closeTabs(sessionId: "s1", tabId: tabID!)
        XCTAssertNil(store.state(for: "s1").agentBrowserTabID, "✕ 删 AI 签清旗防悬挂")
    }

    // MARK: 会话作用域（串区根治）

    func testSessionsAreIsolated() {
        let store = freshStore()
        store.openTarget(sessionId: "s1", target: .singleton(.files))
        XCTAssertTrue(store.tabs(for: "s2").isEmpty, "会话间页签互不可见（bySession 作用域）")
        XCTAssertEqual(store.layout(for: "s2"), .hidden)
    }

    func testCollapseForSessionSwitchKeepsTabs() {
        let store = freshStore()
        store.openTarget(sessionId: "s1", target: .singleton(.files))
        store.collapseForSessionSwitch(from: "s1")
        XCTAssertEqual(store.layout(for: "s1"), .hidden, "切走即收起（用户裁决）")
        XCTAssertEqual(store.tabs(for: "s1").count, 1, "页签保活（切回手动展开即见）")
    }
}
