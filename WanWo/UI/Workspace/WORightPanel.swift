//
//  WORightPanel.swift
//  WanWo
//
//  【批 2a-1 右栏骨架重做（2026-10-18 用户拍板「除侧聊 dock 外全部按原型」）】
//  语义源 = 右侧栏原型.html 逐段（行号锚点见各节）+ 旧 WorkspaceRightSidebarView
//  的路由/状态语义整建搬迁（六页签内容零改动；ZStack 全量挂载保活语义保留）。
//  状态源不变 = WOWorkspaceStore（hidden/split/full 三态恰对应原型
//  closed/normal/full——launcher 是 tabs 空态的面板内容，不是独立 mode）。
//  本体替代旧视图成为 WORootFrame detailsRegion 挂载件；旧视图暂留防回退
//  （零引用态，收官批随 C 层清理删除）。
//
//  原型规格锚点（右侧栏原型.html）：
//    · bar     :990-1016  [tabs 弹性 | + 44 | gap | 全屏 44 交叉淡入 | 关闭 44]
//    · tab     :139-169   高 36 / r9 / max 190 / 字 12.5 / 图标 op .72→1 /
//                × 22 视觉+44 热区 / active #f1f1f3+边 5.5%+影 0 1 2 4%
//    · 渐隐    :127-133   溢出方向 mask 渐隐 14/18px（VS Code 式）
//    · launcher:229-255   垂直居中 / 行 16px 竖 padding / 字 14.5 /
//                kbd 徽标 11 mono / itemIn 交错 72ms+90ms
//    · pop     :294-327   r12 / 边 10% / 阴影 0 22 50 16% / 行交错 26ms+40ms
//  动效三式（paneIn/itemIn/把手入场）在 Motion.swift「右栏三式」节。
//

import SwiftUI

struct WORightPanel: View {
    /// 工作台状态机（不变——与旧挂载件同一状态源）。
    @ObservedObject var store: WOWorkspaceStore
    @ObservedObject var environment: AppEnvironment
    let sessionId: String

    /// 本会话工作台状态（store 按会话作用域的便捷投影）。
    private var sessionState: WOWorkspaceSessionState { store.state(for: sessionId) }

    /// 「+」弹出菜单（原型 addBtn → pop 浮层）。
    @State private var showAddMenu = false

