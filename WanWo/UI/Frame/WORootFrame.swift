//
//  WORootFrame.swift
//  WanWo
//
//  R1 诚实化 + R3a 行操作（analysis/11-ui-design.md §十二）：
//  哨兵退役 → appState 真信号（D1）；epoch 自动刷新（D2）；状态点真值（D3）；
//  hasDetailsSession 真判定（D4）；行操作真动作+搜索+视图菜单（D5）。
//  纪律：body 拆子计算属性（SwiftUI type-check 超时防御，run 35468152722 教训）。
//

import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WORootFrame: View {
    // MARK: - 状态

    @StateObject private var layout = WOLayoutStore()
    @StateObject private var viewStore = WOWorkspaceViewStore()
    /// 【批12+右栏重构批1（2026-09-27 用户拍板）】右栏容器状态机换底座——
    /// cc-haha workspaceStore/openTarget 语义 1:1 移植（三层分离/按会话作用域/
    /// 复用规则/真删释放/undo 撤销/布局三态单值），替换 M6.6 自创底座
    /// （WorkspaceRightSidebarModel 双布尔+kind 枚举单实例——串区/堆签/空壳
    /// 三类 bug 的共同根源）。语义源与逐锚点对照见 WOWorkspaceStore.swift 头注。
    @ObservedObject private var workspaceStore = WOWorkspaceStore.shared
    /// 切会话收起用：上一个会话 id（collapseForSessionSwitch 的 from）。
    @State private var lastSessionId: String?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState

    /// 删除失败呈现（AppEnvironment.deleteSession 失败置串，alert 呈现后清零——
    /// 与旧 SessionsSidebarView 同一消费语义）。
    private var actionErrorPresented: Binding<Bool> {
        Binding(get: { environment.sessionActionError != nil },
                set: { if !$0 { environment.sessionActionError = nil } })
    }

    /// R3a 行操作目标（重命名/删除确认；归档无对话框=dsh 语义）。
    /// M8 批3 D 件：workspace 案带账本会话数（删除确认弹窗「将同时删除
    /// N 个对话」——N=账本实数，进弹窗时定格）。
    private enum R3Target: Equatable {
        case session(id: String, title: String)
        case workspace(id: String, title: String, sessionCount: Int)
        var title: String {
            switch self {
            case .session(_, let title), .workspace(_, let title, _): return title
            }
        }
    }

    @State private var renameTarget: R3Target?
    @State private var renameField = ""
    @State private var deleteTarget: R3Target?
    /// 【批4 真机诊断】列表布局诊断 sheet 开关（侧栏 footer 入口）。
    @State private var showListDiag = false

    // MARK: - Body（只组装）

    var body: some View {
        mainFrame
            // 批B3：旧全屏 overlay 块（第二实例 + opacity/scale transition）拆除——
            // 全屏改为同一实例列宽向左延伸（WOAppFrame 求列折算 + 0.42s 列宽
            // 动画），真值链 = topBar 钮写 model.isFullscreen → 本视图 onChange
            // 桥写 layout.fullscreen；右栏 @State 只此一套（放大后浏览器不再空白）。
        .overlay { WOSettingsModal(isPresented: settingsPresented) }
        // 批12+归挡（2026-09-27 用户裁决）：offload 审批卡迁移=**composer 座位
        // 接管**（WOChatView.composerSeat 第三顺位，WOApprovalCard 同款骨架）
        // ——独立 sheet 形态退役（OpenMinis 原件形态；用户指名对齐"仅可查看
        // 询问权限盖在 dock 上层"的现有样式）。呈现侧状态宿主不变
        // （OffloadApprovalPresenter.shared.pendingRequest，30s 超时语义不变）。
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
            guard let url, let sessionId = appState.currentSessionId else { return }
            // 批12+右栏重构批1：深链资源 → 统一打开入口（cc-haha openTarget
            // 语义——wanwo:// 资源打开即浏览器页签导航落点；用户主动深链=
            // 展开落点）。
            WOWorkspaceOpenRouter.browser(sessionId: sessionId, url: url,
                                          requestedBy: .user, openSidebar: true)
            WanwoURLRouter.shared.consumeResourceURL()
        }
        // 【P2-2 方案甲】工作区文件深链 → 文件页签定位打开（文本在文件里
        // 打开；HTML/其它桶维持浏览器通道——WanwoURLRouter.routeTarget 分流）。
        .onReceive(WanwoURLRouter.shared.$pendingWorkspaceFilePath) { path in
            guard let path, let sessionId = appState.currentSessionId else { return }
            WOWorkspaceOpenRouter.file(sessionId: sessionId, path: path,
                                       requestedBy: .user, openSidebar: true)
            WanwoURLRouter.shared.consumeWorkspaceFilePath()
        }
        // 【批12+右栏重构批1】NotificationCenter .wanwoAgentBrowserNavigation
        // 通道退役——AI 浏览器联动改走统一打开入口（BrowserUseManager 直调
        // WOWorkspaceStore.openAgentBrowser，agent 语义=后台落签不抢焦点）；
        // 轻提示数据源改 store.agentNavigation（WOLightHint 消费段在
        // WOChatView，同批迁移）。
        // 批12+联动B：会话切换（含新建未发消息会话）→ 右栏自动收起（用户令；
        // 页签状态保活=批9B 语义不变，重开即回）。
        .onChange(of: appState.currentSessionId) { newSessionId in
            workspaceStore.collapseForSessionSwitch(from: lastSessionId)
            lastSessionId = newSessionId
        }
        .onAppear {
            lastSessionId = appState.currentSessionId
            syncSessionSelection()
        }
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
        .onChange(of: workspaceLayoutSignature) { signature in
            // 右栏布局 ↔ 布局列宽联动（批12+右栏重构批1：三态单值驱动——
            // split/full 开列、hidden 关列；双布尔双记账旧桥退役）。
            if signature.hasSuffix("|hidden") {
                layout.closeDetails()
            } else {
                layout.openDetails()
            }
        }
        // 批12+右栏重构批1：页签关闭撤销条（用户裁决方式 B——✕ 后底部飘
        // 「已关闭 X · 撤销」，cc-haha reopenClosedTab 语义）。
        .overlay(alignment: .bottom) {
            if let undo = workspaceStore.lastClosedUndo {
                WOUndoToast(text: "已关闭 \(undo.title)",
                            onUndo: { workspaceStore.reopenLastClosed(sessionId: undo.sessionId) },
                            onDone: { workspaceStore.dismissUndoToast(token: undo.token) })
                    .padding(.bottom, 96)
                    .zIndex(91)
            }
        }
        // 【P2-1c 修5 2026-09-28】集中式图片全屏预览（聊天内嵌图/文件页签
        // 图片点击唯一呈现端——黑底 scaledToFit 点按关闭；宿主绝对路径直读，
        // 不依赖挂载时序）。
        .fullScreenCover(item: Binding(
            get: { workspaceStore.pendingImagePreview },
            set: { if $0 == nil { workspaceStore.pendingImagePreview = nil } }
        )) { preview in
            ImageFullScreenPreview(hostPath: preview.path) {
                workspaceStore.pendingImagePreview = nil
            }
            .ignoresSafeArea()
        }
        // 批B3：全屏真值桥接——单一真值 = workspaceSidebar.isFullscreen（右栏
        // topBar 全屏/关闭钮写它，语义不变）；layout.fullscreen 只是布局投影，
        // 仅由本桥与 syncSessionSelection 的无会话复位写入，不独立记账。
        // 批10：桥与投影整体退役——fullscreen 直连入参（见 mainFrame）。
    }

    private var mainFrame: some View {
        let snapshot = makeSnapshot()
        let sessionId = appState.currentSessionId
        return WOAppFrame(
            store: layout,
            // 批12：hasDetailsSession 入参退役（详情列宽门/自动关卡统一绑
            // hasSession——blank 会话开右栏=400 正常列，点"缩小"回 400 不再
            // 整个消失；snapshot.hasDetails 语义保留在快照侧供别处消费）。
            hasSession: sessionId != nil,
            // 批12+右栏重构批1：全屏 = 布局三态之 full（单值真源，双布尔退役）。
            fullscreen: workspaceStore.layout(for: sessionId ?? "") == .full,
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
            // 批B1：白列根治——只有右栏开着时才随会话锚点同步开列；收起态
            // 切会话不再强制开列（列开/关唯一真值 = store 布局三态，批12+
            // 右栏重构批1 换源）。
            if workspaceStore.layout(for: id) != .hidden {
                layout.openDetails()
            }
        } else if environment.selection != .none {
            environment.selection = .none
        }
        if appState.currentSessionId == nil {
            layout.closeDetails()
            workspaceStore.reconcileForNoSession()
        }
    }

    /// 布局桥签名（会话 id + 布局值——onChange 需 Equatable；三态任一变化
    /// 或会话切换都驱动列宽重算）。
    private var workspaceLayoutSignature: String {
        let sid = appState.currentSessionId ?? ""
        return "\(sid)|\(workspaceStore.layout(for: sid).rawValue)"
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
                            renameTarget = .workspace(id: id, title: t?.title ?? "",
                                                      sessionCount: t?.sessionIds.count ?? 0)
                            renameField = t?.title ?? ""
                        },
                        onDeleteWorkspace: { id in
                            let t = snapshot.workspaces.first { $0.id == id }
                            // 【M7-Fix2 批2 B3·反馈24】N=侧栏可见口径
                            // （WOVisibleSessionCount 同源过滤，隐藏 blank
                            // 草稿不计）；删除范围仍=账本实数（commitDelete
                            // 一字不动——清单25 真机验收红线）。
                            deleteTarget = .workspace(id: id, title: t?.title ?? "",
                                                      sessionCount: WOVisibleSessionCount.count(
                                                        inLedger: t?.sessionIds ?? [],
                                                        sessions: snapshot.sessions,
                                                        currentSessionID: appState.currentSessionId))
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
        // 【批4 真机诊断】列表布局诊断 sheet（侧栏 footer 入口——布局快照
        // 直接展示/复制，不依赖文件 App）。
        .sheet(isPresented: $showListDiag) {
            WOListDiagSheet()
        }
    }

    /// 【批4 真机诊断】布局快照 sheet（WOLayoutDiag.lastDump 全文展示 +
    /// 一键复制；用户在会话页滚动后打开侧栏点入即得最新快照）。
    private struct WOListDiagSheet: View {
        @Environment(\.dismiss) private var dismiss
        /// 打开时刻快照（WOLayoutDiag.lastDump 主线程写，此处主线程读）。
        private var dump: String { WOLayoutDiag.lastDump ?? "尚无快照（请先进任意会话并滚动几下，再打开本页）" }

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(dump)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .navigationTitle("列表布局诊断")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = dump
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }

    /// 侧栏 footer：设置真入口（齿轮 → 全窗设置面板；dsh SettingsRoot 语义）
    /// +【批4 真机诊断】列表布局诊断入口（取证期临时行，定位后移除）。
    private func footerBar(wide: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                showListDiag = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13))
                    if wide {
                        Text("列表诊断")
                            .font(.system(size: 13))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundColor(WOAlias.labelSecondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开列表布局诊断")
            Divider().opacity(0.3)
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
    }

    // MARK: - 中栏（Hero / 聊天）

    @ViewBuilder
    private var centerRegion: some View {
        if let sessionId = appState.currentSessionId {
            // 批C1：右栏开关钮在顶栏（WOConversationHead）——批12+右栏重构
            // 批1：切换改 store.toggleWorkspace（hidden↔split 单值三态；full
            // 不经由 toggle，"toggle 不许吞掉对话"）。
            WOChatView(environment: environment, sessionId: sessionId,
                       onToggleRightSidebar: {
                           workspaceStore.toggleWorkspace(sessionId: sessionId)
                       },
                       onOpenAgentBrowser: { url in
                           // 批12+右栏批2 修（2026-09-27 用户实测"轻提示点两次
                           // 建两个浏览页"）：轻提示点击改走 AI 页签复用路径
                           // （openAgentBrowser 单活动页签语义）——此前走
                           // openRouter.browser 恒新建。用户主动点击=展开落点。
                           workspaceStore.openAgentBrowser(sessionId: sessionId,
                                                           url: url, openSidebar: true)
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
        if let sessionId = appState.currentSessionId {
            // 批B2：有会话恒挂载（dsh AppFrame.tsx:35-38「右栏宽 0 时保持挂载
            // 不卸载」）——批12+右栏重构批1：状态源换 WOWorkspaceStore（按会话
            // 作用域），收起=layout hidden（列宽 0 + 禁触门禁保留）。
            WorkspaceRightSidebarView(store: workspaceStore,
                                      environment: environment,
                                      sessionId: sessionId)
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
        case .workspace(let id, _, _):
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
        case .workspace(let id, _, _):
            // M8 批3 D 件：级联删除收口 WorkspaceController.deleteCascade
            // （关活写柄 → 账本逐会话删（lineage 后代随删，jsonl+索引行走
            // SessionStore 删除缝）→ 注册记录删除）。旧 `registry.delete`
            // 直呼（记录保留语义）退役——与 SessionsSidebarView 同一缝。
            let record = environment.workspaceRegistry.get(id)
            let seam = WorkspaceController.WorkspaceSessionDeletionSeam(
                deleteWithDescendants: { [sessionStore = environment.sessionStore] sid in
                    try await sessionStore.deleteSessionWithDescendants(id: sid)
                })
            Task { @MainActor in
                do {
                    let outcome = try await environment.workspaceController.deleteCascade(
                        id: id, sessionDeletion: seam)
                    // 清理选择态/草稿（D 件：选中会话随工作区删除）。
                    for sid in outcome.removedSessionIds { appState.purgeDraft(for: sid) }
                    if case .session(let selectedID) = environment.selection,
                       outcome.removedSessionIds.contains(selectedID) {
                        environment.selection = .none
                    }
                    environment.sessionsRevision += 1
                    // 项目目录删除段（批12+ 删除 C 语义——仅 App 管控 projects
                    // 内路径；外选真实目录绝不触碰）。项目桶 wanwo-memory/
                    // wanwo-notes 随目录级联（预期内，c2-report 登记）。
                    if let record,
                       WanWoPaths.isProjectsGuestPath(record.path),
                       record.path != WanWoPaths.projectsLinuxDir,
                       let hostDir = WanWoPaths.projectsHostRoot(forGuestPath: record.path) {
                        try? FileManager.default.removeItem(at: hostDir)
                        IshExecutorBridge.setProjectDirectories(
                            environment.workspaceRegistry.list().map(\.path)
                                .filter { WanWoPaths.isProjectsGuestPath($0)
                                    && $0 != WanWoPaths.projectsLinuxDir })
                    }
                } catch {
                    environment.sessionActionError =
                        "删除工作区失败：\(String(describing: error))"
                }
            }
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
                case .workspace(_, let title, let count):
                    // M8 批3 D 件：N=账本实数（进弹窗时定格）。
                    return count > 0
                        ? "将删除工作区「\(title)」，将同时删除 \(count) 个对话及其全部记录。该操作不可撤销。"
                        : "将删除工作区「\(title)」。该操作不可撤销。"
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

// MARK: - 集中式图片全屏预览（P2-1c 修5 → 【M7 种子① 件 D 重做 2026-09-28】）

/// 全屏图片预览：UIScrollView 手势仲裁缩放面 + 长按菜单（复制/存相册/分享）。
///
/// 语义源（逐行移植，禁简化——派单铁律）：
///   · OpenMinis src/ios/Views/Chat/Media/ImagePreview.swift
///     ImagePreviewContent（:125-152）+ ImagePreviewContentView（:155-383）
///     ——双指捏合 midpoint 锚定 / 单指下拉 dismiss（跟手 1:1 +
///     lateralDriftFactor 0.5 + 阈值 80 弹回 + backdrop alpha 渐隐）/
///     双击 1x↔max（tap 位置锚定 zoom to rect）/ scale>1 平移钳制 /
///     contentInset 居中 / 单指 pan maximumNumberOfTouches=1（双指让路
///     pinch）/ gestureRecognizerShouldBegin 竖直主导判定。
///   · 存相册 = 原件 ImagePreviewView.saveImageToPhotos（:514-534）逐行移植
///     （PHPhotoLibrary.requestAuthorization(.addOnly) +
///     creationRequestForAsset）。
///   · 分享 = 原件 MinisShareSheet.swift:15-101 逐行移植为 WOShareSheet
///     （png 临时文件 → UIActivityViewController，原件 :506-510 同形态）。
///   · 全屏隐藏状态栏 = 原件 ImagePreviewView:511 `.statusBar(hidden:)`——
///     iOS 16 基线改用新 API `.statusBarHidden(true)`（旧 API 已 deprecated，
///     【QA P1-1 修正 2026-09-28】补齐漏移植）。
/// 已拍板适配（派单简报件 D"用户拍板交互"，勿再议）：
///   ① 单击=关闭（onSingleTap→onClose；原件单击=chrome 切换）；✕ 按钮保留。
///   ② 复制/存相册/分享三功能：【真机实证 2026-09-29】contextMenu 叠
///     UIViewRepresentable 黑屏+锚点错乱 → 预案落地：UIKit
///     UILongPressGestureRecognizer（began 取锚点）+ 自绘浮层菜单
///     （菜单开着时单击=收菜单；✕ 关闭钮 zIndex 压过菜单层）。
///   ③ 存相册结果经既有 WOToast 呈现（菜单形态无原件顶栏按钮位承载
///     saveStatus；PHPhotoLibrary 授权/写入语义不变，saved 2s 复位同原件）。
struct ImageFullScreenPreview: View {
    let hostPath: String
    let onClose: () -> Void

    @State private var image: UIImage?
    /// 存相册状态机（原件 :394-396 SaveStatus 1:1；呈现面适配 toast，拍板③）。
    @State private var saveStatus: SaveStatus = .idle
    /// 存相册终态 toast 文案（nil = 不呈现）。
    @State private var saveToast: String?
    /// 分享面板（sheet 呈现 WOShareSheet，原件 :392 showShareSheet 同语义）。
    @State private var showShareSheet = false
    /// 长按菜单锚点（window 坐标=全屏 overlay 坐标；nil = 收起。拍板②预案：
    /// contextMenu 叠 UIViewRepresentable 真机实证黑屏+锚点错乱 → UIKit 长按
    /// +自绘浮层；M7-E3：换算链改 gr.location(in: self) → window.convert）。
    @State private var menuPoint: CGPoint?
    /// 菜单实测高度（.onAppear/.onChange 从背景 GeometryReader 回填——
    /// 四边钳制按实际尺寸，不用魔法数；M7-E3）。
    @State private var menuHeight: CGFloat = 0

    private enum SaveStatus {
        case idle, saving, saved, failed
    }

    /// 菜单实底色（iOS 系统编辑菜单深色风格≈#262629——深色实底白字，
    /// 任意图片底色可读；M7-E3，平台差异自定方案：dsh/OpenMinis 原件
    /// 均无自绘长按菜单先例，登记 analysis/m7-fix/e3-report.md）。
    private static let menuBackdropColor = Color(red: 0x26 / 255.0,
                                                 green: 0x26 / 255.0,
                                                 blue: 0x29 / 255.0)

    /// 菜单落位算式（纯函数，M7-E3）：默认在长按点上方（底边距锚点 8pt）；
    /// 顶边放不下 → 翻转到长按点下方；再按容器四边+菜单实测尺寸钳制。
    /// 单测缝：锚点钳制逻辑可抽测（算式 1:1 承载处在此）。
    static func menuPosition(anchor: CGPoint, container: CGSize,
                             menuWidth: CGFloat = 210,
                             menuHeight: CGFloat) -> CGPoint {
        let gap: CGFloat = 8
        let halfW = menuWidth / 2
        let halfH = menuHeight / 2
        var top = anchor.y - gap - menuHeight
        if top < 0 { top = anchor.y + gap } // 上方放不下 → 翻转到下方
        top = min(max(top, 0), max(container.height - menuHeight, 0))
        let x = min(max(anchor.x, halfW), max(container.width - halfW, halfW))
        return CGPoint(x: x, y: top + halfH)
    }

    var body: some View {
        ZStack {
            // 原件 ImagePreviewView :398-408 同款：全 bleed 黑底——
            // representable 在安全区内布局，外层黑底补 safe-area 带色差。
            Color.black.ignoresSafeArea()
            if let image {
                ImagePreviewContent(
                    image: image,
                    onDismiss: { onClose() },
                    // 拍板①：单击=关闭（原件 onSingleTap=chrome 切换）。
                    onSingleTap: { onClose() },
                    // 拍板②预案落地：UIKit 长按锚点 → 自绘浮层菜单。
                    onLongPress: { point in
                        withAnimation(.easeOut(duration: 0.15)) { menuPoint = point }
                    }
                )
                .ignoresSafeArea()
            } else {
                // 图片不可用兜底（旧宿主形态保留；无缩放面可挂——点按关闭）。
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("图片不可用")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .onTapGesture { onClose() }
            }
            // 长按浮层菜单（【M7-E3 修 2026-09-29】a) 背景改系统编辑菜单风格
            // 实底（深色实底白字，任意图片底色可读——.thinMaterial 叠深色图
            // 几乎隐形，真机实证）；b) 锚点修正：window 坐标 + 菜单在长按点
            // 上方弹出、越界自动翻转下方、四边按菜单实测尺寸钳制（原固定
            // -140 偏移 + UIScreen.main.bounds 魔法数退役）。
            if let image, let mp = menuPoint {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) { menuPoint = nil }
                            }
                        VStack(spacing: 0) {
                            lightboxMenuButton("复制图片", "doc.on.doc") {
                                UIPasteboard.general.image = image
                                menuPoint = nil
                            }
                            Divider().overlay(Color.white.opacity(0.15))
                            lightboxMenuButton(
                                saveStatus == .saving ? "正在存入相册…" : "存入相册",
                                "square.and.arrow.down",
                                disabled: saveStatus == .saving
                            ) {
                                saveImageToPhotos(image)
                                menuPoint = nil
                            }
                            Divider().overlay(Color.white.opacity(0.15))
                            lightboxMenuButton("分享…", "square.and.arrow.up") {
                                showShareSheet = true
                                menuPoint = nil
                            }
                        }
                        .frame(width: 210)
                        // 实底（iOS 系统编辑菜单深色风格）+ 实测高度（钳制用）。
                        .background(
                            GeometryReader { m in
                                Color.clear
                                    .onAppear { menuHeight = m.size.height }
                                    .onChange(of: m.size.height) { menuHeight = $0 }
                            }
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 13)
                                .fill(Self.menuBackdropColor)
                                .shadow(color: .black.opacity(0.35),
                                        radius: 12, y: 4)
                        )
                        .position(Self.menuPosition(anchor: mp, container: geo.size,
                                                    menuHeight: menuHeight))
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea()
                .zIndex(5)
            }
            // ✕ 按钮保留（拍板①）；zIndex 压过手势层
            //（原件 :415-416 注释同语义——iPad 上按钮在手势层之上）。
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .zIndex(10)
        }
        // 存相册结果 toast（拍板③）。
        .overlay(alignment: .bottom) {
            if let toast = saveToast {
                WOToast(text: toast,
                        icon: Image(systemName: saveStatus == .saved
                                        ? "checkmark.circle"
                                        : "exclamationmark.triangle"),
                        onDone: { saveToast = nil })
                    .padding(.bottom, 96)
            }
        }
        // 分享=原件 :506-510 形态：png 临时文件 → WOShareSheet。
        .sheet(isPresented: $showShareSheet) {
            if let data = image?.pngData(),
               let tmpURL = Self.writeTempImageFile(data: data) {
                WOShareSheet(url: tmpURL)
            }
        }
        // 【QA P1-1 修正 2026-09-28】原件 ImagePreviewView:511
        // `.statusBar(hidden: true)` 漏移植补齐——全屏预览隐藏状态栏；
        // iOS 16 基线用新 API statusBarHidden（原件旧 API 已 deprecated）。
        .statusBarHidden(true)
        .onAppear {
            image = UIImage(contentsOfFile: hostPath)
        }
    }

    /// 存相册（原件 :514-534 逐行移植——授权档/limited 放行/performChanges/
    /// 成功 2s 复位全同；终态呈现由按钮状态改 toast，拍板③）。
    private func lightboxMenuButton(_ title: String, _ icon: String,
                                    disabled: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 15))
                .foregroundStyle(disabled ? .white.opacity(0.4) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                // M7-E3：11→12（20pt 行高 + 24 = 44pt 触屏点击门禁）。
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func saveImageToPhotos(_ image: UIImage) {
        saveStatus = .saving
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    saveStatus = .failed
                    saveToast = "存入相册失败——未获授权"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    saveStatus = success ? .saved : .failed
                    saveToast = success ? "已存入相册" : "存入相册失败"
                    if success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            saveStatus = .idle
                        }
                    }
                }
            }
        }
    }

    /// 原件 :536-540 逐行移植。
    fileprivate static func writeTempImageFile(data: Data) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("share_image_\(UUID().uuidString).png")
        try? data.write(to: tmp)
        return tmp
    }
}

