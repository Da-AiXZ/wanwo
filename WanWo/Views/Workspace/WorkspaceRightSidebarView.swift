//
//  WorkspaceRightSidebarView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.0/§6.6a】右侧边栏视图：
//    · 顶部两钮：全屏（右侧栏占满整窗，左栏由 RootView 折叠）+ 收起/展开；
//    · 顶部页签条：多页签混开 + 每页签 × 关闭 + 「+」菜单五项新开
//      （审查/git 项目第一位，文件/侧聊/浏览器/终端随后——§6.5 排序 + 派单口径）；
//    · 页签内容路由：文件/终端/浏览器/侧聊/审查五视图。
//  UI 形态全新 SwiftUI（A.8 口径：OpenMinis Views 不复用，只对齐形态）。
//

import SwiftUI

struct WorkspaceRightSidebarView: View {
    @ObservedObject var model: WorkspaceRightSidebarModel
    @ObservedObject var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !model.tabs.isEmpty {
                tabStrip
            }
            Divider()
            content
        }
        .background(Color(.systemBackground))
        .frame(maxWidth: model.isFullscreen ? .infinity : WorkspaceRightSidebarModel.expandedWidth,
               maxHeight: .infinity)
        .frame(width: model.isFullscreen ? nil : WorkspaceRightSidebarModel.expandedWidth)
        // 页签随会话切换刷新「审查」入口（git 仓库项目才显示）。
        .onChange(of: environment.selection) { selection in
            model.updateReviewAvailability(sessionID: Self.sessionID(of: selection))
        }
        .onAppear {
            model.updateReviewAvailability(sessionID: Self.sessionID(of: environment.selection))
        }
    }

    /// 当前选中会话 id（各页签的数据锚：终端/文件/审查/侧聊挂当前会话）。
    static func sessionID(of selection: RootSelection) -> String? {
        if case .session(let id) = selection { return id }
        return nil
    }

    // MARK: - 顶部条（全屏 + 收起）

    private var topBar: some View {
        HStack(spacing: 4) {
            Text("工作区")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isFullscreen.toggle()
                }
            } label: {
                Image(systemName: model.isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.isFullscreen ? "退出全屏" : "全屏")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isExpanded = false
                    model.isFullscreen = false
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("收起侧栏")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 页签条（多页签混开 + × + 「+」菜单）

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    tabChip(tab)
                }
                plusMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == model.activeTabID
        return HStack(spacing: 4) {
            Image(systemName: tab.kind.iconName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tab.kind.title)
                .font(.caption)
                .lineLimit(1)
            Button {
                model.close(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭\(tab.kind.title)页签")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill),
                    in: Capsule())
        .overlay(Capsule().stroke(isActive ? Color.accentColor.opacity(0.4) : .clear,
                                  lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { model.activeTabID = tab.id }
    }

    /// 「+」= 弹出菜单五项新开（codex 词汇；审查仅 git 项目时入列）。
    private var plusMenu: some View {
        Menu {
            ForEach(model.menuKinds(), id: \.self) { kind in
                Button {
                    model.openFromMenu(kind)
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
    /// ForEach 移除而释放）。
    @ViewBuilder
    private var content: some View {
        if model.tabs.isEmpty {
            emptyTabsState
        } else {
            ZStack {
                ForEach(model.tabs) { tab in
                    tabContent(tab)
                        .opacity(tab.id == model.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == model.activeTabID)
                        .accessibilityHidden(tab.id != model.activeTabID)
                }
            }
        }
    }

    /// 单页签内容路由（原 content 的 switch 体，视图种类不变）。
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
            WorkspaceBrowserTabView(initialURL: tab.initialURL,
                                    environment: environment)
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
    /// 图标+名称+快捷键提示位；候选与「+」菜单同源——审查=git 项目时入列，
    /// 【批2 2C】轨迹页签随 menuKinds 口径入列）。原「+」菜单空态撤除
    /// （plusMenu 仍保留在页签条）。
    private var emptyTabsState: some View {
        VStack(spacing: 16) {
            Text("打开一个页签")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(WorkspaceRightSidebarModel.candidateKinds(
                    reviewAvailable: model.reviewAvailable), id: \.self) { kind in
                    Button {
                        model.openFromMenu(kind)
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
