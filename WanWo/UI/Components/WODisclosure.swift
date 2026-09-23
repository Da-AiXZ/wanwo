//
//  WOFoldToggle.swift
//  WanWo
//
//  环 2 批 A —— FoldToggle（7.2.8：head-tail 折叠钮）。
//  批12：原 DisclosureRow（7.2.4-5 预留壳）退役——零调用者 + .onHover
//  触屏死件；dsh 语义的现代版 = WanWo/UI/Chat/WOChatView.swift 内
//  WODisclosureRow（扫光/followEnd/分隔点/整行点击，T5 真值），全仓唯一。
//

import SwiftUI

// MARK: - FoldToggle（7.2.8：head-tail 折叠共用钮；文案完全由调用方持有）

public struct WOFoldToggle: View {
    public let expanded: Bool
    public let hidden: Int
    /// 收起钮可见文案（描述目标态）
    public let collapse: String
    /// 展开钮可见文案（带隐藏数插值）
    public let expand: (Int) -> String
    public let onToggle: () -> Void

    public init(expanded: Bool, hidden: Int, collapse: String,
                expand: @escaping (Int) -> String, onToggle: @escaping () -> Void) {
        self.expanded = expanded
        self.hidden = hidden
        self.collapse = collapse
        self.expand = expand
        self.onToggle = onToggle
    }

    public var body: some View {
        // 无内建样式——className 全权交调用方（手册 3239 行）；按钮文本 = 目标态
        Button(action: onToggle) {
            Text(expanded ? collapse : expand(hidden))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(expanded ? collapse : expand(hidden)))
    }
}
