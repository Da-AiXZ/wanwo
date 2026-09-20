//
//  WORootFrame.swift
//  WanWo
//
//  R1 诚实化 + R3a 行操作（analysis/11-ui-design.md §十二）：
//  哨兵退役 → appState 真信号（D1）；epoch 自动刷新（D2）；状态点真值（D3）；
//  hasDetailsSession 真判定（D4）；行操作真动作+搜索+视图菜单（D5）。
//  纪律：body 拆子计算属性（SwiftUI type-check 超时防御，run 35468152722 教训）。
//

import SwiftUI

struct WORootFrame: View {
    // MARK: - 状态

    @StateObject private var layout = WOLayoutStore()
    @StateObject private var viewStore = WOWorkspaceViewStore()
    /// 右栏容器状态机（M6.6 B4 真机验收过的旧件，App 内单实例——页签跨会话保持）。
    @StateObject private var workspaceSidebar = WorkspaceRightSidebarModel()
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState

    /// 删除失败呈现（AppEnvironment.deleteSession 失败置串，alert 呈现后清零——
    /// 与旧 SessionsSidebarView 同一消费语义）。
    private var actionErrorPresented: Binding<Bool> {
        Binding(get: { environment.sessionActionError != nil },
                set: { if !$0 { environment.sessionActionError = nil } })
    }

    /// R3a 行操作目标（重命名/删除确认；归档无对话框=dsh 语义）。
    private enum R3Target: Equatable {
        case session(id: String, title: String)
        case workspace(id: String, title: String)
        var title: String {
            switch self {
            case .session(_, let title), .workspace(_, let title): return title
            }
        }
    }

    @State private var renameTarget: R3Target?
    @State private var renameField = ""
    @State private var deleteTarget: R3Target?

    // MARK: - Body（只组装）

    var body: some View {
        Group {
            if workspaceSidebar.isFullscreen, appState.currentSessionId != nil {
                // 全屏：右栏独占整窗（M6.6 批3 C⑤ 语义；条件根布局承载——
                // iOS16 NavigationSplitViewVisibility 不可用，旧 RootView 同款）。
                WorkspaceRightSidebarView(model: workspaceSidebar,
                                          environment: environment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WOAlias.bgBase)
            } else {
                mainFrame
            }
        }
        .overlay { WOSettingsModal(isPresented: settingsPresented) }
        .overlay(alignment: .topTrailing) { reopenSidebarButton }
        .alert("操作失败", isPresented: actionErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(environment.sessionActionError ?? "")
        }
        .onAppear { syncSessionSelection() }
        .onChange(of: appState.currentSessionId) { _ in syncSessionSelection() }
        // 反向同步：引擎缝开的会话（hero 工作区胶囊 startSession / 深链）写
        // environment.selection → 新 UI 真值跟上（两向同值幂等，不成环）。
        .onChange(of: environment.selection) { selection in
            if case .session(let id) = selection, appState.currentSessionId != id {
                appState.openSession(id)
            }
            if case .none = selection, let current = appState.currentSessionId {
                appState.sessionRemoved(current)
            }
        }
        .onChange(of: workspaceSidebar.isExpanded) { expanded in
            // 右栏收起/展开 ↔ 布局列宽联动（收起=列宽 0 让位给对话区，dsh 让位链）。
            if expanded {
                if appState.currentSessionId != nil { layout.openDetails() }
            } else {
                layout.closeDetails()
            }
        }
    }

    private var mainFrame: some View {
        let snapshot = makeSnapshot()
        return WOAppFrame(
            store: layout,
            hasDetailsSession: snapshot.hasDetails,
            sidebar: { collapsed, width in
                sidebarRegion(snapshot: snapshot, collapsed: collapsed, width: width)
            },
            center: { centerRegion },
            details: { detailsRegion },
            overlayLayer: { EmptyView() }
        )
        .overlay { renameModal }
        .overlay { deleteModal }
    }