// MARK: - 全屏预览缩放面（M7 种子① 件 D · OpenMinis ImagePreview.swift 逐行移植）

/// Zoomable / pannable / pull-to-dismiss image surface. Backed by a UIKit
/// `UIScrollView` so gesture arbitration (1-finger pan vs. 2-finger pinch
/// vs. tap vs. double-tap) is handled by UIKit's recognizer system.
/// SwiftUI's composite gestures deferred all state updates until the
/// finger lifted and treated 2-finger touches as drags.
///
/// Behavior（原件 :107-118 注释逐行对齐）:
///   · 1 finger drag at scale 1  → pull-to-dismiss (follows finger 1:1).
///     Release past `dismissThreshold` fires `onDismiss`. Release short
///     of threshold springs back.
///   · 1 finger drag at scale > 1 → pan inside zoomed image, clamped
///     to edges. Not a dismiss.
///   · 2 finger pinch            → zoom around the pinch midpoint
///     (native UIScrollView behavior).
///   · double tap                → toggle between 1x and max zoom,
///     anchored at the tap location.
///   · single tap                → host callback (`onSingleTap`)——
///     万我拍板①：单击=关闭预览（原件 Minis 中为 chrome 切换）。
///
/// `horizontalDragLocked`（gallery 场景参数）万我全屏无画廊恒缺省 false；
/// 参数与语义逐行保留（禁简化），竖直主导判定随值生效。
struct ImagePreviewContent: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void
    var horizontalDragLocked: Bool = false
    var onSingleTap: (() -> Void)? = nil
    /// 长按菜单锚点透传（视图坐标）。
    var onLongPress: ((CGPoint) -> Void)? = nil
    /// Downward-pull distance (in pt) past which release triggers dismiss.
    var dismissThreshold: CGFloat = 80
    /// Maximum zoom scale for pinch / double-tap.
    var maximumScale: CGFloat = 3.0

    func makeUIView(context: Context) -> ImagePreviewContentView {
        let view = ImagePreviewContentView(image: image)
        view.onDismiss = onDismiss
        view.onSingleTap = onSingleTap
        view.onLongPress = onLongPress
        view.horizontalDragLocked = horizontalDragLocked
        view.dismissThreshold = dismissThreshold
        view.maximumScale = maximumScale
        return view
    }

    func updateUIView(_ view: ImagePreviewContentView, context: Context) {
        view.onDismiss = onDismiss
        view.onSingleTap = onSingleTap
        view.onLongPress = onLongPress
        view.horizontalDragLocked = horizontalDragLocked
        view.dismissThreshold = dismissThreshold
        view.maximumScale = maximumScale
    }
}

