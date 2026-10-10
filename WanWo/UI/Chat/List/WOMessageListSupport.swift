//
//  WOMessageListSupport.swift
//  WanWo
//
//  【重做批 1 · 数据缝】UIKit 消息列表引擎——纯函数面（单测直呼）。
//  来源：tag backup-ci50-20261006 同名文件原样恢复（2026-10-06 逐行重验，
//  与 lody ChatScroll/prepareHistorySlice 对拍一致，见 analysis/
//  chat-rework-plan-20261006.md 第三节验证记录）。本批无消费方 = R0 行为
//  零变化；消费方随批 3/4 引擎内核接入。
//  参照（机制，非代码直搬）：lody LodyChatView.applyRows 快照组装、
//  prepareHistory/prepareHistorySlice（50 窗口 + 4ms 时间预算）、
//  ChatRowPadding 行距；万我表达。
//
//  数据流：ChatViewModel.displayNodes（计算属性，bubbles+live 槽每次求值
//  重算，见 ChatViewModel.swift:1364）→ flatten（节点流拍平 + 元条目合成）→ Diffable snapshot
//  （item identity = 节点 id，既有代际化 id 体系 live-r-N/live-t-N/a(seq)-b(i)
//  直接复用）→ reconfigureItems 更新（非 reload）。
//

import CoreGraphics
import Foundation

// MARK: - 列表条目模型（件 1）

/// 列表条目种类：气泡（含 process 组内逐个平铺——与 LazyVStack ForEach
/// 语义一致，组内子节点同为直系子项）+ 合成元条目（历史头/装配中/流光/
/// 失败横幅——原 messageList 内非 displayNodes 的四个附属视图）。
enum WOMListNodeKind: Equatable {
    case bubble(ConversationProjector.Bubble)
    /// 列表头「加载更早」（lody ChatHistoryHeader 语义；loading=切片量高中）。
    case history(loading: Bool)
    /// phase == .loading 的装配 spinner（原 :851-858）。
    case loading
    /// phase == .streaming 的流光换字状态行（原 :875-882）。
    case beam
    /// phase == .failed 的错误横幅（原 :883-891）。
    case failed(String)
}

struct WOMListNode: Identifiable, Equatable {
    let id: String
    let kind: WOMListNodeKind
}

enum WOMessageListSupport {

    // MARK: 元条目 id 常量（与气泡 id 体系（seq/live 代际）不可能撞名）

    static let historyItemID = "wo-history-header"
    static let loadingItemID = "wo-loading"
    static let beamItemID = "wo-beam"
    static let failedItemID = "wo-failed"

    // MARK: 件 1 拍平（节点流 → 线性条目；纯函数）

    /// 拍平 + 元条目合成。顺序对齐原 messageList：历史头 → loading →
    /// 节点流 → beam → failed。id 直接复用节点既有代际化 id（diffable
    /// 动画质量由此保证——ConversationProjector id 规则不动）。
    static func flatten(nodes: [ConversationProjector.DisplayNode],
                        phase: ChatViewModel.Phase,
                        hasEarlierHistory: Bool,
                        historyLoading: Bool) -> [WOMListNode] {
        var items: [WOMListNode] = []
        if hasEarlierHistory || historyLoading {
            items.append(WOMListNode(id: historyItemID, kind: .history(loading: historyLoading)))
        }
        if phase == .loading {
            items.append(WOMListNode(id: loadingItemID, kind: .loading))
        }
        for node in nodes {
            switch node {
            case .plain(let bubble):
                items.append(WOMListNode(id: bubble.id, kind: .bubble(bubble)))
            case .process(let group):
                for bubble in group.bubbles {
                    items.append(WOMListNode(id: bubble.id, kind: .bubble(bubble)))
                }
            }
        }
        if phase == .streaming {
            items.append(WOMListNode(id: beamItemID, kind: .beam))
        }
        if case .failed(let message) = phase {
            items.append(WOMListNode(id: failedItemID, kind: .failed(message)))
        }
        return items
    }

    // MARK: 件 3 历史窗口（纯边界数学）

    /// 窗口边界：初载窗口 = 尾部 N 条（lody `max(0, count - 50)` 同参）；
    /// 扩窗 = 起点前移一页；起点为 0 即无更早历史。
    /// total = displayNodes 总节点数（process 组计 1——与 flatten 前口径
    /// 一致；窗口在 displayNodes 层切，flatten 后条目数更多但边界只按
    /// 节点数推进，同一 process 组永不劈裂）。
    static func historyWindowBounds(total: Int, start: Int,
                                    pageSize: Int) -> (initialStart: Int,
                                                       expandedStart: Int,
                                                       hasEarlier: Bool) {
        let initialStart = max(0, total - pageSize)
        let hasEarlier = start > 0
        let expandedStart = max(0, start - pageSize)
        return (initialStart, expandedStart, hasEarlier)
    }

