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
        // 万我 M6.1 增（B1c ④审批接线）：offload askOnce 权限确认卡全局
        // 挂载（OpenMinis 挂 ContentView 同位；sheet(item:) 单槽形态原件
        // 1:1——审批来自内核 offload 分发点，可发生于任意会话/页面）。
        .offloadPermissionDialog()
        // 万我 M6.5 增（B3）：wanwo:// 深链消费——设置权限页跳转
        // （OffloadPermissionManager deny 文案 [Open Permissions](wanwo://settings/permissions)
        // 的消费端；资源 URL 的 UI 呈现面随 B4 右侧栏，路由器内已标注）。
        .onOpenURL { url in
            WanwoURLRouter.shared.handle(url)
        }
        .onReceive(WanwoURLRouter.shared.$pendingPermissionsRoute) { pending in
            if pending {
                environment.selection = .permissionDefaults
                WanwoURLRouter.shared.consumePermissionsRoute()
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
