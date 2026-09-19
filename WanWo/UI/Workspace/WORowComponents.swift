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
    let isUngrouped: Bool
    let expanded: Bool
    let onToggle: () -> Void
    var onCreate: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var hovering = false
    @State private var menuOpen = false

    init(label: String, isUngrouped: Bool = false, expanded: Bool,
         onToggle: @escaping () -> Void,
         onCreate: (() -> Void)? = nil,
         onRename: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.label = label
        self.isUngrouped = isUngrouped
        self.expanded = expanded
        self.onToggle = onToggle
        self.onCreate = onCreate
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 6) {
            // slot 16×20：expanded ? FolderOpen : FolderClose；hover 互换 chevron（三角形箭头，open 旋转 90°）
            ZStack {
                // 触屏适配：chevron 展开态恒显（hover 互换在无指针设备不可达）
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .opacity(hovering || expanded ? 0 : 1)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(hovering || expanded ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .foregroundColor(hovering ? WOAlias.labelCaption : (menuOpen ? WOAlias.stateBusinessPrimary : WOAlias.labelTertiary))

            Text(isUngrouped ? "未分组" : label)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(WOAlias.labelPrimary)

            Spacer(minLength: 0)

            // rowActions：hover/menuOpen 显现（display none→inline-flex；gap 12）
            HStack(spacing: 12) {
                if onCreate != nil {
                    Button {
                        onCreate?()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
                if onRename != nil || onDelete != nil {
                    WORowMenuButton(menuOpen: $menuOpen, entries: [
                        WORowMenuEntry(label: "重命名", icon: "pencil", action: onRename),
                        WORowMenuEntry(label: "删除工作区", icon: "trash", isDanger: true, action: onDelete),
                    ])
                }
            }
            .frame(height: 20)
            // 触屏适配：行动作恒显（hover 门控在 iPad 不可达，2026-09-19 登记）
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .background((hovering || menuOpen) ? WOAlias.interactiveBgHover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { onToggle() } // role=treeitem onClick=onToggle
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 会话行（SessionNodeItem：32px——状态槽/标题/时间/hover 菜单；row-in 150ms）

struct WOSessionRow: View {
    let node: WOSessionNode
    let selected: Bool
    var showStatus: Bool = true
    var onOpen: () -> Void
    var onRename: (() -> Void)? = nil
    var onFork: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil

    @State private var hovering = false
    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(node: WOSessionNode, selected: Bool, showStatus: Bool = true,
                onOpen: @escaping () -> Void,
                onRename: (() -> Void)? = nil, onFork: (() -> Void)? = nil,
                onArchive: (() -> Void)? = nil) {
        self.node = node
        self.selected = selected
        self.showStatus = showStatus
        self.onOpen = onOpen
        self.onRename = onRename
        self.onFork = onFork
        self.onArchive = onArchive
    }

    private var displayTitle: String { node.title ?? "新会话" } // displayTitle：blank→'新会话'
    private var status: WOSessionStatus { WOSessionStatus.resolve(for: node) }

    var body: some View {
        HStack(spacing: 0) {
            // 状态槽：!flat||showStatus 时渲染（空闲不显示）
            if showStatus {
                WOStateDot(state: status.dotState, size: 8)
                    .frame(width: 16, height: 20)
                    .padding(.trailing, 4)
            }
            Text(displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(WOAlias.labelPrimary)
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 非 blank 行：时间+菜单恒显并存
            // （触屏适配：dsh hover 互换在无指针设备不可达，2026-09-19 登记；桌面 hover 高亮逻辑保留无害）
            if !node.blank {
                Text(WOTimeLabel.rowLabel(updatedAt: node.updatedAt))
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.labelTertiary)
                    .padding(.trailing, 6)
                WORowMenuButton(menuOpen: $menuOpen, entries: [
                    WORowMenuEntry(label: "重命名", icon: "pencil", action: onRename),
                    WORowMenuEntry(label: "分叉会话", icon: "branch", action: onFork),
                    WORowMenuEntry(label: "归档会话", icon: "archivebox", action: onArchive),
                ])
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .background((selected || hovering || menuOpen) ? WOAlias.interactiveBgHover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        .rowIn(reduceMotion: reduceMotion) // @keyframes row-in from{opacity:0}
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
        .frame(height: 28)
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(.clear))
        .accessibilityLabel(Text(expanded ? "收起" : "展开其余 \(hiddenCount) 个会话"))
    }
}

// MARK: - 行菜单锚钮（省略号；menuOpen 时行底色保持——menuOpen 类语义）

struct WORowMenuButton: View {
    @Binding var menuOpen: Bool
    let entries: [WORowMenuEntry]

    @State private var anchorFrame: CGRect = .zero

    init(menuOpen: Binding<Bool>, entries: [WORowMenuEntry]) {
        _menuOpen = menuOpen
        self.entries = entries
    }

    var body: some View {
        Button {
            menuOpen.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundColor(menuOpen ? WOAlias.labelPrimary : WOAlias.labelTertiary)
        .background(GeometryReader { g in
            Color.clear.preference(key: WORowMenuAnchorKey.self, value: g.frame(in: .global))
        })
        .onPreferenceChange(WORowMenuAnchorKey.self) { anchorFrame = $0 }
        .overlay {
            if menuOpen {
                WORowMenu(anchorFrame: anchorFrame, entries: entries,
                          onClose: { menuOpen = false })
            }
        }
    }
}

struct WORowMenuAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - 行菜单条目与浮层（批量翻译性菜单：重命名/分叉/归档/删除；danger 红字）

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

struct WORowMenu: View {
    let anchorFrame: CGRect
    let entries: [WORowMenuEntry]
    let onClose: () -> Void

    @State private var panelSize: CGSize = .zero

    init(anchorFrame: CGRect, entries: [WORowMenuEntry], onClose: @escaping () -> Void) {
        self.anchorFrame = anchorFrame
        self.entries = entries
        self.onClose = onClose
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onClose() }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Button {
                            onClose()
                            entry.action?()
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = entry.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 12))
                                        .frame(width: 16)
                                        .foregroundColor(entry.isDanger ? WOAlias.stateErrorPrimary : WOAlias.labelTertiary)
                                }
                                Text(entry.label)
                                    .font(.system(size: 14))
                                    .foregroundColor(entry.isDanger ? WOAlias.stateErrorPrimary : WOAlias.labelPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(entry.isDanger ? WOAlias.interactiveBgHoverDanger : WOAlias.interactiveBgHover))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(minWidth: 218, alignment: .leading)
                .background(
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 20)
                            .fill(WOSpecific.menu)
                            .shadow(color: .black.opacity(0.04), radius: 8)
                            .shadow(color: .black.opacity(0.05), radius: 20)
                            .overlay(RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(WOAlias.borderL1, lineWidth: 0.5))
                            .onAppear { panelSize = g.size }
                            .onChange(of: g.size) { panelSize = $0 }
                    }
                )
                .position(WOAnchoredPlacement.place(
                    anchor: anchorFrame, panelSize: panelSize,
                    side: .bottom, align: .end, gap: 4,
                    viewport: UIScreen.main.bounds))
                .transition(.opacity.animation(WOMotion.bezier(duration: WOMotion.t2)))
                .zIndex(60)
            }
            .ignoresSafeArea()
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
