//
//  RootView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.1（RootView：NavigationSplitView 侧栏 +
//  详情区；M1 子集 = 会话列表 + 聊天流 + 设置·Providers；M0 ShellTestView 保留入口）。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            NavigationStack {
                SessionsSidebarView(environment: environment,
                                    selection: $environment.selection)
            }
        } detail: {
            NavigationStack {
                detail
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch environment.selection {
        case .session(let id):
            // .id(id)：切换会话时强制重建 StateObject（新会话新 ViewModel）。
            ChatView(environment: environment, sessionID: id)
                .id(id)
        case .providers:
            ProvidersView(environment: environment)
        case .permissions:
            // M3 T2 权限管理页（规则 CRUD + 预设说明；T1 偏差 6 补齐）。
            PermissionsView(environment: environment)
        case .shellTest:
            // M0 交付物原样可达（回归验收：手动输入 `ls`）。
            ShellTestView()
        case .eventStream:
            // M2.8 只读事件流诊断页（dsh ui-trajectory 最小移植；F060 M8.2 前置）。
            EventStreamView(environment: environment)
        case .none:
            Text("选择或新建一个会话")
                .foregroundStyle(.secondary)
        }
    }
}
