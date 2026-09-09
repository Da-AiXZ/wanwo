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
        case .permissionDefaults:
            // M3 T2.2 设置·新会话默认权限行（PermissionRow.tsx 1:1；P1-4 后
            // 唯一权限入口——规则 CRUD 页随 F022 砍除）。
            PermissionDefaultsView(environment: environment)
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