    /// 会话锚点同步：右栏页签（终端/文件/审查/侧聊/轨迹）以旧 selection 为数据锚，
    /// 新 UI 的当前会话（appState）变化时同步写 environment.selection（同一真值，
    /// 两个入口）；无会话时右栏强制收起（M6.6 C② 语义）。
    private func syncSessionSelection() {
        if let id = appState.currentSessionId {
            if environment.selection != .session(id: id) {
                environment.selection = .session(id: id)
            }
            layout.openDetails()
        } else if environment.selection != .none {
            environment.selection = .none
        }
        if appState.currentSessionId == nil {
            layout.closeDetails()
        }
        workspaceSidebar.reconcileForSelection(sessionID: appState.currentSessionId)
    }

    // MARK: - 快照（列表+运行状态+派生输入，一次求值共用）

    private func makeSnapshot() -> WOWorkspaceSnapshot {
        WOWorkspaceSnapshot(
            sessions: environment.sessionStore.listSessions(),
            workspaces: environment.workspaceRegistry.list(),
            archived: environment.workspaceRegistry.archivedSessionIDs(),
            currentSessionId: appState.currentSessionId,
            activeRunSessionIDs: environment.activeRunSessionIDs,
            pendingSessionIDs: environment.pendingInteractionSessionIDs)
    }

    // MARK: - 侧栏（工作区浏览区）

