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
    // 【终验修正】NavigationSplitViewVisibility 的 .detail/.secondary 在 iOS 16
    // SDK 实测均不存在（CI 两轮编译错实证）——全屏语义由下方条件布局承载
    // （右栏 maxWidth .infinity 已占满内容区=截图 #21 形态；左栏保留，
    // "左栏另行收起"为用户独立操作）。columnVisibility 机制整体不碰。

    var body: some View {
        Group {
            if workspaceSidebar.isFullscreen
                && WorkspaceRightSidebarView.sessionID(of: environment.selection) != nil {
                // 【批3 C⑤】全屏：右栏独占整窗、左栏隐藏（codex 截图 #22/#23）。
                // 条件根布局承载——NavigationSplitViewVisibility 的 .detail/
                // .secondary 在 iOS 16 SDK 实测不存在（文件头顶注 CI 实证），
                // 换根容器的 NavigationStack 状态丢失取舍登记报告；再点退出
                // 全屏即还原 splitLayout。
                WorkspaceRightSidebarView(model: workspaceSidebar,
                                          environment: environment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            } else {
                splitLayout
            }
        }
        // 【批3 C②】无会话不显示右栏：切到非会话选中态 → 强制收起 + 退出全屏
        // （codex 截图 #3——右栏只在会话场景可用；开关钮隐藏见 splitLayout
        // overlay 条件）。onAppear 兜底首帧（初始 .none 也收起）。
        .onAppear {
            workspaceSidebar.reconcileForSelection(
                sessionID: WorkspaceRightSidebarView.sessionID(of: environment.selection))
        }
        .onChange(of: environment.selection) { selection in
            workspaceSidebar.reconcileForSelection(
                sessionID: WorkspaceRightSidebarView.sessionID(of: selection))
        }
        // 【批3 A】设置面板（全窗 overlay——dsh SettingsRoot 为 app 级对话框
        // 同位；settingsPane 非 nil 即呈现，detail 区不切换）。
        .overlay {
            if environment.settingsPane != nil {
                SettingsPanelView(environment: environment)
            }
        }
        // 万我 M6.1 增（B1c ④审批接线）：offload askOnce 权限确认卡全局
        // 挂载（OpenMinis 挂 ContentView 同位）。批12+归挡（2026-09-27）：
        // .offloadPermissionDialog() 修饰器退役——卡片迁 composer 座位接管
        // （WOChatView.composerSeat，WOOffloadPermissionCard）；本视图为新
        // UI 重构后的死代码（零实例化），挂载点仅作历史注记保留。
        // 万我 M6.5 增（B3）：wanwo:// 深链消费——设置权限页跳转
        // （OffloadPermissionManager deny 文案 [Open Permissions](wanwo://settings/permissions)
        // 的消费端）；M6.6（B4）：资源 URL → 右侧栏浏览器页签（B3 标注的
        // 接线点落位）。
        .onOpenURL { url in
            WanwoURLRouter.shared.handle(url)
        }
        .onReceive(WanwoURLRouter.shared.$pendingPermissionsRoute) { pending in
            if pending {
                // 【批3 A】深链落点改设置面板·权限分区（原 selection=
                // .permissionDefaults 推栈页随设置域重组撤除；B1c 闭环勿断）。
                environment.openSettings(at: .permissions)
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

    /// 常规布局（非全屏）：左栏会话列表 + detail（主区 + 右侧栏）。
    private var splitLayout: some View {
        NavigationSplitView {
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
                // 【批3 C②】非会话选中态整栏不渲染（codex #3：右栏只在会话
                // 场景可用；reconcileForSelection 已强制收起，此处双保险）。
                if workspaceSidebar.isExpanded,
                   WorkspaceRightSidebarView.sessionID(of: environment.selection) != nil {
                    Divider()
                    WorkspaceRightSidebarView(model: workspaceSidebar,
                                              environment: environment)
                        .frame(width: workspaceSidebar.isFullscreen ? nil
                               : WorkspaceRightSidebarModel.expandedWidth)
                        .frame(maxWidth: workspaceSidebar.isFullscreen ? .infinity : nil,
                               maxHeight: .infinity)
                }
            }
            // 【批3 C①】收起态重开钮移右上角（codex 截图 #3——与头部工具区
            // 并排；原主区右缘中部悬浮改 .topTrailing）。无会话时同样隐藏
            // （C②——开关钮只在会话场景可用）。
            .overlay(alignment: .topTrailing) {
                if !workspaceSidebar.isExpanded,
                   WorkspaceRightSidebarView.sessionID(of: environment.selection) != nil {
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
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .accessibilityLabel("展开工作区侧栏")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        // hero ↔ 会话/设置页边界过渡（UI 修复批 2 接线：ConversationEmptyStateView
        // 根层 .transition(.opacity) 的生效条件——仅空态进出动画化；会话间/设置
        // 分支间切换不动画，避免 ChatView .id 重建叠加闪烁）。spring 全局标准。
        Group {
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
                // UI 对齐批 1（B）→ UI 修复批 2（W3 重做）：主区空态 dsh hero
                // 形态（品牌+工作区胶囊+composer 同屏；inert/菜单语义 1:1）。
                ConversationEmptyStateView(environment: environment)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: environment.selection == nil)
    }
}
