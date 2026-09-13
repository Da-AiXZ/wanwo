//
//  SkillCatalogInjectorTests.swift
//  WanWoTests
//
//  【M4-D 件 D4 测试】目录注入：消息形态（两行条目/字典序/XML 转义/500 上限/
//  空替换显式空标签）/预算两档（全量或 Omitted+marker）/派生面基线（末条识别/
//  无变化不注入/增删改触发/空态零噪音/压缩影子化后重建——DeriveFold 可注入
//  测试，锚 SessionEvent 构造）。dsh skills.md:229-235 + codex render.rs。
//

import XCTest
@testable import WanWo

final class SkillCatalogInjectorTests: XCTestCase {

    // MARK: fixture

    private func summary(_ name: String, _ description: String,
                         source: SkillSource = .project) -> SkillSummary {
        SkillSummary(name: name, description: description, whenToUse: nil,
                     invocation: .default, source: source,
                     resourceBase: "/tmp/skills/\(name)",
                     bodyPath: "/tmp/skills/\(name)/SKILL.md")
    }

    private func event(_ seq: Int, _ text: String) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: .userMessage(text: text))
    }

    // MARK: 消息形态

    func testMessageShapeTwoLinesPerSkillNameSorted() {
        let snapshot = SkillSnapshot(
            summaries: [summary("zeta", "Last one"), summary("alpha", "First one")],
            errors: [])
        let message = SkillCatalogInjector.message(for: snapshot)

        // system-reminder 包装 + available_skills 标签对 + 两行条目 + 字典序
        XCTAssertTrue(message.hasPrefix("<system-reminder>\n<available_skills>\n"))
        XCTAssertTrue(message.hasSuffix("\n</available_skills>\n</system-reminder>"))
        XCTAssertTrue(message.contains("alpha\nFirst one\nzeta\nLast one"))
        // 不含 body/路径/source/whenToUse
        XCTAssertFalse(message.contains("/tmp/skills"))
        XCTAssertFalse(message.contains("whenToUse"))
    }

    func testXmlEscaping() {
        XCTAssertEqual(SkillCatalogInjector.xmlEscape("a & b < c > d \" e ' f"),
                       "a &amp; b &lt; c &gt; d &quot; e &apos; f")
        // & 先转义不二次
        XCTAssertEqual(SkillCatalogInjector.xmlEscape("&lt;"), "&amp;lt;")
        let snapshot = SkillSnapshot(
            summaries: [summary("esc", "Build for <AWS> & \"ECS\"")], errors: [])
        let message = SkillCatalogInjector.message(for: snapshot)
        XCTAssertTrue(message.contains("Build for &lt;AWS&gt; &amp; &quot;ECS&quot;"))
        XCTAssertFalse(message.contains("Build for <AWS>"))
    }

    func testDescriptionCappedAtFiveHundred() {
        // ≤500 原样
        XCTAssertEqual(SkillCatalogInjector.catalogDescription(String(repeating: "a", count: 500)),
                       String(repeating: "a", count: 500))
        // >500 → 前缀 497 + "..."（codex TRUNCATED_SKILL_DESCRIPTION_SUFFIX 语义）
        let truncated = SkillCatalogInjector.catalogDescription(String(repeating: "a", count: 600))
        XCTAssertEqual(truncated.count, 500)
        XCTAssertTrue(truncated.hasSuffix("..."))
        XCTAssertEqual(String(truncated.dropLast(3)), String(repeating: "a", count: 497))
    }

    // MARK: 空态与全删

    func testEmptySnapshotRendersExplicitEmptyReplacement() {
        let snapshot = SkillSnapshot(summaries: [], errors: [])
        let message = SkillCatalogInjector.message(for: snapshot)
        XCTAssertTrue(message.contains("<available_skills></available_skills>"))
        XCTAssertFalse(message.contains("<available_skills>\n"))
    }

    // MARK: 预算两档 + Omitted marker（codex :1151-1153 文案逐字）

    func testOmissionMarkerWording() {
        XCTAssertEqual(SkillCatalogInjector.omissionMarker(1),
                       "- 1 additional skill omitted from this bounded skills list.")
        XCTAssertEqual(SkillCatalogInjector.omissionMarker(3),
                       "- 3 additional skills omitted from this bounded skills list.")
    }

    func testBudgetFullFitWhenUnderLimit() {
        let snapshot = SkillSnapshot(
            summaries: [summary("small", "tiny description")], errors: [])
        let message = SkillCatalogInjector.message(for: snapshot, tokenBudget: 10_000)
        XCTAssertTrue(message.contains("small\ntiny description"))
        XCTAssertFalse(message.contains("omitted"))
    }

    func testBudgetOmitsEntriesWithMarkerWhenOverLimit() {
        let summaries = (0..<10).map { summary("skill-\($0)", String(repeating: "d", count: 100)) }
        let snapshot = SkillSnapshot(summaries: summaries, errors: [])
        let message = SkillCatalogInjector.message(for: snapshot, tokenBudget: 60)

        // 装得下的条目完整保留；装不下的 Omitted；末尾 marker
        // （预算 60 tokens：单条目 ≈36 → 仅 skill-0 装下，其余 9 条 Omitted；
        // marker ≈20 → 36+21=57 ≤ 60 → skill-0 保留）。
        XCTAssertTrue(message.contains("skill-0\nd"))
        XCTAssertTrue(message.contains("9 additional skills omitted from this bounded skills list."))
        XCTAssertFalse(message.contains("skill-1\nd"))
        XCTAssertFalse(message.contains("skill-9\nd"))
    }

    func testMarkerBudgetPreemption() {
        // D6 顺手补（D4 review 登记项）：marker 成本计入预算——装不下时从尾部
        // 回退条目给 marker 让位（预算 45：条目 36 单独装得下，但 36+21>45 →
        // 回退 → 全部 10 条 Omitted，marker 必现保底）。
        let summaries = (0..<10).map { summary("skill-\($0)", String(repeating: "d", count: 100)) }
        let snapshot = SkillSnapshot(summaries: summaries, errors: [])
        let message = SkillCatalogInjector.message(for: snapshot, tokenBudget: 45)

        XCTAssertTrue(message.contains("10 additional skills omitted from this bounded skills list."))
        XCTAssertFalse(message.contains("skill-0\nd"), "unexpected: " + message)
        XCTAssertTrue(message.contains("<available_skills>\n- 10 additional skills omitted"), "unexpected: " + message)
        print("MARKER_DEBUG_FULL:", message)
    }

    // MARK: 派生面基线与投影

    func testBaselinePicksLastCatalogMessageInDerivedView() {
        let catalog = SkillCatalogInjector.message(
            for: SkillSnapshot(summaries: [summary("a", "A")], errors: []))
        let events: [SessionEvent] = [
            event(0, "user typed <available_skills> in prose"),  // 含标记的普通消息也算（同信任级，登记）
            event(1, "hello"),
            event(2, catalog),
        ]
        XCTAssertEqual(SkillCatalogInjector.baselineText(events: events), catalog)
    }

    func testProjectInjectsOnFirstNonEmptySnapshotOnly() {
        let snapshot = SkillSnapshot(summaries: [summary("a", "A")], errors: [])
        // 首次（无基线）→ 注入
        XCTAssertNotNil(SkillCatalogInjector.project(snapshot: snapshot, events: []))
        // 注入后（基线=候选）→ nil
        let events = [event(0, SkillCatalogInjector.message(for: snapshot))]
        XCTAssertNil(SkillCatalogInjector.project(snapshot: snapshot, events: events))
    }

    func testProjectEmptySnapshotNoHistoryIsSilent() {
        // 空态零噪音：从未有过目录消息 → 空快照不注入
        XCTAssertNil(SkillCatalogInjector.project(
            snapshot: SkillSnapshot(summaries: [], errors: []), events: []))
    }

    func testProjectChangeTriggersReplacement() {
        let old = SkillSnapshot(summaries: [summary("a", "old description")], errors: [])
        let oldEvents = [event(0, SkillCatalogInjector.message(for: old))]

        // 改描述 → 新消息
        let changed = SkillSnapshot(summaries: [summary("a", "new description")], errors: [])
        let changedProjection = SkillCatalogInjector.project(snapshot: changed, events: oldEvents)
        XCTAssertNotNil(changedProjection)
        XCTAssertTrue(changedProjection?.contains("new description") ?? false)

        // 增技能 → 新消息
        let added = SkillSnapshot(summaries: [summary("a", "old description"),
                                              summary("b", "B")], errors: [])
        XCTAssertNotNil(SkillCatalogInjector.project(snapshot: added, events: oldEvents))

        // 全删 → 显式空替换
        let empty = SkillSnapshot(summaries: [], errors: [])
        let emptyProjection = SkillCatalogInjector.project(snapshot: empty, events: oldEvents)
        XCTAssertNotNil(emptyProjection)
        XCTAssertTrue(emptyProjection?.contains("<available_skills></available_skills>") ?? false)

        // 空替换落盘后再投影 → nil（基线=空替换文本）
        let afterEmpty = oldEvents + [event(1, emptyProjection!)]
        XCTAssertNil(SkillCatalogInjector.project(snapshot: empty, events: afterEmpty))
    }

    func testCompactionShadowingLosesBaselineAndReinjects() {
        // dsh :233：目录消息被压缩影子化 → 派生序列无此消息 → 基线丢失 →
        // complete snapshot 自动重建。
        let snapshot = SkillSnapshot(summaries: [summary("a", "A")], errors: [])
        let catalogText = SkillCatalogInjector.message(for: snapshot)
        let events: [SessionEvent] = [
            event(0, "earlier user turn"),
            event(1, catalogText),
            SessionEvent(seq: 2, timeMs: 0,
                         payload: .compactionSummary(compactionId: "c1", summary: "summary",
                                                     shadowedRangeStart: 0,
                                                     shadowedRangeEnd: 1,
                                                     shadowedSeqs: [0, 1],
                                                     shadowedTokenCount: 10)),
        ]
        // 派生面：seq 0/1 被影子化 → 基线 nil → 重新注入
        XCTAssertNil(SkillCatalogInjector.baselineText(events: events))
        XCTAssertEqual(SkillCatalogInjector.project(snapshot: snapshot, events: events),
                       catalogText)
    }
}
