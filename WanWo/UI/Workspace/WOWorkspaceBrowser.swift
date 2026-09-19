//
//  WOWorkspaceBrowser.swift
//  WanWo
//
//  环 4 批 1 —— 工作区浏览区（细读文档 WorkspaceBrowser.tsx 1361 行核心子集）：
//  分组树 + 每组 5 条折叠（blank 不计数）+ 溢出钮 + 底部 fade + 扁平列表 + 真数据接线。
//  批 2 待补：搜索胶囊/拖拽排序/三 Modal/视图选项菜单/WorkspacePicker。
//

import SwiftUI

// MARK: - 数据快照（WorkspaceRegistry + SessionStore → 派生器输入）

struct WOWorkspaceSnapshot {
    let sessions: [SessionSummary]
    let workspaces: [WorkspaceRecord]
    let archived: Set<String>
    let currentSessionId: String?

    init(sessions: [SessionSummary], workspaces: [WorkspaceRecord],
                archived: Set<String>, currentSessionId: String?) {
        self.sessions = sessions
        self.workspaces = workspaces
        self.archived = archived
        self.currentSessionId = currentSessionId
    }
}

// MARK: - 浏览区（region slot 消费者）

struct WOWorkspaceBrowser: View {
    @ObservedObject var viewStore: WOWorkspaceViewStore
    /// 真数据源（WorkspaceRegistry/SessionStore 门面）
    let snapshot: () -> WOWorkspaceSnapshot
    var onOpenSession: (String) -> Void
    var onNewSession: (String?) -> Void
    /// 重命名/删除/分叉/归档动作（环 4 批 2 接 Modal 与 registry 写路径；批 1 菜单项隐藏）
    var onRenameSession: ((String) -> Void)? = nil
    var onDeleteWorkspace: ((String) -> Void)? = nil

    /// 每组未展开可见普通会话数（COLLAPSED_SESSION_LIMIT=5，手册 768 行）
    static let collapsedSessionLimit = 5

    @State private var localExpansion: Set<String> = [] // 5+ 展开态（瞬态，SessionTree 语义）
    @State private var reloadToken = 0

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
            // sectionHeader：批 1 极简（搜索/视图选项/添加工作区 = 批 2）
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(viewStore.groupBy == .flat ? "会话" : "工作区")
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.labelTertiary)
            }
            .frame(height: 36)
            .padding(.leading, 4)
            .padding(.bottom, 4)
            .padding(.trailing, -4)
            .padding(.top, 2)

            listBody
        }
        .id(reloadToken)
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
        let groups = WOWorkspaceTreeDeriver.deriveGroups(
            sessions: snap.sessions, workspaces: snap.workspaces,
            archived: snap.archived, currentSessionId: snap.currentSessionId,
            view: viewStore)

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if groups.allSatisfy({ $0.sessions.isEmpty }) {
                    Text("暂无会话")
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
                onCreate: group.workspaceId != nil ? { onNewSession(group.workspaceId) } : nil
            )

            // blank 占位行置顶（提升语义），后接可见普通行
            ForEach(blanks) { node in
                WOSessionRow(node: node, selected: snap.currentSessionId == node.id,
                             showStatus: false, onOpen: { onOpenSession(node.id) })
            }
            ForEach(visibleNormal) { node in
                WOSessionRow(node: node, selected: snap.currentSessionId == node.id,
                             showStatus: statusShows(node),
                             onOpen: { onOpenSession(node.id) })
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

    private func statusShows(_ node: WOSessionNode) -> Bool {
        WOSessionStatus.resolve(for: node).showsDot
    }

    // ── 扁平列表（FlatList：严格最新优先）──
    @ViewBuilder
    private func flatList(_ snap: WOWorkspaceSnapshot) -> some View {
        let rows = WOWorkspaceTreeDeriver.deriveFlat(
            sessions: snap.sessions, archived: snap.archived,
            currentSessionId: snap.currentSessionId)

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
                                 onOpen: { onOpenSession(node.id) })
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