/// UIKit implementation backing `ImagePreviewContent`.
/// （原件 :155-383 逐行移植；仅两处抽出见 `shouldDismiss` /
/// `backdropDimProgress` 单测缝注释——算式 1:1，承载处改变。）
final class ImagePreviewContentView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onDismiss: (() -> Void)?
    var onSingleTap: (() -> Void)?
    /// 长按菜单锚点回调（视图坐标；拍板②预案落地：contextMenu 叠
    /// UIViewRepresentable 真机实证黑屏+锚点错乱，改 UIKit 长按+自绘浮层）。
    var onLongPress: ((CGPoint) -> Void)?
    var horizontalDragLocked: Bool = false
    var dismissThreshold: CGFloat = 80
    var maximumScale: CGFloat = 3.0 {
        didSet { scrollView.maximumZoomScale = maximumScale }
    }

    private let scrollView = UIScrollView()
    private let imageView: UIImageView
    private let backdrop = UIView()

    /// Translation applied to the scrollView during an in-progress
    /// dismiss drag. Lives on `scrollView.transform` (not
    /// contentOffset) so the scrollView's own clamping doesn't fight
    /// us.
    private var dismissTranslation: CGPoint = .zero
    /// Lateral drift factor so horizontal motion during dismiss still
    /// produces sideways movement (matches Photos.app feel).
    private let lateralDriftFactor: CGFloat = 0.5

    private var singleFingerDismissPan: UIPanGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var singleTap: UITapGestureRecognizer!

    init(image: UIImage) {
        self.imageView = UIImageView(image: image)
        super.init(frame: .zero)

        backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = maximumScale
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // NOTE: imageView uses manual frame layout (not autolayout) so
        // we can size it to the aspect-fitted rect within the scroll
        // view's bounds every time layoutSubviews runs. Pinning it to
        // the contentLayoutGuide instead would leave a tall image
        // running off-screen and appear to the user as "already zoomed".
        imageView.contentMode = .scaleToFill  // we compute the exact aspect-fit frame ourselves
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Single-finger dismiss pan. `maximumNumberOfTouches = 1` so
        // two-finger touches bypass this recognizer and reach the
        // scrollView's pinch recognizer instead.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        singleFingerDismissPan = pan
        addGestureRecognizer(pan)

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        // 长按菜单（拍板②预案：UILongPressGestureRecognizer 承载——
        // contextMenu 修饰符与 UIScrollView 缩放视图叠用真机黑屏）。
        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = self
        addGestureRecognizer(longPress)
        double.numberOfTapsRequired = 2
        double.numberOfTouchesRequired = 1
        addGestureRecognizer(double)
        doubleTap = double

        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        single.numberOfTouchesRequired = 1
        single.require(toFail: double)
        addGestureRecognizer(single)
        singleTap = single
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        sizeAndCenterImageView()
    }

    /// 件 D 单测缝（派单简报"dismissThreshold 判定可抽测"）：原件
    /// handleDismissPan :313-317 的内联释放判定抽出为纯函数——
    /// 算式 1:1（`pulled >= dismissThreshold`），仅承载处改变。
    static func shouldDismiss(pulledY: CGFloat, threshold: CGFloat) -> Bool {
        pulledY >= threshold
    }

    /// 件 D 单测缝：原件 applyDismissTransform :337-338 的内联渐隐进度
    /// 算式抽出为纯函数——1:1（clamp 到 [0, threshold] 再归一）。
    static func backdropDimProgress(pulledY: CGFloat, threshold: CGFloat) -> CGFloat {
        min(max(pulledY, 0), threshold) / threshold
    }

    /// Compute the aspect-fitted rect for the image within the
    /// scrollView's bounds and set the imageView's frame to it at
    /// zoom 1.  Also drives `contentSize` so the scrollView knows
    /// the true natural page size. When zoomed in, the imageView's
    /// frame is grown by `zoomScale` via `scrollView.zoom(...)`'s
    /// internal transform — we only re-center on layout changes.
    private func sizeAndCenterImageView() {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        let imgSize = imageView.image?.size ?? .zero
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        // Only recompute the base (zoomScale == 1) frame when the
        // scroll view is at its resting zoom. When zoomed in, the
        // content size and imageView frame are already managed by the
        // scroll view itself, and we just re-center via insets.
        if abs(scrollView.zoomScale - 1.0) < 0.01 {
            let ratio = min(boundsSize.width / imgSize.width,
                            boundsSize.height / imgSize.height)
            let fitted = CGSize(width: imgSize.width * ratio,
                                height: imgSize.height * ratio)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
        }

        // Re-center content so it sits in the middle of the viewport
        // when the content is smaller than the viewport (both at
        // zoom 1 and while zooming out).
        let xInset = max((boundsSize.width - scrollView.contentSize.width) / 2, 0)
        let yInset = max((boundsSize.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: yInset, left: xInset, bottom: yInset, right: xInset)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Re-center via contentInset as the content grows/shrinks
        // relative to the viewport.
        let boundsSize = scrollView.bounds.size
        let xInset = max((boundsSize.width - scrollView.contentSize.width) / 2, 0)
        let yInset = max((boundsSize.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: yInset, left: xInset, bottom: yInset, right: xInset)
    }

    // MARK: Dismiss pan

    @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else { return }

        switch gr.state {
        case .began, .changed:
            let t = gr.translation(in: self)
            dismissTranslation = CGPoint(x: t.x * lateralDriftFactor, y: t.y)
            applyDismissTransform()
        case .ended, .cancelled, .failed:
            let pulled = dismissTranslation.y
            if Self.shouldDismiss(pulledY: pulled, threshold: dismissThreshold) {
                onDismiss?()
                return
            }
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: {
                    self.dismissTranslation = .zero
                    self.applyDismissTransform()
                }
            )
        default:
            break
        }
    }

    private func applyDismissTransform() {
        scrollView.transform = CGAffineTransform(translationX: dismissTranslation.x,
                                                  y: dismissTranslation.y)
        let progress = Self.backdropDimProgress(pulledY: dismissTranslation.y,
                                                threshold: dismissThreshold)
        backdrop.alpha = 1.0 - progress * 0.6
    }

    // MARK: Taps

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let location = gr.location(in: imageView)
            let targetScale = maximumScale
            let size = scrollView.bounds.size
            let w = size.width / targetScale
            let h = size.height / targetScale
            let rect = CGRect(x: location.x - w / 2,
                              y: location.y - h / 2,
                              width: w,
                              height: h)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
        onSingleTap?()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let local = gr.location(in: self)
        // M7-E3：换算到 window 坐标再透传——本 UIView 在 fullScreenCover 内
        // ignoresSafeArea 铺满全屏，window 空间与宿主 ZStack 坐标空间一致；
        // 旧实现直接回传 self 坐标，宿主按屏幕空间钳制时锚点偏差（真机实证）。
        let windowPoint = window.map { $0.convert(local, from: self) } ?? local
        onLongPress?(windowPoint)
    }

    // MARK: UIGestureRecognizerDelegate

    // `UIView` has its own `gestureRecognizerShouldBegin(_:)` so this
    // needs `override` even though the signature originates on the
    // `UIGestureRecognizerDelegate` protocol.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === singleFingerDismissPan else { return true }
        guard scrollView.zoomScale <= 1.01 else { return false }
        if horizontalDragLocked {
            let v = singleFingerDismissPan.velocity(in: self)
            if abs(v.x) > abs(v.y) { return false }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return false
    }
}