    // 页签条溢出追踪（动态渐隐 mask 的输入）。
    @State private var tabScrollOffset: CGFloat = 0
    @State private var tabContentWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            panelContent
        }
        .background(WOAlias.bgBase)
        // 宽度交给父级列（details 契约 400 / 全屏 viewport——旧件批B3 语义保留）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 「+」弹出菜单（挂 panel 左上垂下；锚定近似点见 addMenuOverlay 注）。
        .overlay(alignment: .topLeading) { addMenuOverlay }
        // 弹层开着时点面板任意处先收弹层（pop 语义：浮层外即 dismiss）。
        .contentShape(Rectangle())
        .onTapGesture {
            if showAddMenu {
                withAnimation(WOMotion.bezier(duration: WOMotion.t2)) {
                    showAddMenu = false
                }
            }
        }
        // 页签随会话切换刷新「审查」入口（旧件语义原样搬迁）。
        .onChange(of: environment.selection) { selection in
            store.updateReviewAvailability(
                sessionId: Self.sessionID(of: selection),
                workspacePath: environment.guestWorkspacePath(
                    for: Self.sessionID(of: selection) ?? ""))
        }
        .onAppear {
            store.updateReviewAvailability(
                sessionId: Self.sessionID(of: environment.selection),
                workspacePath: environment.guestWorkspacePath(
                    for: Self.sessionID(of: environment.selection) ?? ""))
        }
    }

    /// 当前选中会话 id（各页签数据锚；旧件同名静态的调用方=页签内容视图，
    /// 本体保留同签名供它们继续消费）。
    static func sessionID(of selection: RootSelection) -> String? {
        if case .session(let id) = selection { return id }
        return nil
    }

    // MARK: - 顶栏 bar（原型 :990-1016）

    private var topBar: some View {
        HStack(spacing: 0) {
            tabBar
            addButton
            Spacer(minLength: 8) // 原型 .bar-gap（flex:1, min-width:8）
            fullscreenButton
            closeButton
        }
        .padding(.horizontal, 8)
        .frame(height: 48) // 原型 tabs padding 6×2 + tab 36 = 48
        .background(WOAlias.bgBase)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WOStatic.panelInk55).frame(height: 1)
        }
        .zIndex(2)
    }

    // MARK: 页签条（弹性区；溢出方向渐隐）

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessionState.tabs) { tab in
                    tabChip(tab)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: WOTabContentWidthKey.self,
                                       value: g.size.width)
            })
            .background(GeometryReader { g in
                Color.clear.preference(key: WOTabScrollOffsetKey.self,
                                       value: g.frame(in: .named("woTabStrip")).minX)
            })
        }
        .coordinateSpace(name: "woTabStrip")
        .onPreferenceChange(WOTabContentWidthKey.self) { tabContentWidth = $0 }
        .onPreferenceChange(WOTabScrollOffsetKey.self) { tabScrollOffset = $0 }
        // 溢出两端渐隐（原型 mask 14/18px；仅溢出方向淡出）。
        .mask {
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(stops: tabFadeStops(width: geo.size.width),
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
    }

    /// 渐隐 mask 停靠点（原型 --fade-l 14 / --fade-r 18；未溢出=全显）。
    private func tabFadeStops(width: CGFloat) -> [Gradient.Stop] {
        let safeWidth = max(width, 1)
        let overflow = tabContentWidth > safeWidth + 1
        if !overflow {
            let solid = Gradient.Stop(color: .black, location: 0)
            let solidEnd = Gradient.Stop(color: .black, location: 1)
            return [solid, solidEnd]
        }
        let maxOffset = tabContentWidth - safeWidth
        let fadeL: CGFloat = tabScrollOffset < -1 ? 14 : 0
        let fadeR: CGFloat = tabScrollOffset > maxOffset + 1 ? 0 : 18
        var stops: [Gradient.Stop] = []
        var leftEdge: CGFloat = 0
        if fadeL > 0 {
            leftEdge = min(fadeL / safeWidth, 0.45)
            stops.append(Gradient.Stop(color: .clear, location: 0))
            stops.append(Gradient.Stop(color: .black, location: leftEdge))
        } else {
            stops.append(Gradient.Stop(color: .black, location: 0))
        }
        if fadeR > 0 {
            let rightStart = max((safeWidth - fadeR) / safeWidth, leftEdge + 0.01)
            stops.append(Gradient.Stop(color: .black, location: rightStart))
            stops.append(Gradient.Stop(color: .clear, location: 1))
        } else {
            stops.append(Gradient.Stop(color: .black, location: 1))
        }
        return stops
    }

    // MARK: 页签 chip（原型 :139-169）

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == sessionState.activeTabID
        let label = tabChipTitle(tab)
        // 原型 .bar-tabs.fit：放得下时解除宽度上限（单签完整标题）。
        let maxWidth: CGFloat? = sessionState.tabs.count == 1 ? nil : 190
        return HStack(spacing: 6) {
            Image(systemName: tab.kind.iconName)
                .font(.system(size: 12))
                .foregroundColor(isActive ? WOAlias.labelPrimary : WOAlias.labelSecondary)
                .opacity(isActive ? 1 : 0.72)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(isActive ? WOAlias.labelPrimary : WOAlias.labelSecondary)
                .lineLimit(1)
                .frame(maxWidth: maxWidth, alignment: .leading)
            Button {
                store.closeTabs(sessionId: sessionId, tabId: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(WOAlias.labelTertiary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.clear))
                    .contentShape(Rectangle().size(width: 44, height: 44))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭" + label + "页签")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(isActive ? WOStatic.panelTabActiveBg : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(isActive ? WOStatic.panelInk55 : Color.clear, lineWidth: 1))
        .shadow(color: Color.black.opacity(isActive ? 0.04 : 0), radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture {
            store.activateTab(sessionId: sessionId, tabId: tab.id)
        }
    }

    /// 页签标题（旧件语义搬迁：浏览器=回写标题 → host → kind 词汇）。
    private func tabChipTitle(_ tab: WorkspaceTab) -> String {
        if tab.kind == .browser {
            if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty { return title }
            if let host = tab.url?.host, !host.isEmpty { return host }
        }
        return tab.kind.title
    }

    // MARK: bar 右端三钮（+ / 全屏交叉淡入 / 关闭）

    private var addButton: some View {
        Button {
            withAnimation(WOMotion.bezier(duration: WOMotion.t2)) {
                showAddMenu.toggle()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(WOAlias.labelSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel("打开新标签页")
    }

    /// 全屏钮（原型 fs-ico 两组图标交叉淡入，:998-1009）。
    private var fullscreenButton: some View {
        let isFull = sessionState.layout == .full
        return Button {
            store.toggleFullscreen(sessionId: sessionId)
        } label: {
            ZStack {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .opacity(isFull ? 1 : 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .opacity(isFull ? 0 : 1)
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(WOAlias.labelSecondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel(isFull ? "退出全屏" : "全屏")
    }

    private var closeButton: some View {
        Button {
            store.setLayout(.hidden, sessionId: sessionId)
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 17))
                .foregroundColor(WOAlias.labelSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel("关闭面板")
    }

    // MARK: - 面板内容（launcher 空态 / 页签保活路由）

    @ViewBuilder
    private var panelContent: some View {
        if sessionState.tabs.isEmpty {
            launcher
        } else {
            ZStack {
                ForEach(sessionState.tabs) { tab in
                    let isActive = tab.id == sessionState.activeTabID
                    tabContent(tab)
                        .woPaneIn(isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                }
            }
        }
    }

    /// launcher（原型 :229-255；五入口垂直居中 + kbd 徽标 + 交错入场）。
    private var launcher: some View {
        let kinds = store.candidateKinds()
        return VStack(spacing: 2) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                Button {
                    WOWorkspaceOpenRouter.open(.init(
                        sessionId: sessionId,
                        target: .singleton(kind)))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.iconName)
                            .font(.system(size: 15))
                            .foregroundColor(WOAlias.labelSecondary)
                            .opacity(0.8)
                            .frame(width: 20)
                        Text(kind.title)
                            .font(.system(size: 14.5))
                            .foregroundColor(WOAlias.labelPrimary)
                        Spacer(minLength: 0)
                        if let hint = kbdHint(kind) {
                            Text(hint)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(WOAlias.labelSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(WOStatic.panelInk55))
                                // 原型 .kbd 独立 cardIn（delay i*72+190ms）——
                                // 比宿主行（90ms）晚 100ms 浮入。
                                .woItemIn(index: index, step: 0.072, base: 0.19)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .woPressable()
                .woItemIn(index: index)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // tabs 清空→launcher 重现：if/else 分支切换=identity 重置，行
        // onAppear 每次重播交错（与原型 DOM 重建语义一致）。
        .id("wo-launcher")
    }

    /// kbd 徽标文案（原型 :1545-1549 原字面；trajectory 原型无此项，留空）。
    private func kbdHint(_ kind: WorkspaceTabKind) -> String? {
        switch kind {
        case .files: return "Ctrl+P"
        case .sideChat: return "Ctrl+Alt+S"
        case .browser: return "Ctrl+T"
        case .terminal: return "Ctrl+`"
        case .review: return "Ctrl+Shift+G"
        case .trajectory: return nil
        }
    }

    // MARK: 单页签路由（旧件 tabContent 语义原样搬迁——六页签内容零改动）

    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .files:
            WorkspaceFileTabView(environment: environment)
        case .terminal:
            WorkspaceTerminalTabView(environment: environment)
        case .browser:
            WorkspaceBrowserTabView(initialURL: tab.url,
                                    environment: environment,
                                    onNavigationReport: { url, title in
                                        store.updateBrowserTab(sessionId: sessionId,
                                                               tabId: tab.id,
                                                               url: url, title: title)
                                    })
        case .sideChat:
            SideChatView(environment: environment,
                         parentSessionID: Self.sessionID(of: environment.selection))
        case .review:
            ReviewTabView(environment: environment)
        case .trajectory:
            TrajectoryTabView(environment: environment,
                              sessionID: Self.sessionID(of: environment.selection))
        }
    }

    // MARK: - 「+」弹出菜单（原型 pop :294-327）

    @ViewBuilder
    private var addMenuOverlay: some View {
        if showAddMenu {
            let kinds = store.candidateKinds()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    Button {
                        showAddMenu = false
                        WOWorkspaceOpenRouter.open(.init(
                            sessionId: sessionId,
                            target: .singleton(kind)))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.iconName)
                                .font(.system(size: 14))
                                .foregroundColor(WOAlias.labelSecondary)
                                .opacity(0.75)
                                .frame(width: 18)
                            Text(kind.title)
                                .font(.system(size: 13.5))
                                .foregroundColor(WOAlias.labelPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12.5)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .woPressable()
                    .woItemIn(index: index, step: 0.026, base: 0.04)
                }
            }
            .padding(5)
            .frame(width: 230, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(WOAlias.bgBase))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(WOStatic.panelInk55, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.16), radius: 25, y: 11)
            .shadow(color: Color.black.opacity(0.07), radius: 5, y: 1.5)
            // 锚定近似：+ 钮 x 随 tabs 弹性宽变化，本浮层挂 panel 左上垂下
            //（tabs 通常 0-2 枚，观感差可忽略；精确锚定登记后置）。
            .padding(.leading, 12)
            .padding(.top, 54)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - preference keys（页签条溢出追踪）

private struct WOTabContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WOTabScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 悬浮把手（原型 .handle :183-199 + :1021-1026）

/// 右栏收起态的打开入口（与原型同款：视口右上 14/14、44px、白 86% 毛玻璃、
/// r10、边 1px、阴影 0 8 24 10%；入场 scale .7 + translateX 10 → none）。
/// 挂载点 = WORootFrame overlay 层（details 列宽 0 时仍可见可点——收起态
/// details 列自带禁触门禁，把手必须活在其外）。
struct WORightPanelHandle: View {
    let onOpen: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onOpen()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 16))
                .foregroundColor(WOAlias.labelSecondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(WOStatic.panelHandleBg)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 10)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(WOAlias.borderL2, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel("打开面板")
        .opacity(shown ? 1 : 0)
        .scaleEffect(reduceMotion || shown ? 1 : 0.7)
        .offset(x: reduceMotion || shown ? 0 : 10)
        .onAppear {
            guard !shown else { return }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.15)) { shown = true }
            } else {
                withAnimation(WOMotion.bezier(duration: WOMotion.panelHandleIn)) {
                    shown = true
                }
            }
        }
        // 移除时对称退场（transition 挂 condition 翻转——宿主侧 if 条件）。
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(.easeIn(duration: 0.15))))
    }
}
