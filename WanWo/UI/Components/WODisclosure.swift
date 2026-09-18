//
//  WODisclosureRow.swift + WOFoldToggle.swift
//  WanWo
//
//  环 2 批 A —— DisclosureRow（7.2.4-5：24px 紧凑流程行共用披露壳）+ FoldToggle（7.2.8：head-tail 折叠钮）。
//

import SwiftUI

// MARK: - DisclosureRow（ReadBlock/SearchBlock/WebBlock 等流程块共用外壳）

public struct WODisclosureRow<Icon: View, Content: View>: View {
    public let expandable: Bool
    public let open: Bool
    public let onToggle: (() -> Void)?
    /// 整行可点（expandOnRowClick）；否则只有 leading 按钮可点
    public var expandOnRowClick: Bool = false
    @ViewBuilder public let icon: () -> Icon
    public let title: Text
    /// hover 时 icon 互换为 chevron（默认 = expandable）
    public var previewChevron: Bool?
    /// 收起态同行附加内容（展开即隐，除非 keepContentWhenOpen）
    public var collapsedContent: Text? = nil
    public var keepContentWhenOpen: Bool = false
    @ViewBuilder public let content: () -> Content

    @State private var hovering = false

    public init(expandable: Bool, open: Bool, onToggle: (() -> Void)? = nil,
                expandOnRowClick: Bool = false,
                icon: @escaping () -> Icon, title: Text,
                previewChevron: Bool? = nil,
                collapsedContent: Text? = nil, keepContentWhenOpen: Bool = false,
                content: @escaping () -> Content) {
        self.expandable = expandable
        self.open = open
        self.onToggle = onToggle
        self.expandOnRowClick = expandOnRowClick
        self.icon = icon
        self.title = title
        self.previewChevron = previewChevron
        self.collapsedContent = collapsedContent
        self.keepContentWhenOpen = keepContentWhenOpen
        self.content = content
    }

    private var chevronShown: Bool { previewChevron ?? expandable }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // leading：16px 定宽盒；icon 与 chevron 绝对叠放，hover 120ms 互换（手册 3203-3204 行）
                Button {
                    if expandable { onToggle?() }
                } label: {
                    ZStack {
                        icon()
                            .opacity(chevronShown && hovering ? 0 : 1)
                        if chevronShown {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .opacity(chevronShown && hovering ? 1 : 0)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .animation(.easeInOut(duration: 0.12), value: hovering)
                }
                .buttonStyle(.plain)
                .disabled(!expandable)

                title
                    .font(.system(size: 13)) // secondary 字号层（比正文低半级，手册 3199 行）
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let collapsedContent, !open || keepContentWhenOpen {
                    collapsedContent
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if expandable && expandOnRowClick { onToggle?() } } // 整行可点分支

            if open {
                // 展开正文：pad 4 0 8（上紧下松），横缩进归使用方（手册 3207 行）
                content()
                    .padding(.vertical, 4)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }
}

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
