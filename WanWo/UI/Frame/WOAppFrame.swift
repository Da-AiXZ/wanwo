//
//  WOAppFrame.swift
//  WanWo
//
//  环 3 —— 三栏框架（细读文档第 2 章 AppFrame.tsx 218 行 + AppFrame.module.css 119 行）。
//  grid 三列 / 0.3s 唯一曲线过渡（拖拽时关）/ DragHandle 8px 命中带 + details 浮动把手 /
//  narrow<1024 断点 / 切会话自动关详情 / 0 宽 details 不卸载 / overlay 层 z20 点击穿透。
//

import SwiftUI

public enum WODragSide: Equatable {
    case sidebar, details
}

public struct WOAppFrame<Sidebar: View, Center: View, Details: View, Overlay: View>: View {
    @ObservedObject public var store: WOLayoutStore
    /// 会话是否「非 blank」——false/nil 时详情栏不算开（blank 会话不算，手册 571 行）
    public var hasDetailsSession: Bool
    @ViewBuilder public var sidebar: (_ collapsed: Bool, _ width: CGFloat) -> Sidebar
    @ViewBuilder public var center: () -> Center
    @ViewBuilder public var details: () -> Details
    /// shell.overlay 槽（z20 点击穿透层；条目各自 opt-in pointer events）
    @ViewBuilder public var overlayLayer: () -> Overlay

    @State private var viewportWidth: CGFloat = 0
    @State private var dragging: WODragSide? = nil
    /// 拖拽基线 = 拖起时的渲染宽（colsRef 语义，不跳回存储偏好）
    @State private var dragBaseSidebar: CGFloat = 0
    @State private var dragBaseDetails: CGFloat = 0
    /// 切会话自动关详情：上一个非空会话消失时触发（手册 572 行）
    @State private var lastHadSession = false

    public init(store: WOLayoutStore, hasDetailsSession: Bool = false,
                sidebar: @escaping (_ collapsed: Bool, _ width: CGFloat) -> Sidebar,
                center: @escaping () -> Center,
                details: @escaping () -> Details,
                overlayLayer: @escaping () -> Overlay = { EmptyView() }) {
        self.store = store
        self.hasDetailsSession = hasDetailsSession
        self.sidebar = sidebar
        self.center = center
        self.details = details
        self.overlayLayer = overlayLayer
    }

    // narrow<1024；collapsed 语义随 narrow 切换（手册 574 行）
    private var sidebarCollapsed: Bool {
        store.narrow ? !store.narrowExpanded : store.sidebar == 0
    }
    private var sidebarPreference: CGFloat {
        sidebarCollapsed ? 0 : (store.sidebar == 0 ? WOLayoutContract.sidebarDefault : store.sidebar)
    }
    private var effectiveDetails: CGFloat {
        hasDetailsSession ? store.details : 0
    }

    public var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let cols = WOColumnSolver.compute(
                viewport: viewport,
                sidebar: sidebarCollapsed ? WOLayoutContract.sidebarCollapsed : sidebarPreference,
                details: effectiveDetails)

