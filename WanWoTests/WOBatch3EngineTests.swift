//
//  WOBatch3EngineTests.swift
//  WanWoTests
//
//  【重做批 3】引擎内核用例——池（updateHeight 规则/签名语义/first-write
//  采纳/stale 顶替/retain 清理）、Markdown 文档缓存、入场账本、探针环形
//  缓冲。主体源自 tag backup-ci50-20261006 Batch1ListSkeletonTests 对应节
//  （逐条核对搬移），命名随重做批次重组。
//

import XCTest
import SwiftUI
@testable import WanWo

final class WOBatch3EngineTests: XCTestCase {

    // MARK: Markdown 文档缓存（键形状 + 解析入库）

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

    // MARK: 池高度回传缝（updateHeight）

    @MainActor
    func testPoolUpdateHeightRules() {
        let pool = WOHostSizingPool()
        // 首写生效（无缓存条目 → 写入返回 true）。
        XCTAssertTrue(pool.updateHeight(id: "h1", width: 300, height: 88.4))
        XCTAssertEqual(pool.cachedHeight(id: "h1", width: 300), 89) // ceil
        // 差 ≤0.5pt 视为无变化（防 33Hz 微增量风暴）→ no-op 返回 false。
        XCTAssertFalse(pool.updateHeight(id: "h1", width: 300, height: 88.6))
        XCTAssertEqual(pool.cachedHeight(id: "h1", width: 300), 89)
        // 超差更新（真实内容膨胀场景）→ 返回 true 且缓存修正。
        XCTAssertTrue(pool.updateHeight(id: "h1", width: 300, height: 240))
        XCTAssertEqual(pool.cachedHeight(id: "h1", width: 300), 240)
        // 宽度变化 = 覆盖语义【QA P0-1 纠偏】（池单 id 单条目，宽度是失效
        // 判定而非多宽度存储——lody 同型）：500 宽首写覆盖 300 宽条目，
        // 旧宽直读失效返回 nil。
        XCTAssertTrue(pool.updateHeight(id: "h1", width: 500, height: 100))
        XCTAssertEqual(pool.cachedHeight(id: "h1", width: 500), 100)
        XCTAssertNil(pool.cachedHeight(id: "h1", width: 300))
        // 未知 id 直读 nil（retention 清理后的迟到上报不伪造可读高度）。
        XCTAssertNil(pool.cachedHeight(id: "ghost", width: 300))
    }

    @MainActor
    func testPoolUpdateHeightKeepsSignature() {
        // 高度修正不改内容签名：量高入库（签名 v3）→ 回传修正后，同签名
        // 问询不再重测（直读修正值），签名 bump 后照常失效重测。
        let pool = WOHostSizingPool()
        _ = pool.height(id: "h2", width: 300, signature: "v3",
                        makeContent: { AnyView(Text("x").frame(height: 50)) })
        _ = pool.updateHeight(id: "h2", width: 300, height: 120)
        // 同签名 + 已修正高度 → 高度问询直读（makeContent 不再被调——
        // 用哨兵闭包断言：若被调用会返回 999 的高度）。
        let probed = pool.height(id: "h2", width: 300, signature: "v3",
                                 makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(probed, 120)
        // 签名 bump → 缓存失效 → 重测路径接管（返回新内容实测高度）。
        let remeasured = pool.height(id: "h2", width: 300, signature: "v4",
                                     makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(remeasured, 999)
    }

    @MainActor
    func testPoolUpdateHeightFirstWriteAdoptsSignature() {
        // 【QA P1-2 封口】heights 清空后（retain/invalidateWidth）回传迟到
        // 首写：带调用方签名写入 → 同签名问询直读修正值（不被空态重测
        // 覆盖——防永久溢出窗口）；签名 bump 后照常重测。
        let pool = WOHostSizingPool()
        XCTAssertTrue(pool.updateHeight(id: "h3", width: 300, height: 200,
                                        signature: "v2"))
        let probed = pool.height(id: "h3", width: 300, signature: "v2",
                                 makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(probed, 200)
        let remeasured = pool.height(id: "h3", width: 300, signature: "v3",
                                     makeContent: { AnyView(Color.clear.frame(height: 888)) })
        XCTAssertEqual(remeasured, 888)
    }

    // MARK: 池宽度变化 stale 顶替（右栏开合卡顿根治）

    @MainActor
    func testPoolStaleSweepOnWidthChange() {
        let pool = WOHostSizingPool()
        _ = pool.height(id: "s1", width: 300, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 80)) })
        // 宽度变化 + 签名未变 → 旧高先顶（不触发同步重测——哨兵 999 不被调）
        // + 记入 staleSweep 待异步重测。
        let stale = pool.height(id: "s1", width: 500, signature: "v1",
                                makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(stale, 80)
        XCTAssertEqual(pool.staleSweep, [WOHostSizingPool.StaleEntry(id: "s1", width: 500)])
        // 重复问询去重（pendingRemasure 锚）——不重复入队。
        _ = pool.height(id: "s1", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(pool.staleSweep.count, 1)
        // drain 取走队列。
        let batch = pool.drainStaleSweep()
        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(pool.staleSweep.isEmpty)
        // remeasure 完成释放去重锚 → 宽度再变可重新入队。
        _ = pool.remeasure(id: "s1", width: 500, signature: "v1",
                           makeContent: { AnyView(Color.clear.frame(height: 120)) })
        _ = pool.height(id: "s1", width: 600, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertEqual(pool.staleSweep, [WOHostSizingPool.StaleEntry(id: "s1", width: 600)])
    }

    @MainActor
    func testPoolSignatureChangeStillSyncRemasures() {
        // 签名变化（内容更新面）保持同步重测语义——不进 stale 队列。
        let pool = WOHostSizingPool()
        _ = pool.height(id: "s2", width: 300, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 80)) })
        let remeasured = pool.height(id: "s2", width: 300, signature: "v2",
                                     makeContent: { AnyView(Color.clear.frame(height: 140)) })
        XCTAssertEqual(remeasured, 140)
        XCTAssertTrue(pool.staleSweep.isEmpty)
    }

    @MainActor
    func testPoolRetainClearsStaleBookkeeping() {
        let pool = WOHostSizingPool()
        _ = pool.height(id: "s3", width: 300, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 80)) })
        _ = pool.height(id: "s3", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear.frame(height: 999)) })
        XCTAssertFalse(pool.staleSweep.isEmpty)
        pool.retain(["other"])
        XCTAssertTrue(pool.staleSweep.isEmpty)
        XCTAssertNil(pool.cachedHeight(id: "s3", width: 500))
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

    // MARK: 探针实例（环形缓冲）

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
