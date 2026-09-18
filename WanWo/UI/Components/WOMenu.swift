//
//  WOMenu.swift
//  WanWo
//
//  环 2 批 A —— Menu（7.2.14-15：锚定下拉菜单；entry 判别联合/尾随对勾/一层子菜单/footer 钉底）。
//  双渲染模式（原位/portal）在 SwiftUI 统一为全屏 overlay 层（外点关闭与 Escape 内建）。
//

import SwiftUI

// MARK: - 数据模型（判别联合 → Swift enum；'type' in 守卫 → switch）

public enum WOMenuEntry: Identifiable, Equatable {
    /// 普通行：disabled 灰显；danger 错误色+危险 hover；selected 尾随对勾（非填充高亮）
    case item(id: String, label: String, icon: Image? = nil, disabled: Bool = false,
              danger: Bool = false, selected: Bool = false, submenu: [WOMenuEntry] = [])
    case separator(id: String)
    case label(id: String, text: String)

    public var id: String {
        switch self {
        case .item(let id, _, _, _, _, _, _): return id
        case .separator(let id): return id
        case .label(let id, _): return id
        }
    }
    public var isSeparator: Bool { if case .separator = self { return true }; return false }
    public var isLabel: Bool { if case .label = self { return true }; return false }
}

// MARK: - 菜单视图（owner 受控 open；onClose=外点/Escape）

public struct WOMenu: View {
    public let anchorFrame: CGRect          // 锚的视口 rect（GeometryReader 上报）
    public let items: [WOMenuEntry]
    public var selectedId: String? = nil
    public var onClose: () -> Void
    public var onSelect: ((String) -> Void)? = nil
    public var side: WOPopupSide = .bottom
    public var align: WOPopupAlign = .start
    public var dense: Bool = false          // 降行距不改字号与卡宽
    public var compact: Bool = false        // 小字号小间距小卡宽
    public var footer: [WOMenuEntry] = []   // 滚动区下方钉底行组
    public var hasSubmenus: Bool = false    // 有子菜单的菜单不给高度上限（clip 裁侧卡）

    @State private var panelSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(anchorFrame: CGRect, items: [WOMenuEntry], selectedId: String? = nil,
                onClose: @escaping () -> Void, onSelect: ((String) -> Void)? = nil,
                side: WOPopupSide = .bottom, align: WOPopupAlign = .start,
                dense: Bool = false, compact: Bool = false,
                footer: [WOMenuEntry] = [], hasSubmenus: Bool = false) {
        self.anchorFrame = anchorFrame
        self.items = items
        self.selectedId = selectedId
        self.onClose = onClose
        self.onSelect = onSelect
        self.side = side
        self.align = align
        self.dense = dense
        self.compact = compact
        self.footer = footer
        self.hasSubmenus = hasSubmenus
    }

    // 卡样式：pad 4 r20 specific-menu 背景 + elevation-prominent（描边重绑 l1）+ 滚动条 l2 重绑
    private var cardMinWidth: CGFloat { compact ? 164 : 218 }   // 双宿主设计主卡 218 宽
    private var cardMaxWidth: CGFloat { compact ? 164 : 360 }
    private var itemMinHeight: CGFloat { compact ? 26 : (dense ? 34 : 40) }
    private var itemFont: Font { compact ? .system(size: 12) : .system(size: 14) }
    private var itemRadius: CGFloat { compact ? 5 : 10 }

