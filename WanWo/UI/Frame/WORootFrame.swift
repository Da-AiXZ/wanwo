//
//  WORootFrame.swift
//  WanWo
//
//  R1 诚实化改造（analysis/11-ui-design.md §十二 R1；11-ui-design §十二 R1）：
//  哨兵退役 → appState 真信号（①当前会话唯一权威，D1 清偿）；
//  列表自动刷新（②epoch 驱动，D2 清偿）；hasDetailsSession 真判定（④，D4 清偿）；
//  状态点真值（③AppEnvironment 既有镜像 → snapshot → 派生器，D3 清偿）。
//

import SwiftUI

struct WORootFrame: View {
    /// 新会话统一入口：建 blank 会话，带 workspaceId 则挂组，否则落未分组桶
    private func newSession(in workspaceId: String?) {
        if let s = try? environment.sessionStore.createSession(cwd: nil) {
            if let wsId = workspaceId {
                try? environment.workspaceRegistry.attachSession(sessionId: s.id, to: wsId)
            }
            // R1：当前会话真信号（唯一入口；点行/旧界面/深链同写 appState）。
            appState.openSession(s.id)
        }
    }

    @StateObject private var layout = WOLayoutStore()
    @StateObject private var viewStore = WOWorkspaceViewStore()
    @EnvironmentObject private var environment: AppEnvironment
    /// R1：App 级会话真值源（当前会话/列表纪元）。
    @EnvironmentObject private var appState: WOAppState

    var body: some View {
        // 快照一次求值：列表 + 派生输入 + hasDetailsSession 共用（同步 actor 读沿
        // 环4批1 既有模式；写路径失效经 appState.sessionListEpoch 推重渲）。
        let sessions = environment.sessionStore.listSessions()
        let snapshot = WOWorkspaceSnapshot(
            sessions: sessions,
            workspaces: environment.workspaceRegistry.list(),
            archived: environment.workspaceRegistry.archivedSessionIDs(),
            currentSessionId: appState.currentSessionId,
            activeRunSessionIDs: environment.activeRunSessionIDs,
            pendingSessionIDs: environment.pendingInteractionSessionIDs)

        WOAppFrame(
            store: layout,
            // R1：真判定——当前会话存在且非 blank（dsh AppFrame detailsSession 语义；
            // 骨架期恒 true 于本环退役，D4 清偿）。
            hasDetailsSession: snapshot.hasDetails,
            sidebar: { collapsed, width in
                WOSidebarShell(
                    collapsed: collapsed,
                    width: width,
                    onToggleSidebar: { layout.toggleSidebar() },
                    onNewSession: { newSession(in: nil) },
                    region: { wide, quiet in
                        if wide {
                            WOWorkspaceBrowser(
                                viewStore: viewStore,
                                snapshot: { snapshot },
                                onOpenSession: { sessionId in
                                    // 真打开：置当前会话 → 中栏挂 WOChatView
                                    appState.openSession(sessionId)
                                },
                                onNewSession: { workspaceId in
                                    newSession(in: workspaceId)
                                }
                            )
                        } else {
                            WOSlotPlaceholder(text: nil, quiet: quiet)
                        }
                    },
                    footer: { wide in
                        WOSlotPlaceholder(text: wide ? "设置入口 · R5" : nil, quiet: false)
                    }
                )
            },
            center: {
                // 无当前会话=Hero 引导；有=真聊天（.id 换会话换 ViewModel）
                if let sessionId = appState.currentSessionId {
                    WOChatView(environment: environment, sessionId: sessionId)
                        .id(sessionId)
                } else {
                    WOChatHero(onNewSession: { newSession(in: nil) })
                }
            },
            details: {
                // 详情栏槽：右栏四页签归 R4；关闭钮（codex 面板语义）
                ZStack(alignment: .topTrailing) {
                    WOSlotPlaceholder(text: "详情栏 · 右栏四页签 R4", quiet: false)
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
        // R1：列表自动刷新机制——appState.sessionListEpoch（@Published）变化触发本
        // body 重求值 → 快照重拉 → 浏览区差分刷新（D2 清偿）。
        // 纪律：禁 .id(epoch) 整树重建——那正是 9-19"列表闪跳"的反模式（identity
        // 重置杀掉进行中手势；差分刷新靠 Equatable 派生输出，WOGroupNode 已 Equatable）。
    }
}

/// 脚手架占位（非设计稿——可见性标注，后续环逐个替换）
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
