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

    /// stale 重测去重锚键（per-(id, width)——【空白修复批】多宽缓存下同一行
    /// 可同时有多个宽度在途重测，由 Set<String> 升级为结构键）。
    struct RemasureKey: Hashable {
        let id: String
        let width: CGFloat
    }

    private static let sizingLimit = 24

    /// id → 池条目（池即复用面：cell 显示与离屏量高共用同一实例）。
    private var entries: [String: Entry] = [:]
    /// LRU 近用序（lody recent 数组同构）。
    private var recent: [String] = []
    /// id → (宽 → 量高)（与 entries 分离——条目可被逐出而高度仍有效）。
    /// 【空白修复批·根修】由单槽 [String: HeightEntry] 升级为**多宽缓存**
    /// [String: [CGFloat: HeightEntry]]：宽度是池高度缓存的真 key（类头
    /// 注释原本声称的语义）。病灶：空闲预热每轮给每行测 4 个候选宽，
    /// 单槽被覆盖到最后一个最窄候选——layout 以当前宽问高时命中 stale
    /// 顶替路径原样返回窄宽巨高（886→2043/1682→3294）→ 按虚高排版 =
    /// 空白区；随后 stale 切片修正走披露动画 = 被拽感；下轮预热再投毒 =
    /// 时隐时现。多宽缓存后各候选宽互不覆盖，问询宽命中即直读。
    private var heights: [String: [CGFloat: HeightEntry]] = [:]
    /// 【CI修49】宽度变化 stale 顶替：宽度已变但旧高先顶的行（异步重测
    /// 队列去重锚）——【空白修复批】per-(id, width) 去重。
    private var pendingRemasure: Set<RemasureKey> = []

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
    /// 高度缓存条目总数（探针消费。【空白修复批】多宽缓存下口径变更：
    /// id→宽→条目两级，本值 = 全部 (id, width) 条目数而非行数——
    /// list-diag 对拍口径同步）。
    var heightCount: Int { heights.values.reduce(0) { $0 + $1.count } }

    // MARK: 量高（主线程；未变行直读缓存）

    /// 量高：内容/宽度未变 → 缓存直读（零触碰池）；变化 → 池内视图重测。
    /// makeContent 闭包仅在需要（重）装配时调用——测量与显示同一视图实例。
    /// 【CI修49 宽度变化分支】：签名未变、宽度变（旋转/分栏/右栏开合）→
    /// **旧高先顶（stale）**并记入 staleSweep 待异步切片重测——同步重测
    /// 会让列宽动画（0.42s 逐帧变宽）每帧全量量高 = 动画帧全丢（真机
    /// 病灶：右栏开合瞬跳）。stale 高度由切片重测/显示面回传修正。
    /// 【空白修复批·stale 顶替语义改版（多宽缓存）】请求宽未命中（签名同）
    /// → 不再"唯一槽原样返回"（旧单槽投毒通道：预热最窄候选顶替后，当前
    /// 宽问高返回窄宽巨高=空白区根因），改为**取该行最接近请求宽的既有
    /// 条目返回 + 入队 StaleEntry(请求宽)**——最近宽近似误差有界（宽度差
    /// 最小者），真值由 stale 切片/显示面回传消化。签名不同（内容版本变）
    /// 仍走同步重测（现行为——内容变化必须即时出真值）。
    func height(id: String, width: CGFloat, signature: String,
                makeContent: () -> AnyView) -> CGFloat {
        let width = max(1, width)
        if let cached = heights[id]?[width] {
            if cached.signature == signature {
                return cached.height
            }
            // 同宽不同签名 → 内容变 → 落到同步重测。
        } else if let nearest = nearestEntry(id: id, width: width,
                                             matchingSignature: signature) {
            // 请求宽未命中 + 签名同 → 最近宽近似 + 入队 stale 重测（per-
            // (id, width) 去重锚：重复问询不重复入队）。
            let key = RemasureKey(id: id, width: width)
            if !pendingRemasure.contains(key) {
                pendingRemasure.insert(key)
                staleSweep.append(StaleEntry(id: id, width: width))
            }
            return nearest.height
        }
        let measured = measure(id: id, width: width, signature: signature,
                               makeContent: makeContent)
        heights[id, default: [:]][width] =
            HeightEntry(height: measured, width: width, signature: signature)
        return measured
    }

    /// 最近宽条目查找（请求宽未命中时的近似来源）：遍历该行全部既有宽键，
    /// 取 |既有宽 − 请求宽| 最小者。matchingSignature 非 nil 时只在同签名
    /// 条目中找（内容版本隔离——旧版本条目的高度对新版本无参考意义）。
    private func nearestEntry(id: String, width: CGFloat,
                              matchingSignature: String?) -> HeightEntry? {
        guard let byWidth = heights[id] else { return nil }
        var best: HeightEntry?
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for (existingWidth, entry) in byWidth {
            if let signature = matchingSignature, entry.signature != signature {
                continue
            }
            let delta = abs(existingWidth - width)
            if delta < bestDelta {
                bestDelta = delta
                best = entry
            }
        }
        return best
    }

    /// 取走 stale 顶替队列（core 切片重测消费；pending 去重锚保留至
    /// remeasure 完成时移除——重复问询不重复入队）。
    func drainStaleSweep() -> [StaleEntry] {
        let batch = staleSweep
        staleSweep = []
        return batch
    }

    /// 【QA P1-3】stale 重测丢弃路径释放去重锚（切片中宽度失配/行已移除
    /// 而跳过的条目——不释放则该 (id, width) 后续所有宽度变化永不重新入队，
    /// stale 自愈链对该行失效）。释放后宽度稳定时的下一次问询重新入队。
    func cancelPendingRemasure(id: String, width: CGFloat) {
        pendingRemasure.remove(RemasureKey(id: id, width: max(1, width)))
    }

    /// 强制重测（reconfigure 已知内容变化的行；【CI修49】完成时释放该行
    /// 的 stale 去重锚——后续宽度再变可重新入队；【空白修复批】写入精确
    /// width 键，不覆盖该行其他宽度的条目）。
    @discardableResult
    func remeasure(id: String, width: CGFloat, signature: String,
                   makeContent: () -> AnyView) -> CGFloat {
        let width = max(1, width)
        let measured = measure(id: id, width: width, signature: signature,
                               makeContent: makeContent)
        heights[id, default: [:]][width] =
            HeightEntry(height: measured, width: width, signature: signature)
        pendingRemasure.remove(RemasureKey(id: id, width: width))
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
    /// 【空白修复批】签名保留/死区判定均按 (id, width) 精确键——写入不
    /// 覆盖该行其他宽度的条目（多宽缓存主不变量）。
    @discardableResult
    func updateHeight(id: String, width: CGFloat, height: CGFloat,
                      signature: String? = nil) -> Bool {
        let width = max(1, width)
        let rounded = ceil(height)
        if let cached = heights[id]?[width],
           abs(cached.height - rounded) <= 0.5 {
            return false
        }
        heights[id, default: [:]][width] =
            HeightEntry(height: rounded, width: width,
                        signature: heights[id]?[width]?.signature ?? signature ?? "")
        return true
    }

    func cachedHeight(id: String, width: CGFloat) -> CGFloat? {
        heights[id]?[max(1, width)]?.height
    }

    /// 【重做批5·宽度解耦】纯量高（结果**不落池**）——流体重排的兜底
    /// 量高（fluid 期首帧新行兜底）。与
    /// measure 同款 fitting 流程（复用池视图），只差不写 heights。
    func measureOnly(id: String, width: CGFloat, makeContent: () -> AnyView) -> CGFloat {
        let width = max(1, width)
        let host: UIHostingController<AnyView>
        if let entry = entries[id] {
            host = entry.host
            host.rootView = makeContent()
        } else {
            host = UIHostingController(rootView: makeContent())
            host.view.backgroundColor = .clear
            host.safeAreaRegions.remove(.all)
            host.view.insetsLayoutMarginsFromSafeArea = false
            entries[id] = Entry(host: host, signature: "")
        }
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > Self.sizingLimit,
              let index = recent.firstIndex(where: { $0 != id && entries[$0]?.host.view.superview == nil }) {
            let evicted = recent.remove(at: index)
            entries[evicted] = nil
        }
        host.view.frame = CGRect(origin: .zero,
                                 size: CGSize(width: width, height: 1))
        let size = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height)
    }

    /// 【重做批5·宽度解耦】直写条目（绕过 0.5pt 死区与签名保留规则）——
    /// 流体收尾切换时批量落显示面回传真值用（实测自显示环境）。
    /// 【空白修复批】写入精确 width 键（不覆盖该行其他宽度条目）；去重锚
    /// 按 (id, width) 释放。
    func forceHeight(id: String, width: CGFloat, height: CGFloat, signature: String) {
        let width = max(1, width)
        heights[id, default: [:]][width] =
            HeightEntry(height: ceil(height), width: width, signature: signature)
        pendingRemasure.remove(RemasureKey(id: id, width: width))
    }

    /// 宽度变化 → 全量失效（高度缓存清空；池视图保留待重测时复用；
    /// 【空白修复批】多宽缓存语义不变——全宽全清）。
    func invalidateWidth() {
        heights.removeAll()
    }

    /// 【重做批4·四修】账本宽度对齐（高度维持原值）：可见行跳过离屏重测时
    /// 调用——显示 cell 在新宽度下重排后经回传桥回报真值，期间账本宽度先
    /// 对齐（防同宽度问询反复入 stale 队列）；释放 pendingRemasure 去重锚
    /// （回传 updateHeight 不经锚；若回传因死区未至，后续宽度变化仍可重新
    /// 入队=自愈链不断）。
    /// 【空白修复批·多宽语义】该请求宽已有条目 → 仅清 (id, width) 去重锚
    /// （"防重复入队"原意）；无条目 → **从最近宽条目拷贝一条到请求宽**
    /// （高度暂为近似值——显示 cell 在新宽度重排后经回传桥回报真值即修正）
    /// + 清锚。账本宽度对齐后同宽问询不再入 stale 队（原单槽版=把唯一槽
    /// 改写宽度，多宽下等价操作=补一条近似条目）。
    func rekeyWidth(id: String, width: CGFloat) {
        let width = max(1, width)
        if heights[id]?[width] != nil {
            pendingRemasure.remove(RemasureKey(id: id, width: width))
            return
        }
        if let nearest = nearestEntry(id: id, width: width, matchingSignature: nil) {
            heights[id, default: [:]][width] =
                HeightEntry(height: nearest.height, width: width,
                            signature: nearest.signature)
        }
        pendingRemasure.remove(RemasureKey(id: id, width: width))
    }

    /// 行移出数据集 → 高度随之清理（lody retain 过滤同语义；
    /// 【CI修49】stale 去重锚/队列同步清理——会话切换不残留；
    /// 【空白修复批】heights 两级过滤（按行 id 清全部宽条目）。
    func retain(_ ids: Set<String>) {
        heights = heights.filter { ids.contains($0.key) }
        entries = entries.filter { ids.contains($0.key) }
        recent.removeAll { !ids.contains($0) }
        pendingRemasure = pendingRemasure.filter { ids.contains($0.id) }
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
            // 【批4 渲染层根修】与显示 cell（WONodeCell）同源：显式剥离
            // safe area——离屏 host 无 window 本无 safeAreaInsets，显式声明
            // 保证量高/显示两环境布局参数一致（ZOZOTOWN 实证同修法）。
            host.safeAreaRegions.remove(.all)
            host.view.insetsLayoutMarginsFromSafeArea = false
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