            colsContent(cols, viewport: viewport)
                .onAppear { viewportWidth = viewport; store.setNarrow(viewport < WOLayoutContract.autoCollapseBreakpoint) }
                .onChange(of: viewport) { w in
                    viewportWidth = w
                    store.setNarrow(w < WOLayoutContract.autoCollapseBreakpoint)
                }
                .onChange(of: hasDetailsSession) { has in
                    // detailsSession 变化且上一个非空 → 自动关详情（手册 572 行）
                    if lastHadSession && !has { store.closeDetails() }
                    lastHadSession = has
                }
        }
    }

    @ViewBuilder
    private func colsContent(_ cols: WOColumns, viewport: CGFloat) -> some View {
        let motion = dragging == nil ? WOMotion.bezier(duration: 0.42) : nil // 原型拍板 0.42s（覆盖 dsh 0.3，2026-09-19 真机反馈）；拖时关过渡

        HStack(spacing: 0) {
            // sidebarCol：min-width 0 overflow hidden specific-sidebar-fill 右 0.5px l3（收拢仍保留带边框轨道）
            sidebar(sidebarCollapsed, cols.sidebar)
                .frame(width: cols.sidebar)
                .frame(maxHeight: .infinity)
                .clipped()
                .background(WOSpecific.sidebarFill)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(WOAlias.borderL3).frame(width: 0.5)
                }

            // centerCol：min-width 0 column overflow hidden
            center()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    // 右栏入口（codex 右上开关语义）：details 关闭时显示
                    if cols.details == 0 {
                        Button { store.openDetails() } label: {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(WOAlias.interactiveBgHover))
                                .foregroundColor(WOAlias.labelSecondary)
                        }
                        .buttonStyle(.plain)
                        .woTooltip("打开侧边栏", side: .bottom, delayMs: 500)
                        .padding(.trailing, 14)
                        .padding(.top, 14)
                    }
                }

            // detailsCol：0 宽不卸载子树；collapsed 去左 1px 缝（手册 581 行）
            details()
                .frame(width: cols.details)
                .frame(maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .leading) {
                    if cols.details > 0 {
                        Rectangle().fill(WOAlias.borderL3).frame(width: 0.5)
                    }
                }
        }
        .frame(width: viewport)
        .modifier(WOColumnsAnimation(motion: motion, key: WOColumnsKey(sidebar: cols.sidebar, details: cols.details)))

        // DragHandle：!sidebarCollapsed 时 sidebar 侧；details>0 时 details 侧（手册 577 行）
        .overlay(alignment: .leading) {
            if !sidebarCollapsed {
                WODragHandle(side: .sidebar, isDragging: dragging == .sidebar,
                             x: cols.sidebar, viewport: viewport,
                             baseSidebar: cols.sidebar, baseDetails: cols.details,
                             onDragStart: { dragBaseSidebar = cols.sidebar; dragBaseDetails = cols.details; dragging = .sidebar },
                             onDragEnd: { dragging = nil },
                             onSidebarDrag: { dx in store.setSidebar(dragBaseSidebar + dx) },
                             onDetailsDrag: { dx in store.setDetails(dragBaseDetails - dx) })
            }
        }
        .overlay(alignment: .leading) {
            // alignment 必须 leading：手柄自身 offset(x-4) 定位到 details 左缘；
            // trailing 会双重定位把手柄甩出视口（真机"拖宽无反应"根因）
            if cols.details > 0 {
                WODragHandle(side: .details, isDragging: dragging == .details,
                             x: viewport - cols.details, viewport: viewport,
                             baseSidebar: cols.sidebar, baseDetails: cols.details,
                             onDragStart: { dragBaseSidebar = cols.sidebar; dragBaseDetails = cols.details; dragging = .details },
                             onDragEnd: { dragging = nil },
                             onSidebarDrag: { dx in store.setSidebar(dragBaseSidebar + dx) },
                             onDetailsDrag: { dx in store.setDetails(dragBaseDetails - dx) })
            }
        }
        // shell.overlay：z20 pointer-events none，子项各自 opt-in
        .overlay {
            overlayLayer()
                .allowsHitTesting(false)
        }
    }
}

/// 列宽过渡（拖拽/reduced-motion 时无动画）
private struct WOColumnsAnimation: ViewModifier {
    let motion: Animation?
    let key: WOColumnsKey

    // 恒定单一 modifier：if/else 分支切换会重置子树 identity（进行中拖动手势被销毁=拖动打断+闪跳根因）。
    // animation(_:value:) 本身接受 Optional——nil 即无动画，参数变化不换身份。
    func body(content: Content) -> some View {
        content.animation(motion, value: key)
    }
}

private struct WOColumnsKey: Equatable {
    let sidebar: CGFloat
    let details: CGFloat
}

// MARK: - 拖宽手柄（8px 命中带；details 侧 hover 显现 12×32 浮动把手）

struct WODragHandle: View {
    let side: WODragSide
    let isDragging: Bool
    /// 手柄 x（左缘；内含 margin-left −4 命中带）
    let x: CGFloat
    let viewport: CGFloat
    let baseSidebar: CGFloat
    let baseDetails: CGFloat
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onSidebarDrag: (CGFloat) -> Void
    let onDetailsDrag: (CGFloat) -> Void

    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .offset(x: x - 4) // margin-left -4 命中带（垂直由 overlay 居中承接）
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        if !isDragging { onDragStart() }
                        let dx = g.translation.width
                        switch side {
                        case .sidebar: onSidebarDrag(dx)
                        case .details: onDetailsDrag(dx)
                        }
                    }
                    .onEnded { _ in onDragEnd() }
            )
            .overlay {
                if side == .details {
                    // 12×32 浮动把手：hover/拖拽显现（手册 583 行）
                    Capsule()
                        .fill(hovering || isDragging ? WOAlias.buttonFloatingHover : WOAlias.buttonFloatingFill)
                        .overlay(Capsule().strokeBorder(
                            hovering || isDragging ? WOAlias.borderL3 : WOAlias.borderL2DarkmodeThin, lineWidth: 0.5))
                        .frame(width: 12, height: 32)
                        .opacity(hovering || isDragging ? 1 : 0)
                        .animation(WOMotion.bezier(duration: 0.3), value: hovering || isDragging)
                }
            }
    }
}

// MARK: - 指针形状（iPad 指针/触控板；iOS 无原生 col-resize 光标，此处空实现占位）

extension View {
    @ViewBuilder
    func cursor(_ kind: ResizeCursorKind) -> some View {
        // iPadOS 指针光标定制（UIPointerInteraction）在环 8 收官统一挂；此处保命中等效
        self
    }
}

enum ResizeCursorKind {
    case resizeLeftRight
}