// MARK: - 分享面板（M7 种子① 件 D · OpenMinis MinisShareSheet.swift 逐行移植）

/// UIKit UIActivityViewController wrapper for sharing a single URL
/// (file or link). 语义源：OpenMinis src/ios/Views/Chat/MinisShareSheet.swift
/// :15-101 逐行品牌折算（Minis→WO；注释内 minis:// 同折算为 wanwo://）——
/// 万我无 UIActivityViewController 既有先例（grep 实证仅 ShareLink），
/// 按派单口径照原件形态移植。
struct WOShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let safeURL = WOShareSheet.sanitizedShareURL(url) ?? url
        return UIActivityViewController(activityItems: [safeURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// [T-share-sheet-uti] Catalyst ShareKit crash mitigation
    /// (`Minis-2026-05-18-205557.ips`): `SHKItemIsPDF` →
    /// `UTTypeGetForIdentifier` traps on file URLs whose path extension
    /// produces a malformed UTI string (empty / non-ASCII / very long
    /// extensions, or when iOS can't map the extension to a registered
    /// type). Workaround: if the URL is a file URL whose extension
    /// isn't a short ASCII-alphanumeric token that resolves to a known
    /// `UTType`, copy the file to a `.bin` neighbor in `tmp/` so the
    /// share sheet sees a vanilla `public.data` UTI and skips the
    /// PDF-detection assert. http/https URLs pass through unchanged;
    /// other schemes (wanwo://, file:// with no path, etc.) return
    /// nil so the caller can fall back to the raw URL — those scheme
    /// strings reach ShareKit through a different code path and have
    /// not been observed to crash.
    static func sanitizedShareURL(_ url: URL) -> URL? {
        // Non-file URLs: only sanitize http/https; let everything else
        // through untouched (ShareKit handles raw URLs via the URL
        // branch, not the file-UTI branch).
        guard url.isFileURL else {
            return nil
        }
        let ext = url.pathExtension
        if isSafePathExtension(ext) {
            return nil // original URL is fine — no copy needed
        }
        // Make a sanitized copy in tmp with a `.bin` extension. We
        // keep the basename to retain hint value in the share UI but
        // strip non-ASCII / control chars so the receiving app sees a
        // sane filename.
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("share-sanitized", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let baseName = sanitizedBaseName(url.deletingPathExtension().lastPathComponent)
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let safeURL = tmpDir.appendingPathComponent("\(baseName)-\(stamp).bin")
        // If the source file doesn't exist or copy fails, returning
        // nil makes the caller fall back to the raw URL — better to
        // attempt the share with the original (and risk the assert
        // again) than to silently swallow the user's share request.
        guard fm.fileExists(atPath: url.path) else { return nil }
        try? fm.removeItem(at: safeURL)
        do {
            try fm.copyItem(at: url, to: safeURL)
            return safeURL
        } catch {
            return nil
        }
    }

    /// `true` iff `ext` is a short ASCII-alphanumeric string that maps
    /// to a registered `UTType`. Empty extensions, anything containing
    /// non-ASCII or punctuation, and extensions that don't resolve to
    /// a known type all fail the check — those are the inputs that
    /// can produce the ShareKit assertion.
    private static func isSafePathExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, ext.count <= 8 else { return false }
        for scalar in ext.unicodeScalars {
            // 0-9 / A-Z / a-z only.
            let v = scalar.value
            let isDigit = v >= 0x30 && v <= 0x39
            let isUpper = v >= 0x41 && v <= 0x5A
            let isLower = v >= 0x61 && v <= 0x7A
            if !(isDigit || isUpper || isLower) { return false }
        }
        return UTType(filenameExtension: ext) != nil
    }

    /// Strip non-ASCII-alnum / non-`-_.` chars from a basename so the
    /// share-sheet's filename hint is benign even if the source name
    /// contained CJK or punctuation that contributed to the original
    /// UTI mishap.
    private static func sanitizedBaseName(_ name: String) -> String {
        let allowed: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let filtered = String(name.filter { allowed.contains($0) })
        return filtered.isEmpty ? "share" : String(filtered.prefix(40))
    }
}