    /// 窗口切片（displayNodes 层；防御 clamp——压缩/裁剪后 start 越界时
    /// 贴回合法区间，不越界读）。
    static func windowedSlice(nodes: [ConversationProjector.DisplayNode],
                              start: Int) -> (slice: [ConversationProjector.DisplayNode],
                                              clampedStart: Int) {
        let clamped = min(max(0, start), nodes.count)
        return (Array(nodes[clamped...]), clamped)
    }

    // MARK: 件 3 量高时间预算（lody prepareHistorySlice 4ms 预算的调度形态）

    /// 一轮切片的确定性调度：给定每条均匀成本与截止时钟，返回本轮处理条数
    /// 与下一游标。纯函数（时钟/成本注入）——真机侧由调用方传
    /// CACurrentMediaTime 差值与实测均摊成本；单测用合成时钟断言预算边界。
    /// lody 语义 1:1：单条超预算也至少处理一条（ponytail 注释同款——单条
    /// 巨行不允许饿死整轮）。
    static func measureSlice(currentIndex: Int, total: Int,
                             elapsedMs: Double, budgetMs: Double,
                             costPerItemMs: Double) -> (processed: Int, nextIndex: Int) {
        var index = currentIndex
        var processed = 0
        // 至少一条（防饿死），其后按预算推进。
        repeat {
            index += 1
            processed += 1
        } while index < total
            && elapsedMs + Double(processed) * costPerItemMs < budgetMs
        return (processed, index)
    }

    // MARK: 件 2 行高插值（批 2 逐帧引擎的纯函数预置；批 1 高度直给）

    /// 时间收敛插值（lody ChatScroll.advance **1:1 对齐**——ChatStream.swift
    /// :85-91：`current + (target - current) * (1 - exp(-elapsed / response))`；
    /// ①亚像素步直接给 target（UIScrollView 把 offset 取整到像素网格，小于
    /// 一像素的步长会四舍五入回原地、display link 永续空转——lody :87-89 注释
    /// 同语义）；②半像素内贴 target（收敛尾巴终止）。批 1 行高精确直给；
    /// 本函数批 2 由 display link 贴底（response 0.10）与行高插值（0.06，
    /// 若启用）共用。
    static func advanceHeight(current: CGFloat, toward target: CGFloat,
                              elapsed: Double, response: Double,
                              minimumStep: Double = 0) -> CGFloat {
        let next = current + (target - current) * (1 - Foundation.exp(-max(0, elapsed) / response))
        if elapsed > 0 && abs(Double(next - current)) < minimumStep { return target }
        return abs(target - next) <= 0.5 ? target : next
    }

    // MARK: 批 2 件 1/2 贴底几何（lody ChatScroll.bottom/:93-96 1:1）

    /// 贴底落点 = 内容高 - 视口高 + 底部 adjustedInset（不越过顶部 rubber
    /// band 边界）。adjustedContentInset 口径（contentInset + safeArea）。
    static func bottomOffset(contentHeight: Double, viewportHeight: Double,
                             topInset: Double, bottomInset: Double) -> Double {
        max(-topInset, contentHeight - viewportHeight + bottomInset)
    }

    /// 【重做批6 · 同出动画】参考件缓动曲线采样：cubic-bezier(.22,1,.36,1)
    /// （《同出丝滑效果》.new-msg height 曲线，与《设置模型配置原型》同族）。
    /// CSS 缓动同款语义：给定进度 x∈[0,1]，二分求 t 使 BezierX(t)=x，返回
    /// BezierY(t)。控制点 P1=(0.22,1) P2=(0.36,1)（y 恒 1→强 ease-out 形）。
    /// 纯函数（单测直呼）；x 越界原样返回（0/1 端点无插值）。
    static func coGrowEase(_ x: Double) -> Double {
        guard x > 0, x < 1 else { return x }
        var lo = 0.0
        var hi = 1.0
        var t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            let bx = 3 * (1 - t) * (1 - t) * t * 0.22
                + 3 * (1 - t) * t * t * 0.36
                + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        // y 控制点均 1.0：by(t) = 3(1-t)²t + 3(1-t)t² + t³
        return 3 * (1 - t) * (1 - t) * t + 3 * (1 - t) * t * t + t * t * t
    }

