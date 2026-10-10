//
//  WORailMathTests.swift
//  WanWoTests
//
//  【rail T02】确定性宽度动画数学单测（CI 跑；本地无 Xcode——静态纪律 +
//  本文件构成 rail 算术的回归兜底）：
//    · blendFrame/blendHeight 端点恒等（p=0 恒等 from / p=1 恒等 to）+
//      中点线性（rail 唯一算术来源，layout 与单测同源——架构文档 §9）；
//    · rail 布局状态机 beginRail/updateRailProgress/endRail + prepare 早退
//      （rail 期零 delegate 询问 = 零量高零 onLiveWidthChange，§3.7）；
//    · WORailCurve.progress 端点/单调性/与 disclosureEase 同曲线一致性 +
//      曲线/时长单源常量钉死。
//

import XCTest
import CoreGraphics
@testable import WanWo

final class WORailMathTests: XCTestCase {

    // MARK: - blendFrame（rail 唯一算术来源）

    func testBlendFrameEndpointsIdentity() {
        let a = CGRect(x: 16, y: 75, width: 343, height: 120)
        let b = CGRect(x: 16, y: 75, width: 511, height: 200)
        XCTAssertEqual(WOMessageListSupport.blendFrame(a, b, 0), a)
        XCTAssertEqual(WOMessageListSupport.blendFrame(a, b, 1), b)
        // 越界原样返回端点帧（p≤0 → a；p≥1 → b）。
        XCTAssertEqual(WOMessageListSupport.blendFrame(a, b, -0.5), a)
        XCTAssertEqual(WOMessageListSupport.blendFrame(a, b, 1.5), b)
    }

