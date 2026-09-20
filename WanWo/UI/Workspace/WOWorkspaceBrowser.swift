//
//  WOWorkspaceBrowser.swift
//  WanWo
//
//  环 4 批 1 + R3b 全量补完（对照用户验收原型 wanwo-ui-prototype.html 左栏节 + digest-A）：
//  分组树/扁平列表 + 每组 5 条折叠（blank 不计数）+ 溢出钮 + 底部 fade +
//  段头三图标钮（视图选项/搜索/添加工作区）+ 搜索 250ms 防抖 +
//  添加工作区流（名称 Modal → WorkspaceAdoption → registry.create）+
//  手动排序拖拽（draggable/dropDestination，iOS 16 触屏长按拖起；
//  工作区行 → registry.insertBefore 分数键，会话行 → insertSessionBefore 组内账本）。
//

import SwiftUI

// MARK: - 数据快照（WorkspaceRegistry + SessionStore + 运行状态镜像 → 派生器输入）

struct WOWorkspaceSnapshot {
    let sessions: [SessionSummary]
    let workspaces: [WorkspaceRecord]
    let archived: Set<String>
    let currentSessionId: String?
    /// R1 状态点真值（D3 清偿）：AppEnvironment 既有镜像（M6.6 B4 建，ChatViewModel 上报）。
    /// pending 粒度=有/无（琥珀点）；种类文案区分（等待审批/等待回答）挂 R3 拆镜像时补。
    let activeRunSessionIDs: Set<String>
    let pendingSessionIDs: Set<String>

    init(sessions: [SessionSummary], workspaces: [WorkspaceRecord],
                archived: Set<String>, currentSessionId: String?,
                activeRunSessionIDs: Set<String> = [],
                pendingSessionIDs: Set<String> = []) {
        self.sessions = sessions
        self.workspaces = workspaces
        self.archived = archived
        self.currentSessionId = currentSessionId
        self.activeRunSessionIDs = activeRunSessionIDs
        self.pendingSessionIDs = pendingSessionIDs
    }

    /// dsh AppFrame detailsSession 语义：当前会话存在且非 blank。
    var hasDetails: Bool {
        guard let id = currentSessionId else { return false }
        return sessions.contains { $0.id == id && $0.title != nil }
    }
}

// MARK: - 浏览区（region slot 消费者）

struct WOWorkspaceBrowser: View {
    @ObservedObject var viewStore: WOWorkspaceViewStore
    /// 真数据源（WorkspaceRegistry/SessionStore 门面）
    let snapshot: () -> WOWorkspaceSnapshot
    var onOpenSession: (String) -> Void
    var onNewSession: (String?) -> Void
    /// R3a 行操作真动作（F072；有真动作才渲染菜单项=死按钮门禁内建）。
    var onRenameSession: ((String) -> Void)? = nil
    var onArchiveSession: ((String) -> Void)? = nil
    var onDeleteSession: ((String) -> Void)? = nil
    var onRenameWorkspace: ((String) -> Void)? = nil
    var onDeleteWorkspace: ((String) -> Void)? = nil

    /// 每组未展开可见普通会话数（COLLAPSED_SESSION_LIMIT=5，手册 768 行）
    static let collapsedSessionLimit = 5

    /// 拖拽 payload 前缀（旧 SessionsSidebarView 同款格式，跨视图一致）
    static let sessionPayloadPrefix = "wanwo:session:"
    static let workspacePayloadPrefix = "wanwo:workspace:"
    /// 搜索防抖（dsh SEARCH_DEBOUNCE_MS=250）
    static let searchDebounceNanos: UInt64 = 250_000_000

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState

    @State private var localExpansion: Set<String> = [] // 5+ 展开态（瞬态，SessionTree 语义）
    // R1：reloadToken 手动刷新机制退役（D2 清偿）——写路径失效经 appState.sessionListEpoch
    // 推 body 重求值，快照闭包重拉自动生效；.id 整树重建是 9-19 闪跳反模式，禁用。
    /// R3a/R3b：搜索（本地 title 匹配 + 250ms 防抖；dsh 服务端 session.search 挂 F069 FTS 后升级）。
    @State private var searchQuery = ""
    @State private var searchDebounced = ""
    @State private var searchActive = false
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    /// 视图选项菜单开合。
    @State private var viewMenuOpen = false
    /// R3b 添加工作区流（原型 wsModal：名称输入 + 创建；重名/空值门控）。
    @State private var addWorkspaceOpen = false
    @State private var addWorkspaceName = ""
    @State private var addWorkspaceBusy = false
    @State private var addWorkspaceError: String? = nil
    /// 创建成功/拖拽失败 toast（原型「工作区「X」已创建」）。
    @State private var toastText: String? = nil

    init(viewStore: WOWorkspaceViewStore,
                snapshot: @escaping () -> WOWorkspaceSnapshot,
                onOpenSession: @escaping (String) -> Void,
                onNewSession: @escaping (String?) -> Void,
                onRenameSession: ((String) -> Void)? = nil,
                onArchiveSession: ((String) -> Void)? = nil,
                onDeleteSession: ((String) -> Void)? = nil,
                onRenameWorkspace: ((String) -> Void)? = nil,
                onDeleteWorkspace: ((String) -> Void)? = nil) {
        self.viewStore = viewStore
        self.snapshot = snapshot
        self.onOpenSession = onOpenSession
        self.onNewSession = onNewSession
        self.onRenameSession = onRenameSession
        self.onArchiveSession = onArchiveSession
        self.onDeleteSession = onDeleteSession
        self.onRenameWorkspace = onRenameWorkspace
        self.onDeleteWorkspace = onDeleteWorkspace
    }

    /// 手动排序拖拽总开关：orderBy == .manual 且分组视图（扁平列表无序账本，不支持）。
    private var dragEnabled: Bool {
        viewStore.orderBy == .manual && viewStore.groupBy == .workspace
    }

