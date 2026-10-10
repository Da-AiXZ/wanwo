//
//  WOHostSizingPoolMultiWidthTests.swift
//  WanWoTests
//
//  【空白修复批】池多宽缓存语义单测（纯簿记面——本文件全部走不触渲染的
//  路径：updateHeight/forceHeight/cachedHeight 直写直读 + height() 的
//  最近宽命中分支（有同签名既有条目时零量高）+ stale 队列/去重锚簿记。
//  remeasure/measure 路径需 UIHostingController 离屏量高，本文件不触碰
//  ——渲染面由真机验收（FREEZE-ON/PREWARM 探针）覆盖）：
//    · 双宽共存（A@882 与 A@482 互不覆盖——单槽投毒通道的根修回归锚）；
//    · updateHeight/forceHeight 按宽入键（0.5pt 死区 per-width、签名保留
//      per-width）；
//    · retain 全宽过滤；
//    · pendingRemasure per-(id,width) 去重 + cancel 释放后可重新入队；
//    · rekeyWidth 最近宽拷贝/清锚语义。
//

import XCTest
import SwiftUI
import CoreGraphics
@testable import WanWo

@MainActor
final class WOHostSizingPoolMultiWidthTests: XCTestCase {

    private func makePool() -> WOHostSizingPool {
        WOHostSizingPool()
    }

    // MARK: - 双宽共存（根修主不变量）

