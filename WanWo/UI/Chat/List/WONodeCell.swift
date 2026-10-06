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
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            ])
            self.host = host
        }
        // 【CI修50】揭示裁剪（复用分支也要重申——复用不重建约束但 clipped
        // 属性可能被系统复用池重置）。
        contentView.clipsToBounds = true
        isAccessibilityElement = false
        contentView.isAccessibilityElement = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // host 保留（复用面）；内容在下次 configure 时以 identity 重挂载替换。
    }
}