    // MARK: Body（只组装）

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            listBody
        }
        .overlay(alignment: .top) {
            if let text = toastText {
                WOToast(text: text, icon: Image(systemName: "checkmark.circle"),
                        onDone: { toastText = nil })
                    .padding(.top, 8)
                    .zIndex(80)
            }
        }
        .fullScreenCover(isPresented: $addWorkspaceOpen, onDismiss: { resetAddWorkspace() }) {
            WOAddWorkspaceModal(
                name: $addWorkspaceName,
                busy: addWorkspaceBusy,
                duplicate: addWorkspaceNameDuplicate,
                error: addWorkspaceError,
                canCreate: canCommitAddWorkspace,
                onCancel: { addWorkspaceOpen = false },
                onCreate: { commitAddWorkspace() })
        }
    }

    // MARK: - 段头（原型 ws-bar：标题「工作区」12px/600 + 三个 24px 图标钮；
    // 搜索态隐藏标题与动作钮，搜索框 flex:1 接管）

    @ViewBuilder
    private var sectionHeader: some View {
        HStack(spacing: 4) {
            if searchActive {
                searchField
            } else {
                Text("工作区")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.2) // letter-spacing .2px
                    .foregroundColor(WOAlias.labelTertiary)
                Spacer(minLength: 0)
                headerActions
            }
        }
        .frame(height: 36)
        .padding(.leading, 4)
        .padding(.bottom, 4)
        .padding(.trailing, 12)
        .padding(.top, 2)
    }

    /// ws-actions：视图选项 / 搜索 / 添加工作区（24×24 命中区、13px 图标、r6 hover 底）。
    private var headerActions: some View {
        HStack(spacing: 2) {
            Button {
                viewMenuOpen.toggle()
            } label: {
                headerIcon("line.3.horizontal.decrease", active: viewMenuOpen)
            }
            .buttonStyle(.plain)
            .overlay {
                if viewMenuOpen {
                    WOWorkspaceViewMenu(open: $viewMenuOpen, viewStore: viewStore)
                }
            }

            Button {
                searchActive = true
            } label: {
                headerIcon("magnifyingglass", active: false)
            }
            .buttonStyle(.plain)

            Button {
                openAddWorkspace()
            } label: {
                headerIcon("plus", active: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func headerIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundColor(active ? WOAlias.labelSecondary : WOAlias.labelTertiary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? WOAlias.interactiveBgHover : .clear))
            .contentShape(Rectangle())
    }

    /// ws-search：28px 高、r10、module 底 + 0.5px l4 边；13px 输入、placeholder caption。
    /// 清空即时生效；非空 250ms 防抖后过滤（dsh SEARCH_DEBOUNCE_MS）。
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelCaption)
            TextField("搜索会话…", text: Binding(
                get: { searchQuery },
                set: { updateSearch($0) }))
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    updateSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(WOAlias.labelCaption)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 触屏承接原型 Escape 语义：清空并退出搜索态
            Button {
                exitSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOAlias.labelCaption)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 10).fill(WOSpecific.tip))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(WOAlias.borderL4, lineWidth: 0.5))
    }

    private func updateSearch(_ value: String) {
        searchQuery = value
        searchDebounceTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchDebounced = "" // 清空即时生效（原型 Escape/清空语义）
            return
        }
        searchDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.searchDebounceNanos)
            } catch {
                return // 已被新输入取消
            }
            searchDebounced = trimmed
        }
    }

    private func exitSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchQuery = ""
        searchDebounced = ""
        searchActive = false
    }

    // MARK: - 列表

    @ViewBuilder
    private var listBody: some View {
        let snap = snapshot()
        switch viewStore.groupBy {
        case .flat:
            flatList(snap)
        case .workspace:
            groupTree(snap)
        }
    }

    // ── 分组树（SessionTree 语义）──
    @ViewBuilder
    private func groupTree(_ snap: WOWorkspaceSnapshot) -> some View {
        let all = WOWorkspaceTreeDeriver.deriveGroups(
            sessions: snap.sessions, workspaces: snap.workspaces,
            archived: snap.archived, currentSessionId: snap.currentSessionId,
            activeRunSessionIDs: snap.activeRunSessionIDs,
            pendingSessionIDs: snap.pendingSessionIDs,
            view: viewStore)
        // R3a 搜索过滤：防抖 query 非空时组内只留匹配行、无命中组整组隐藏。
        let groups = filteredGroups(all)

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if groups.allSatisfy({ $0.sessions.isEmpty }) || groups.isEmpty {
                    Text(searchDebounced.isEmpty ? "暂无会话" : "无匹配会话")
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                }
                ForEach(groups) { group in
                    groupSection(group, snapshot: snap)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .bottom) {
            // fade：24px 渐变（transparent → sidebar-fill），pointer-events none
            LinearGradient(colors: [.clear, WOSpecific.sidebarFill],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func groupSection(_ group: WOGroupNode, snapshot: WOWorkspaceSnapshot) -> some View {
        let expanded = viewStore.isExpanded(group.key)
        // 每组 5 条折叠：blank 行始终保留不计数（手册 769 行）
        let blanks = group.sessions.filter { $0.blank }
        let normal = group.sessions.filter { !$0.blank }
        let sessionExpanded = localExpansion.contains(group.key) || expanded
        let visibleNormal = sessionExpanded ? normal : Array(normal.prefix(Self.collapsedSessionLimit))
        let hiddenCount = max(0, normal.count - Self.collapsedSessionLimit)

        VStack(alignment: .leading, spacing: 2) {
            WOProjectRow(
                label: group.label,
                isUngrouped: group.key == WOWorkspaceTreeDeriver.ungroupedKey,
                expanded: expanded,
                onToggle: { viewStore.setGroupExpanded(group.key, !expanded) },
                onCreate: group.workspaceId != nil ? { onNewSession(group.workspaceId) } : nil,
                // R3a：组行真动作（未分组桶无 rename/delete——dsh UNGROUPED 语义）。
                onRename: (group.workspaceId != nil && onRenameWorkspace != nil)
                    ? { onRenameWorkspace?(group.workspaceId!) } : nil,
                onDelete: (group.workspaceId != nil && onDeleteWorkspace != nil)
                    ? { onDeleteWorkspace?(group.workspaceId!) } : nil
            )
            // 手动排序：组头拖拽（payload=wanwo:workspace:）——落别组头 = 移到该组前
            // （registry.insertBefore 分数键中点插入）；未分组桶非 registry 行，不挂。
            .modifier(WODragModifiers(
                payload: (dragEnabled && group.workspaceId != nil)
                    ? Self.workspacePayloadPrefix + group.workspaceId! : nil,
                onDrop: { commitGroupHeaderDrop($0, group: group) }))

            // blank 占位行置顶（提升语义），后接可见普通行
            ForEach(blanks) { node in
                WOSessionRow(node: node, selected: snapshot.currentSessionId == node.id,
                             showStatus: false, onOpen: { onOpenSession(node.id) },
                             onRename: onRenameSession.map { cb in { cb(node.id) } },
                             onArchive: onArchiveSession.map { cb in { cb(node.id) } },
                             onDelete: onDeleteSession.map { cb in { cb(node.id) } })
            }
            ForEach(visibleNormal) { node in
                WOSessionRow(node: node, selected: snapshot.currentSessionId == node.id,
                             showStatus: true,
                             onOpen: { onOpenSession(node.id) },
                             onRename: onRenameSession.map { cb in { cb(node.id) } },
                             onArchive: onArchiveSession.map { cb in { cb(node.id) } },
                             onDelete: onDeleteSession.map { cb in { cb(node.id) } })
                // 手动排序：会话行拖拽（组内账本序——insertSessionBefore；
                // 未分组桶无账本、blank 占位行不参与拖拽）
                .modifier(WODragModifiers(
                    payload: dragSessionPayload(node: node, group: group),
                    onDrop: { commitSessionDrop($0, target: node, group: group) }))
            }

            if hiddenCount > 0 {
                WOOverflowButton(hiddenCount: hiddenCount, expanded: sessionExpanded) {
                    if sessionExpanded {
                        localExpansion.remove(group.key)
                    } else {
                        localExpansion.insert(group.key)
                    }
                }
            }
        }
    }

    private func dragSessionPayload(node: WOSessionNode, group: WOGroupNode) -> String? {
        guard dragEnabled, group.workspaceId != nil, !node.blank else { return nil }
        return Self.sessionPayloadPrefix + node.id
    }

    /// R3a：搜索过滤（本地 title contains，大小写不敏感；防抖 query）。
    private func filteredGroups(_ groups: [WOGroupNode]) -> [WOGroupNode] {
        let q = searchDebounced.lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let hit = group.sessions.filter {
                ($0.title ?? "新会话").lowercased().contains(q)
            }
            guard !hit.isEmpty else { return nil }
            return WOGroupNode(key: group.key, workspaceId: group.workspaceId,
                               label: group.label, createdAt: group.createdAt,
                               sessions: hit, containsCurrent: group.containsCurrent)
        }
    }

    // ── 扁平列表（FlatList：严格最新优先；无序账本，不挂拖拽）──
    @ViewBuilder
    private func flatList(_ snap: WOWorkspaceSnapshot) -> some View {
        let all = WOWorkspaceTreeDeriver.deriveFlat(
            sessions: snap.sessions, archived: snap.archived,
            currentSessionId: snap.currentSessionId,
            activeRunSessionIDs: snap.activeRunSessionIDs,
            pendingSessionIDs: snap.pendingSessionIDs)
        let q = searchDebounced.lowercased()
        let rows = q.isEmpty ? all : all.filter {
            ($0.title ?? "新会话").lowercased().contains(q)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if rows.isEmpty {
                    Text(searchDebounced.isEmpty ? "暂无会话" : "无匹配会话")
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                }
                ForEach(rows) { node in
                    WOSessionRow(node: node, selected: snap.currentSessionId == node.id,
                                 showStatus: !node.blank,
                                 onOpen: { onOpenSession(node.id) },
                                 onRename: onRenameSession.map { cb in { cb(node.id) } },
                                 onArchive: onArchiveSession.map { cb in { cb(node.id) } },
                                 onDelete: onDeleteSession.map { cb in { cb(node.id) } })
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, WOSpecific.sidebarFill],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 手动排序落点（draggable payload → insertBefore / insertSessionBefore）

    /// 会话行落点：锚 = 被落行自身（插到其前）；落自身 = 原位 no-op。
    private func commitSessionDrop(_ items: [String], target: WOSessionNode,
                                   group: WOGroupNode) -> Bool {
        guard dragEnabled, let workspaceId = group.workspaceId else { return false }
        for item in items where item.hasPrefix(Self.sessionPayloadPrefix) {
            let sid = String(item.dropFirst(Self.sessionPayloadPrefix.count))
            if sid == target.id { return true } // 原位
            do {
                try environment.workspaceController.insertSessionBefore(
                    sessionId: sid, beforeSessionId: target.id, in: workspaceId)
                appState.bumpSessionList() // 推 WORootFrame 快照重算（列表纪元刷新）
                return true
            } catch {
                toastText = "移动失败：\(Self.shortError(error))"
                return false
            }
        }
        return false
    }

    /// 组头落点：工作区 payload → 移到该组前（insertBefore 分数键）；
    /// 会话 payload → 移到组首（锚 = 组内第一个非 blank 非自身行；空组追加末尾）。
    private func commitGroupHeaderDrop(_ items: [String], group: WOGroupNode) -> Bool {
        guard dragEnabled else { return false }
        for item in items {
            if item.hasPrefix(Self.workspacePayloadPrefix) {
                let wid = String(item.dropFirst(Self.workspacePayloadPrefix.count))
                guard let anchorId = group.workspaceId, wid != anchorId else { return false }
                do {
                    _ = try environment.workspaceController.insertBefore(
                        id: wid, beforeId: anchorId)
                    appState.bumpSessionList()
                    return true
                } catch {
                    toastText = "移动失败：\(Self.shortError(error))"
                    return false
                }
            }
            if item.hasPrefix(Self.sessionPayloadPrefix) {
                let sid = String(item.dropFirst(Self.sessionPayloadPrefix.count))
                guard let workspaceId = group.workspaceId else { return false }
                let anchor = group.sessions.first { !$0.blank && $0.id != sid }?.id
                do {
                    try environment.workspaceController.insertSessionBefore(
                        sessionId: sid, beforeSessionId: anchor, in: workspaceId)
                    appState.bumpSessionList()
                    return true
                } catch {
                    toastText = "移动失败：\(Self.shortError(error))"
                    return false
                }
            }
        }
        return false
    }

    private static func shortError(_ error: Error) -> String {
        if let e = error as? WorkspaceRegistryError {
            switch e {
            case .moveInvalid: return "会话或锚不在该组账本"
            case .attachRejected(let id): return "会话 \(id) 不满足挂载校验"
            case .pathNotFound(let path): return "路径不存在：\(path)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - 添加工作区流（原型 wsModal → WorkspaceAdoption → registry.create）

    private var addWorkspaceNameTrimmed: String {
        addWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 重名门控：与任一既有工作区同名 → 阻止创建并提示
    /// （registry 幂等会复用同路径实体——门控让用户显式改名的意图可见）。
    private var addWorkspaceNameDuplicate: Bool {
        guard !addWorkspaceNameTrimmed.isEmpty else { return false }
        return snapshot().workspaces.contains { $0.title == addWorkspaceNameTrimmed }
    }

    /// 空值/重名/进行中门控 → 创建钮 disabled（原型 wsCreate.disabled 语义）。
    private var canCommitAddWorkspace: Bool {
        !addWorkspaceNameTrimmed.isEmpty && !addWorkspaceNameDuplicate && !addWorkspaceBusy
    }

    private func openAddWorkspace() {
        addWorkspaceError = nil
        addWorkspaceName = ""
        addWorkspaceOpen = true
    }

    private func resetAddWorkspace() {
        addWorkspaceName = ""
        addWorkspaceBusy = false
        addWorkspaceError = nil
    }

    private func commitAddWorkspace() {
        let name = addWorkspaceNameTrimmed
        guard canCommitAddWorkspace else { return }
        addWorkspaceBusy = true
        addWorkspaceError = nil
        do {
            // 建项目目录（幂等）+ registry.create（幂等）——「输入名字即全部」
            // （与旧侧栏/空态页共用 WorkspaceAdoption；dsh「选择目录就是添加工作区的全部」）。
            let workspace = try WorkspaceAdoption.adopt(name: name, environment: environment)
            addWorkspaceBusy = false
            addWorkspaceOpen = false
            resetAddWorkspace()
            appState.bumpSessionList()
            toastText = "工作区「\(workspace.title)」已创建"
        } catch {
            addWorkspaceBusy = false
            addWorkspaceError = "添加失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 添加工作区 Modal（原型 wsModal：380px 卡 r24、44px r22 输入、取消/创建）

struct WOAddWorkspaceModal: View {
    @Binding var name: String
    let busy: Bool
    let duplicate: Bool
    let error: String?
    let canCreate: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var nameFocused: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(WOAlias.bgMask1)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            card
                .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.96))
                .offset(y: reduceMotion ? 0 : (shown ? 0 : 10))
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { nameFocused = true }
            DispatchQueue.main.async { // 延帧（onAppear 首帧前动画被吞铁律）
                withAnimation(reduceMotion ? nil : WOMotion.standardSpring) { shown = true }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加工作区")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(WOAlias.labelPrimary)
            Text("给新工作区起个名字，创建后立即可用。")
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelSecondary)

            TextField("工作区名称", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($nameFocused)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 22).fill(WOSpecific.tip))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(duplicate ? WOAlias.stateWarnSecondary
                                            : WOAlias.borderL4, lineWidth: 0.5))
                .disabled(busy)
                .onSubmit { if canCreate { onCreate() } }

            if duplicate {
                Text("已存在同名工作区，换个名字吧。")
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateWarnLabel)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateErrorPrimary)
            }

            HStack(spacing: 10) {
                Button {
                    onCancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.bgLayer3)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .woPressable()

                Button {
                    onCreate()
                } label: {
                    Text(busy ? "创建中…" : "创建")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(canCreate ? WOAlias.buttonPrimaryFill
                                            : WOAlias.buttonPrimaryDimmed))
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .woPressable()
            }
        }
        .padding(24)
        .frame(width: min(380, UIScreen.main.bounds.width - 48), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(WOAlias.bgLayer2))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
        .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 0)
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(WOAlias.borderL4, lineWidth: 0.5))
    }
}

