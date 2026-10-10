//
//  WONodeCell.swift
//  WanWo
//
//  【批 1 · 件 1】单一生成 cell 类：UICollectionViewCell 内嵌 UIHostingController
//  承载既有 SwiftUI 节点视图（WONodeItemContent）。复用 = UIKit 原生 cell 复用
//  （一行一类），内容以 identity（.id(item.id)）强制重挂载——SwiftUI @State
//  随 identity 重置，复用正确性锚在 WONodeContent 装配侧。
//  高度：不在此 self-size——WOMessageListLayout 从 WOHostSizingPool 取精确
//  高度直给 frame（批 1 高度精确直给，与 LazyVStack 现状行为对齐）。
//

import SwiftUI
import UIKit

final class WONodeCell: UICollectionViewCell {

    private var host: UIHostingController<AnyView>?

    /// host.view 与 contentView 的三边钉约束（top/leading/trailing；高度
    /// 由 sizingOptions intrinsicContentSize 自持）。【巨行位图化】冻结时
    /// 摘除、解冻时原样激活（约束描述保留，装回即恢复）。
    private var hostConstraints: [NSLayoutConstraint] = []

    /// 【巨行位图化】冻结态簿记：静态快照视图（rail 期顶替 host.view 挂在
    /// contentView 上）。
    private var frozenSnapshot: UIView?
    /// 冻结态标记（freeze/unfreeze 幂等锚；prepareForReuse 防御读）。
    private(set) var isContentFrozen = false

    /// 【批4 真机诊断】host 实际渲染框（dumpLayoutSnapshot 对拍"布局 frame
    /// vs 内容实画"——渲染层空白/半画定位）。
    var hostViewFrame: CGRect {
        host?.view.frame ?? .zero
    }

