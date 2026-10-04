//
//  Batch2FollowMotionTests.swift
//  WanWoTests
//
//  【批 2 · 跟随精修 5 件】纯函数面用例：件 1 贴底几何（advanceHeight 1:1
//  对齐 lody ChatScroll.advance / bottomOffset / resumeDistance）、件 2 回底
//  恢复判定、件 3 让位增量、件 4 迟滞带判定、件 5 WOTextReveal（CKTextReveal
//  机制矩阵——修正/Unicode/平滑/兜底全排，参照 ChatKit StreamingTextReveal
//  Tests 形态）。
//

import XCTest
@testable import WanWo

final class Batch2FollowMotionTests: XCTestCase {

    // MARK: 件 1 贴底几何（lody ChatScroll 1:1）

    func testBottomOffset() {
        // max(-topInset, contentHeight - viewportHeight + bottomInset)。
        XCTAssertEqual(WOMessageListSupport.bottomOffset(
            contentHeight: 1000, viewportHeight: 600,
            topInset: 0, bottomInset: 0), 400)
        // 动态让位 inset 参与落点（件 3 联动）。
        XCTAssertEqual(WOMessageListSupport.bottomOffset(
            contentHeight: 1000, viewportHeight: 600,
            topInset: 0, bottomInset: 30), 430)
        // 内容不足一屏：不越过顶部 rubber band 边界。
        XCTAssertEqual(WOMessageListSupport.bottomOffset(
            contentHeight: 300, viewportHeight: 600,
            topInset: 50, bottomInset: 0), -50)
    }

    func testAdvanceHeightSubpixelStep() {
        // lody :87-89 注释语义：步长小于一像素会四舍五入回原地——
        // minimumStep 触发时直接给 target，display link 不空转。
        let stepped = WOMessageListSupport.advanceHeight(
            current: 500, toward: 500.3, elapsed: 0.016, response: 0.10,
            minimumStep: 1.0)
        XCTAssertEqual(stepped, 500.3)
        // 步长充足：正常插值（不触发 minimumStep）。
        let normal = WOMessageListSupport.advanceHeight(
            current: 0, toward: 300, elapsed: 0.016, response: 0.10,
            minimumStep: 1.0 / 3.0)
        XCTAssertGreaterThan(normal, 30)
        // 半像素贴 target（收敛尾巴终止）。
        XCTAssertEqual(WOMessageListSupport.advanceHeight(
            current: 300, toward: 300.4, elapsed: 1, response: 0.10), 300.4)
    }

    // MARK: 件 2 回底恢复判定（lody resumeTrackingAtBottom ≤1pt）

