//
//  WORootFrame.swift
//  WanWo
//
//  R1 诚实化改造（analysis/11-ui-design.md §十二 R1；11-ui-design §十二 R1）：
//  哨兵退役 → appState 真信号（①当前会话唯一权威，D1 清偿）；
//  列表自动刷新（②epoch 驱动，D2 清偿）；hasDetailsSession 真判定（④，D4 清偿）；
//  状态点真值（③AppEnvironment 既有镜像 → snapshot → 派生器，D3 清偿）。
//

import SwiftUI

struct WORootFrame: View {
    /// 新会话统一入口：建 blank 会话，带 workspaceId 则挂组，否则落未分组桶
    private func newSession(in workspaceId: String?) {        if let s = try? environment.sessionStore.createSession(cwd: nil) {
            if let wsId = workspaceId {
                try? environment.workspaceRegistry.attachSession(sessionId: s.id, to: wsId)
            }
            // R1：当前会话真信号（唯一入口；点行/旧界面/深链同写 appState）。
            appState.openSession(s.id)
        }
    }

    // MARK: - R3a 行操作动作（F072；API=既有路径：setTitle/archiveSession/deleteSession）

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let target = renameTarget else { return }
        switch target {
        case .session(let id, _):
            // F072 session.rename 折算：GRDB 索引标题直写（旧侧栏 :1040 同路）。
            environment.database.setTitle(id: id, title: name)
        case .workspace(let id, _):
            _ = try? environment.workspaceRegistry.renameTitle(id: id, title: name)
        }
        renameTarget = nil
    }

    private func commitArchive(_ id: String) {
        // 归档无对话框（dsh 语义；归档会话从列表隐藏——恢复入口不做的用户裁定）。
        try? environment.workspaceController.archiveSession(sessionId: id)
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        switch target {
        case .session(let id, _):
            appState.sessionRemoved(id) // 选中收敛先行（中栏切走→写柄 close）
            Task { await environment.deleteSession(id: id) }
        case .workspace(let id, _):
            // registry delete：组内会话回落未分组（账本/目录不动，幂等）。
            _ = try? environment.workspaceRegistry.delete(id: id)
        }
        deleteTarget = nil
    }

    @StateObject private var layout = WOLayoutStore()
    @StateObject private var viewStore = WOWorkspaceViewStore()
    @EnvironmentObject private var environment: AppEnvironment
    /// R1：App 级会话真值源（当前会话/列表纪元）。
    @EnvironmentObject private var appState: WOAppState

    // MARK: - R3a 行操作状态（重命名/删除确认 Modal；归档无对话框=dsh 语义）

    private enum R3Target: Equatable {
        case session(id: String, title: String)
        case workspace(id: String, title: String)
        var id: String {
            switch self {
            case .session(let id, _), .workspace(let id, _): return id
            }
        }
        var title: String {
            switch self {
            case .session(_, let title), .workspace(_, let title): return title
            }
        }
    }

    @State private var renameTarget: R3Target?
    @State private var renameText = ""
    @State private var deleteTarget: R3Target?

    var body: some View {
        // 快照一次求值：列表 + 派生输入 + hasDetailsSession 共用（同步 actor 读沿
        // 环4批1 既有模式；写路径失效经 appState.sessionListEpoch 推重渲）。
        let sessions = environment.sessionStore.listSessions()
        let snapshot = WOWorkspaceSnapshot(
            sessions: sessions,
            workspaces: environment.workspaceRegistry.list(),
            archived: environment.workspaceRegistry.archivedSessionIDs(),
            currentSessionId: appState.currentSessionId,
            activeRunSessionIDs: environment.activeRunSessionIDs,
            pendingSessionIDs: environment.pendingInteractionSessionIDs)

        WOAppFrame(
            store: layout,
            // R1：真判定——当前会话存在且非 blank（dsh AppFrame detailsSession 语义；
            // 骨架期恒 true 于本环退役，D4 清偿）。
            hasDetailsSession: snapshot.hasDetails,
            sidebar: { collapsed, width in
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
                                onOpenSession: { sessionId in
                                    // 真打开：置当前会话 → 中栏挂 WOChatView
                                    appState.openSession(sessionId)
                                },
                                onNewSession: { workspaceId in
                                    newSession(in: workspaceId)
                                },
                                onRenameSession: { id in
                                    let t = snapshot.sessions.first { $0.id == id }
                                    renameTarget = .session(id: id, title: t?.title ?? "")
                                    renameText = t?.title ?? ""
                                },
                                onArchiveSession: { commitArchive($0) },
                                onDeleteSession: { id in
                                    let t = snapshot.sessions.first { $0.id == id }
                                    deleteTarget = .session(id: id, title: t?.title ?? "新会话")
                                },
                                onRenameWorkspace: { id in
                                    let t = snapshot.workspaces.first { $0.id == id }
                                    renameTarget = .workspace(id: id, title: t?.title ?? "")
                                    renameText = t?.title ?? ""
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
            },
            center: {
                // 无当前会话=Hero 引导；有=真聊天（.id 换会话换 ViewModel）
                if let sessionId = appState.currentSessionId {
                    WOChatView(environment: environment, sessionId: sessionId)
                        .id(sessionId)
                } else {
                    WOChatHero(onNewSession: { newSession(in: nil) })
                }
            },
            details: {
                // 详情栏槽：右栏四页签归 R4；关闭钮（codex 面板语义）
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
            },
            overlayLayer: { EmptyView() }
        )
        // R1：列表自动刷新机制——appState.sessionListEpoch（@Published）变化触发本
        // body 重求值 → 快照重拉 → 浏览区差分刷新（D2 清偿）。
        // 纪律：禁 .id(epoch) 整树重建——那正是 9-19"列表闪跳"的反模式（identity
        // 重置杀掉进行中手势；差分刷新靠 Equatable 派生输出，WOGroupNode 已 Equatable）。

        // ── R3a Modal：重命名 / 删除确认 ──
        .overlay {
            WOModal(
                open: renameTarget != nil,
                onClose: { renameTarget = nil },
                title: renameTarget.map { t in
                    if case .workspace = t { return "重命名工作区" }
                    return "重命名会话"
                } ?? "重命名"
            ) {
                TextField("名称", text: $renameText)
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

                    Button {
                        commitRename()
                    } label: {
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WOStatic.neutral00)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(renameText.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? WOAlias.buttonPrimaryDimmed : WOAlias.buttonPrimaryFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .woPressable()
                }
            }
        }
        .overlay {
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