    func testDualWidthEntriesCoexist() {
        let pool = makePool()
        // 预热最窄候选（482，巨高）与当前显示宽（882，真值）先后入池——
        // 单槽时代后者被前者顶替（886→2043 投毒），多宽下必须互不覆盖。
        XCTAssertTrue(pool.updateHeight(id: "A", width: 482, height: 2043,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 882, height: 886,
                                        signature: "v1"))
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 882), 886)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 482), 2043)
        // 探针口径：heightCount = 全部 (id, width) 条目数。
        XCTAssertEqual(pool.heightCount, 2)
    }

    // MARK: - updateHeight 按宽入键

    func testUpdateHeightDeadZoneAndSignaturePerWidth() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 882, height: 886,
                                        signature: "v1"))
        // 同宽 0.5pt 死区（实现契约=先 ceil 再比较：ceil 后同整数值吞掉）。
        XCTAssertFalse(pool.updateHeight(id: "A", width: 882, height: 886.0))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 882, height: 887))
        // 异宽同 id：死区不跨宽（482 无既有条目 → 必写）。
        XCTAssertTrue(pool.updateHeight(id: "A", width: 482, height: 887))
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 482), 887)
        XCTAssertEqual(pool.heightCount, 2)
        // 签名保留 per-width：既有条目保留原签名面（此处经回传无签名直写
        // 不覆盖 "v1" 面——通过 stale 最近宽匹配签名间接验证：下方 stale
        // 测试组覆盖）。
    }

    // MARK: - forceHeight 按宽入键

    func testForceHeightPerWidthKeying() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 482, height: 2043,
                                        signature: "v1"))
        // 直写绕过死区与签名保留（流体收尾批量落真值语义）——只动 882 键。
        pool.forceHeight(id: "A", width: 882, height: 886, signature: "v2")
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 882), 886)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 482), 2043)
        // 再写同宽走直写幂等（无死区），不触碰异宽条目。
        pool.forceHeight(id: "A", width: 882, height: 900, signature: "v3")
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 882), 900)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 482), 2043)
        XCTAssertEqual(pool.heightCount, 2)
    }

    // MARK: - retain 全宽过滤

    func testRetainFiltersEntriesAcrossAllWidths() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 882, height: 886,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 482, height: 2043,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "B", width: 882, height: 100,
                                        signature: "v1"))
        // retain B → A 的全部宽条目清空；B 保留。
        pool.retain(["B"])
        XCTAssertNil(pool.cachedHeight(id: "A", width: 882))
        XCTAssertNil(pool.cachedHeight(id: "A", width: 482))
        XCTAssertEqual(pool.cachedHeight(id: "B", width: 882), 100)
        XCTAssertEqual(pool.heightCount, 1)
        // retain 空（会话切换）→ 全清。
        pool.retain([])
        XCTAssertEqual(pool.heightCount, 0)
    }

    // MARK: - stale 队列 / pendingRemasure per-(id, width)

    /// height() 最近宽命中分支（零渲染路径）：请求宽未命中 + 同签名最近宽
    /// 既有条目 → 返回最近宽高度 + 入队 StaleEntry(请求宽)。
    func testStaleEnqueueNearestWidthAndPerKeyDedup() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 300, height: 500,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 700, height: 300,
                                        signature: "v1"))
        // 请求 640：最近宽 = 700（|700−640|=60 < |300−640|=340）。
        let height = pool.height(id: "A", width: 640, signature: "v1",
                                 makeContent: { AnyView(Color.clear) })
        XCTAssertEqual(height, 300)
        var batch = pool.drainStaleSweep()
        XCTAssertEqual(batch, [WOHostSizingPool.StaleEntry(id: "A", width: 640)])
        // 重复问询同宽：per-(id, width) 去重锚 → 不重复入队。
        _ = pool.height(id: "A", width: 640, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertTrue(pool.drainStaleSweep().isEmpty)
        // 异宽问询（600）：与既有条目等距时取先遍历者——本断言只验入队键
        // 正确（新宽键独立入队）。
        _ = pool.height(id: "A", width: 600, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        batch = pool.drainStaleSweep()
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.id, "A")
        XCTAssertEqual(batch.first?.width, 600)
        // 同行旧宽键在途不妨碍新宽键入队（多宽并发重测不变量）：
        // (A,640) 锚仍在（未 cancel/remeasure），(A,600) 已入队——两条互不遮蔽。
    }

    func testCancelPendingRemasureReleasesPerKeyAnchor() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 300, height: 500,
                                        signature: "v1"))
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertFalse(pool.drainStaleSweep().isEmpty)
        // 异宽 cancel 不应释放 (A,500) 锚。
        pool.cancelPendingRemasure(id: "A", width: 999)
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertTrue(pool.drainStaleSweep().isEmpty)
        // 精确 cancel 释放 → 同宽问询重新入队（QA P1-3 自愈链回归锚）。
        pool.cancelPendingRemasure(id: "A", width: 500)
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertEqual(pool.drainStaleSweep(),
                       [WOHostSizingPool.StaleEntry(id: "A", width: 500)])
    }

    /// 最近宽查找的签名隔离（零渲染路径验证）：异签名既有条目不作为近似
    /// 来源——请求 v2 时只在 v2 条目中取最近宽（命中 → stale 入队路径，
    /// 不落量高）；返回高度断言钉死来源条目。
    func testNearestWidthIgnoresForeignSignatureEntries() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 300, height: 500,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 700, height: 300,
                                        signature: "v2"))
        // 请求 (640, v2)：若签名过滤失效会取 v1@300（h=500）；正确行为
        // 取 v2@700（h=300）。返回值钉死来源 + 入队钉死走 stale 路径
        //（量高路径不入 stale 队）。
        let height = pool.height(id: "A", width: 640, signature: "v2",
                                 makeContent: { AnyView(Color.clear) })
        XCTAssertEqual(height, 300)
        XCTAssertEqual(pool.drainStaleSweep(),
                       [WOHostSizingPool.StaleEntry(id: "A", width: 640)])
    }

    // MARK: - rekeyWidth 多宽语义

    func testRekeyWidthCopiesNearestAndClearsAnchor() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 300, height: 500,
                                        signature: "v1"))
        // 入队 (A,500)（500 无条目、300 同签名最近宽）。
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertFalse(pool.drainStaleSweep().isEmpty)
        // 可见行跳过重测路径：rekey 到请求宽 → 从最近宽（300）拷贝近似
        // 条目 + 清锚（防重复入队原意）。
        pool.rekeyWidth(id: "A", width: 500)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 500), 500)
        // 锚已清 + 500 已有条目 → 再问询缓存直读零入队。
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertTrue(pool.drainStaleSweep().isEmpty)
    }

    func testRekeyWidthOnExistingEntryOnlyClearsAnchor() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 300, height: 500,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 500, height: 480,
                                        signature: "v1"))
        _ = pool.height(id: "A", width: 500, signature: "v1",
                        makeContent: { AnyView(Color.clear) })
        XCTAssertTrue(pool.drainStaleSweep().isEmpty) // 缓存直读不入队（前置）
        // 直接对已有条目宽 rekey：高度维持原值、仅清锚语义（无拷贝副作用）。
        pool.rekeyWidth(id: "A", width: 500)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 500), 480)
        XCTAssertEqual(pool.cachedHeight(id: "A", width: 300), 500)
    }

    // MARK: - invalidateWidth 语义不变（全宽全清）

    func testInvalidateWidthClearsAllWidths() {
        let pool = makePool()
        XCTAssertTrue(pool.updateHeight(id: "A", width: 882, height: 886,
                                        signature: "v1"))
        XCTAssertTrue(pool.updateHeight(id: "A", width: 482, height: 2043,
                                        signature: "v1"))
        pool.invalidateWidth()
        XCTAssertEqual(pool.heightCount, 0)
        XCTAssertNil(pool.cachedHeight(id: "A", width: 882))
        XCTAssertNil(pool.cachedHeight(id: "A", width: 482))
    }
}