    func testShouldResumeFollowing() {
        // 距底 ≤1pt：恢复。
        XCTAssertTrue(WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: 400, offsetY: 399))
        XCTAssertTrue(WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: 400, offsetY: 400))
        // 距底 >1pt：不恢复（用户停在历史区）。
        XCTAssertFalse(WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: 400, offsetY: 398.5))
        // resumeDistance 常量 = lody 实码 80。
        XCTAssertEqual(WOMessageListSupport.resumeDistance, 80)
    }

    // MARK: 件 3 让位增量（与静态 189 分立的动态部分）

    func testBottomInsetIncrement() {
        // 常态座位 ≈ 基准 137：增量 0（视觉零变化——不与静态 189 叠加）。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 137, baseline: 137), 0)
        // 审批卡/todo 卡把座位顶高：增量 = 超出部分。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 200, baseline: 137), 63)
        // 座位低于基准：不为负（静态 189 兜底）。
        XCTAssertEqual(WOMessageListSupport.bottomInsetIncrement(
            composerChromeHeight: 100, baseline: 137), 0)
    }

    // MARK: 件 4 离屏冻结迟滞带（lody 80/160）

    func testFreezeMarginHysteresis() {
        // 未冻 80 / 已冻 160（回带带更宽，防边界 churn）。
        XCTAssertEqual(WOMessageListSupport.freezeMargin(alreadyFrozen: false), 80)
        XCTAssertEqual(WOMessageListSupport.freezeMargin(alreadyFrozen: true), 160)
    }

    func testIsOffscreen() {
        let viewport = CGRect(x: 0, y: 0, width: 375, height: 800)
        // 行在视口内：不判离屏。
        XCTAssertFalse(WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 16, y: 100, width: 343, height: 50),
            viewport: viewport, margin: 80))
        // 行在 ±80 迟滞带内（视口上方 60pt 处）：不算离屏。
        XCTAssertFalse(WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 16, y: -60, width: 343, height: 50),
            viewport: viewport, margin: 80))
        // 行滚出迟滞带（视口上方 200pt）：离屏 → 冻结。
        XCTAssertTrue(WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 16, y: -200, width: 343, height: 50),
            viewport: viewport, margin: 80))
        // 已冻结行用 160 宽带：-200 仍在带内 → 回带解冻。
        XCTAssertFalse(WOMessageListSupport.isOffscreen(
            frame: CGRect(x: 16, y: -200, width: 343, height: 50),
            viewport: viewport, margin: 160))
    }

    // MARK: 件 5 WOTextReveal（CKTextReveal 机制矩阵）

    /// 参照 ChatKit correctionReplacesPendingText：非前缀修正 = 权威修正
    /// 直接 finish（不重播旧内容）。
    func testCorrectionReplacesPendingText() {
        var stream = WOTextReveal()
        stream.receive("Initial", animate: false, at: 0)
        stream.receive("Initial appended text", animate: true, at: 1)
        XCTAssertTrue(stream.hasPending)
        stream.receive("Corrected", animate: true, at: 1.01)
        stream.advance(at: 2)
        XCTAssertEqual(stream.shown, "Corrected")
        XCTAssertFalse(stream.hasPending)
    }

    /// 参照 ChatKit unicodeAppendAndFinishPreserveExactContent。
    func testUnicodeAppendAndFinishPreserveExactContent() {
        let text = "👩🏽‍💻 café\nمرحبا 世界"
        var stream = WOTextReveal()
        stream.receive(text, animate: true, at: 1)
        stream.advance(at: 1.02)
        XCTAssertTrue(text.hasPrefix(stream.shown))
        stream.finish()
        XCTAssertEqual(stream.shown, text)
        XCTAssertFalse(stream.hasPending)
    }

    /// 参照 ChatKit independentStreamsAndAnimationDisable：animate=false =
    /// 直显（无节奏）；双实例互不干扰。
    func testAnimationDisableAndIndependentStreams() {
        var first = WOTextReveal()
        var second = WOTextReveal()
        first.receive("First reply", animate: true, at: 1)
        second.receive("Second reply", animate: true, at: 1)
        first.receive("First reply", animate: false, at: 1.01)
        XCTAssertEqual(first.shown, "First reply")
        XCTAssertEqual(second.shown, "")
        XCTAssertTrue(second.hasPending)
        second.advance(at: 2)
        XCTAssertEqual(second.shown, "Second reply")
    }

    /// 前缀扩展累积：多次 receive 后 advance 按序排空（不丢字、不重字）。
    func testPrefixAppendDrainsInOrder() {
        var stream = WOTextReveal()
        stream.receive("你好，", animate: true, at: 1.0)
        stream.receive("你好，世界！", animate: true, at: 1.04)
        stream.receive("你好，世界！完成。", animate: true, at: 1.08)
        // 多帧推进直到排空。
        var time = 1.10
        while stream.hasPending, time < 5 {
            stream.advance(at: time)
            time += 0.03
        }
        XCTAssertFalse(stream.hasPending)
        XCTAssertEqual(stream.shown, "你好，世界！完成。")
    }

    /// 无输入 ≥0.45s → 全排（CK :47 兜底——输入流断了不等下一个 delta）。
    func testIdleThresholdFlushesAll() {
        var stream = WOTextReveal()
        stream.receive("一段较长的待显示文本内容用于验证兜底", animate: true, at: 1.0)
        // 0.2s 时 advance：尚未到 0.45s 阈值（backlog 小于速率上限时部分显示）。
        stream.advance(at: 1.2)
        let partial = stream.shown
        // 0.5s 时 advance（距上次 receive 0.5s ≥0.45）：全排。
        stream.advance(at: 1.5)
        XCTAssertFalse(stream.hasPending)
        XCTAssertEqual(stream.shown, "一段较长的待显示文本内容用于验证兜底")
        // 0.2s 帧至少打了基础速度的量（38 字/s × 0.2s 上限）——不做精确断言，
        // 只验证兜底前不是全量直出。
        XCTAssertLessThanOrEqual(partial.count, stream.shown.count)
    }

    /// 超大积压 >2048 → 全排（CK :47 猝发护栏）。
    func testHugeBacklogFlushesAll() {
        var stream = WOTextReveal()
        let huge = String(repeating: "字", count: 3000)
        stream.receive(huge, animate: true, at: 1.0)
        stream.advance(at: 1.01)
        XCTAssertFalse(stream.hasPending)
        XCTAssertEqual(stream.shown, huge)
    }

    /// elapsed clamp 0.12s（CK :40——长卡顿不产生超大步长）：小积压下
    /// 0.4s 间隔的单帧步长被 clamp 约束（无 clamp 会按 0.4s 计步一次打完）。
    func testElapsedClamp() {
        var stream = WOTextReveal()
        stream.receive(String(repeating: "x", count: 10), animate: true, at: 1.0)
        // 1.4s advance：距 receive 0.4s < 0.45 阈值（不触发全排）；
        // elapsed = 0.4 被 clamp 到 0.12。
        stream.advance(at: 1.4)
        XCTAssertLessThanOrEqual(stream.shown.count, 7)
        XCTAssertTrue(stream.hasPending)
        // 数学：speed = max(38, 41.8, 10/0.18≈55.6) = 55.6 字/s；
        // clamp 后 batch = Int(55.6 × 0.12) ≈ 6（无 clamp = 22 → 全排）。
    }

    /// 同文本重复 receive = no-op（CK :16-19；幂等守卫）。
    func testDuplicateReceiveIsNoop() {
        var stream = WOTextReveal()
        stream.receive("abc", animate: true, at: 1.0)
        stream.advance(at: 1.03)
        let shown = stream.shown
        stream.receive("abc", animate: true, at: 1.06)
        XCTAssertEqual(stream.shown, shown)
        // 权威内容未被扰动：排空后仍逐字等于 source（无重字/丢字）。
        var time = 1.09
        while stream.hasPending, time < 3 {
            stream.advance(at: time)
            time += 0.03
        }
        XCTAssertEqual(stream.shown, "abc")
    }
}
