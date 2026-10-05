//
//  WOHostSizingPool.swift
//  WanWo
//
//  【批 1 · 件 2】hosting 视图复用池 + 行高缓存（lody ChatMarkdownStore
//  池语义的万我泛化形态：池不按 markdown 一种内容，按"任意 SwiftUI 条目
//  视图"工作——气泡/思考/工具卡/元条目统一走同池）。
//
//  lody 铁律逐条落地：
//    · sizingLimit 24 的 LRU，**绝不逐出已挂载（superview != nil）的视图**
//      （ChatMarkdownStore :118-127 注释同语义）；
//    · height(id:) 只在内容/宽度变化时触碰量高（:129-136 同语义——flow
//      布局每次 invalidation 都会问尺寸，未变行绝不重测）；
//    · 宽度是缓存 key 的一部分（旋转/分栏自动失效）。
//  【批1-QA P2-2 修·偏差如实登记】本池是**离屏量高池**（heights + 量高用
//  host 视图），与列表显示面（WONodeCell 自持 UIHostingController）**分池**
//  ——lody「可见行用的就是量过它的那个视图」的共池铁律在批 1 简化为：
//  量高与显示共用同一**内容装配缝**（WONodeItemContent + .id(identity 锚)）
//  而非同一视图实例（规避同一 host view 双父的手术风险）。批 2 逐帧引擎
//  时做共池合体评估（team-lead 已在账）。
//  批 1 高度精确直给（与 LazyVStack 现状行为对齐）；current/target 插值
//  数学已在 WOMessageListSupport.advanceHeight 预置，批 2 displaylink 接管。
//

import SwiftUI
import UIKit

@MainActor
final class WOHostSizingPool: NSObject {

    /// 单池条目：承载任意 SwiftUI 内容的 hosting 控制器（内容以闭包重建，
    /// identity 由调用方包 .id 强制——见 core 条目内容装配）。
    private struct Entry {
        let host: UIHostingController<AnyView>
        /// 量高时记录的内容签名（调用方提供；内容变 → 重测）。
        var signature: String
    }

    /// 行高缓存值（宽度绑定；lody Height 结构同形）。
    struct HeightEntry: Equatable {
        let height: CGFloat
        let width: CGFloat
        let signature: String
    }

    private static let sizingLimit = 24

    /// id → 池条目（池即复用面：cell 显示与离屏量高共用同一实例）。
    private var entries: [String: Entry] = [:]
    /// LRU 近用序（lody recent 数组同构）。
    private var recent: [String] = []
    /// id → 量高（与 entries 分离——条目可被逐出而高度仍有效）。
    private var heights: [String: HeightEntry] = [:]
    /// 【CI修49】宽度变化 stale 顶替：宽度已变但旧高先顶的行（异步重测
    /// 队列去重锚）。
    private var pendingRemasure: Set<String> = []

    /// stale 顶替条目（core 异步切片重测的消费单元）。
    struct StaleEntry: Equatable {
        let id: String
        let width: CGFloat
    }
    /// 本轮问询中 stale 顶替的行（layout prepare 期间收集；core 经
    /// drainStaleSweep 取走并切片重测）。
    private(set) var staleSweep: [StaleEntry] = []

    /// 池规模（探针消费）。
    var poolCount: Int { entries.count }
    var heightCount: Int { heights.count }

    // MARK: 量高（主线程；未变行直读缓存）

    /// 量高：内容/宽度未变 → 缓存直读（零触碰池）；变化 → 池内视图重测。
    /// makeContent 闭包仅在需要（重）装配时调用——测量与显示同一视图实例。
    /// 【CI修49 宽度变化分支】：签名未变、宽度变（旋转/分栏/右栏开合）→
    /// **旧高先顶（stale）**并记入 staleSweep 待异步切片重测——同步重测
    /// 会让列宽动画（0.42s 逐帧变宽）每帧全量量高 = 动画帧全丢（真机
    /// 病灶：右栏开合瞬跳）。stale 高度由切片重测/显示面回传修正。
    func height(id: String, width: CGFloat, signature: String,
                makeContent: () -> AnyView) -> CGFloat {
        let width = max(1, width)
        if let cached = heights[id] {
            if cached.width == width, cached.signature == signature {
                return cached.height
            }
            if cached.signature == signature {
                if !pendingRemasure.contains(id) {
                    pendingRemasure.insert(id)
                    staleSweep.append(StaleEntry(id: id, width: width))
                }
                return cached.height
            }
        }
        let measured = measure(id: id, width: width, signature: signature,
                               makeContent: makeContent)
        heights[id] = HeightEntry(height: measured, width: width, signature: signature)
        return measured
    }

