//
//  M7CardTests.swift
//  WanWoTests
//
//  【M7 件 I 单测】UI 状态卡与设置分区路由（搭车批）：
//    - SettingsPane.memory 分区注册（七分区路由完整性——MemorySettingsView 落点
//      + nav 元数据三面 title/icon/footer 一致性）。
//    - TodoProjection fold → WOTodoChecklistCard 输入形状（投影纯函数侧：
//      整表 last-write-wins / turn/start 清空 / 完成计数源）。
//    - GoalView → WOGoalStatusCard 输入形状（phase 徽章四态 + 回合计数字段）。
//    - MemorySettings 开关持久化（UserDefaults 单键 + 默认开——拍板①）。
//    - MemoryPromptSection：summary 空 → nil（prompts.rs None 语义）；非空 →
//      readPath 模板渲染含 base_path/memory_summary 两占位替换。
//

import XCTest
@testable import WanWo

final class M7CardTests: XCTestCase {

    // MARK: - 设置分区路由

    func testSettingsPaneMemoryRegistered() {
        XCTAssertTrue(SettingsPane.allCases.contains(.memory))
        XCTAssertEqual(SettingsPane.memory.title, "记忆")
        XCTAssertEqual(SettingsPane.memory.destinationIdentifier, "MemorySettingsView")
        XCTAssertFalse(SettingsPane.memory.iconName.isEmpty)
        // 深链路由 enum 语义不变（既有六分区逐一保留）。
        XCTAssertEqual(SettingsPane.providers.destinationIdentifier, "ProvidersView")
        XCTAssertEqual(SettingsPane.diagnostics.destinationIdentifier, "EventStreamView")
    }

    // MARK: - Todo 卡输入形状

    func testTodoProjectionFoldsForCard() throws {
        let payload: JSONValue = .object(["todos": .array([
            .object(["content": .string("写 spec"), "status": .string("completed")]),
            .object(["content": .string("实现"), "status": .string("in_progress")]),
        ])])
        let events = [
            SessionEvent(seq: 0, timeMs: 0, payload: .turnStart(turn: 1)),
            SessionEvent(seq: 1, timeMs: 0, payload: .extensionEvent(
                kind: TodoEvents.writeKind, payload: payload)),
        ]
        let todos = TodoProjection.fold(events: events)
        XCTAssertEqual(todos?.count, 2)
        XCTAssertEqual(todos?.filter { $0.status == .completed }.count, 1)
        // turn/start 清空（卡片空态来源）。
        let cleared = TodoProjection.fold(events + [
            SessionEvent(seq: 2, timeMs: 0, payload: .turnStart(turn: 2)),
        ])
        XCTAssertNil(cleared)
    }

    // MARK: - Goal 卡输入形状

    func testGoalViewCardFields() {
        let goal = GoalView(id: "g1", revision: 3,
                            objective: "Ship memory feature",
                            phase: .active, blockedReason: nil, maxGoalRounds: 8,
                            roundsStarted: 2, createdAt: 0, updatedAt: 0,
                            activation: .armed)
        XCTAssertEqual(goal.phase, .active)
        XCTAssertEqual(goal.roundsStarted, 2)
        XCTAssertEqual(goal.maxGoalRounds, 8)
        XCTAssertNil(goal.blockedReason)
        // 受阻态徽章带 reason。
        let blocked = GoalView(id: goal.id, revision: 4, objective: goal.objective,
                               phase: .blocked,
                               blockedReason: .init(code: "awaiting-input",
                                                    message: "等待用户输入"),
                               maxGoalRounds: 8, roundsStarted: 2, createdAt: 0,
                               updatedAt: 0, activation: .armed)
        XCTAssertEqual(blocked.blockedReason?.message, "等待用户输入")
    }

    // MARK: - Memory 总开关

    func testMemorySettingsDefaultsEnabled() {
        // 默认开（拍板①；UserDefaults 未写入时读面为 true）。
        UserDefaults.standard.removeObject(forKey: MemorySettings.enabledKey)
        XCTAssertTrue(MemorySettings.isEnabled)
        MemorySettings.isEnabled = false
        XCTAssertFalse(MemorySettings.isEnabled)
        MemorySettings.isEnabled = true
        XCTAssertTrue(MemorySettings.isEnabled)
    }

    // MARK: - memory read-path 段

    func testMemoryPromptSectionSummaryGate() throws {
        // 空 summary → nil（prompts.rs :41-43 None → 不注册段落）。
        XCTAssertNil(MemoryPromptSection.summarySection(summaryText: "   \n  "))
        // 非空 → 段落落 SECTION_ORDERS.memorySummary 槽位 + 双占位替换。
        let section = MemoryPromptSection.summarySection(summaryText: "v1\nknown facts")
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.name, "memory:read-path")
        XCTAssertEqual(section?.order, SECTION_ORDERS.memorySummary)
        let text = try XCTUnwrap(section?.text)
        XCTAssertTrue(text.contains(MemoryConstants.memoryGuestPath))
        XCTAssertTrue(text.contains("known facts"))
        XCTAssertFalse(text.contains("{{ base_path }}"))
        XCTAssertFalse(text.contains("{{ memory_summary }}"))
    }
}
