//
//  RootView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.1（RootView：NavigationSplitView 侧栏 +
//  详情区；M1 子集 = 会话列表 + 聊天流 + 设置·Providers；M0 ShellTestView 保留入口）。
//  M6.6（B4）增：右侧工作区侧栏（WorkspaceRightSidebarView——主对话区右侧第三栏；
//  全屏 = 右侧栏占满、左栏折叠；wanwo:// 资源深链 → 浏览器页签接线）。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// M6.6（B4）：右侧栏容器状态（App 内单实例——页签跨会话切换保持）。
    @StateObject private var workspaceSidebar = WorkspaceRightSidebarModel()
    /// 全屏时折叠左栏（右栏占满整窗——§6.0 全屏语义折算）。
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            NavigationStack {
                SessionsSidebarView(environment: environment,
                                    selection: $environment.selection)
            }
        } detail: {
            HStack(spacing: 0) {
                NavigationStack {
                    detail
                }
                // M6.6（B4）：右侧工作区侧栏（可收起/展开 + 全屏）。
                if workspaceSidebar.isExpanded {
                    Divider()
                    WorkspaceRightSidebarView(model: workspaceSidebar,
                                              environment: environment)
                        .frame(width: workspaceSidebar.isFullscreen ? nil
                               : WorkspaceRightSidebarModel.expandedWidth)
                        .frame(maxWidth: workspaceSidebar.isFullscreen ? .infinity : nil,
                               maxHeight: .infinity)
                }
            }
            // 收起态的重开钮（§6.0 侧栏开关的另一向；悬浮于主对话区右缘）。
            .overlay(alignment: .trailing) {
                if !workspaceSidebar.isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            workspaceSidebar.isExpanded = true
                        }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: 12, weight: .medium))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(.trailing, 8)
                    .accessibilityLabel("展开工作区侧栏")
                }
            }
        }
        // 全屏切换 → 左栏折叠（右栏占满整窗）。
        .onChange(of: workspaceSidebar.isFullscreen) { fullscreen in
            withAnimation(.easeInOut(duration: 0.2)) {
                splitVisibility = fullscreen ? .detail : .all
            }
        }
        // 万我 M6.1 增（B1c ④审批接线）：offload askOnce 权限确认卡全局
        // 挂载（OpenMinis 挂 ContentView 同位；sheet(item:) 单槽形态原件
        // 1:1——审批来自内核 offload 分发点，可发生于任意会话/页面）。
        .offloadPermissionDialog()
        // 万我 M6.5 增（B3）：wanwo:// 深链消费——设置权限页跳转
        // （OffloadPermissionManager deny 文案 [Open Permissions](wanwo://settings/permissions)
        // 的消费端）；M6.6（B4）：资源 URL → 右侧栏浏览器页签（B3 标注的
        // 接线点落位）。
        .onOpenURL { url in
            WanwoURLRouter.shared.handle(url)
        }
        .onReceive(WanwoURLRouter.shared.$pendingPermissionsRoute) { pending in
            if pending {
                environment.selection = .permissionDefaults
                WanwoURLRouter.shared.consumePermissionsRoute()
            }
        }
        .onReceive(WanwoURLRouter.shared.$pendingResourceURL) { url in
            guard let url else { return }
            workspaceSidebar.isExpanded = true
            workspaceSidebar.openResourceURL(url)
            WanwoURLRouter.shared.consumeResourceURL()
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
        case .mcpServers:
            // M4-A 件11：设置·MCP server 管理（OpenMinis MCPIntegrationsView
            // 交互参照；配置→MCPRuntime 装配收口）。
            MCPServersView(environment: environment)
        case .skills:
            // M4-D D7：设置·技能管理（列表/启停/导入；最小素净版——dsh
            // apps/web 无原件取证，M9 对齐登记）。
            SkillsView(environment: environment)
        case .mounts:
            // M6.4（B3）：设置·外挂载文件夹管理（F071——MountedFoldersManager
            // 状态面 + UIDocumentPicker 挂载流程）。
            MountedFoldersSettingsView()
        case .shellTest:
            // M0 交付物原样可达（DEBUG-only 入口——B4 起侧栏不再露出，
            // 回归验收仍可从诊断面进入；手动输入 `ls`）。
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
