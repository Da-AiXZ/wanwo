//
//  WorkspaceRightSidebarView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.0/§6.6a】右侧边栏视图。
//  【批12+右栏重构批1（2026-09-27 用户拍板）】状态源换 WOWorkspaceStore
//  （cc-haha workspaceStore 语义 1:1——按会话作用域/复用规则/真删释放/undo
//  撤销/布局三态单值）；视图结构不变：顶部两钮 + 页签条 + 内容路由（ZStack
//  全量挂载保活，批2 B② 语义保留）。全打开动作走 WOWorkspaceOpenRouter。
//

import SwiftUI

struct WorkspaceRightSidebarView: View {
    /// 工作台状态机（cc-haha workspaceStore 语义；App 级单例按会话作用域）。
    @ObservedObject var store: WOWorkspaceStore
    @ObservedObject var environment: AppEnvironment
    let sessionId: String

    /// 本会话工作台状态（store 按会话作用域的便捷投影）。
    private var sessionState: WOWorkspaceSessionState { store.state(for: sessionId) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !sessionState.tabs.isEmpty {
                tabStrip
            }
            Divider()
            content
        }
        .background(Color(.systemBackground))
        // 批B3：去自限宽——宽度完全交给父级列：常规态=details 契约列宽（400），
        // 全屏态=viewport −sidebar（WOAppFrame 求列折算），本视图只纵向撑满。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 页签随会话切换刷新「审查」入口（git 仓库项目才显示）。
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

    /// 当前选中会话 id（各页签的数据锚：终端/文件/审查/侧聊挂当前会话）。
    static func sessionID(of selection: RootSelection) -> String? {
        if case .session(let id) = selection { return id }
        return nil
    }

    // MARK: - 顶部条（全屏 + 关闭；2026-09-21 用户令：两钮加大拉开、
    //  关闭改 ✕ 图标钮。批12+右栏重构批1：真值换布局三态单值）

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("工作区")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    store.toggleFullscreen(sessionId: sessionId)
                }
            } label: {
                Image(systemName: sessionState.layout == .full
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(WOAlias.labelSecondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(WOAlias.interactiveBgHover))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sessionState.layout == .full ? "退出全屏" : "全屏")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.setLayout(.hidden, sessionId: sessionId)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WOAlias.labelSecondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(WOAlias.interactiveBgHover))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭侧栏")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 页签条（多页签混开 + × + 「+」菜单）

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessionState.tabs) { tab in
                    tabChip(tab)
                }
                plusMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == sessionState.activeTabID
        // 批12+右栏重构批1：页签条显示真实标题——浏览器=页标题回写，回落
        // host，再回落 kind 词汇（cc-haha workspaceTabTitle :965-989 语义）。
        let label = tabChipTitle(tab)
        return HStack(spacing: 4) {
            Image(systemName: tab.kind.iconName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 96)
            Button {
                store.closeTabs(sessionId: sessionId, tabId: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭\(label)页签")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill),
                    in: Capsule())
        .overlay(Capsule().stroke(isActive ? Color.accentColor.opacity(0.4) : .clear,
                                  lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { store.activateTab(sessionId: sessionId, tabId: tab.id) }
    }

    /// 页签标题（cc-haha workspaceTabTitle 语义：浏览器=回写标题 → host →
    /// kind 词汇；其余=kind 词汇）。
    private func tabChipTitle(_ tab: WorkspaceTab) -> String {
        if tab.kind == .browser {
            if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty { return title }
            if let host = tab.url?.host, !host.isEmpty { return host }
        }
        return tab.kind.title
    }

    /// 「+」= 弹出菜单新开（codex 词汇；审查仅 git 项目时入列）。
    private var plusMenu: some View {
        Menu {
            ForEach(store.candidateKinds(), id: \.self) { kind in
                Button {
                    WOWorkspaceOpenRouter.open(.init(
                        sessionId: sessionId,
                        target: .singleton(kind)))
                } label: {
                    Label(kind.title, systemImage: kind.iconName)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color(.secondarySystemFill), in: Circle())
        }
    }

    // MARK: - 内容路由

    /// 【批2 B②】页签内容容器——ZStack 全量挂载 + opacity 切换。
    /// 语义源 = dsh ui-layout AppFrame.tsx:35-38「右栏宽 0 时保持挂载不卸载」
    /// 同语义：原 `switch tab.kind` 条件渲染下切页签 = 旧视图销毁重建（浏览器
    /// 网页状态/终端 shell 随切丢）。全量挂载后每页签视图身份稳定（ForEach
    /// id 锚定），隐藏面 opacity 0 + 关 hit-testing + 关辅助功能；页签资源
    /// （BrowserTabPool / 终端 shell）随页签存续、切走不回收（关闭页签才随
    /// ForEach 移除而释放——批12+右栏重构批1：按会话作用域，跨会话不串）。
    @ViewBuilder
    private var content: some View {
        if sessionState.tabs.isEmpty {
            emptyTabsState
        } else {
            ZStack {
                ForEach(sessionState.tabs) { tab in
                    tabContent(tab)
                        .opacity(tab.id == sessionState.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == sessionState.activeTabID)
                        .accessibilityHidden(tab.id != sessionState.activeTabID)
                }
            }
            // 页签切换丝滑淡切（UI 修复批 2：保活 ZStack 的 opacity 跳变 →
            // spring 过渡；全局动画标准 response 0.3 / damping 0.85）。
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: sessionState.activeTabID)
        }
    }

    /// 单页签内容路由（原 content 的 switch 体，视图种类不变；载荷从
    /// WorkspaceTab 取——浏览器页签 url 为导航目标/最近落点）。
    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .files:
            WorkspaceFileTabView(environment: environment)
        case .terminal:
            WorkspaceTerminalTabView(environment: environment)
        case .browser:
            // 【批2 B①】environment 传入——页签内 pool.sessionId 绑定当前选中
            // 会话（下载落盘依赖；原构造无 environment，下载批准后被静默取消）。
            // 批12+右栏重构批1：tab.url 为导航目标，onChange 消费（视图内既
            // 有链）；导航/标题事实回写 store（页签条显示真实标题）。
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
            // 【批2 2C】轨迹页签（dsh ui-trajectory 台账版；锚定当前选中会话）。
            TrajectoryTabView(environment: environment,
                              sessionID: Self.sessionID(of: environment.selection))
        }
    }

    /// 【批3 C③】空态 = 页签列表页（codex 截图 #3 逐字形态：大按钮行 =
    /// 图标+名称+快捷键提示位；候选与「+」菜单同源）。
    private var emptyTabsState: some View {
        VStack(spacing: 16) {
            Text("打开一个页签")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(store.candidateKinds(), id: \.self) { kind in
                    Button {
                        WOWorkspaceOpenRouter.open(.init(
                            sessionId: sessionId,
                            target: .singleton(kind)))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.iconName)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(kind.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            // 快捷键提示位（codex #3 逐字形态；iOS 触屏无
                            // 键盘——占位留空，登记报告）。
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 10,
                                                         style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
