//
//  WOWorkspaceBrowser.swift
//  WanWo
//
//  环 4 批 1 —— 工作区浏览区（细读文档 WorkspaceBrowser.tsx 1361 行核心子集）：
//  分组树 + 每组 5 条折叠（blank 不计数）+ 溢出钮 + 底部 fade + 扁平列表 + 真数据接线。
//  批 2 待补：搜索胶囊/拖拽排序/三 Modal/视图选项菜单/WorkspacePicker。
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

    @State private var localExpansion: Set<String> = [] // 5+ 展开态（瞬态，SessionTree 语义）
    // R1：reloadToken 手动刷新机制退役（D2 清偿）——写路径失效经 appState.sessionListEpoch
    // 推 body 重求值，快照闭包重拉自动生效；.id 整树重建是 9-19 闪跳反模式，禁用。
    /// R3a：搜索（本地 title 匹配；dsh 服务端 session.search 挂 F069 FTS 后升级）。
    @State private var searchQuery = ""
    @State private var searchActive = false
    /// 视图选项菜单开合。
    @State private var viewMenuOpen = false

    init(viewStore: WOWorkspaceViewStore,
                snapshot: @escaping () -> WOWorkspaceSnapshot,
                onOpenSession: @escaping (String) -> Void,
                onNewSession: @escaping (String?) -> Void) {
        self.viewStore = viewStore
        self.snapshot = snapshot
        self.onOpenSession = onOpenSession
        self.onNewSession = onNewSession
    }

    var body: some View {
        // listArea：flex1 margin 负值贴栏缘；treeBody 相对定位
        VStack(alignment: .leading, spacing: 0) {
            // sectionHeader（R3a：搜索框 + 视图选项 + 添加工作区入口挂 R3b）。
            HStack(spacing: 4) {
                if searchActive {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(WOAlias.labelTertiary)
                        TextField("搜索会话…", text: $searchQuery)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(WOAlias.labelTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                } else {
                    Text(viewStore.groupBy == .flat ? "会话" : "工作区")
                        .font(.system(size: 12))
                        .foregroundColor(WOAlias.labelTertiary)
                    Spacer(minLength: 0)
                    // 视图选项菜单（分组方式/排序方式——viewStore 持久化）。
                    Button {
                        viewMenuOpen.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12))
                            .foregroundColor(viewMenuOpen ? WOAlias.labelPrimary : WOAlias.labelTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        if viewMenuOpen {
                            WOWorkspaceViewMenu(open: $viewMenuOpen, viewStore: viewStore)
                        }
                    }
                    // 搜索切换（dsh 搜索圆钮；触屏恒显语义）。
                    Button {
                        searchActive = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 36)
            .padding(.leading, 4)
            .padding(.bottom, 4)
            .padding(.trailing, 12)
            .padding(.top, 2)

            listBody
        }
    }

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
        // R3a 搜索过滤：query 非空时组内只留匹配行、无命中组整组隐藏
        // （dsh 搜索语义：data-title contains；Escape 清空由 searchActive 关闭承接）。
        let groups = filteredGroups(all)

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if groups.allSatisfy({ $0.sessions.isEmpty }) || groups.isEmpty {
                    Text(searchQuery.isEmpty ? "暂无会话" : "无匹配会话")
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                }
                ForEach(groups) { group in
                    groupSection(group, snapshot: snap)
                }
            }
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
                             showStatus: statusShows(node),
                             onOpen: { onOpenSession(node.id) },
                             onRename: onRenameSession.map { cb in { cb(node.id) } },
                             onArchive: onArchiveSession.map { cb in { cb(node.id) } },
                             onDelete: onDeleteSession.map { cb in { cb(node.id) } })
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

    /// R3a：搜索过滤（本地 title contains，大小写不敏感）。
    private func filteredGroups(_ groups: [WOGroupNode]) -> [WOGroupNode] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
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

    private func statusShows(_ node: WOSessionNode) -> Bool {
        WOSessionStatus.resolve(for: node).showsDot
    }

    // ── 扁平列表（FlatList：严格最新优先）──
    @ViewBuilder
    private func flatList(_ snap: WOWorkspaceSnapshot) -> some View {
        let all = WOWorkspaceTreeDeriver.deriveFlat(
            sessions: snap.sessions, archived: snap.archived,
            currentSessionId: snap.currentSessionId,
            activeRunSessionIDs: snap.activeRunSessionIDs,
            pendingSessionIDs: snap.pendingSessionIDs)
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? all : all.filter {
            ($0.title ?? "新会话").lowercased().contains(q)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if rows.isEmpty {
                    Text("暂无会话")
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                }
                ForEach(rows) { node in
                    WOSessionRow(node: node, selected: snap.currentSessionId == node.id,
                                 showStatus: statusShows(node),
                                 onOpen: { onOpenSession(node.id) },
                                 onRename: onRenameSession.map { cb in { cb(node.id) } },
                                 onArchive: onArchiveSession.map { cb in { cb(node.id) } },
                                 onDelete: onDeleteSession.map { cb in { cb(node.id) } })
                }
            }
            .padding(.bottom, 16)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, WOSpecific.sidebarFill],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 视图选项菜单（R3a：分组方式/排序方式——viewStore 持久化，
// dsh WorkspaceBrowser stores 视图菜单语义；尾随对勾=WORowMenu 同款选中语义）

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
            menuRow("最近更新", selected: viewStore.orderBy == .updated) {
                viewStore.setOrderBy(.updated)
            }
            menuRow("手动排序", selected: viewStore.orderBy == .manual) {
                viewStore.setOrderBy(.manual)
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
            .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.interactiveBgHover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
