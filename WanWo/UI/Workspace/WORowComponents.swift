//
//  WORowComponents.swift
//  WanWo
//
//  环 4 批 1 —— 行组件（细读文档 Rows.tsx 501 行 + Rows.module.css 368 行，行 740-765）。
//  项目行 34px / 会话行 32px / 溢出折叠钮 / hover 互换 / row-in 入场。
//

import SwiftUI

// MARK: - 项目行（ProjectRowItem：34px 头行——文件夹图标↔chevron hover 互换 + 行菜单 + 新会话 +）

struct WOProjectRow: View {
    let label: String
    let expanded: Bool
    let onToggle: () -> Void
    var onCreate: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var hovering = false

    init(label: String, expanded: Bool,
         onToggle: @escaping () -> Void,
         onCreate: (() -> Void)? = nil,
         onRename: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.label = label
        self.expanded = expanded
        self.onToggle = onToggle
        self.onCreate = onCreate
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        // 原型 .conv-group-hd：gap 4 / 34px / r8 / pad 0 8；g-folder 常显（hover 变蓝）
        HStack(spacing: 4) {
            Image(systemName: expanded ? "folder.fill" : "folder")
                .font(.system(size: 15))
                .foregroundColor(hovering
                                 ? WOAlias.stateBusinessPrimary
                                 : WOAlias.labelTertiary)

            Text(label)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(WOAlias.labelPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // g-chev：12px chevron（open rotate 90；展开态恒显=触屏适配——hover 显隐在无指针设备不可达）
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundColor(WOAlias.labelCaption)
                .frame(width: 12, height: 12)

            // rowActions：触屏恒显（hover 门控在 iPad 不可达，2026-09-19 登记）
            // 批D3：钮 24→32、图标 13→15、间距 2→6（触屏命中 ≥32pt）
            HStack(spacing: 6) {
                if onCreate != nil {
                    Button {
                        onCreate?()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(WOAlias.labelTertiary)
                }
                if onRename != nil || onDelete != nil {
                    WORowMenuButton(entries: [
                        WORowMenuEntry(label: "重命名", icon: "pencil", action: onRename),
                        WORowMenuEntry(label: "删除工作区", icon: "trash", isDanger: true, action: onDelete),
                    ])
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44) // 批D3：34→44（触屏 HIG 行整行 ≥44pt）
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(hovering ? WOAlias.interactiveBgHover : .clear))
        .onHover { hovering = $0 }
        .onTapGesture { onToggle() } // role=treeitem onClick=onToggle
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - 会话行（SessionNodeItem：32px——状态槽/标题/时间/hover 菜单；row-in 150ms）

struct WOSessionRow: View {
    let node: WOSessionNode
    let selected: Bool
    var showStatus: Bool = true
    var onOpen: () -> Void
    var onRename: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(node: WOSessionNode, selected: Bool, showStatus: Bool = true,
                onOpen: @escaping () -> Void,
                onRename: (() -> Void)? = nil,
                onArchive: (() -> Void)? = nil,
                onDelete: (() -> Void)? = nil) {
        self.node = node
        self.selected = selected
        self.showStatus = showStatus
        self.onOpen = onOpen
        self.onRename = onRename
        self.onArchive = onArchive
        self.onDelete = onDelete
    }

    private var displayTitle: String { node.title ?? "新会话" } // displayTitle：blank→'新会话'
    private var status: WOSessionStatus { WOSessionStatus.resolve(for: node) }

    var body: some View {
        // 原型 .conv-item：32px / r8 / pad 0 8；active=bg-active（≠hover 的 bg-hover）
        HStack(spacing: 0) {
            // 状态槽 ci-status：16×20 恒渲染（idle=透明+1.5px caption 描边——原型四态，
            // 空白占位行除外）；非 idle 走 WOStateDot（ongoing=像素追逐环，环 2 钉死形态）
            if showStatus {
                Group {
                    if status == .idle {
                        WOIdleDot(size: 8)
                    } else {
                        WOStateDot(state: status.dotState, size: 8)
                    }
                }
                .frame(width: 16, height: 20)
                .padding(.trailing, 6) // 批D3：4→6
            }
            Text(displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(WOAlias.labelPrimary)
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            // ci-time：12px caption 色（blank 行原型显「刚刚」，无 ci-more）
            Text(WOTimeLabel.rowLabel(updatedAt: node.updatedAt))
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelCaption)
                .padding(.trailing, 6)
            // 死按钮门禁：动作全空时不渲染菜单钮（R3a 真动作接线后非 blank 恒显）。
            if !node.blank,
               onRename != nil || onArchive != nil || onDelete != nil {
                WORowMenuButton(entries: [
                    WORowMenuEntry(label: "重命名", icon: "pencil", action: onRename),
                    WORowMenuEntry(label: "归档会话", icon: "archivebox", action: onArchive),
                    // fork 不做（用户裁定，digest-K §6.4⑤；dsh 语义存档 Rows.tsx:385-386）。
                    WORowMenuEntry(label: "删除会话", icon: "trash", isDanger: true, action: onDelete),
                ])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44) // 批D3：32→44（触屏 HIG 行整行 ≥44pt）
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground))
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        .rowIn(reduceMotion: reduceMotion) // @keyframes row-in from{opacity:0}
    }

    /// active（选中）→ bg-active；hover/menu-open → bg-hover（原型两级底色）
    private var rowBackground: Color {
        if selected { return WOAlias.interactiveBgActive }
        if hovering { return WOAlias.interactiveBgHover }
        return .clear
    }
}

// MARK: - idle 状态点（原型 .ci-dot.idle：透明底 + inset 1.5px caption 描边）

struct WOIdleDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .strokeBorder(WOAlias.labelCaption, lineWidth: 1.5)
            .frame(width: size, height: size)
    }
}

// MARK: - 溢出折叠钮（sessionOverflowButton：「展开其余 n 个会话」/「收起」）

struct WOOverflowButton: View {
    let hiddenCount: Int
    let expanded: Bool
    let onToggle: () -> Void

    init(hiddenCount: Int, expanded: Bool, onToggle: @escaping () -> Void) {
        self.hiddenCount = hiddenCount
        self.expanded = expanded
        self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onToggle) {
            Text(expanded ? "收起" : "展开其余 \(hiddenCount) 个会话")
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
                .padding(.trailing, 12)
        }
        .frame(height: 40) // 批D3：28→40（触屏命中区放大）
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(.clear))
        .accessibilityLabel(Text(expanded ? "收起" : "展开其余 \(hiddenCount) 个会话"))
    }
}