// MARK: - 手动排序拖拽修饰（draggable + dropDestination 条件收敛；
// payload nil = 不挂——iOS 16 触屏长按拖起，旧 SidebarDragModifiers 同款形态）

private struct WODragModifiers: ViewModifier {
    let payload: String?
    let onDrop: ([String]) -> Bool

    func body(content: Content) -> some View {
        if let payload {
            content
                .draggable(payload)
                .dropDestination(for: String.self) { items, _ in
                    onDrop(items)
                }
        } else {
            content
        }
    }
}

// MARK: - 视图选项菜单（R3a：分组方式/排序方式——viewStore 持久化，
// 原型 viewOptMenu 语义：尾随对勾选中；排序行序=原型（手动排序/最近更新））

struct WOWorkspaceViewMenu: View {
    @Binding var open: Bool
    @ObservedObject var viewStore: WOWorkspaceViewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuLabel("分组方式")
            menuRow("按工作区", selected: viewStore.groupBy == .workspace) {
                viewStore.setGroupBy(.workspace)
            }
            menuRow("单列表", selected: viewStore.groupBy == .flat) {
                viewStore.setGroupBy(.flat)
            }
            Divider().opacity(0.5).padding(.vertical, 4)
            menuLabel("排序方式")
            menuRow("手动排序", selected: viewStore.orderBy == .manual) {
                viewStore.setOrderBy(.manual)
            }
            menuRow("最近更新", selected: viewStore.orderBy == .updated) {
                viewStore.setOrderBy(.updated)
            }
        }
        .padding(4)
        .frame(width: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(WOSpecific.menu)
                .shadow(color: .black.opacity(0.04), radius: 8)
                .shadow(color: .black.opacity(0.05), radius: 20)
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(WOAlias.borderL1, lineWidth: 0.5))
        )
        .transition(.opacity.animation(WOMotion.bezier(duration: WOMotion.t2)))
        .zIndex(60)
    }

    private func menuLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(WOAlias.labelTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func menuRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            open = false
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.stateBusinessPrimary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