    /// 取走 stale 顶替队列（core 切片重测消费；pending 去重锚保留至
    /// remeasure 完成时移除——重复问询不重复入队）。
    func drainStaleSweep() -> [StaleEntry] {
        let batch = staleSweep
        staleSweep = []
        return batch
    }

    /// 【QA P1-3】stale 重测丢弃路径释放去重锚（切片中宽度失配/行已移除
    /// 而跳过的条目——不释放则该行后续所有宽度变化永不重新入队，stale
    /// 自愈链对该行失效）。释放后宽度稳定时的下一次问询重新入队。
    func cancelPendingRemasure(id: String) {
        pendingRemasure.remove(id)
    }

    /// 强制重测（reconfigure 已知内容变化的行；【CI修49】完成时释放该行
    /// 的 stale 去重锚——后续宽度再变可重新入队）。
    @discardableResult
    func remeasure(id: String, width: CGFloat, signature: String,
                   makeContent: () -> AnyView) -> CGFloat {
        let width = max(1, width)
        let measured = measure(id: id, width: width, signature: signature,
                               makeContent: makeContent)
        heights[id] = HeightEntry(height: measured, width: width, signature: signature)
        pendingRemasure.remove(id)
        return measured
    }

    /// 【CI修48】显示面实测高度回传（业界标准方案：GeometryReader 高度上报
    /// 桥——Stack Overflow 58399123/62263294 形态。根因：异步渲染组件
    /// （Markdown task 解析/图片异步加载/折叠展开）首量只有空态高度，挂载
    /// 后内容膨胀而 cell frame 已定死 → 溢出叠印）。
    /// 差 ≤0.5pt 为亚像素死区（吞同值/抖动；真实增长 >0.5pt 照常上报生效，
    /// 含 33Hz live 行逐帧增长）→ 返回是否实际更新（true = 调用方需
    /// invalidateLayout）。
    /// 签名规则：已存在条目保留原签名（内容版本面由 sync 重测路径管理，
    /// 回传只修高度）；**首写**采用调用方传入签名（core 传当前内容版本——
    /// QA P1-2 封口：防 heights 被清空后 "" 签名条目被下一轮空态重测覆盖
    /// 回传修正值，且内容 ideal 高不再变化 → 永久溢出）。
    @discardableResult
    func updateHeight(id: String, width: CGFloat, height: CGFloat,
                      signature: String? = nil) -> Bool {
        let width = max(1, width)
        let rounded = ceil(height)
        if let cached = heights[id],
           cached.width == width, abs(cached.height - rounded) <= 0.5 {
            return false
        }
        heights[id] = HeightEntry(height: rounded, width: width,
                                  signature: heights[id]?.signature ?? signature ?? "")
        return true
    }

    func cachedHeight(id: String, width: CGFloat) -> CGFloat? {
        guard let cached = heights[id], cached.width == max(1, width) else { return nil }
        return cached.height
    }

    /// 宽度变化 → 全量失效（高度缓存清空；池视图保留待重测时复用）。
    func invalidateWidth() {
        heights.removeAll()
    }

    /// 行移出数据集 → 高度随之清理（lody retain 过滤同语义；
    /// 【CI修49】stale 去重锚/队列同步清理——会话切换不残留）。
    func retain(_ ids: Set<String>) {
        heights = heights.filter { ids.contains($0.key) }
        entries = entries.filter { ids.contains($0.key) }
        recent.removeAll { !ids.contains($0) }
        pendingRemasure = pendingRemasure.filter { ids.contains($0) }
        staleSweep.removeAll { !ids.contains($0.id) }
    }

    // MARK: 内部

    private func measure(id: String, width: CGFloat, signature: String,
                         makeContent: () -> AnyView) -> CGFloat {
        let host: UIHostingController<AnyView>
        if let entry = entries[id] {
            host = entry.host
            // 内容装配统一走同一缝：core 传入的 AnyView 内含 .id(id)，
            // 内容变则 SwiftUI 状态随 identity 重置（复用正确性锚）。
            host.rootView = makeContent()
        } else {
            host = UIHostingController(rootView: makeContent())
            host.view.backgroundColor = .clear
            entries[id] = Entry(host: host, signature: signature)
        }
        // LRU 近用 + 池上限（不逐出已挂载视图——lody 铁律）。
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > Self.sizingLimit,
              let index = recent.firstIndex(where: { $0 != id && entries[$0]?.host.view.superview == nil }) {
            let evicted = recent.remove(at: index)
            entries[evicted] = nil
        }
        // SwiftUI 量高：定宽 + 竖向 fitting 探测（hosting view 标准测法）。
        host.view.frame = CGRect(origin: .zero,
                                 size: CGSize(width: width, height: 1))
        let size = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height)
    }
}
