//
//  WOVisibleSessionCountTests.swift
//  WanWoTests
//
//  【M7-Fix2 批2 B3 · 反馈24】删除确认计数口径纯函数例：
//  隐藏 blank 草稿剔除 / 当前 blank 计入 / 有事件恒非 blank / 账本去重 /
//  摘要缺失兜底 / 空账本。
//

import XCTest
@testable import WanWo

final class WOVisibleSessionCountTests: XCTestCase {

    // MARK: - fixture

    private func summary(id: String, title: String?,
                         eventCount: Int = 3) -> SessionSummary {
        SessionSummary(id: id, title: title,
                       createdAt: Date(), updatedAt: Date(),
                       eventCount: eventCount)
    }

    // MARK: - 计数口径

    /// 隐藏 blank 草稿（新会话复用机制不显示在侧栏者）不计入（反馈24 病灶）。
    func testHiddenBlankDraftIsExcluded() {
        let sessions = [
            summary(id: "a", title: "会话A"),
            summary(id: "b", title: "会话B"),
            summary(id: "blank", title: nil, eventCount: 0),
        ]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a", "blank", "b"], sessions: sessions,
            currentSessionID: nil)
        XCTAssertEqual(count, 2, "隐藏 blank 草稿应被剔除——N 不再比用户所见多 1")
    }

    /// 当前选中的 blank 占位在侧栏可见（dsh tree.ts:131 规则翻转）→ 计入。
    func testCurrentBlankIsCounted() {
        let sessions = [
            summary(id: "a", title: "会话A"),
            summary(id: "blank", title: nil, eventCount: 0),
        ]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a", "blank"], sessions: sessions,
            currentSessionID: "blank")
        XCTAssertEqual(count, 2)
    }

    /// 有事件无标题的会话恒非 blank（SidebarGroupingModel.isBlank 语义
    /// ——回合被中断未生成标题的会话绝不从列表消失）→ 计入。
    func testSessionWithEventsNeverCountsAsBlank() {
        let sessions = [summary(id: "a", title: nil, eventCount: 5)]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a"], sessions: sessions, currentSessionID: nil)
        XCTAssertEqual(count, 1)
    }

    /// 空白标题（非 nil 但全空白）同 blank 口径。
    func testWhitespaceTitleBlankIsExcluded() {
        let sessions = [
            summary(id: "a", title: "会话A"),
            summary(id: "ws", title: "   ", eventCount: 0),
        ]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a", "ws"], sessions: sessions, currentSessionID: nil)
        XCTAssertEqual(count, 1)
    }

    /// 账本重复 id 去重（账本对账竞态防御）。
    func testLedgerDuplicatesCountedOnce() {
        let sessions = [summary(id: "a", title: "会话A")]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a", "a", "a"], sessions: sessions,
            currentSessionID: nil)
        XCTAssertEqual(count, 1)
    }

    /// 摘要缺失（快照竞态）按可见计兜底——只剔除能证明不可见的项。
    func testMissingSummaryCountsAsVisible() {
        let sessions = [summary(id: "a", title: "会话A")]
        let count = WOVisibleSessionCount.count(
            inLedger: ["a", "ghost"], sessions: sessions,
            currentSessionID: nil)
        XCTAssertEqual(count, 2)
    }

    /// 空账本 = 0（弹窗走「不删对话」文案分支）。
    func testEmptyLedgerIsZero() {
        XCTAssertEqual(WOVisibleSessionCount.count(
            inLedger: [], sessions: [], currentSessionID: nil), 0)
    }
}