    /// 【披露缓动 2026-10-09】展开/收起专用：cubic-bezier(0.4,0,0.2,1)——
    /// 四份动画参考件（analysis/anim-ref-20261009/1~4.html）与 Motion.swift
    /// 全库唯一曲线同款：快起步缓落地、落地即停（无回弹无弹簧）。
    /// 取代披露路径沿用 coGrowEase 强 ease-out 的做法——该曲线前 10% 时间
    /// 走约 40% 进度，是真机"展开一帧瞬跳"的几何根因（同曲线同时长下，
    /// 格子跑到 40% 时格内内容（Motion.bezier 同为 0.4,0,0.2,1）仅 0.6%，
    /// 中段大空白=用户截图 IMG_2625 实证）。结构与 coGrowEase 同（二分求
    /// t 使 BezierX(t)=x，返回 BezierY(t)）；控制点 P1=(0.4,0) P2=(0.2,1)。
    /// 纯函数（单测直呼）；x 越界原样返回（0/1 端点无插值）。
    static func disclosureEase(_ x: Double) -> Double {
        guard x > 0, x < 1 else { return x }
        var lo = 0.0
        var hi = 1.0
        var t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            let bx = 3 * (1 - t) * (1 - t) * t * 0.4
                + 3 * (1 - t) * t * t * 0.2
                + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        // y(t) = 3(1-t)²t·P1y + 3(1-t)t²·P2y + t³；P1y=0 → 首项恒 0。
        return 3 * (1 - t) * t * t + t * t * t
    }

    /// 回底按钮出现距离（lody ChatScroll.resumeDistance :81 = 80——简报
    /// 「240 或 lody 等价值」，实码为准取 80）。
    static let resumeDistance: Double = 80

    /// 回底恢复判定（lody resumeTrackingAtBottom :244 同参：距底 ≤1pt）。
    static func shouldResumeFollowing(bottomOffset: Double, offsetY: Double) -> Bool {
        bottomOffset - offsetY <= 1
    }

    // MARK: 【rail T02】帧混合纯函数（侧栏开合确定性宽度动画——单测直呼）

    /// 帧线性混合（rail 唯一算术来源，WOMessageListLayout 与单测共用；
    /// 架构文档 §3.8/§9 横切纪律：rail 几何算术禁散落内联）。p 端点原样
    /// 返回端点帧（p≤0 → a；p≥1 → b——端点恒等由单测钉死）。
    static func blendFrame(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        if p <= 0 { return a }
        if p >= 1 { return b }
        let t = CGFloat(p)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t)
    }

    /// 内容高混合（两端 contentHeight 线性；端点恒等同 blendFrame）。
    static func blendHeight(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat {
        if p <= 0 { return a }
        if p >= 1 { return b }
        return a + (b - a) * CGFloat(p)
    }

    // MARK: 批 2 件 3 让位增量（与静态 sectionInset 分立的动态部分）

    /// composer 座位组超出旧链基准的部分 → contentInset.bottom 动态增量
    /// （lody updateBottomInset 语义：让位与滚动位置解耦、变更才写）。
    /// 基准 137 = 旧链让位预算（digest 注释「dock 悬浮区实测 137pt」）——
    /// 常态座位高 ≈ 基准时增量为 0（视觉零变化），审批卡/todo 卡/GoalBar
    /// 把座位顶高时增量 > 0（治 C：新内容不再出现在变高的 dock 下）。
    /// 真机标定项：基准值。
    static func bottomInsetIncrement(composerChromeHeight: CGFloat,
                                     baseline: CGFloat) -> CGFloat {
        max(0, composerChromeHeight - baseline)
    }

    /// composer 座位组基准高（旧链让位预算；WOChatView 通道传值）。
    static let dockBaselineHeight: CGFloat = 137

    // MARK: 批 2 件 4 离屏冻结判定（lody updateDeferredStreams 迟滞带纯函数形）

    /// 迟滞带半径：未冻结 80 / 已冻结 160（lody :200——回带判定用更宽带，
    /// 防边界抖动 churn）。
    static func freezeMargin(alreadyFrozen: Bool) -> CGFloat {
        alreadyFrozen ? 160 : 80
    }

    /// 行 frame 是否滚出「视口 ± margin」迟滞带（lody :201-207：viewport
    /// insetBy(dy: -margin) 后 frame.intersects 判定；万我用 layout frame
    /// 直查，无需 lody 的 tailFrame 位移补偿——万我无行高动画）。
    static func isOffscreen(frame: CGRect, viewport: CGRect,
                            margin: CGFloat) -> Bool {
        !frame.intersects(viewport.insetBy(dx: 0, dy: -margin))
    }

    // MARK: 件 5 探针汇总（纯函数）

    /// apply 耗时样本 → 汇总行（max/mean/p95 + 快照规模；os_log 落行用）。
    static func probeSummary(durationsMs: [Double], itemCounts: [Int]) -> String {
        guard !durationsMs.isEmpty else { return "apply=none" }
        let sorted = durationsMs.sorted()
        let mean = durationsMs.reduce(0, +) / Double(durationsMs.count)
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        let maxItems = itemCounts.max() ?? 0
        return String(format: "apply n=%d mean=%.2fms p95=%.2fms max=%.2fms maxItems=%d",
                      sorted.count, mean, sorted[p95Index], sorted.max() ?? 0, maxItems)
    }
}