    /// SwiftUI 内容的理想高度（systemLayoutSizeFitting 同款探测，显示环境
    /// 实测——与账本/布局高三方对拍）。
    var hostIntrinsicHeight: CGFloat {
        guard let host else { return -1 }
        let size = host.view.systemLayoutSizeFitting(
            CGSize(width: host.view.bounds.width,
                   height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height)
    }

    /// 内容装配（cellProvider 每次 dequeue/reconfigure 调；AnyView 内含
    /// .id(item.id)——内容变则 SwiftUI 状态随 identity 重置）。
    /// 同 cell 实例换内容 = rootView 替换（SwiftUI 桥一次性建好，复用零重建）。
    func configure(content: AnyView) {
        if let host {
            host.rootView = content
            host.view.setNeedsLayout()
            // 【批4 渲染层根修·复用残留】rootView 替换后强制重算固有尺寸：
            // 三边钉下 host 高=intrinsic，复用换身份不重算=intrinsic 残留
            // 旧身份高度（CELL 实证 drawH=46/362 停留旧值、新内容被旧框
            // 裁剪）。sizingOptions 主修之外的双保险（若其自动维护在某
            // 时序未触发，此处显式兜底）。
            host.view.invalidateIntrinsicContentSize()
        } else {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            // 【批4 渲染层根修】剥离 safe area——业界实证（Apple Forums
            // 官方："Embedding a UIHostingController inside of cells is not
            // officially supported"；ZOZOTOWN 实战：cell 内 SwiftUI 内容因
            // safeAreaInsets 被意外继承而不渲染/布局错位，修法=
            // safeAreaRegions.remove(.all)）。离屏量高 host 无 window →
            // safeAreaInsets 恒 0；显示 cell 挂窗 → 继承 iPad 状态栏/home 条
            // ~44pt——同一内容两环境布局参数不同=量高与显示分叉的来源。
            // 部署目标 16.6 > 16.4，API 无需可用性分支。
            host.safeAreaRegions.remove(.all)
            host.view.insetsLayoutMarginsFromSafeArea = false
            // 【批4 渲染层根修·主修】iOS16 官方 host-in-cell 机制：自动维护
            // intrinsicContentSize——rootView 变化 → intrinsic 自动失效 →
            // 三边钉约束重算 host 高。三边钉（top/leading/trailing + 高度
            // 自持）保证：①复用换身份后高度跟随新内容（CELL 残留根治）；
            // ②贪婪展开件（思考/工具的 ScrollView 展开体）拿到自身理想高
            // proposal 才能展开（frame 直设钉死 proposal 会压扁展开=展开
            // 不显示）；③揭示动画=SwiftUI 内部动画单源（CI修50 单动画源
            // 语义），GeometryReader 逐帧回传→账本→cell frame 跟随。
            host.sizingOptions = [.intrinsicContentSize]
            contentView.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            let constraints = [
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            ]
            NSLayoutConstraint.activate(constraints)
            // 【巨行位图化】约束描述存底（冻结摘除 / 解冻装回）。
            hostConstraints = constraints
            self.host = host
        }
        // 【CI修50】揭示裁剪（复用分支也要重申——复用不重建约束但 clipped
        // 属性可能被系统复用池重置）。
        contentView.clipsToBounds = true
        isAccessibilityElement = false
        contentView.isAccessibilityElement = true
    }

    // MARK: 【巨行位图化·方案 A】rail 期巨行内容冻结

    /// rail 期把"高过一屏"的可见巨行内容替换为静态快照（消除其逐帧 SwiftUI
    /// 重排 = rail 逐帧卡顿源；其他行照常流动）。机制：host.view 从
    /// contentView **移除**（保留控制器引用与约束描述）——host 离层后
    /// SwiftUI 不再为其布局 = 逐帧重排成本归零（只 hide 不行：宽度约束仍
    /// 会驱动它重排）；当前外观以 snapshotView 拍下，作为静态视图铺满
    /// contentView（四边钉约束——随插值中的 cell frame 逐帧贴合，内容随帧
    /// 平滑缩放无 letterbox；0.4s rail 瞬态缩放换满帧流动的取舍，rail 后
    /// 解冻恢复原渲染零残留）。
    /// 快照失败（视图未渲染/离窗窗口期）→ fail-open 不冻结（cell 保持
    /// 活行语义，卡顿面收窄但正确性无损）。
    /// 交互注意：host 离层期间 WOHeightReporting 静默（rail 门本就丢弃
    /// 上报，无损失）；解冻后 host 重排一次并经报告桥回传真值（结算窗
    /// 消化）。
    func freezeContentSnapshot() {
        guard !isContentFrozen else { return } // 幂等（restart 链重复起跑）
        guard let host, host.view.superview === contentView else { return }
        // 先拍快照（host 仍在层级内、已渲染——snapshotView 可靠），再摘除。
        guard let snapshot = host.view.snapshotView(afterScreenUpdates: false)
        else { return }
        // 约束先摘后移除（防跨层级悬挂约束告警）；描述保留在 hostConstraints。
        NSLayoutConstraint.deactivate(hostConstraints)
        host.view.removeFromSuperview()
        frozenSnapshot = snapshot
        snapshot.translatesAutoresizingMaskIntoConstraints = false
        snapshot.isUserInteractionEnabled = false
        contentView.addSubview(snapshot)
        NSLayoutConstraint.activate([
            snapshot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            snapshot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            snapshot.topAnchor.constraint(equalTo: contentView.topAnchor),
            snapshot.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isContentFrozen = true
    }

    /// 解冻：快照移除、host.view 按原约束装回 contentView，强制重排一次
    /// （invalidateIntrinsicContentSize + setNeedsLayout——复用残留同款
    /// 防御），随后 SwiftUI 重排并经 WOHeightReporting 桥回传真值（rail 后
    /// 结算窗消化）。幂等（非冻结态空操作——全恢复路径可无差别调用）。
    func unfreezeContentSnapshot() {
        guard isContentFrozen else { return }
        frozenSnapshot?.removeFromSuperview()
        frozenSnapshot = nil
        if let host {
            contentView.addSubview(host.view)
            // translatesAutoresizingMaskIntoConstraints 在 configure 时
            // 已置 false 且从未改动——装回即受 hostConstraints 约束。
            NSLayoutConstraint.activate(hostConstraints)
            host.view.invalidateIntrinsicContentSize()
            host.view.setNeedsLayout()
        }
        isContentFrozen = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 【巨行位图化】防御：rail 期可见 cell 不会被 reuse，但异常路径
        // （冻结态 cell 进入复用池）下不恢复 = 快照残留 + host 永久离层
        // ——解冻幂等恢复（host 保留，内容在下次 configure 时以 identity
        // 重挂载替换）。
        unfreezeContentSnapshot()
        // host 保留（复用面）；内容在下次 configure 时以 identity 重挂载替换。
    }
}
