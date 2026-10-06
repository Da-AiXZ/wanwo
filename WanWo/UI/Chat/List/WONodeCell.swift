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
        } else {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            // 【批4 渲染层根修 2026-10-07】剥离 safe area——业界实证（Apple
            // Forums 官方："Embedding a UIHostingController inside of cells
            // is not officially supported"；ZOZOTOWN 实战：cell 内 SwiftUI
            // 内容因 safeAreaInsets 被意外继承而不渲染/布局错位，修法=
            // safeAreaRegions.remove(.all)）。离屏量高 host 无 window →
            // safeAreaInsets 恒 0；显示 cell 挂窗 → 继承 iPad 状态栏/home 条
            // ~44pt——同一内容两环境布局参数不同=量高与显示分叉的结构性
            // 来源之一。部署目标 16.6 > 16.4，API 无需可用性分支。
            host.safeAreaRegions.remove(.all)
            host.view.insetsLayoutMarginsFromSafeArea = false
            contentView.addSubview(host.view)
            // 【批4 渲染层根修·主修】lody ChatMarkdownCell 同款 frame 直设
            // 布局：host 不挂约束，frame 由 layoutSubviews 每 pass 按 cell
            // 内容区强制直设。旧三边钉依赖 intrinsicContentSize 驱动高度，
            // 而 UIHostingController 无 sizingOptions 维护时不自动更新——
            // list-diag CELL 实证：复用换身份后 host frame 停留旧值（总结
            // 行 layoutH=946/drawH=46、26pt 胶囊行 drawH=362 三帧不动），
            // 新内容被旧高度裁剪=真机"格子占位正确、内容只画一角"的根因。
            self.host = host
        }
        // 【CI修50】揭示裁剪（复用分支也要重申——复用不重建约束但 clipped
        // 属性可能被系统复用池重置）。
        contentView.clipsToBounds = true
        isAccessibilityElement = false
        contentView.isAccessibilityElement = true
    }

    /// 【批4 渲染层根修·主修】每 pass 强制内容框=cell 内容区（lody
    /// ChatMarkdownCell.layoutSubviews 的 markdown.measure→frame 同语义：
    /// 显示与测量永远同步，复用残留旧框从机制上消灭）。SwiftUI 内容垂直
    /// 不贪婪（顶对齐排列），cell 高度由 layout 按账本给——内容完整呈现、
    /// 差值部分留白在底部（几 pt 级）。揭示动画（cell frame 渐进）时
    /// layoutSubviews 逐帧跟随 = 裁剪揭示语义保持。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host, contentView.bounds.width > 1, contentView.bounds.height > 1 else { return }
        host.view.frame = CGRect(origin: .zero, size: contentView.bounds.size)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // host 保留（复用面）；内容在下次 configure 时以 identity 重挂载替换。
    }
}
