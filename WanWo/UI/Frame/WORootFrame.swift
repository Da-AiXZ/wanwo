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
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState

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
        let snapshot = makeSnapshot()
        WOAppFrame(
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
                WOSlotPlaceholder(text: wide ? "设置入口 · R5" : nil, quiet: false)
            }
        )
    }

    // MARK: - 中栏（Hero / 聊天）

    @ViewBuilder
    private var centerRegion: some View {
        if let sessionId = appState.currentSessionId {
            WOChatView(environment: environment, sessionId: sessionId)
                .id(sessionId)
        } else {
            WOChatHero(onNewSession: { newSession(in: nil) })
        }
    }

    // MARK: - 详情栏（右栏四页签归 R4）

    private var detailsRegion: some View {
        ZStack(alignment: .topTrailing) {
            WOSlotPlaceholder(text: "详情栏 · 右栏四页签 R4", quiet: false)
            Button { layout.closeDetails() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(WOAlias.interactiveBgHover))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .padding(.top, 14)
        }
    }

    // MARK: - 动作

    /// 新会话统一入口：建 blank 会话，带 workspaceId 则挂组。
    private func newSession(in workspaceId: String?) {
        if let s = try? environment.sessionStore.createSession(cwd: nil) {
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
            TextField("名称", text: $renameField)
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
