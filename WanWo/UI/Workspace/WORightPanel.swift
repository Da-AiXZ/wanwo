//
//  WORightPanel.swift
//  WanWo
//
//  【批 2a-1 修 2（2026-10-18 用户真机反馈十项）· 语义源 = 右侧栏原型.html
//  + codex 截图规范（用户逐条拍板）】在 2c83da6 骨架上的修正批：
//    1. 收起/展开动画补原型同款两属性（原型 :98-113 逐行对照）：layout→hidden
//       时内容 opacity→0（0.3s 先完成）+ offset→28px（0.42s 与列宽同步）——
//       列宽压缩重排被淡出掩盖（此前只有 width 一个属性，内容全程可见地被
//       挤压重排 = 用户指认的"由一排到一列怪重排"）；展开反向。
//    2. launcher 交错浮入真正生效：details 列恒挂载 → onAppear 在不可见时
//       已播完——改 epoch 门：右栏每次 hidden→可见，行 id 重建、onAppear
//       重触发；itemIn 本体改两帧法（onAppear 同帧提交被首帧吞，Motion.swift）。
//    3. bar 布局（codex 截图规范）：空态只有全屏+关闭贴右（无 +）；+ 仅页签态
//       出现、跟随末签右侧；bar 下分隔线删除（原型 border 做错了）。
//    4. 页签 chip：Button 化+woPressable 按压（0.97）；× 热区 44→30（误触修复）；
//       水平 padding 加宽。
//    5. + 打开同类页签恒新开（options.forceNew——推翻单例复用；AI 联动/file
//       深链仍复用，见 WOWorkspaceStore）。
//    6. 新开页签自动滚到可见（ScrollViewReader anchor .trailing）；两端渐隐改
//       覆盖式常显（溢出时双端白渐变 overlay——不依赖滚动 offset 追踪）。
//    7. 「+」pop 逐值对齐原型 :294-327：min-width 190 / 描边 borderL2(10%) /
//       阴影 y22+3 / 出场 translateY(-8)+scale(.975) 浮出 / 行图标 15px；
//       锚定 + 钮正下方（tabs 宽 + 右缘钳制）。
//  六页签内容零改动；ZStack 保活；WOAppFrame 三栏契约不碰。
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
    /// 收起视觉（原型 .panel closed 态同款）双时钟：淡出 0.2s easeOut（比列宽
    /// 0.42 快一半，压缩前段内容即消失）+ 右移 28px 与列宽 rail 同曲线同步。
    /// （修2 二轮：v1 的 .animation(value:) 链真机无感——改 onChange 内
    /// withAnimation 显式事务 + fade/slide 拆双 state 各配时长。）
    @State private var collapseFade = false
    @State private var collapseSlide = false
    /// launcher 交错重播代数（hidden→可见时 +1，行 id 重建、onAppear 重触发）。
    @State private var launcherEpoch = 0
    /// 页签条内容宽（溢出渐隐判定 + pop 锚定基准）。
    @State private var tabContentWidth: CGFloat = 0
    /// 页签条可视宽（溢出判定）。
    @State private var tabViewportWidth: CGFloat = 0
    /// 面板宽（pop 右缘钳制）。
    @State private var panelWidth: CGFloat = 0

    /// 是否溢出（页签条内容宽 > 可视宽）。
    private var tabsOverflow: Bool { tabContentWidth > tabViewportWidth + 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            panelContent
        }
        .background(WOAlias.bgBase)
        // 宽度交给父级列（details 契约 400 / 全屏 viewport——旧件批B3 语义保留）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelWidthReader)
        // 【修 2-1】原型 .panel closed 态同款：淡出（0.2s，列宽前半段内容即
        // 消失）+ 右移 28px（0.42s 与列宽 rail 同曲线）——压缩重排被掩盖。
        .opacity(collapseFade ? 0 : 1)
        .offset(x: collapseSlide ? 28 : 0)
        // 「+」弹出菜单（锚定 + 钮正下方；右缘钳制）。
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
        .onChange(of: sessionState.layout) { newLayout in
            // 【修 2-1】收起视觉状态机（withAnimation 显式事务——.animation(value:)
            // 链真机无感的修正）+ 【修 2-2】launcher 重播门。
            let nowHidden = (newLayout == .hidden)
            if nowHidden != collapseFade || nowHidden != collapseSlide {
                withAnimation(.easeOut(duration: 0.2)) { collapseFade = nowHidden }
                withAnimation(WOMotion.bezier(duration: WOMotion.sidebarRailDuration)) {
                    collapseSlide = nowHidden
                }
            }
            if newLayout != .hidden { launcherEpoch += 1 }
        }
        .onAppear {
            store.updateReviewAvailability(
                sessionId: Self.sessionID(of: environment.selection),
                workspacePath: environment.guestWorkspacePath(
                    for: Self.sessionID(of: environment.selection) ?? ""))
            collapseFade = (sessionState.layout == .hidden)
            collapseSlide = collapseFade
        }
    }

    /// 当前选中会话 id（各页签数据锚；旧件同名静态的调用方=页签内容视图）。
    static func sessionID(of selection: RootSelection) -> String? {
        if case .session(let id) = selection { return id }
        return nil
    }

    /// 面板宽 preference 源（pop 右缘钳制用）。
    private var panelWidthReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: WOPanelWidthKey.self, value: geo.size.width)
        }
        .onPreferenceChange(WOPanelWidthKey.self) { panelWidth = $0 }
    }

    // MARK: - 顶栏 bar（codex 截图规范：空态两钮贴右；页签态 tabs+add 在左）

    private var topBar: some View {
        HStack(spacing: 0) {
            if !sessionState.tabs.isEmpty {
                tabBar
                addButton
            }
            Spacer(minLength: 8) // 弹性空隙（无页签时把两钮推到右缘）
            fullscreenButton
            closeButton
        }
        .padding(.horizontal, 8)
        .frame(height: 48) // 原型 tabs padding 6×2 + tab 36 = 48
        .background(WOAlias.bgBase)
        // 分隔线删除（2026-10-18 用户拍板：codex 全屏/关闭下方无分隔）。
        .zIndex(2)
    }

    // MARK: 页签条（弹性区；溢出覆盖式渐隐 + 新签自动滚入）

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessionState.tabs) { tab in
                        tabChip(tab)
                            .id(tab.id)
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: WOTabContentWidthKey.self,
                                           value: g.size.width)
                })
            }
            // 【修 3】tabBar 宽度=页签内容宽（不吞弹性空间）——「+」因此紧贴
            // 末签右侧（此前 ScrollView 弹性全宽把 + 推到右缘）；超可用宽时
            // 收缩为可用宽（chips 滚动）。
            .frame(width: min(tabContentWidth + 1,
                              max(panelWidth - 156, 60)))
            // 【修 7】溢出两端渐隐——mask 让 chips 自身在端头淡出（白罩在白
            // 底 chips 上无对比已废；对话标题栏/dock 渐隐同族的独立罩对白底
            // 无效，故回 mask 语义、静态双端、溢出判定保留）。
            .mask {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let stops: [Gradient.Stop] = tabsOverflow
                        ? [Gradient.Stop(color: .clear, location: 0),
                           Gradient.Stop(color: .black, location: min(14 / w, 0.4)),
                           Gradient.Stop(color: .black, location: max((w - 18) / w, 0.6)),
                           Gradient.Stop(color: .clear, location: 1)]
                        : [Gradient.Stop(color: .black, location: 0),
                           Gradient.Stop(color: .black, location: 1)]
                    Rectangle().fill(LinearGradient(stops: stops,
                                                    startPoint: .leading,
                                                    endPoint: .trailing))
                }
            }
            .onPreferenceChange(WOTabContentWidthKey.self) { tabContentWidth = $0 }
            .onPreferenceChange(WOTabViewportKey.self) { tabViewportWidth = $0 }
            // 【修 2-6】新开页签自动滚到可见（新签露出、旧签挤左——用户拍板）。
            .onChange(of: sessionState.tabs) { tabs in
                if let last = tabs.last {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            }
        }
    }

    // MARK: 页签 chip（原型 :139-169；Button 化+按压；× 热区 30）

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == sessionState.activeTabID
        let label = tabChipTitle(tab)
        // 原型 .bar-tabs.fit：放得下时解除宽度上限（单签完整标题）。
        let maxWidth: CGFloat? = sessionState.tabs.count == 1 ? nil : 190
        return Button {
            store.activateTab(sessionId: sessionId, tabId: tab.id)
        } label: {
            HStack(spacing: 8) {
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
                        .contentShape(Rectangle().size(width: 25, height: 25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭" + label + "页签")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(isActive ? WOStatic.panelTabActiveBg : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isActive ? WOStatic.panelInk55 : Color.clear, lineWidth: 1))
            .shadow(color: Color.black.opacity(isActive ? 0.04 : 0), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .woPressable()
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

    /// launcher（原型 :229-255；五入口垂直居中 + kbd 徽标 + 交错入场；
    /// epoch 门：右栏每次展开行 id 重建 → 交错在可见时机重播）。
    private var launcher: some View {
        let kinds = store.candidateKinds()
        return VStack(spacing: 2) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                Button {
                    WOWorkspaceOpenRouter.open(.init(
                        sessionId: sessionId,
                        target: .singleton(kind),
                        options: .init(forceNew: true)))
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
                                // 原型 .kbd 独立 cardIn——delay 提至 0.5：
                                // 列宽展开（0.42s）大半完成后行内容才揭示，
                                // 浮入动画须在可见窗口内播（v1 base 0.19 时
                                // 行主体被列宽揭示淹没只有 kbd 可见的教训）。
                                .woItemIn(index: index, step: 0.072, base: 0.5)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .woPressable()
                // epoch 变化 → 行 id 变化 → 视图重建 → woItemIn onAppear 重播
                //（恒挂载下 onAppear 只在首挂载触发的根治）；delay 0.35 起——
                // 列宽展开 83% 后行区域已揭示，浮入全程可见（真机反馈"只有
                // kbd 有动画"=行浮入被列宽揭示淹没的修正）。
                .id(kind.rawValue + "-e" + String(launcherEpoch))
                .woItemIn(index: index, step: 0.072, base: 0.35)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    // MARK: - 「+」弹出菜单（原型 pop :294-327 逐值对齐）

    /// pop 锚定 x：+ 钮正下方 = 水平 padding 8 + tabs 内容宽 + 间距 4；
    /// 右缘钳制（浮层 minWidth 190 预留）。
    private var addMenuAnchorX: CGFloat {
        let natural = tabContentWidth + 20
        let maxLeading = max(panelWidth - 230, 8)
        return min(natural, maxLeading)
    }

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
                            target: .singleton(kind),
                            options: .init(forceNew: true)))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.iconName)
                                .font(.system(size: 15))
                                .foregroundColor(WOAlias.labelSecondary)
                                .opacity(0.75)
                                .frame(width: 19)
                            Text(kind.title)
                                .font(.system(size: 13.5))
                                .foregroundColor(WOAlias.labelPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .woPressable()
                    .woItemIn(index: index, step: 0.026, base: 0.04)
                }
            }
            .padding(5)
            // 定宽 190（原型 min-width 190 的触屏恒定形态；此前 minWidth 无
            // 上限被行内 Spacer 撑宽=用户反馈"太宽"）。
            .frame(width: 190, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(WOAlias.bgBase))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(WOAlias.borderL2, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.16), radius: 25, y: 11)
            .shadow(color: Color.black.opacity(0.07), radius: 5, y: 1.5)
            // 原型 .pop.open 出场形态：translateY(-8)+scale(.975) 浮出（顶部锚点）。
            .scaleEffect(showAddMenu ? 1 : 0.975, anchor: .top)
            .offset(y: showAddMenu ? 0 : -8)
            .opacity(showAddMenu ? 1 : 0)
            .animation(WOMotion.bezier(duration: 0.42), value: showAddMenu)
            .padding(.leading, addMenuAnchorX)
            .padding(.top, 50)
        }
    }
}

// MARK: - preference keys（页签条溢出追踪 + pop 钳制）

private struct WOTabContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WOTabViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WOPanelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 悬浮把手（原型 .handle :183-199 + :1021-1026）

/// 右栏收起态的打开入口（与原型同款：视口右上 14/14、44px、白 86% 毛玻璃、
/// r10、边 1px、阴影 0 8 24 10%；入场 scale .7 + translateX 10 → none）。
/// 挂载点 = WORootFrame mainFrame 外层 overlay（收起态 details 列禁触门禁
/// 在外，把手必须活在其外；WOAppFrame overlayLayer 槽整体禁触不可用）。
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
                    .fill(WOAlias.panelHandleBg)
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
            // 两帧法（同 WOItemInModifier——onAppear 同帧提交被首帧吞）。
            DispatchQueue.main.async {
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.15)) { shown = true }
                } else {
                    withAnimation(WOMotion.bezier(duration: WOMotion.panelHandleIn)) {
                        shown = true
                    }
                }
            }
        }
        // 移除时对称退场（transition 挂 condition 翻转——宿主侧 if 条件）。
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(.easeIn(duration: 0.15))))
    }
}