// MARK: - 行菜单锚钮（省略号；原生 Menu 弹层——系统接管定位/命中/区外关闭，
// 2026-09-20 真机反馈修复：自绘 overlay 浮层被侧栏 .clipped() 裁切 + 被后续行
// 盖住 + 无区外关闭 = 错位/点不了/关不掉；dsh 自绘 anchored Menu → SwiftUI
// Menu 系统弹层为旧件既有拍板先例 ConversationEmptyStateView:34）

struct WORowMenuButton: View {
    let entries: [WORowMenuEntry]

    var body: some View {
        Menu {
            ForEach(entries) { entry in
                if entry.isDanger {
                    Button(role: .destructive) {
                        entry.action?()
                    } label: {
                        Label(entry.label, systemImage: entry.icon ?? "trash")
                    }
                } else {
                    Button {
                        entry.action?()
                    } label: {
                        if let icon = entry.icon {
                            Label(entry.label, systemImage: icon)
                        } else {
                            Text(entry.label)
                        }
                    }
                }
            }
        } label: {
            // 原型 .ci-more/.g-more：批D3 命中区 24×24→32×32 + 15px svg
            //（contentShape 随框同步扩——触屏 ≥32pt 行内钮门禁）
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .foregroundColor(WOAlias.labelTertiary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 行菜单条目（条目形态保留；渲染交给系统弹层）

struct WORowMenuEntry: Identifiable {
    let id = UUID()
    let label: String
    let icon: String?
    let isDanger: Bool
    let action: (() -> Void)?

    init(label: String, icon: String? = nil, isDanger: Bool = false, action: (() -> Void)? = nil) {
        self.label = label
        self.icon = icon
        self.isDanger = isDanger
        self.action = action
    }
}

// MARK: - row-in 入场（@keyframes row-in from{opacity:0} 150ms）

struct RowInModifier: ViewModifier {
    let reduce: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                DispatchQueue.main.async { // 延帧（onAppear 首帧前动画被吞铁律）
                    withAnimation(reduce ? nil : .easeOut(duration: 0.15)) { shown = true }
                }
            }
    }
}

extension View {
    @ViewBuilder
    func rowIn(reduceMotion: Bool) -> some View {
        modifier(RowInModifier(reduce: reduceMotion))
    }
}
