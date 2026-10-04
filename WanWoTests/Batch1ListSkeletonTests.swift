//
//  Batch1ListSkeletonTests.swift
//  WanWoTests
//
//  【批 1】UIKit 消息列表骨架——纯函数面用例（本地无编译环境，静态自检从严
//  + CI XCTest 云端跑）。覆盖：件 1 flatten（身份稳定性/元条目合成）、
//  件 3 窗口边界 + 预算切片、件 2 插值数学、件 5 探针汇总、件 4 缓存键与
//  解析入库、入场账本（WOEntryLedger）。
//

import XCTest
import SwiftStreamingMarkdown
@testable import WanWo

final class Batch1ListSkeletonTests: XCTestCase {

    // MARK: 件 1 flatten（节点流拍平 + 元条目合成）

    private func bubble(_ id: String, _ text: String) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: .assistant(text))
    }

    func testFlattenOrderAndIDs() {
        let nodes: [ConversationProjector.DisplayNode] = [
            .plain(bubble("u1", "hi")),
            .plain(bubble("a1", "hello")),
        ]
        let items = WOMessageListSupport.flatten(nodes: nodes, phase: .idle,
                                                 hasEarlierHistory: false,
                                                 historyLoading: false)
        // 顺序与身份：无元条目时 = 节点流逐条直映（id 复用既有代际化体系）。
        XCTAssertEqual(items.map(\.id), ["u1", "a1"])
        XCTAssertEqual(items[0].kind, .bubble(bubble("u1", "hi")))
    }

    func testFlattenMetaItemsComposition() {
        let nodes: [ConversationProjector.DisplayNode] = [
            .plain(bubble("u1", "hi")),
        ]
        // 失败态全元条目在场：历史头 → 节点 → failed（顺序对齐原 messageList
        // 附属视图排布；loading 仅 .loading 相位、beam 仅 .streaming 相位）。
        let items = WOMessageListSupport.flatten(
            nodes: nodes, phase: .failed("boom"),
            hasEarlierHistory: true, historyLoading: true)
        XCTAssertEqual(items.map(\.id), [
            WOMessageListSupport.historyItemID,
            "u1",
            WOMessageListSupport.failedItemID,
        ])
        XCTAssertEqual(items[0].kind, .history(loading: true))
        XCTAssertEqual(items[2].kind, .failed("boom"))
        // loading 相位：历史头 + loading 条目（无 beam/failed）。
        let loading = WOMessageListSupport.flatten(
            nodes: nodes, phase: .loading,
            hasEarlierHistory: true, historyLoading: false)
        XCTAssertEqual(loading.map(\.id), [
            WOMessageListSupport.historyItemID,
            WOMessageListSupport.loadingItemID,
            "u1",
        ])
        XCTAssertEqual(loading[1].kind, .loading)
    }

    func testFlattenProcessGroupFlattens() {
        let group = ConversationProjector.TurnProcessGroup(
            id: "tp-1", bubbles: [bubble("t1", "x"), bubble("r1", "y")])
        let items = WOMessageListSupport.flatten(
            nodes: [.process(group)], phase: .streaming,
            hasEarlierHistory: false, historyLoading: false)
        // 组内逐个平铺为直系子项（与 LazyVStack ForEach 语义一致）+ 尾部 beam。
        XCTAssertEqual(items.map(\.id), ["t1", "r1", WOMessageListSupport.beamItemID])
    }

    func testFlattenIdentityStability() {
        // 同输入 → 全等（33Hz no-op 守卫的比对基线）。
        let nodes: [ConversationProjector.DisplayNode] = [.plain(bubble("a1", "hi"))]
        let first = WOMessageListSupport.flatten(nodes: nodes, phase: .idle,
                                                 hasEarlierHistory: false,
                                                 historyLoading: false)
        let second = WOMessageListSupport.flatten(nodes: nodes, phase: .idle,
                                                  hasEarlierHistory: false,
                                                  historyLoading: false)
        XCTAssertEqual(first, second)
        // 同 id 内容变 → 不等（reconfigure 触发依据），id 不变（身份锚）。
        let changed = WOMessageListSupport.flatten(
            nodes: [.plain(bubble("a1", "hi!"))], phase: .idle,
            hasEarlierHistory: false, historyLoading: false)
        XCTAssertNotEqual(first, changed)
        XCTAssertEqual(first.map(\.id), changed.map(\.id))
        // 历史头 loading 翻转 → 不等（头条 reconfigure 触发依据）。
        let headerFlip = WOMessageListSupport.flatten(
            nodes: nodes, phase: .idle, hasEarlierHistory: true,
            historyLoading: false)
        let headerLoading = WOMessageListSupport.flatten(
            nodes: nodes, phase: .idle, hasEarlierHistory: true,
            historyLoading: true)
        XCTAssertNotEqual(headerFlip, headerLoading)
        XCTAssertEqual(headerFlip.map(\.id), headerLoading.map(\.id))
    }

    // MARK: 件 3 历史窗口（边界数学）

    func testHistoryWindowBoundsInitialTail() {
        // 120 节点 / 页 50：初载窗口 = 尾部 50（起点 70）。
        let bounds = WOMessageListSupport.historyWindowBounds(
            total: 120, start: 0, pageSize: 50)
        XCTAssertEqual(bounds.initialStart, 70)
        // 有更早历史（起点 > 0）；扩窗再前移一页。
        XCTAssertTrue(bounds.hasEarlier == false) // start=0 本身无更早
        let expanded = WOMessageListSupport.historyWindowBounds(
            total: 120, start: 70, pageSize: 50)
        XCTAssertTrue(expanded.hasEarlier)
        XCTAssertEqual(expanded.expandedStart, 20)
    }

    func testHistoryWindowBoundsSmallTotal() {
        // 总量 < 页大小：全量在列（起点 0），无更早。
        let bounds = WOMessageListSupport.historyWindowBounds(
            total: 30, start: 0, pageSize: 50)
        XCTAssertEqual(bounds.initialStart, 0)
        XCTAssertFalse(bounds.hasEarlier)
    }

    func testWindowedSliceClamps() {
        let nodes: [ConversationProjector.DisplayNode] = (0..<10).map {
            .plain(bubble("n\($0)", "t"))
        }
        // 正常切片：起点 3 → 尾部 7 条。
        let (slice, clamped) = WOMessageListSupport.windowedSlice(nodes: nodes, start: 3)
        XCTAssertEqual(clamped, 3)
        XCTAssertEqual(slice.count, 7)
        XCTAssertEqual((slice.first?.id)!, "n3")
        // 防越界：start 超界贴回合法区间（不崩、不空窗误判）。
        let (overSlice, overClamped) = WOMessageListSupport.windowedSlice(nodes: nodes, start: 99)
        XCTAssertEqual(overClamped, 10)
        XCTAssertTrue(overSlice.isEmpty)
    }

    // MARK: 件 3 量高时间预算（至少一条防饿死）

    func testMeasureSliceBudgetAdvances() {
        // 成本 1ms / 预算 4ms / 已耗 0：单轮处理 4 条（预算内推进）。
        let result = WOMessageListSupport.measureSlice(
            currentIndex: 0, total: 100, elapsedMs: 0,
            budgetMs: 4, costPerItemMs: 1)
        XCTAssertEqual(result.processed, 4)
        XCTAssertEqual(result.nextIndex, 4)
    }

    func testMeasureSliceAtLeastOneItem() {
        // 单条成本超预算：仍至少处理一条（lody 防饿死铁律——单条巨行
        // 不允许饿死整轮）。
        let result = WOMessageListSupport.measureSlice(
            currentIndex: 7, total: 100, elapsedMs: 3.9,
            budgetMs: 4, costPerItemMs: 50)
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.nextIndex, 8)
    }

    func testMeasureSliceCompletesAtTotal() {
        // 剩余不足预算：处理到 total 收口（游标不越界）。
        let result = WOMessageListSupport.measureSlice(
            currentIndex: 8, total: 10, elapsedMs: 0,
            budgetMs: 4, costPerItemMs: 0.1)
        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(result.nextIndex, 10)
    }

    // MARK: 件 2 行高插值（批 2 件 1 起为 lody ChatScroll.advance 1:1 对齐版）

    func testAdvanceHeightConverges() {
        // 大 elapsed：一步贴到目标。
        let value = WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 10, response: 0.25)
        XCTAssertEqual(value, 300)
        // elapsed 0：不推进（lody 物理语义——本帧无时间流逝，位置不动；
        // exp(0)=1 → 增量为 0）。原"elapsed 0 直给 target"断言随 1:1 对齐
        // 改造（批 2 件 5 矩阵同步）。
        XCTAssertEqual(WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 0, response: 0.25), 100)
        // response 0 且 elapsed > 0：一步满速贴 target（exp(-∞)=0）。
        XCTAssertEqual(WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 0.1, response: 0), 300)
        // 小 elapsed：朝目标推进但不越过（缓出方向正确）。
        let partial = WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 0.02, response: 0.25)
        XCTAssertGreaterThan(partial, 100)
        XCTAssertLessThan(partial, 300)
        // 亚像素 minimumStep（lody :87-89）：步长 < 1px 直接给 target——
        // 防 UIScrollView 像素取整导致 display link 永续空转。
        let stepped = WOMessageListSupport.advanceHeight(
            current: 100, toward: 100.4, elapsed: 0.001, response: 1,
            minimumStep: 1.0)
        XCTAssertEqual(stepped, 100.4)
    }

    // MARK: 件 5 探针汇总

    func testProbeSummaryEmpty() {
        XCTAssertEqual(WOMessageListSupport.probeSummary(durationsMs: [],
                                                         itemCounts: []), "apply=none")
    }

    func testProbeSummaryPercentiles() {
        let durations = Array(repeating: 2.0, count: 99) + [100.0]
        let line = WOMessageListSupport.probeSummary(
            durationsMs: durations, itemCounts: [10, 20])
        // p95 不被单极值拉飞（99 条 2ms + 1 条 100ms → p95=2ms，max=100ms）。
        XCTAssertTrue(line.contains("p95=2.00ms"))
        XCTAssertTrue(line.contains("max=100.00ms"))
        XCTAssertTrue(line.contains("maxItems=20"))
    }

    // MARK: 件 4 Markdown 文档缓存（键形状 + 解析入库）

    func testMarkdownCacheKeyShape() {
        // 键 = 配置代际 \0 文本（流式/非流式命名空间分离的 lody 语义；
        // 同文本恒同键，不同文本恒异键）。
        XCTAssertEqual(WOMarkdownDocumentCache.key("hi"),
                       WOMarkdownDocumentCache.key("hi"))
        XCTAssertNotEqual(WOMarkdownDocumentCache.key("hi"),
                          WOMarkdownDocumentCache.key("hi "))
        XCTAssertTrue(WOMarkdownDocumentCache.key("hi").hasPrefix("v1\u{0}"))
    }

    func testMarkdownCacheParseAndRoundtrip() async {
        // shared 单例（init private）；文本唯一防跨用例污染。
        let cache = WOMarkdownDocumentCache.shared
        let text = "# 标题\n\n正文段落-b1-\(UUID().uuidString)"
        // 未命中：document(for:) 为 nil。
        XCTAssertNil(cache.document(for: text))
        // 解析入库 → 命中同文档（RenderableDocument Equatable）。
        let parsed = await cache.parseAndStore(text, config: .default)
        let hit = cache.document(for: text)
        XCTAssertEqual(hit, parsed)
        // 再次 parseAndStore = 缓存直回（同实例语义，等值断言）。
        let again = await cache.parseAndStore(text, config: .default)
        XCTAssertEqual(again, parsed)
    }

    // MARK: 入场账本（WOEntryLedger；@MainActor）

    @MainActor
    func testEntryLedgerSeenAndUserSentinel() {
        let ledger = WOEntryLedger()
        XCTAssertFalse(ledger.seeded)
        // 首投影补种。
        ledger.seedAll(["u1", "a1", "r1"])
        ledger.markSeeded()
        XCTAssertTrue(ledger.seeded)
        XCTAssertTrue(ledger.seenIDs.contains("u1"))
        // 幂等补种。
        ledger.seedAll(["u1", "a1", "r1"])
        XCTAssertEqual(ledger.seenIDs.count, 3)
        // 用户哨兵交接：u-pending seen → 置真；落盘 u(seq) seen → 归位。
        ledger.markSeen("u-pending", kindTag: "user")
        XCTAssertTrue(ledger.pendingUserSeen)
        ledger.markSeen("u5", kindTag: "user")
        XCTAssertFalse(ledger.pendingUserSeen)
        // 非用户节点不触碰哨兵旗。
        ledger.markSeen("a9", kindTag: "assistant")
        XCTAssertFalse(ledger.pendingUserSeen)
        // 重置（会话切换）。
        ledger.reset()
        XCTAssertFalse(ledger.seeded)
        XCTAssertTrue(ledger.seenIDs.isEmpty)
        XCTAssertFalse(ledger.pendingUserSeen)
    }

    // MARK: 件 5 探针实例（环形缓冲）

    @MainActor
    func testProbeRecordAndReset() {
        // shared 单例（init private）；先 reset 防跨用例污染。
        let probe = WOChatProbe.shared
        probe.reset()
        probe.record(durationMs: 1.0, itemCount: 5, reconfigureCount: 1, poolCount: 3)
        probe.record(durationMs: 12.0, itemCount: 6, reconfigureCount: 2, poolCount: 4)
        XCTAssertEqual(probe.samples.count, 2)
        XCTAssertEqual(probe.samples[0].itemCount, 5)
        XCTAssertEqual(probe.samples[1].reconfigureCount, 2)
        let line = probe.flushSummary()
        XCTAssertTrue(line.contains("n=2"))
        probe.reset()
        XCTAssertTrue(probe.samples.isEmpty)
    }
}
