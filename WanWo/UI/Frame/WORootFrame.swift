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
        mainFrame
            // 批B3：旧全屏 overlay 块（第二实例 + opacity/scale transition）拆除——
            // 全屏改为同一实例列宽向左延伸（WOAppFrame 求列折算 + 0.42s 列宽
            // 动画），真值链 = topBar 钮写 model.isFullscreen → 本视图 onChange
            // 桥写 layout.fullscreen；右栏 @State 只此一套（放大后浏览器不再空白）。
        .overlay { WOSettingsModal(isPresented: settingsPresented) }
        // 批C1：reopenSidebarButton 退役——右栏开关唯一入口=顶栏钮
        //（WOConversationHead，规格沿用本钮的 32pt r9 玻璃白 fab）。
        .alert("操作失败", isPresented: actionErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(environment.sessionActionError ?? "")
        }
        // wanwo:// 深链消费（旧 RootView 1:1）：资源 URL → 右栏对应页签；
        // 权限路由 → 设置·权限分区；外部 scheme 入口同路。
        .onOpenURL { url in
            WanwoURLRouter.shared.handle(url)
        }
        .onReceive(WanwoURLRouter.shared.$pendingPermissionsRoute) { pending in
            if pending {
                environment.openSettings(at: .permissions)
                WanwoURLRouter.shared.consumePermissionsRoute()
            }
        }
        .onReceive(WanwoURLRouter.shared.$pendingResourceURL) { url in
            guard let url else { return }
            // 批14：深链打开诊断（AI 打开资源路径的状态留痕）。
            RightRailDiag.event("wanwo:// 深链打开 前: isExpanded=\(workspaceSidebar.isExpanded) isFullscreen=\(workspaceSidebar.isFullscreen) url=\(url.absoluteString)")
            workspaceSidebar.isExpanded = true
            workspaceSidebar.openResourceURL(url)
            WanwoURLRouter.shared.consumeResourceURL()
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
            // 批14：桥执行诊断（钮点击→isExpanded→列宽 的链路留痕）。
            RightRailDiag.event("onChange(isExpanded)=\(expanded) session=\(appState.currentSessionId ?? "nil") → \(expanded ? "openDetails" : "closeDetails")")
            if expanded {
                if appState.currentSessionId != nil { layout.openDetails() }
            } else {
                layout.closeDetails()
            }
        }
        // 批B3：全屏真值桥接——单一真值 = workspaceSidebar.isFullscreen（右栏
        // topBar 全屏/关闭钮写它，语义不变）；layout.fullscreen 只是布局投影，
        // 仅由本桥与 syncSessionSelection 的无会话复位写入，不独立记账。
        // 批10：桥与投影整体退役——fullscreen 直连入参（见 mainFrame）。
    }

    private var mainFrame: some View {
        let snapshot = makeSnapshot()
        return WOAppFrame(
            store: layout,
            // 批12：hasDetailsSession 入参退役（详情列宽门/自动关卡统一绑
            // hasSession——blank 会话开右栏=400 正常列，点"缩小"回 400 不再
            // 整个消失；snapshot.hasDetails 语义保留在快照侧供别处消费）。
            hasSession: appState.currentSessionId != nil,
            fullscreen: workspaceSidebar.isFullscreen,
            sidebar: { collapsed, width in
                sidebarRegion(snapshot: snapshot, collapsed: collapsed, width: width)
            },
            center: { centerRegion },
            details: { detailsRegion },
            overlayLayer: { EmptyView() }
        )
        .overlay { renameModal }
        .overlay { deleteModal }
        // 新会话挂组 toast（digest-H 文案「已挂到工作区「X」」；发射点=
        // AppEnvironment.createSession(inWorkspace:) 挂成功处）。
        .overlay(alignment: .bottom) {
            if let toast = environment.attachToast {
                WOToast(text: toast, icon: Image(systemName: "checkmark.circle"),
                        onDone: { environment.attachToast = nil })
                    .padding(.bottom, 96)
                    .zIndex(90)
            }
        }
    }

    /// 会话锚点同步：右栏页签（终端/文件/审查/侧聊/轨迹）以旧 selection 为数据锚，
    /// 新 UI 的当前会话（appState）变化时同步写 environment.selection（同一真值，
    /// 两个入口）；无会话时右栏强制收起（M6.6 C② 语义）。
    private func syncSessionSelection() {
        if let id = appState.currentSessionId {
            if environment.selection != .session(id: id) {
                environment.selection = .session(id: id)
            }
            // 批B1：白列根治——只有 isExpanded 时才随会话锚点同步开列；
            // 收起态切会话不再强制开列（列开/关唯一真值=workspaceSidebar
            // .isExpanded，右栏本体由 B2 恒挂载保证不再出现纯白 placeholder）。
            if workspaceSidebar.isExpanded {
                layout.openDetails()
            }
        } else if environment.selection != .none {
            environment.selection = .none
        }
        if appState.currentSessionId == nil {
            layout.closeDetails()
            // 批10：layout.fullscreen 投影已退役（真值=model.isFullscreen 直连
            // WOAppFrame 入参，无投影即无脱钩，无需复位）。
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
            // 批A1：侧栏总钮改走引擎缝 startSession（dsh navigation 语义）——
            // target=当前会话工作区 ?? 最近活动工作区；无任何工作区 →
            // clearSelection 留空态，绝不产生 cwd=nil 孤儿会话（旧 newSession
            // (in: nil) 直建未挂组会话的路径退役）。
            onNewSession: { environment.workspaceNavigator.startSession(nil) },
            region: { wide, quiet in
                if wide {
                    WOWorkspaceBrowser(
                        viewStore: viewStore,
                        snapshot: { snapshot },
                        onOpenSession: { appState.openSession($0) },
                        // 批A1：组行 + 显式带 workspaceId，同缝收口（复用组内
                        // blank 或新建并挂组）。
                        onNewSession: { environment.workspaceNavigator.startSession($0) },
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) // 批D3：38→44
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开设置")
    }

    // MARK: - 中栏（Hero / 聊天）

    @ViewBuilder
    private var centerRegion: some View {
        if let sessionId = appState.currentSessionId {
            // 批C1：右栏开关钮在顶栏（WOConversationHead）——workspaceSidebar
            // 真值在根帧，闭包下发切换（isExpanded onChange 既有链驱动列宽）。
            // 批12：展开时强制清全屏。
            // 批14：语义化开关+幽灵态自愈——裸 toggle 的坑：isExpanded=true
            // 而 details=0 的"逻辑开着但看不见"态下，第一下点=切到 false=
            // 用户看来的"没反应"。现在目标态由「可见性」判定（isExpanded 且
            // 列宽>0 才算开），点一下必达可见结果。
            WOChatView(environment: environment, sessionId: sessionId,
                       onToggleRightSidebar: {
                           let visible = workspaceSidebar.isExpanded && layout.details > 0
                           // 批15c：点击反馈直显（toast 复用挂组通道）——点击若到
                           // 达此处必有可见弹条；不弹=点击未命中按钮（命中层问题）。
                           environment.attachToast = "开关点击 isExpanded=\(workspaceSidebar.isExpanded) details=\(layout.details) fullscreen=\(workspaceSidebar.isFullscreen) → \(visible ? "关闭" : "打开")"
                           RightRailDiag.event("顶栏钮点击 前: isExpanded=\(workspaceSidebar.isExpanded) details=\(layout.details) isFullscreen=\(workspaceSidebar.isFullscreen) session=\(sessionId) → 目标=\(visible ? "关闭" : "打开")")
                           if visible {
                               workspaceSidebar.isExpanded = false
                           } else {
                               workspaceSidebar.isExpanded = true
                               workspaceSidebar.isFullscreen = false
                               if appState.currentSessionId != nil {
                                   layout.openDetails() // 幂等；幽灵态列宽 0 时重开
                               }
                           }
                       })
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
        if appState.currentSessionId != nil {
            // 批B2：有会话恒挂载（dsh AppFrame.tsx:35-38「右栏宽 0 时保持挂载
            // 不卸载」；WOAppFrame detailsCol「0 宽不卸载子树」注释同证）——
            // 收起=布局列宽 0（既有 onChange(isExpanded)→closeDetails 链），
            // 浏览器网页/文件树/终端页签的 @State 在 0 宽列里保活，再展开原样
            // 回来。无会话仍走 placeholder（reconcileForSelection 语义不动）。
            WorkspaceRightSidebarView(model: workspaceSidebar,
                                      environment: environment)
        } else {
            WOSlotPlaceholder(text: nil, quiet: false)
        }
    }

    /// 设置面板呈现绑定（settingsPane 非 nil 即呈现；关闭=closeSettings 回 nil）。
    private var settingsPresented: Binding<Bool> {
        Binding(get: { environment.settingsPane != nil },
                set: { if !$0 { environment.closeSettings() } })
    }

    // MARK: - 动作

    // 批A1：旧 newSession(in:) 退役——侧栏新会话统一走
    // environment.workspaceNavigator.startSession（WorkspaceNavigator.swift
    // :188-212 既有缝：显式 wsId ?? 当前会话工作区 ?? 最近活动工作区；无工作区
    // → clearSelection 留空态）。attach + toast 已在 createSession(inWorkspace:)
    // 缝内（AppEnvironment），改道后自动继承，此处不再补。

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
            appState.purgeDraft(for: id) // 草稿持久键随会话清除（防 UserDefaults 孤儿）
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
                    return "将把「\(title)」从工作区列表中移除。文件夹与此工作区下会话的记录会保留在数据库中。"
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
