//
//  ResourceGuardSection.swift
//  WanWo
//
//  【M5-A 批 G2 · 资源护栏观测面（诊断页状态段）】
//  背景：M5.1 验收条文（10-design）"并发 50 命令压测不失控、无线程池耗尽"
//  ——压测在真机做（iSH 需内核 boot，CI 无此面），观测载体=诊断页状态段。
//  数据源 = AppEnvironment.resourceGovernor.snapshot（G1 门面七字段快照，
//  IshResourceGovernor.swift:55-70/:193-206——governor zone/运行态/
//  footprint mode/fork guard stalls/喂送遥测；快照注释原文即
//  "G2 真机压测的观测载体"）。
//  形态：EventStreamView 诊断页首段（同款 Section List 段式；零交互纯只读）。
//  刷新：onAppear 拉取 + 1s Timer 定时器驱动（自裁定——压测观测实时性；
//  快照为 NSLock 纯读 + 内核只读属性，主线程 1s 拉取廉价）。
//  时间格式沿诊断页惯例（EventStreamView loadedLabel 的
//  .dateTime.hour().minute().second() 同款）。
//

import SwiftUI

/// 快照 → 展示行映射（G2 测试锚点：zone 三值映射 + 字段格式化；纯函数）。
enum ResourceGuardStatus {

    /// 一行展示项（label=条目名，value=状态值）。
    struct Line: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// governor zone → 用户可读名（ISHKernel.h Scheduler category 注释：
    /// 0 GREEN / 1 YELLOW / 2 RED；非后台时段恒 0）。越界值不崩——显示
    /// UNKNOWN(N)（诊断页不抛纪律，EventStreamRowBuilder 同款）。
    static func zoneName(_ zone: Int32) -> String {
        switch zone {
        case 0: return "GREEN"
        case 1: return "YELLOW"
        case 2: return "RED"
        default: return "UNKNOWN(\(zone))"
        }
    }

    /// 快照 → 四行展示项（派单展示项逐条；零交互纯只读）。
    static func lines(for snapshot: IshResourceGovernorSnapshot) -> [Line] {
        // ① CPU Governor：zone 名 + 运行态（后台 governor 定时器是否在跑）。
        let governorValue = "\(zoneName(snapshot.governorZone)) · "
            + (snapshot.isGovernorRunning ? "运行中" : "未运行")
        // ② 内存准入：footprint mode 激活态（mm.h:127-128——首次喂送后为真）。
        let footprintValue = snapshot.isFootprintModeActive ? "已激活" : "未激活"
        // ③ Fork Guard：累计 stalls（自 boot 单调递增——压测失控的第一指标）。
        let forkValue = "累计 \(snapshot.forkGuardStallCount) 次"
        // ④ 喂送：次数 + 最近时刻 + 定时器态（nil = 尚未喂过）。
        let feedTime: String
        if let last = snapshot.lastFeedDate {
            feedTime = last.formatted(.dateTime.hour().minute().second())
        } else {
            feedTime = "尚未喂送"
        }
        let feedValue = "\(snapshot.feedCount) 次 · 最近 \(feedTime) · 定时器 "
            + (snapshot.isFeedTimerRunning ? "运行中" : "已停")
        // 真机批 D：最近后台时段摘要（后台限速曾是黑盒——回前台只见当下态）。
        let bgValue: String
        if let bg = snapshot.lastBackgroundSummary {
            let fmt = { (d: Date) in d.formatted(.dateTime.hour().minute().second()) }
            bgValue = "\(fmt(bg.startedAt))–\(fmt(bg.endedAt)) · 峰值 \(zoneName(bg.peakZone)) · stalls +\(bg.forkGuardStalls)"
        } else {
            bgValue = "无记录"
        }
        return [
            Line(label: "CPU Governor", value: governorValue),
            Line(label: "内存准入", value: footprintValue),
            Line(label: "Fork Guard", value: forkValue),
            Line(label: "喂送", value: feedValue),
            Line(label: "最近后台", value: bgValue),
        ]
    }
}

/// 诊断页「资源护栏」段（EventStreamView List 首段；同款 Section 段式，
/// 零交互纯只读——真机压测的观测载体）。
struct ResourceGuardSection: View {
    let snapshot: IshResourceGovernorSnapshot?

    var body: some View {
        Section("资源护栏") {
            if let snapshot {
                ForEach(ResourceGuardStatus.lines(for: snapshot)) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label)
                            .font(.footnote)
                        Spacer(minLength: 12)
                        Text(line.value)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } else {
                Text("尚未拉取快照")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
