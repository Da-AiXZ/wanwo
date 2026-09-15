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

    @ViewBuilder
    private var content: some View {
        if model.tabs.isEmpty {
            emptyTabsState
        } else if let tab = model.activeTab {
            switch tab.kind {
            case .files:
                WorkspaceFileTabView(environment: environment)
            case .terminal:
                WorkspaceTerminalTabView(environment: environment)
            case .browser:
                WorkspaceBrowserTabView(initialURL: tab.initialURL)
            case .sideChat:
                SideChatView(environment: environment,
                             parentSessionID: Self.sessionID(of: environment.selection))
            case .review:
                ReviewTabView(environment: environment)
            }
        } else {
            emptyTabsState
        }
    }

    /// 空页签态（「+」新开引导；词汇对齐 codex 新标签语义）。
    private var emptyTabsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("从「+」打开文件、终端、浏览器或侧边聊天")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            plusMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
