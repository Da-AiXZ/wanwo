//
//  WOChatProbe.swift
//  WanWo
//
//  【批 1 · 件 5】性能探针第一批（lody ChatPerformanceProbe/ChatScrollProbe
//  方法的万我 XCTest 云端形态——纯函数级 + DEBUG 内存环形缓冲，真机可取；
//  lody 的 simctl 离线程序形态不适用，GitHub Actions XCTest 跑纯函数）。
//  本批：①applyRows 耗时/快照规模环形缓冲 + os_log 落行 ②滚动漂移断言
//  留批 2（需要真机滚动）。汇总数学在 WOMessageListSupport.probeSummary
//  （纯函数，单测直呼）。
//

import Foundation
import UIKit

@MainActor
final class WOChatProbe {
    static let shared = WOChatProbe()

    struct Sample: Equatable {
        let at: CFTimeInterval
        let durationMs: Double
        let itemCount: Int
        let reconfigureCount: Int
        let poolCount: Int
    }

    /// 环形缓冲（1024 条封顶——覆盖一次长流式回合的 apply 序列）。
    private static let capacity = 1024
    private(set) var samples: [Sample] = []
    private let logger = AppLogger(category: "ChatListProbe")

    private init() {}

    func record(durationMs: Double, itemCount: Int, reconfigureCount: Int,
                poolCount: Int) {
        let sample = Sample(at: CACurrentMediaTime(), durationMs: durationMs,
                            itemCount: itemCount, reconfigureCount: reconfigureCount,
                            poolCount: poolCount)
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        // 慢 apply 落 os_log（>8ms 才打扰——33Hz 帧预算 30ms 的一半）。
        if durationMs > 8 {
            logger.info(String(format: "apply slow %.2fms items=%d reconf=%d",
                               durationMs, itemCount, reconfigureCount))
        }
    }

    /// 环形缓冲汇总落行（手动触发；DEBUG 面向真机取证）。
    func flushSummary() -> String {
        let line = WOMessageListSupport.probeSummary(
            durationsMs: samples.map(\.durationMs),
            itemCounts: samples.map(\.itemCount))
        logger.info(line)
        return line
    }

    func reset() { samples.removeAll() }
}