    func testBlendFrameMidpointLinear() {
        let a = CGRect(x: 10, y: 0, width: 300, height: 80)
        let b = CGRect(x: 10, y: 40, width: 500, height: 160)
        let mid = WOMessageListSupport.blendFrame(a, b, 0.5)
        XCTAssertEqual(mid.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(mid.minY, 20, accuracy: 0.0001)
        XCTAssertEqual(mid.width, 400, accuracy: 0.0001)
        XCTAssertEqual(mid.height, 120, accuracy: 0.0001)
        // 四分之一点线性（x/y 全通道）。
        let quarter = WOMessageListSupport.blendFrame(a, b, 0.25)
        XCTAssertEqual(quarter.minY, 10, accuracy: 0.0001)
        XCTAssertEqual(quarter.width, 350, accuracy: 0.0001)
    }

    func testBlendHeightEndpointsAndMidpoint() {
        XCTAssertEqual(WOMessageListSupport.blendHeight(100, 300, 0), 100)
        XCTAssertEqual(WOMessageListSupport.blendHeight(100, 300, 1), 300)
        XCTAssertEqual(WOMessageListSupport.blendHeight(100, 300, 0.5), 200, accuracy: 0.0001)
        XCTAssertEqual(WOMessageListSupport.blendHeight(100, 300, 0.25), 150, accuracy: 0.0001)
    }

    // MARK: - rail 布局状态机 + prepare 早退

    /// delegate 询问计数 mock（rail 期 prepare 必须零触碰）。
    private final class LayoutDelegateMock: WOMessageListLayoutDelegate {
        var heightForItemCount = 0
        func listLayout(_ layout: WOMessageListLayout,
                        heightForItemAt indexPath: IndexPath,
                        width: CGFloat) -> CGFloat {
            heightForItemCount += 1
            return 44
        }
    }

    func testRailPrepareDoesNotTouchDelegate() {
        let layout = WOMessageListLayout()
        let mock = LayoutDelegateMock()
        layout.delegate = mock
        // 非 rail 期（本测试无 collectionView）prepare 同样零 delegate 询问
        //（guard 早退；此处只钉死计数不被意外污染）。
        layout.prepare()
        XCTAssertEqual(mock.heightForItemCount, 0)
        // rail 启动 → prepare 早退：零量高、零 onLiveWidthChange。
        let from = [CGRect](repeating: CGRect(x: 16, y: 75, width: 343, height: 44),
                            count: 3)
        let to = [CGRect](repeating: CGRect(x: 16, y: 75, width: 511, height: 44),
                          count: 3)
        layout.beginRail(fromFrames: from, toFrames: to)
        XCTAssertTrue(layout.isRailActive)
        layout.updateRailProgress(0.5)
        layout.prepare() // rail 期早退路径
        XCTAssertEqual(mock.heightForItemCount, 0)
        layout.endRail()
        XCTAssertFalse(layout.isRailActive)
        // endRail 定格新端帧（一次切真布局零跳变）。
        XCTAssertEqual(layout.snapshotFrames(), to)
    }

    func testRailProgressBlending() {
        let layout = WOMessageListLayout()
        let from = [CGRect(x: 16, y: 75, width: 300, height: 44)]
        let to = [CGRect(x: 16, y: 75, width: 500, height: 88)]
        layout.beginRail(fromFrames: from, toFrames: to)
        layout.updateRailProgress(0)
        XCTAssertEqual(layout.snapshotFrames()[0], from[0])
        layout.updateRailProgress(1)
        XCTAssertEqual(layout.snapshotFrames()[0], to[0])
        layout.updateRailProgress(0.5)
        let mid = layout.snapshotFrames()[0]
        XCTAssertEqual(mid.width, 400, accuracy: 0.0001)
        XCTAssertEqual(mid.height, 66, accuracy: 0.0001)
        // 缺失行语义（R9-7）：from 缺行 → to 直用。
        layout.endRail()
        layout.beginRail(fromFrames: [], toFrames: to)
        layout.updateRailProgress(0)
        XCTAssertEqual(layout.snapshotFrames(), to)
        layout.updateRailProgress(0.7)
        XCTAssertEqual(layout.snapshotFrames(), to)
    }

    func testRailProgressMonotonicInLayoutWidth() {
        let layout = WOMessageListLayout()
        let from = [CGRect](repeating: CGRect(x: 16, y: 75, width: 300, height: 44),
                            count: 2)
        let to = [CGRect](repeating: CGRect(x: 16, y: 75, width: 500, height: 44),
                          count: 2)
        layout.beginRail(fromFrames: from, toFrames: to)
        var previousWidth: CGFloat = -1
        for step in 0...10 {
            layout.updateRailProgress(CGFloat(step) / 10)
            for frame in layout.snapshotFrames() {
                XCTAssertGreaterThanOrEqual(frame.width, previousWidth)
                previousWidth = frame.width
            }
        }
    }

    // MARK: - WORailCurve（曲线单源）

    func testRailCurveEndpoints() {
        XCTAssertEqual(WORailCurve.progress(0), 0)
        XCTAssertEqual(WORailCurve.progress(1), 1)
        // 越界原样返回（0/1 端点无插值）。
        XCTAssertEqual(WORailCurve.progress(-0.2), -0.2)
        XCTAssertEqual(WORailCurve.progress(1.2), 1.2)
    }

    func testRailCurveMonotonic() {
        var previous = -1.0
        for step in 0...20 {
            let x = Double(step) / 20
            let y = WORailCurve.progress(x)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-9,
                                        "eased 进度必须单调不减：x=\(x) y=\(y)")
            previous = y
        }
    }

    /// 单源一致性：与披露缓动（同控制点 0.4,0,0.2,1 同算法的历史件）逐点一致。
    func testRailCurveMatchesDisclosureEase() {
        for step in 1..<20 {
            let x = Double(step) / 20
            XCTAssertEqual(WORailCurve.progress(x),
                           WOMessageListSupport.disclosureEase(x),
                           accuracy: 1e-12,
                           "同曲线两实现必须逐点一致：x=\(x)")
        }
    }

    func testRailCurveSingleSourceConstants() {
        // controlPoints 即全库唯一曲线（WOMotion.bezier 消费本常量，零第二份字面量）。
        XCTAssertEqual(WORailCurve.controlPoints.0, 0.4, accuracy: 1e-12)
        XCTAssertEqual(WORailCurve.controlPoints.1, 0, accuracy: 1e-12)
        XCTAssertEqual(WORailCurve.controlPoints.2, 0.2, accuracy: 1e-12)
        XCTAssertEqual(WORailCurve.controlPoints.3, 1, accuracy: 1e-12)
        // 时长单源（SwiftUI 列宽动画与 core rail 时钟共同读）。
        XCTAssertEqual(WOMotion.sidebarRailDuration, 0.42, accuracy: 1e-12)
    }
}
