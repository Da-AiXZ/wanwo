//
//  SeedImagePreviewDismissTests.swift
//  WanWoTests
//
//  【M7 种子① 件 D 2026-09-28 · 单测面】全屏预览下拉 dismiss 纯函数缝
//  （WORootFrame.swift ImagePreviewContentView 静态算式）：
//    - 派单简报："非纯函数 UI 件不强求单测；ImagePreviewContent 若可注入
//      纯逻辑（dismissThreshold 判定）可抽测"——本面即该抽测。
//    - 对拍锚点（语义源 OpenMinis ImagePreview.swift 逐行移植的算式）：
//      · shouldDismiss = handleDismissPan :313-317 内联
//        `pulled >= dismissThreshold`；
//      · backdropDimProgress = applyDismissTransform :337-338 内联
//        `min(max(y, 0), threshold) / threshold`（负拉起 clamp 0、
//        超阈值 clamp 1——backdrop alpha 最低 1-0.6=0.4 不全透）。
//    - 不可单测面（真机验收）：UIScrollView 手势仲裁全套（捏合/双击/平移
//      钳制/contentInset 居中/竖直主导判定）、contextMenu 与手势共存、
//      PHPhotoLibrary 存相册授权链、UIActivityViewController 分享链。
//

import XCTest
@testable import WanWo

final class SeedImagePreviewDismissTests: XCTestCase {

    // MARK: shouldDismiss（原件 :313-317 算式对拍）

    func testShouldDismissAtThresholdBoundary() {
        // 【QA P1-2/P2-6 修正 2026-09-28】阈值直写字面量（消除测试侧
        // ImagePreviewContentDefaults 中转——缺省值锚定已由
        // testShouldDismissDefaultThresholdIs80pt 的真实属性断言承担，
        // 本测只验算式边界，不再隔一层常量）。
        let threshold: CGFloat = 80

        // 跟手位移恰达阈值 → 触发 dismiss（>= 判定，非 >）
        XCTAssertTrue(ImagePreviewContentView.shouldDismiss(
            pulledY: threshold, threshold: threshold))
        // 差 1pt 短于阈值 → 弹回（不 dismiss）
        XCTAssertFalse(ImagePreviewContentView.shouldDismiss(
            pulledY: threshold - 1, threshold: threshold))
        // 超过阈值 → dismiss
        XCTAssertTrue(ImagePreviewContentView.shouldDismiss(
            pulledY: threshold + 1, threshold: threshold))
    }

    func testShouldDismissDefaultThresholdIs80pt() {
        // 【QA P1-2 修正 2026-09-28】真实缺省值锚定：直取
        // ImagePreviewContentView 缺省构造的 dismissThreshold 属性断言
        // （原件 :131 `var dismissThreshold: CGFloat = 80`）——生产侧缺省
        // 被改动时本测试必红（此前两断言显式传 80，名不符实）。
        XCTAssertEqual(ImagePreviewContentView(image: UIImage()).dismissThreshold, 80)
        // 缺省阈值下的边界行为（>= 判定，非 >）
        XCTAssertTrue(ImagePreviewContentView.shouldDismiss(pulledY: 80, threshold: 80))
        XCTAssertFalse(ImagePreviewContentView.shouldDismiss(pulledY: 79.9, threshold: 80))
    }

    // MARK: backdropDimProgress（原件 :337-338 算式对拍）

    func testBackdropDimProgressClampsAndNormalizes() {
        let threshold: CGFloat = 80

        // 负向（手指上推）clamp 到 0 → backdrop 不变暗（alpha 保持 1）
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: -30, threshold: threshold), 0, accuracy: 0.0001)
        // 起点为 0
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: 0, threshold: threshold), 0, accuracy: 0.0001)
        // 半程 → 0.5（alpha = 1 - 0.5*0.6 = 0.7，原件 :338 渐隐斜率）
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: 40, threshold: threshold), 0.5, accuracy: 0.0001)
        // 恰达阈值 → 1（alpha = 0.4，不全透）
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: 80, threshold: threshold), 1, accuracy: 0.0001)
        // 超阈值继续拉 → clamp 1（不产生 alpha<0.4 的过暗）
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: 200, threshold: threshold), 1, accuracy: 0.0001)
    }

    func testBackdropDimProgressScalesWithThreshold() {
        // 阈值可注入（ImagePreviewContent.dismissThreshold 参数面）——
        // 同位移在不同阈值下进度随阈值缩放。
        XCTAssertEqual(ImagePreviewContentView.backdropDimProgress(
            pulledY: 40, threshold: 160), 0.25, accuracy: 0.0001)
    }
}
