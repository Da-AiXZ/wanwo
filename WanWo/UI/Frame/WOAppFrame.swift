//
//  WOAppFrame.swift
//  WanWo
//
//  环 3 —— 三栏框架（细读文档第 2 章 AppFrame.tsx 218 行 + AppFrame.module.css 119 行）。
//  grid 三列 / 0.3s 唯一曲线过渡（拖拽时关）/ DragHandle 8px 命中带 + details 浮动把手 /
//  narrow<1024 断点 / 切会话自动关详情 / 0 宽 details 不卸载 / overlay 层 z20 点击穿透。
//

import SwiftUI

public struct WOAppFrame<Sidebar: View, Center: View, Details: View, Overlay: View>: View {
    @ObservedObject public var store: WOLayoutStore
    /// 会话是否「非 blank」——false/nil 时详情栏不算开（blank 会话不算，手册 571 行）
    public var hasDetailsSession: Bool
    @ViewBuilder public var sidebar: (_ collapsed: Bool, _ width: CGFloat) -> Sidebar
    @ViewBuilder public var center: () -> Center
    @ViewBuilder public var details: () -> Details
    /// shell.overlay 槽（z20 点击穿透层；条目各自 opt-in pointer events）
    @ViewBuilder public var overlayLayer: () -> Overlay

    /// 切会话自动关详情：上一个非空会话消失时触发（手册 572 行）
    @State private var lastHadSession = false

    public init(store: WOLayoutStore, hasDetailsSession: Bool = false,
                @ViewBuilder sidebar: @escaping (_ collapsed: Bool, _ width: CGFloat) -> Sidebar,
                @ViewBuilder center: @escaping () -> Center,
                @ViewBuilder details: @escaping () -> Details,
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
                .onAppear { store.setNarrow(viewport < WOLayoutContract.autoCollapseBreakpoint) }
                .onChange(of: viewport) { w in
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
        // 0.42s 唯一曲线（原型拍板，覆盖 dsh 0.3；2026-09-19 真机反馈）。
        let motion = WOMotion.bezier(duration: 0.42)

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
                    // 右栏入口 fab（codex 右上开关语义；digest-H fab 规格：
                    // 32px 圆角 9 玻璃白 .9+blur）：details 关闭时显示
                    if cols.details == 0 {
                        Button { store.openDetails() } label: {
                            Image(systemName: "sidebar.trailing")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(WOAlias.labelSecondary)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(WOStatic.neutral00.opacity(0.9)))
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                        .padding(.top, 12)
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
        // 拖拽手柄移除（2026-09-21 用户令：左右栏拖拽调宽在触屏太难用，禁用；
        // 宽度=契约默认固定，开合只走 toggle）。栏宽动画保留。
        .modifier(WOColumnsAnimation(motion: motion, key: WOColumnsKey(sidebar: cols.sidebar, details: cols.details)))
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
