//
//  ResourceGuardStatusTests.swift
//  WanWoTests
//
//  【M5-A 批 G2 测试 · 快照→展示行映射（纯函数面）】
//    - zone 三值映射（IshKernel.h 注释 0 GREEN / 1 YELLOW / 2 RED）+ 越界不崩
//    - 四行展示项格式化（运行态/激活态/stall 计数/喂送遥测）
//    - 未激活/未喂送兜底文案
//  UI 主体（Section 渲染、1s 定时器刷新、真机压测观测）真机验收——与
//  J2/J3/J4 真机面同纪律。
//

import XCTest
@testable import WanWo

final class ResourceGuardStatusTests: XCTestCase {

    private func makeSnapshot(zone: Int32 = 0,
                              governorRunning: Bool = false,
                              footprintActive: Bool = false,
                              stalls: UInt64 = 0,
                              feedTimerRunning: Bool = true,
                              feedCount: Int = 0,
                              lastFeed: Date? = nil) -> IshResourceGovernorSnapshot {
        IshResourceGovernorSnapshot(governorZone: zone,
                                    isGovernorRunning: governorRunning,
                                    isFootprintModeActive: footprintActive,
                                    forkGuardStallCount: stalls,
                                    isFeedTimerRunning: feedTimerRunning,
                                    feedCount: feedCount,
                                    lastFeedDate: lastFeed)
    }

    func testZoneNameMapping() {
        // IshKernel.h governor zone 注释逐值。
        XCTAssertEqual(ResourceGuardStatus.zoneName(0), "GREEN")
        XCTAssertEqual(ResourceGuardStatus.zoneName(1), "YELLOW")
        XCTAssertEqual(ResourceGuardStatus.zoneName(2), "RED")
        // 越界不崩（诊断页不抛纪律——UNKNOWN(N) 直显）。
        XCTAssertEqual(ResourceGuardStatus.zoneName(7), "UNKNOWN(7)")
        XCTAssertEqual(ResourceGuardStatus.zoneName(-1), "UNKNOWN(-1)")
    }

    func testLinesShapeAndFormatting() {
        let snapshot = makeSnapshot(zone: 2, governorRunning: true,
                                    footprintActive: true, stalls: 3,
                                    feedTimerRunning: true, feedCount: 120,
                                    lastFeed: Date(timeIntervalSince1970: 0))
        let lines = ResourceGuardStatus.lines(for: snapshot)
        // 派单展示项恰四条，label 逐条对齐。
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].label, "CPU Governor")
        XCTAssertEqual(lines[1].label, "内存准入")
        XCTAssertEqual(lines[2].label, "Fork Guard")
        XCTAssertEqual(lines[3].label, "喂送")
        // 字段格式化逐条。
        XCTAssertEqual(lines[0].value, "RED · 运行中")
        XCTAssertEqual(lines[1].value, "已激活")
        XCTAssertEqual(lines[2].value, "累计 3 次")
        XCTAssertTrue(lines[3].value.contains("120 次"), lines[3].value)
        XCTAssertTrue(lines[3].value.contains("定时器 运行中"), lines[3].value)
        // 喂送时刻存在时不出现"尚未喂送"兜底。
        XCTAssertFalse(lines[3].value.contains("尚未喂送"), lines[3].value)
    }

    func testLinesInactiveAndUnfed() {
        // 全零快照（启动初态）：GREEN/未运行、未激活、0 stalls、尚未喂送。
        let lines = ResourceGuardStatus.lines(for: makeSnapshot())
        XCTAssertEqual(lines[0].value, "GREEN · 未运行")
        XCTAssertEqual(lines[1].value, "未激活")
        XCTAssertEqual(lines[2].value, "累计 0 次")
        XCTAssertTrue(lines[3].value.contains("尚未喂送"), lines[3].value)
        XCTAssertTrue(lines[3].value.contains("定时器 运行中"), lines[3].value)
    }

    func testLinesFeedTimerStopped() {
        // 定时器停止=内核 stale 规则下的失效关闸方向（mm.h:110-111）——直显不美化。
        let lines = ResourceGuardStatus.lines(for: makeSnapshot(feedTimerRunning: false,
                                                                feedCount: 8))
        XCTAssertTrue(lines[3].value.contains("定时器 已停"), lines[3].value)
        XCTAssertTrue(lines[3].value.contains("8 次"), lines[3].value)
    }
}