    public var body: some View {
        // 全屏层：外点关闭（useDismissOnOutsidePointer 语义）+ Escape
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onClose() } // 外点（Escape 见 WOHelpers 键盘桥待办）
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    viewport
                    if !footer.isEmpty {
                        // footer：margin-top 4 + pad-top 4 + 0.5px l2 发丝线（l1 在菜单面上几乎不可见）
                        Divider().overlay(WOAlias.borderL2).padding(.horizontal, 2)
                        renderEntries(footer, compact: compact)
                            .padding(.top, 4)
                    }
                }
                .background(
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: compact ? 7 : 20)
                            .fill(WOSpecific.menu)
                            .shadow(color: .black.opacity(0.04), radius: 8)
                            .shadow(color: .black.opacity(0.05), radius: 20) // elevation-prominent
                            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 20)
                                .strokeBorder(WOAlias.borderL1, lineWidth: 0.5)) // 描边色重绑 l1
                            .onAppear { panelSize = g.size }
                            .onChange(of: g.size) { panelSize = $0 }
                    }
                )
                .frame(minWidth: cardMinWidth, maxWidth: cardMaxWidth, alignment: .leading)
                .position(WOAnchoredPlacement.place(
                    anchor: anchorFrame, panelSize: panelSize,
                    side: side, align: align, gap: 4,
                    viewport: UIScreen.main.bounds))
                .transition(.opacity.animation(reduceMotion ? nil
                    : WOMotion.bezier(duration: WOMotion.t2))) // T2 档
            }
            .ignoresSafeArea()
    }

    @ViewBuilder private var viewport: some View {
        // scrollable 判定：无子菜单的菜单才拿高度上限（calc(100vh - 24px)＝距上下缘 12px）
        let list = renderEntries(items, compact: compact)
        if hasSubmenus {
            list
        } else {
            ScrollView {
                list
            }
            .frame(maxHeight: UIScreen.main.bounds.height - 24)
        }
    }

    @ViewBuilder private func renderEntries(_ entries: [WOMenuEntry], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .separator:
                    // h0.5 margin 4 2 l1（figma 122:9481 py4/px2）
                    Divider().overlay(WOAlias.borderL1)
                        .padding(.vertical, 4).padding(.horizontal, 2)
                case .label(_, let text):
                    Text(text)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundColor(WOAlias.labelTertiary)
                        .padding(.horizontal, compact ? 7 : 10)
                        .padding(.vertical, compact ? 4 : 8)
                case .item(let id, let label, let icon, let disabled, let danger, _, let submenu):
                    ItemRow(id: id, label: label, icon: icon, disabled: disabled, danger: danger,
                            submenu: submenu, compact: compact, dense: dense,
                            selectedId: selectedId, onSelect: onSelect)
                }
            }
        }
        .padding(4)
    }

    // 普通行（figma .Menu_cell）：min-h 40 pad 8 10 r10 gap8 14px/22px；
    // 选中 = 尾随对勾非填充（selected 格保持素填充）；danger 文字图标同色 + 危险 hover
    private struct ItemRow: View {
        let id: String
        let label: String
        let icon: Image?
        let disabled: Bool
        let danger: Bool
        let submenu: [WOMenuEntry]
        let compact: Bool
        let dense: Bool
        let selectedId: String?
        let onSelect: ((String) -> Void)?

        @State private var hovering = false
        @State private var submenuOpen = false

        private var isSelected: Bool { selectedId == id }
        private var itemMinHeight: CGFloat { compact ? 26 : (dense ? 34 : 40) }

        var body: some View {
            // itemWrap：relative；hover/focus 开子菜单（hover 出即收）
            HStack(spacing: compact ? 6 : 8) {
                if let icon {
                    icon.resizable().scaledToFit()
                        .frame(width: compact ? 14 : 16, height: compact ? 14 : 16)
                        .foregroundColor(danger ? WOAlias.stateErrorPrimary : WOAlias.labelTertiary)
                }
                Text(label)
                    .font(compact ? .system(size: 12) : .system(size: 14))
                    .foregroundColor(danger ? WOAlias.stateErrorPrimary : WOAlias.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    // 选中标记是尾随对勾（figma .Menu_cell），primary 色
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.brandPrimary)
                }
                if !submenu.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(WOAlias.labelTertiary)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : (dense ? 5 : 8))
            .frame(minHeight: itemMinHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: compact ? 5 : 10)
                    .fill(danger ? (hovering ? WOAlias.interactiveBgHoverDanger : .clear)
                          : (hovering ? WOAlias.interactiveBgHover : .clear))
            )
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if !submenu.isEmpty { submenuOpen = h } // hover 出即收
            }
            .onTapGesture {
                // disabled 与「仅开子菜单的父行」不回调 onSelect（手册 3353 行）
                guard !disabled else { return }
                if submenu.isEmpty { onSelect?(id) }
            }
            .overlay(alignment: .leading) {
                if submenuOpen, !submenu.isEmpty {
                    // 子菜单卡：与父卡底对齐向上生长，水平离 itemWrap 10px（4 pad + 6 间隙）；
                    // 子行无 danger/selected/子子菜单（一层嵌套上限）
                    WOMenuChildList(entries: submenu, compact: compact)
                        .offset(x: (compact ? 164 : 218) + 6)
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            // 子菜单透明桥：pointer 横穿 10px 缝隙不触发 leave（SwiftUI hover 语义由 overlay 连体承接）
        }
    }

    // 子菜单列表（role=menu）
    private struct WOMenuChildList: View {
        let entries: [WOMenuEntry]
        let compact: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    switch entry {
                    case .separator:
                        Divider().overlay(WOAlias.borderL1).padding(.vertical, 4).padding(.horizontal, 2)
                    case .label(_, let text):
                        Text(text).font(.system(size: 12)).foregroundColor(WOAlias.labelTertiary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    case .item(let id, let label, let icon, let disabled, _, _, _):
                        HStack(spacing: 8) {
                            if let icon {
                                icon.resizable().scaledToFit().frame(width: 16, height: 16)
                                    .foregroundColor(WOAlias.labelTertiary)
                            }
                            Text(label).font(.system(size: 14)).foregroundColor(WOAlias.labelPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(minHeight: 40, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.interactiveBgHover))
                        .opacity(disabled ? 0.4 : 1)
                    }
                }
            }
            .padding(4)
            .frame(minWidth: 163, alignment: .leading) // figma 419:16920 子卡 min-width 163
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(WOSpecific.menu)
                    .shadow(color: .black.opacity(0.04), radius: 8)
                    .shadow(color: .black.opacity(0.05), radius: 20)
                    .overlay(RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(WOAlias.borderL1, lineWidth: 0.5))
            )
        }
    }
}
