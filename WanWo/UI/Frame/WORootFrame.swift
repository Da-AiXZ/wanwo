//
//  WORootFrame.swift
//  WanWo
//
//  环 3 —— 新 UI 根组装：AppFrame + SidebarShell 装配（对应 dsh root 注册语义）。
//  中栏/详情栏为中性占位（内容归环 5 对话区/环 5b 消息流）；工作区树归环 4；
//  设置入口归环 7。旧 RootView 保留至环 8 统一删除（旧 UI 即删拍板：新屏上线即删对应代码）。
//

import SwiftUI

struct WORootFrame: View {
    @StateObject private var layout = WOLayoutStore()
    @StateObject private var viewStore = WOWorkspaceViewStore()
    @EnvironmentObject private var environment: AppEnvironment
    /// 环 4 批 1：列表手动刷新（新建/重命名/删除后触发）；自动跟随事件流归环 5
    @State private var sidebarReloadToken = 0

    var body: some View {
        WOAppFrame(
            store: layout,
            hasDetailsSession: true, // 环 3 骨架期恒 true（否则右栏永远打不开）；环 5 接真实会话信号（blank 会话不算）
            sidebar: { collapsed, width in
                WOSidebarShell(
                    collapsed: collapsed,
                    width: width,
                    onToggleSidebar: { layout.toggleSidebar() },
                    onNewSession: {
                        // 环 4 接 WorkspaceRegistry.startSession（继承当前工作区语义）
                    },
                    region: { wide, quiet in
                        if wide {
                            WOWorkspaceBrowser(
                                viewStore: viewStore,
                                snapshot: {
                                    WOWorkspaceSnapshot(
                                        sessions: environment.sessionStore.listSessions(),
                                        workspaces: environment.workspaceRegistry.list(),
                                        archived: environment.workspaceRegistry.archivedSessionIDs(),
                                        currentSessionId: nil) // 环 5 接当前会话信号
                                },
                                onOpenSession: { sessionId in
                                    // 环 5 接会话打开（sessions.open 语义）
                                    _ = sessionId
                                },
                                onNewSession: { workspaceId in
                                    // 新会话：建 blank + attach 到工作区 + 刷新列表
                                    if let s = try? environment.sessionStore.createSession(cwd: nil) {
                                        if let wsId = workspaceId {
                                            try? environment.workspaceRegistry.attachSession(sessionId: s.id, to: wsId)
                                        }
                                        sidebarReloadToken += 1
                                    }
                                }
                            )
                            .id(sidebarReloadToken)
                        } else {
                            WOSlotPlaceholder(text: nil, quiet: quiet)
                        }
                    },
                    footer: { wide in
                        WOSlotPlaceholder(text: wide ? "设置入口 · 环 7" : nil, quiet: false)
                    }
                )
            },
            center: {
                // 对话区槽：hero/消息流归环 5（跨空态/会话态保持视图身份）
                WOSlotPlaceholder(text: "对话区 · 环 5", quiet: false)
            },
            details: {
                // 详情栏槽：DetailsPanel 归环 5；关闭钮（codex 面板语义，环 3 骨架期唯一关闭入口）
                ZStack(alignment: .topTrailing) {
                    WOSlotPlaceholder(text: "详情栏 · 环 5", quiet: false)
                    Button { layout.closeDetails() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(WOAlias.interactiveBgHover))
                            .foregroundColor(WOAlias.labelSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.top, 14)
                }
            },
            overlayLayer: { EmptyView() }
        )
    }
}

/// 脚手架占位（非设计稿——环 3 出包的可见性标注，后续环逐个替换）
struct WOSlotPlaceholder: View {
    let text: String?
    let quiet: Bool

    var body: some View {
        ZStack {
            WOAlias.bgBase
            if let text {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(WOAlias.labelDimmed)
            }
        }
    }
}
