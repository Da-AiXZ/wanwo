//
//  WOMessageListSupportTests.swift
//  WanWoTests
//
//  【重做批 1】纯函数面用例——覆盖 WanWo/UI/Chat/List/WOMessageListSupport.swift
//  全部公开纯函数（flatten 拍平与元条目合成 / 历史窗口边界 / 窗口切片 /
//  量高预算切片 / 行高插值 / 贴底几何 / 冻结迟滞带 / 回底判定 / 让位增量 /
//  探针汇总）18 个用例。本地无编译环境，静态自检从严 + CI XCTest 云端跑。
//  测试主体源自 tag backup-ci50-20261006 Batch1ListSkeletonTests 的纯函数
//  部分（逐条核对后搬移），底部几何/冻结带/回底/让位为本批新增覆盖。
//

import XCTest
@testable import WanWo

final class WOMessageListSupportTests: XCTestCase {

    // MARK: 构造 helper

    private func bubble(_ id: String, _ text: String) -> ConversationProjector.Bubble {
        ConversationProjector.Bubble(id: id, kind: .assistant(text))
    }

    // MARK: flatten（节点流拍平 + 元条目合成）

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

    // MARK: 历史窗口（边界数学）

    func testHistoryWindowBoundsInitialTail() {
        // 120 节点 / 页 50：初载窗口 = 尾部 50（起点 70）。
        let bounds = WOMessageListSupport.historyWindowBounds(
            total: 120, start: 0, pageSize: 50)
        XCTAssertEqual(bounds.initialStart, 70)
        // start=0 本身无更早；扩窗态（start=70）有更早、再前移一页。
        XCTAssertFalse(bounds.hasEarlier)
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
        XCTAssertEqual(slice.first?.id, "n3")
        // 防越界：start 超界贴回合法区间（不崩、不空窗误判）。
        let (overSlice, overClamped) = WOMessageListSupport.windowedSlice(nodes: nodes, start: 99)
        XCTAssertEqual(overClamped, 10)
        XCTAssertTrue(overSlice.isEmpty)
        // 负起点贴回 0（防御性）。
        let (negSlice, negClamped) = WOMessageListSupport.windowedSlice(nodes: nodes, start: -5)
        XCTAssertEqual(negClamped, 0)
        XCTAssertEqual(negSlice.count, 10)
    }

    // MARK: 量高时间预算（至少一条防饿死）

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

    // MARK: 行高插值（lody ChatScroll.advance 1:1 对齐版）

    func testAdvanceHeightConverges() {
        // 大 elapsed：一步贴到目标。
        let value = WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 10, response: 0.25)
        XCTAssertEqual(value, 300)
        // elapsed 0：不推进（本帧无时间流逝，位置不动）。
        XCTAssertEqual(WOMessageListSupport.advanceHeight(
            current: 100, toward: 300, elapsed: 0, response: 0.25), 100)
        // response 0 且 elapsed > 0：一步满速贴 target。
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

    // MARK: 贴底几何（lody ChatScroll.bottom 1:1）

    func testBottomOffsetArithmetic() {
        // 常规：内容 1000 / 视口 600 / 底 inset 100 → offset 500。
        XCTAssertEqual(
            WOMessageListSupport.bottomOffset(contentHeight: 1000,
                                              viewportHeight: 600,
                                              topInset: 0, bottomInset: 100),
            500)
        // 内容矮于视口：不越过顶部 rubber band 边界（负 offset 钳到 -topInset）。
        XCTAssertEqual(
            WOMessageListSupport.bottomOffset(contentHeight: 300,
                                              viewportHeight: 600,
                                              topInset: 20, bottomInset: 0),
            -20)
    }

    // MARK: 冻结迟滞带（未冻 80 / 已冻 160——防边界 churn）

    func testFreezeMarginHysteresis() {
        XCTAssertEqual(WOMessageListSupport.freezeMargin(alreadyFrozen: false), 80)
        XCTAssertEqual(WOMessageListSupport.freezeMargin(alreadyFrozen: true), 160)
    }

    func testIsOffscreenBand() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 600)
        // 带内（贴视口下缘 50pt，未冻 80 带覆盖）→ 不算离屏。
        let inside = WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 0, y: 610, width: 100, height: 50),
            viewport: viewport, margin: 80)
        XCTAssertFalse(inside)
        // 出带（距视口下缘 > 80）→ 离屏。
        let outside = WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 0, y: 700, width: 100, height: 50),
            viewport: viewport, margin: 80)
        XCTAssertTrue(outside)
        // 已冻行用 160 宽带：80~160 之间仍在带内（迟滞——防边界抖动）。
        let hysteresis = WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 0, y: 700, width: 100, height: 50),
            viewport: viewport, margin: 160)
        XCTAssertFalse(hysteresis)
    }

    // MARK: 回底恢复判定（距底 ≤1pt）

    func testShouldResumeFollowing() {
        XCTAssertTrue(WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: 500, offsetY: 499.5))
        XCTAssertFalse(WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: 500, offsetY: 419))
    }

    // MARK: 让位增量（composer 座位超基准部分）

    func testBottomInsetIncrement() {
        // 常态座位 ≈ 基准 → 增量 0（视觉零变化）。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 137, baseline: 137), 0)
        // 审批卡/todo 卡顶高座位 → 正增量。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 200, baseline: 137), 63)
        // 座位矮于基准（理论不出现）→ 钳 0。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 100, baseline: 137), 0)
    }

    // MARK: 探针汇总

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

    // MARK: - 【重做批6】同出缓动曲线（cubic-bezier(.22,1,.36,1) 采样）

    func testCoGrowEaseEndpoints() {
        // 端点恒等：x=0→0、x=1→1、越界原样返回（无插值面）。
        XCTAssertEqual(WOMessageListSupport.coGrowEase(0), 0, accuracy: 1e-9)
        XCTAssertEqual(WOMessageListSupport.coGrowEase(1), 1, accuracy: 1e-9)
        XCTAssertEqual(WOMessageListSupport.coGrowEase(-0.5), -0.5, accuracy: 1e-9)
        XCTAssertEqual(WOMessageListSupport.coGrowEase(1.5), 1.5, accuracy: 1e-9)
    }

    func testCoGrowEaseMonotonicAndShape() {
        // 单调不减 + 值域 [0,1]。
        var previous = -1.0
        for step in 1...99 {
            let x = Double(step) / 100.0
            let y = WOMessageListSupport.coGrowEase(x)
            XCTAssertTrue(y >= previous - 1e-9, "x=\(x) 非单调")
            XCTAssertTrue(y >= 0 && y <= 1, "x=\(x) 越界")
            previous = y
        }
        // 强 ease-out 形（P1y=P2y=1）：半程进度输出显著过半（>0.7）。
        XCTAssertGreaterThan(WOMessageListSupport.coGrowEase(0.5), 0.7)
    }
}
