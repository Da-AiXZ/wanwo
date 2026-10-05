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

    /// 内容装配（cellProvider 每次 dequeue/reconfigure 调；AnyView 内含
    /// .id(item.id)——内容变则 SwiftUI 状态随 identity 重置）。
    /// 同 cell 实例换内容 = rootView 替换（SwiftUI 桥一次性建好，复用零重建）。
    func configure(content: AnyView) {
        if let host {
            host.rootView = content
            host.view.setNeedsLayout()
        } else {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            contentView.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            // 【CI修50】top/leading/trailing 三边钉 + intrinsic 高（旧四边
            // 钉：行高动画时 host 被约束拉伸挤压内容 = 真机展开"残影/抽搐"
            // 根因之一——内容是被捏变形而非被揭示）；cell frame 动画时
            // host 保持目标全高，由 contentView 裁剪渐进揭示 = 参考件
            // 《设置模型配置原型》.collapsible overflow:hidden 语义。
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
