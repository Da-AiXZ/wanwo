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
    /// 当前是否选中会话（批10：全屏折算门从 hasDetailsSession 改为本值——
    /// blank 会话期间全屏不再"隐身/复活挤压"；右栏本体由 detailsRegion 恒挂载。
    /// 批12：详情列宽门与自动关卡也统一改绑本值——blank 会话开右栏=400 正常
    /// 列、点"缩小"回 400 不再整个消失（hasDetails 门下 effectiveDetails=0
    /// 是"点缩小=直接关闭"的真根因）；无会话仍自动关+列宽 0）。
    public var hasSession: Bool
    /// 右栏全屏（批10：真值=WorkspaceRightSidebarModel.isFullscreen 直连，
    /// layout.fullscreen 投影退役——双记账脱钩是"点开变全屏还关不掉"根因）
    public var fullscreen: Bool
    @ViewBuilder public var sidebar: (_ collapsed: Bool, _ width: CGFloat) -> Sidebar
    @ViewBuilder public var center: () -> Center
    @ViewBuilder public var details: () -> Details
    /// shell.overlay 槽（z20 点击穿透层；条目各自 opt-in pointer events）
    @ViewBuilder public var overlayLayer: () -> Overlay

    /// 切会话自动关详情：上一个会话消失时触发（手册 572 行；批12 绑 hasSession）
    @State private var lastHadSession = false

    public init(store: WOLayoutStore,
                hasSession: Bool = false, fullscreen: Bool = false,
                @ViewBuilder sidebar: @escaping (_ collapsed: Bool, _ width: CGFloat) -> Sidebar,
                @ViewBuilder center: @escaping () -> Center,
                @ViewBuilder details: @escaping () -> Details,
                overlayLayer: @escaping () -> Overlay = { EmptyView() }) {
        self.store = store
        self.hasSession = hasSession
        self.fullscreen = fullscreen
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
        hasSession ? store.details : 0
    }

    public var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            // 批B3（返工：IIFE 包裹——ViewBuilder 闭包内 var+条件重赋值会被
            // result builder transform 按 View 约束处理，Void 不满足 View，
            // 有编译风险；IIFE 让 builder 只看到一个 let 声明）：
            // 全屏 = 同一面板向左延伸占满（原型 303 行 .app.right-full
            // .sidebar-right{flex:1} + .right-full .main{flex:0 0 0}）——求列后
            // 覆写折算，WOColumnSolver.compute 纯函数语义不动（无测试改动）。
            // 左栏保留（56 轨或偏好宽），主区收 0。列宽变化仍走
            // WOColumnsAnimation 0.42s 单 modifier（不换根，GeometryReader 全程在树）。
            let cols: WOColumns = {
                var c = WOColumnSolver.compute(
                    viewport: viewport,
                    sidebar: sidebarCollapsed ? WOLayoutContract.sidebarCollapsed : sidebarPreference,
                    details: effectiveDetails)
                // 批10：折算门从 hasDetailsSession 改为 hasSession（blank 会话
                // 期间全屏不再"隐身/复活挤压"——真机反馈 2026-09-22）；真值=
                // 入参 fullscreen（WorkspaceRightSidebarModel.isFullscreen 直连）。
                // 批15f：此处的 RightRailDiag.event 删除——折算分支位于
                // GeometryReader body 求值热路径（动画期间每帧多次求值），
                // 每次求值写日志（文件+NSLog+UserDefaults）引发重算/IO 风暴，
                // 主线程被淹没 → scene-update watchdog 10s 击杀（.ips 实证
                // "exhausted real (wall clock) time allowance of 10.00 seconds"，
                // 日志 4043 条中同一秒数百条"折算触发"）。诊断一律不得挂热路径。
                if fullscreen, hasSession {
                    c = WOColumns(sidebar: c.sidebar,
                                  center: 0,
                                  details: max(0, viewport - c.sidebar))
                }
                return c
            }()

            colsContent(cols, viewport: viewport)
                .onAppear { store.setNarrow(viewport < WOLayoutContract.autoCollapseBreakpoint) }
                .onChange(of: viewport) { w in
                    store.setNarrow(w < WOLayoutContract.autoCollapseBreakpoint)
                }
                .onChange(of: hasSession) { has in
                    // 会话消失且上一个有会话 → 自动关详情（手册 572 行；批12
                    // 从 hasDetailsSession 改绑 hasSession——blank 会话不再
                    // 半路把已开的右栏列宽打 0 造成"隐形/点缩小=关闭"）。
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
            // 批C1：右栏 fab 退役——右栏开关唯一入口=顶栏钮（WOConversationHead）。
            // 批10 修复：中栏改固定轨道宽（dsh grid 三列轨道语义）——原 maxWidth∞
            // 无锁宽，列内宽内容（长统计行/长标题等）把中栏顶大 → HStack 总宽
            // 超 viewport 被居中裁切 → 左栏出屏+右栏 topBar 钮出屏（真机
            // IMG_2404/2406："右栏向左展开挤开一切"）。width=cols.center 由
            // 让位链契约给出（全屏折算 center=0 时 width 0，clipped 收口）。
            center()
                .frame(width: cols.center)
                .frame(maxHeight: .infinity)
                .clipped()

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