    @ViewBuilder
    private func sidebarRegion(snapshot: WOWorkspaceSnapshot,
                               collapsed: Bool, width: CGFloat) -> some View {
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
                        onOpenSession: { appState.openSession($0) },
                        onNewSession: { newSession(in: $0) },
                        onRenameSession: { id in
                            let t = snapshot.sessions.first { $0.id == id }
                            renameTarget = .session(id: id, title: t?.title ?? "")
                            renameField = t?.title ?? ""
                        },
                        onArchiveSession: { commitArchive($0) },
                        onDeleteSession: { id in
                            let t = snapshot.sessions.first { $0.id == id }
                            deleteTarget = .session(id: id, title: t?.title ?? "新会话")
                        },
                        onRenameWorkspace: { id in
                            let t = snapshot.workspaces.first { $0.id == id }
                            renameTarget = .workspace(id: id, title: t?.title ?? "")
                            renameField = t?.title ?? ""
                        },
                        onDeleteWorkspace: { id in
                            let t = snapshot.workspaces.first { $0.id == id }
                            deleteTarget = .workspace(id: id, title: t?.title ?? "")
                        }
                    )
                } else {
                    WOSlotPlaceholder(text: nil, quiet: quiet)
                }
            },
            footer: { wide in
                footerBar(wide: wide)
            }
        )
    }

    /// 侧栏 footer：设置真入口（齿轮 → 全窗设置面板；dsh SettingsRoot 语义）。
    private func footerBar(wide: Bool) -> some View {
        Button {
            environment.openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                if wide {
                    Text("设置")
                        .font(.system(size: 13))
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开设置")
    }

    // MARK: - 中栏（Hero / 聊天）

    @ViewBuilder
    private var centerRegion: some View {
        if let sessionId = appState.currentSessionId {
            WOChatView(environment: environment, sessionId: sessionId)
                .id(sessionId)
        } else {
            // 无会话空态 = dsh EmptyHero 语义（工作区胶囊选组即建会话入组，
            // 草稿交接 pendingFirstDraft；WOChatHero 内部走引擎缝）。
            WOChatHero()
        }
    }

    // MARK: - 详情栏（右栏：M6.6 旧件接线——五页签容器真功能）

    @ViewBuilder
    private var detailsRegion: some View {
        if appState.currentSessionId != nil, workspaceSidebar.isExpanded {
            WorkspaceRightSidebarView(model: workspaceSidebar,
                                      environment: environment)
        } else {
            WOSlotPlaceholder(text: nil, quiet: false)
        }
    }

    /// 收起态重开钮（M6.6 批3 C①：右上角；无会话/全屏时隐藏）。
    @ViewBuilder
    private var reopenSidebarButton: some View {
        if !workspaceSidebar.isExpanded,
           appState.currentSessionId != nil,
           !workspaceSidebar.isFullscreen,
           environment.settingsPane == nil {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    workspaceSidebar.isExpanded = true
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOAlias.labelSecondary)
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 12)
            .accessibilityLabel("展开工作区侧栏")
        }
    }

    /// 设置面板呈现绑定（settingsPane 非 nil 即呈现；关闭=closeSettings 回 nil）。
    private var settingsPresented: Binding<Bool> {
        Binding(get: { environment.settingsPane != nil },
                set: { if !$0 { environment.closeSettings() } })
    }

    // MARK: - 动作

    /// 新会话统一入口：建会话并打开；带 workspaceId 则挂组。
    /// 组内新建 cwd 必须传组规范路径——attachSession 以 header.cwd 与组路径
    /// 做成员资格校验（cwd=nil 的会话会被拒绝落未分组，impl-workspace 核证）。
    private func newSession(in workspaceId: String?) {
        let cwd: String? = workspaceId.flatMap { id in
            environment.workspaceRegistry.list().first { $0.id == id }?.path
        }
        if let s = try? environment.sessionStore.createSession(cwd: cwd) {
            if let wsId = workspaceId {
                try? environment.workspaceRegistry.attachSession(sessionId: s.id, to: wsId)
            }
            appState.openSession(s.id)
        }
    }

    private func commitRename() {
        let name = renameField.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let target = renameTarget else { return }
        switch target {
        case .session(let id, _):
            environment.database.setTitle(id: id, title: name)
        case .workspace(let id, _):
            _ = try? environment.workspaceRegistry.renameTitle(id: id, title: name)
        }
        renameTarget = nil
    }

    private func commitArchive(_ id: String) {
        try? environment.workspaceController.archiveSession(sessionId: id)
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        switch target {
        case .session(let id, _):
            appState.sessionRemoved(id)
            Task { await environment.deleteSession(id: id) }
        case .workspace(let id, _):
            _ = try? environment.workspaceRegistry.delete(id)
        }
        deleteTarget = nil
    }

    // MARK: - Modal（重命名 / 删除确认）

    @ViewBuilder
    private var renameModal: some View {
        WOModal(
            open: renameTarget != nil,
            onClose: { renameTarget = nil },
            title: renameTarget.map { t in
                if case .workspace = t { return "重命名工作区" }
                return "重命名会话"
            } ?? "重命名"
        ) {
            TextField(renameTarget.map { t in
                if case .workspace = t { return "工作区名称" }
                return "会话名称"
            } ?? "名称", text: $renameField)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                .onSubmit { commitRename() }
        } footer: {
            HStack(spacing: 10) {
                Button {
                    renameTarget = nil
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.bgLayer3)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .woPressable()

                let canCommit = !renameField.trimmingCharacters(in: .whitespaces).isEmpty
                Button {
                    commitRename()
                } label: {
                    Text("确认")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(canCommit ? WOAlias.buttonPrimaryFill
                                            : WOAlias.buttonPrimaryDimmed))
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .woPressable()
            }
        }
    }

    @ViewBuilder
    private var deleteModal: some View {
        WOModal(
            open: deleteTarget != nil,
            onClose: { deleteTarget = nil },
            title: deleteTarget.map { t in
                if case .workspace = t { return "删除工作区" }
                return "删除会话"
            } ?? "删除",
            description: deleteTarget.map { t in
                switch t {
                case .session(_, let title):
                    return "将删除会话「\(title)」及其全部记录。该操作不可撤销。"
                case .workspace(_, let title):
                    return "将把「\(title)」从工作区列表中移除。文件夹与会话记录会保留，其会话将显示在「未分组」下。"
                }
            }
        ) {
            EmptyView()
        } footer: {
            HStack(spacing: 10) {
                Button {
                    deleteTarget = nil
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.bgLayer3)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .woPressable()

                Button {
                    commitDelete()
                } label: {
                    Text("删除")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.stateErrorPrimary))
                }
                .buttonStyle(.plain)
                .woPressable()
            }
        }
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
