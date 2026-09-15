//
//  SessionsSidebarView.swift
//  WanWo
//
//  【P2-7 对齐 dsh 侧栏骨架重排 · 原件非本仓库】结构出处：
//  dsh ui-sidebar/src/client/SidebarRoot.tsx —— 列几何骨架 :126-222：
//  品牌行 :140-168（展开态品牌即新建会话快捷径，mark+name 双元素）、
//  独立新建钮 :189-200（IconNewChat 14 + 'session.new'「新会话」）、
//  浏览区 :202-209（sidebar.workspaces hole）、foot :211-219（设置入口底部钉住）。
//  dsh ui-workspace/src/client/rows/WorkspaceBrowser.tsx —— 浏览区：
//  section header :1072-1181（「会话」label + 搜索）、orderBy.updated 语义
//  :116-121（updatedAt 降序 + Session id 升序 tie-break）、
//  空态/搜索态词汇 :436-438/:783-785（'empty.none'「暂无会话」/
//  'search.noMatches'「无匹配会话」）、相对时间词典 :65-71（'time.ago'「{t}前」）。
//
//  【M6.6 B4 增量改造（§9 左侧栏欠账 6 项；语义源 WorkspaceBrowser.tsx +
//  B3 WorkspaceRegistry/Controller）——M3 以来稳定面保持增量，不推倒重写】
//    ① 工作区分组树（groups 行 + 组内会话 + Ungrouped 桶；SidebarGroupingModel
//      纯逻辑收口）+ 平铺模式保留（ViewOptionsMenu 切换——既有单层列表原样）；
//    ② 每组 5 条折叠 + 「展开其余 N 个会话」（COLLAPSED_SESSION_LIMIT=5；
//      blank 占位不计限额）；
//    ③ 拖拽排序（会话行 draggable → 组内 insertSessionBefore；工作区行 →
//      insertBefore；另配上移/下移菜单兜底——触屏拖拽形态标注见批次报告）；
//    ④ 行操作补齐（F072）：重命名（会话标题 / 工作区 groups.name）/ 归档
//      （archivedAtMs——归档行从列表隐去）；滑动删除保留（平铺模式既有交互）；
//    ⑤ section header 三钮：搜索（本地标题过滤保留，升级 = M9.3 FTS 后）/
//      视图选项（分组-平铺 + 排序）/ 添加工作区（+ → 目录选择 → 挂载 →
//      WorkspaceRegistry.create → 建会话 attach——dsh「选择目录就是添加
//      工作区的全部」语义，iOS 走 UIDocumentPicker 不可抗力映射）；
//    ⑥ blank 占位会话（title nil → 「新会话」行，新建会话即占位行）。
//  诊断区旧 ShellTestView 入口随本批降级为 DEBUG-only（ia-audit §3.1 计划；
//  终端迁入右侧栏 WorkspaceTerminalTabView）。
//

import SwiftUI

struct SessionsSidebarView: View {
    @ObservedObject var environment: AppEnvironment
    @Binding var selection: RootSelection

    @State private var summaries: [SessionSummary] = []
    @State private var creating = false
    /// dsh WorkspaceBrowser.tsx:875 query 状态（'search.placeholder'
    /// 「搜索会话…」）——WanWo 无 session.search 远程 API，本批=本地标题过滤。
    @State private var query = ""
    /// 待确认删除的行号集（A6：滑动删除 → 确认对话框 → 执行）。
    @State private var pendingDeleteOffsets: IndexSet?

    // MARK: M6.6（B4）§9 欠账状态

    /// 工作区快照（workspaceController.follow 帧驱动）。
    @State private var workspaces: [WorkspaceRecord] = []
    /// 分组/平铺视图（dsh ViewOptionsMenu groupBy 维；M3 平铺保留）。
    @State private var grouped = true
    /// 排序（平铺/未分组桶生效；组内序 = 账本对账）。
    @State private var sort: SidebarSort = .updatedDesc
    /// 搜索框可见性（header 搜索钮切换）。
    @State private var searchVisible = false
    /// 展开的组（工作区 id / ungrouped 键）。
    @State private var expandedGroups: Set<String> = []
    /// follow 订阅取消句柄。
    @State private var followCancel: (() -> Void)?
    /// 已归档会话集（归档行隐去）。
    @State private var archivedIDs: Set<String> = []
    /// 重命名目标（会话 / 工作区；alert TextField 承载）。
    @State private var renameTarget: RenameTarget?
    @State private var renameDraft = ""
    /// 添加工作区流程（目录选择 sheet + 失败横幅）。
    @State private var showingWorkspacePicker = false
    @State private var addWorkspaceError: String?

    enum RenameTarget: Equatable {
        case session(id: String, current: String?)
        case workspace(id: String, current: String)
    }

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            newSessionButton
            browseHeader
            sessionList
            Divider()
            footArea
        }
        .task {
            await reload()
            subscribeWorkspaces()
        }
        .onDisappear {
            followCancel?()
            followCancel = nil
        }
        .onChange(of: environment.sessionsRevision) { _ in
            Task { await reload() }
        }
        // T2.6 件4（用户 #16）：侧栏不参与键盘规避——对话 pane 弹键盘时
        // SplitView 两 pane 同被顶起曾致侧栏整体上移；侧栏无输入面，恒满高。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
        // P2-⑫：呈现由 confirmationDialog 改居中模态（dsh SettingsRoot/
        // WorkspaceBrowser 删除确认对话框形态）。
        // T2.6 件1：去全屏遮罩（用户点名——与 P1-6 三处同族，dsh
        // RiskConfirmation 挂 PopupSelectView 无全屏遮罩，仅居中确认卡）。
        .fullScreenCover(isPresented: Binding(get: { pendingDeleteOffsets != nil },
                                             set: { if !$0 { pendingDeleteOffsets = nil } })) {
            ZStack {
                VStack(alignment: .leading, spacing: 14) {
                    Text("删除会话？该操作不可撤销。")
                        .font(.system(size: 17, weight: .semibold))
                    Text("删除后会话事件流与派生历史一并移除，且无法恢复。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Spacer()
                        Button("取消") { pendingDeleteOffsets = nil }
                            .buttonStyle(.bordered)
                        Button("删除会话") {
                            if let offsets = pendingDeleteOffsets {
                                delete(at: offsets)
                            }
                            pendingDeleteOffsets = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(18)
                .frame(maxWidth: 420)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(24)
            }
            .presentationBackground(.clear)
        }
        // a①（吞错面修复）：删除失败的用户可见反馈——AppEnvironment.
        // deleteSession 失败置 sessionActionError，alert 呈现后清零。
        .alert("删除会话失败",
               isPresented: Binding(
                get: { environment.sessionActionError != nil },
                set: { if !$0 { environment.sessionActionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(environment.sessionActionError ?? "")
        }
        // M6.6（B4）④：重命名（会话标题 / 工作区 groups.name）。
        .alert(renameTitle, isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { commitRename() }
        }
        // M6.6（B4）⑤：添加工作区目录选择（UIDocumentPicker 不可抗力映射）。
        .sheet(isPresented: $showingWorkspacePicker) {
            FolderPicker { url in
                // picker sheet 退场后一拍执行（同 MountedFoldersSettingsView 纪律
                // ——iOS 拒绝叠 sheet，同步处理会被首次选择静默丢失）。
                DispatchQueue.main.async {
                    addWorkspace(from: url)
                }
            }
        }
        .alert("添加工作区失败",
               isPresented: Binding(
                get: { addWorkspaceError != nil },
                set: { if !$0 { addWorkspaceError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(addWorkspaceError ?? "")
        }
    }

    // MARK: - 品牌行 + 新建钮（dsh SidebarRoot.tsx:140-200）

    /// 品牌行：mark + name 双元素；点按 = 新建会话（dsh :141-148「展开态品牌
    /// 即新建会话快捷径」，aria-label = session.new.label「新建会话」）。
    /// WanWo 无 buildVersion 缝（dsh localBuildVersion :38-45），品牌名固定「万我」。
    private var brandRow: some View {
        Button {
            newSession()
        } label: {
            HStack(spacing: 8) {
                Text("万")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor))
                Text("万我")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityLabel("新建会话")
    }

    /// 独立新建钮（dsh :189-200：IconNewChatOutline16 size 14 + 「新会话」
    /// label——与品牌行同写通 newSession 一径）。新建即 blank 占位行（⑥）。
    private var newSessionButton: some View {
        Button {
            newSession()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 13))
                Text("新会话")
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 浏览区 header（dsh WorkspaceBrowser.tsx:1072-1181 + 三钮）

    /// section header：「会话」label + 搜索 / 视图选项 / 添加工作区 三钮
    /// （dsh ViewOptionsMenu + WorkspacePicker 落点；⑤）。
    private var browseHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("会话")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // 搜索钮（本地标题过滤保留；内容搜索升级 = M9.3 FTS 后——挂账）。
                Button {
                    searchVisible.toggle()
                    if !searchVisible { query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("搜索会话")
                // 视图选项（分组-平铺 + 排序；dsh ViewOptionsMenu 语义）。
                Menu {
                    Toggle(isOn: $grouped) {
                        Label("按工作区分组", systemImage: "folder")
                    }
                    Menu {
                        Picker("排序", selection: $sort) {
                            Text("更新时间").tag(SidebarSort.updatedDesc)
                            Text("标题").tag(SidebarSort.titleAsc)
                        }
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .accessibilityLabel("视图选项")
                // 添加工作区（+：选择目录即全部——挂载 + 注册 + 建会话 attach）。
                Button {
                    showingWorkspacePicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("添加工作区")
            }
            if searchVisible {
                searchField
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// 搜索框（dsh :1079-1133 search 语义：placeholder + clear 按钮；
    /// Escape 收起属 web 键盘态——触屏无对应，省略）。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索会话…", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 会话列表（分组树 / 平铺双形态）

    /// 渲染集合 = 查询过滤 + 归档排除（归档行隐去——④ archiveSession 语义）。
    private var filteredSummaries: [SessionSummary] {
        let base = summaries.filter { !archivedIDs.contains($0.id) }
        return SidebarGroupingModel.filterSessions(base, query: query)
    }

    private var summariesByID: [String: SessionSummary] {
        Dictionary(uniqueKeysWithValues: filteredSummaries.map { ($0.id, $0) })
    }

    /// 分组视图模型（SidebarGroupingModel 纯逻辑——§9 ①②③⑦ 收口）。
    private var displayGroups: [SidebarGroup] {
        SidebarGroupingModel.deriveGroups(sessions: filteredSummaries,
                                          workspaces: workspaces,
                                          grouped: grouped,
                                          sort: sort)
    }

    /// 会话列表：分组模式 = 工作区 Section 树（每组 5 条折叠）；平铺模式 =
    /// M3 既有单层列表原样（滑动删除承载）。
    private var sessionList: some View {
        List {
            if grouped {
                ForEach(displayGroups) { group in
                    groupSection(group)
                }
            } else {
                let rows = filteredSummaries
                ForEach(rows) { summary in
                    sessionRow(summary, group: nil)
                }
                .onDelete { indexSet in
                    // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
                    pendingDeleteOffsets = indexSet
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if displayGroups.allSatisfy({ $0.sessionIds.isEmpty }) {
                Text(query.isEmpty ? "暂无会话" : "无匹配会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一个分组 Section（工作区行 header + 组内会话行 + 折叠展开行；
    /// Ungrouped 桶同构——workspaceID 为 nil 时 header 无行操作）。
    @ViewBuilder
    private func groupSection(_ group: SidebarGroup) -> some View {
        let byID = summariesByID
        let expanded = expandedGroups.contains(group.id)
        let collapse = SidebarGroupingModel.collapseView(ids: group.sessionIds,
                                                         sessions: filteredSummaries,
                                                         expanded: expanded)
        Section {
            ForEach(collapse.visible, id: \.self) { sid in
                if let summary = byID[sid] {
                    sessionRow(summary, group: group)
                }
            }
            if collapse.hiddenCount > 0 {
                // dsh :41-56 + 截图 #23「展开其余 N 个会话」。
                Button {
                    expandedGroups.insert(group.id)
                } label: {
                    Text("展开其余 \(collapse.hiddenCount) 个会话")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        } header: {
            if grouped {
                groupHeader(group)
            }
        }
    }

    /// 工作区行（Ungrouped 桶 = 静态 label；工作区行带折叠 chevron + 重命名
    /// + 拖拽落点（insertBefore 锚）。
    @ViewBuilder
    private func groupHeader(_ group: SidebarGroup) -> some View {
        if let workspaceID = group.workspaceID {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedGroups.contains(group.id) ? 90 : 0))
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(group.sessionIds.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleGroup(group.id)
            }
            .contextMenu {
                Button {
                    renameTarget = .workspace(id: workspaceID, current: group.title)
                    renameDraft = group.title
                } label: {
                    Label("重命名工作区", systemImage: "pencil")
                }
            }
            // 工作区行拖拽排序（③：insertBefore 语义——M6.5 dsh 契约）。
            .draggable("wanwo:workspace:\(workspaceID)")
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items: items, anchorGroup: group)
            }
        } else {
            // Ungrouped 桶 header（dsh UNGROUPED_KEY 段——静态 label）。
            HStack(spacing: 4) {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleGroup(group.id) }
        }
    }

    /// 单行会话：标题（dsh blank 行语义「新会话」）+ 相对时间（time.ago
    /// 词典）+ 琥珀警示点 + 选中高亮（dsh currentId 高亮语义）。
    /// M6.6（B4）④：contextMenu 重命名/归档/删除；③：draggable + 组内落点。
    private func sessionRow(_ summary: SessionSummary,
                            group: SidebarGroup?) -> some View {
        Button {
            selection = .session(id: summary.id)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title ?? "新会话")
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(relativeTime(summary.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // M3 T1：琥珀警示圆点（dsh 2026-07-23 笔记——sidebar
                // mirrors every blocked interaction with an amber
                // warning dot that outranks the running ring；
                // WanWo 侧栏暂无运行中圆环，见批次报告偏差登记）。
                if environment.pendingInteractionSessionIDs.contains(summary.id) {
                    Circle()
                        .fill(ApprovalPanelStyle.warnPrimary)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("有待决审批或提问")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent(summary) ? Color(.secondarySystemFill) : nil)
        .contextMenu {
            Button {
                renameTarget = .session(id: summary.id, current: summary.title)
                renameDraft = summary.title ?? ""
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                archiveSession(summary.id)
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            // ③ 拖拽兜底：组内上移/下移（工作区组才有账本序语义）。
            if let group, group.workspaceID != nil {
                Button {
                    moveSession(summary.id, in: group, offset: -1)
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .disabled(isFirstNonBlank(summary.id, in: group))
                Button {
                    moveSession(summary.id, in: group, offset: +1)
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .disabled(isLast(summary.id, in: group))
            }
            Button(role: .destructive) {
                Task { await environment.deleteSession(id: summary.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // ③ 拖拽排序（工作区组内；Ungrouped/平铺无账本——不挂）。
        .modifier(SidebarDragModifiers(
            payload: group?.workspaceID != nil ? "wanwo:session:\(summary.id)" : nil,
            onDrop: { items in
                if let group {
                    return handleSessionDrop(items: items, target: summary, group: group)
                }
                return false
            }))
    }

    // MARK: - foot（dsh SidebarRoot.tsx:211-219）

    /// 底部钉住区：设置段（Providers / 权限）+ 诊断段（事件流；Shell 测试
    /// M0 入口随 B4 降级为 DEBUG-only——终端迁入右侧栏，ia-audit §3.1 收口）。
    private var footArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            footButton("Providers", icon: "cpu") {
                selection = .providers
            }
            footButton("MCP", icon: "puzzlepiece.extension") {
                // M4-A 件11：设置·MCP server 管理（配置存储+最小设置页）。
                selection = .mcpServers
            }
            footButton("Skills", icon: "square.stack.3d.up") {
                // M4-D D7：设置·技能管理（启停覆盖层+迁移导入）。
                selection = .skills
            }
            footButton("权限", icon: "lock.shield") {
                // M3 T2.2：设置·新会话默认权限行（PermissionRow.tsx 1:1；
                // P1-4 后唯一权限入口——规则 CRUD 页随 F022 砍除）。
                selection = .permissionDefaults
            }
            footButton("外挂载文件夹", icon: "externaldrive.badge.plus") {
                // M6.4（B3）：设置·外挂载文件夹管理（F071 挂载流程 + 写权限面）。
                selection = .mounts
            }
            Text("诊断")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            // M6.6（B4）：Shell 测试 M0 入口降级 DEBUG-only（ia-audit §3.1；
            // 终端已迁右侧栏 WorkspaceTerminalTabView——Release 侧栏不再露出）。
            #if DEBUG
            footButton("Shell 测试（M0）", icon: "terminal") {
                selection = .shellTest
            }
            #endif
            footButton("事件流", icon: "list.bullet.rectangle") {
                // M2.8 只读事件流诊断页（页内自选会话，取更简单方案）。
                selection = .eventStream
            }
        }
        .padding(.vertical, 10)
    }

    private func footButton(_ title: String,
                            icon: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.callout)
                Spacer()
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - 数据与操作

    private func reload() async {
        var loaded = await environment.loadSessions()
        // dsh WorkspaceBrowser.tsx:116-121 compareSessionRecency
        // （orderBy.updated 语义）：updatedAt 降序、Session id 升序 tie-break。
        loaded.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        summaries = loaded
        archivedIDs = environment.workspaceRegistry.archivedSessionIDs()
        // 工作区基线快照（follow 订阅在 task 里；此处直读 registry 兜底首帧前空窗）。
        workspaces = environment.workspaceRegistry.list()
    }

    /// workspaceController.follow 订阅（B3 follow 快照流——工作区行数据源；
    /// registry 接受型变更即发全量帧）。
    private func subscribeWorkspaces() {
        guard followCancel == nil else { return }
        let (stream, cancel) = environment.workspaceController.follow()
        followCancel = cancel
        Task { @MainActor in
            for await frame in stream {
                workspaces = frame.workspaces
            }
        }
    }

    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    private func newSession() {
        creating = true
        Task {
            if let summary = await environment.createSession() {
                selection = .session(id: summary.id)
            }
            creating = false
        }
    }

    private func delete(at offsets: IndexSet) {
        // a②（搜索态 offset 错位修复）：onDelete 的 offsets 是渲染行集
        // （filteredSummaries）的索引——此前对全量 summaries 取值，搜索态下
        // 两集合下标错位=删错行。按渲染行集映射回 id（含越界防御）。
        let rows = filteredSummaries
        let ids = offsets.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        Task {
            for id in ids {
                await environment.deleteSession(id: id)
            }
        }
    }

    // MARK: M6.6（B4）④：重命名 / 归档

    private var renameTitle: String {
        switch renameTarget {
        case .session: return "重命名会话"
        case .workspace: return "重命名工作区"
        case nil: return "重命名"
        }
    }

    private func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch renameTarget {
        case .session(let id, _):
            // 会话标题（F072 session.rename 折算：GRDB 索引标题直写——
            // 标题非模型上下文事实源，事件流侧由标题生成器同口径管理）。
            environment.database.setTitle(id: id, title: name)
            environment.sessionsRevision += 1
        case .workspace(let id, _):
            do {
                _ = try environment.workspaceController.rename(id: id, to: name)
            } catch {
                addWorkspaceError = "重命名失败：\(String(describing: error))"
            }
        case nil:
            break
        }
        renameTarget = nil
    }

    private func archiveSession(_ id: String) {
        do {
            try environment.workspaceController.archiveSession(sessionId: id)
        } catch {
            addWorkspaceError = "归档失败：\(String(describing: error))"
        }
        // 归档行即时隐去（reload 由 registry.onChange → follow 帧驱动，这里
        // 直接置集合作乐观收敛）。
        archivedIDs.insert(id)
    }

    // MARK: M6.6（B4）③：拖拽排序与兜底

    /// 落点处理（draggable payload → insertSessionBefore / insertBefore）。
    private func handleDrop(items: [String], anchorGroup: SidebarGroup) -> Bool {
        for item in items {
            if item.hasPrefix("wanwo:session:") {
                let sid = String(item.dropFirst("wanwo:session:".count))
                guard let workspaceID = anchorGroup.workspaceID else { return false }
                // 锚 = 组内第一条非 blank 会话前的空隙（落组头 = 移到组首——
                // dropDestination 挂在 header 上，锚取组首会话；空组 = 追加）。
                let anchor = anchorGroup.sessionIds.first { $0 != sid }
                do {
                    _ = try environment.workspaceController.insertSessionBefore(
                        sessionId: sid, beforeSessionId: anchor, in: workspaceID)
                    return true
                } catch {
                    addWorkspaceError = "移动失败：\(String(describing: error))"
                    return false
                }
            }
            if item.hasPrefix("wanwo:workspace:") {
                let wid = String(item.dropFirst("wanwo:workspace:".count))
                // 锚 = 被落组自身（移到其前）；落到 Ungrouped header = 追加末尾。
                let anchor: String? = anchorGroup.workspaceID != nil
                    ? anchorGroup.workspaceID : nil
                do {
                    _ = try environment.workspaceController.insertBefore(
                        id: wid, beforeId: anchor)
                    return true
                } catch {
                    addWorkspaceError = "移动失败：\(String(describing: error))"
                    return false
                }
            }
        }
        return false
    }

    /// 组内会话行落点（锚 = 被落行自身）。
    private func handleSessionDrop(items: [String],
                                   target: SessionSummary,
                                   group: SidebarGroup) -> Bool {
        for item in items where item.hasPrefix("wanwo:session:") {
            let sid = String(item.dropFirst("wanwo:session:".count))
            guard let workspaceID = group.workspaceID else { return false }
            let anchor: String? = target.id == sid ? nil : target.id
            do {
                _ = try environment.workspaceController.insertSessionBefore(
                    sessionId: sid, beforeSessionId: anchor, in: workspaceID)
                return true
            } catch {
                addWorkspaceError = "移动失败：\(String(describing: error))"
                return false
            }
        }
        return false
    }

    /// 上移/下移兜底（触屏拖拽的可达路径；offset -1/+1 在可见账本序内换位）。
    private func moveSession(_ sid: String, in group: SidebarGroup, offset: Int) {
        guard let workspaceID = group.workspaceID,
              let index = group.sessionIds.firstIndex(of: sid) else { return }
        let targetIndex = index + offset
        guard group.sessionIds.indices.contains(targetIndex) else { return }
        if offset < 0 {
            // 上移 = 插到前一位之前。
            let anchor = group.sessionIds[targetIndex]
            _ = try? environment.workspaceController.insertSessionBefore(
                sessionId: sid, beforeSessionId: anchor == sid ? nil : anchor,
                in: workspaceID)
        } else {
            // 下移 = 插到后一位之后（dsh insertBefore 语义折算：锚 = 后位
            // 的后一位；无后位 = 追加末尾）。
            let afterIndex = targetIndex + 1
            let anchor: String? = afterIndex < group.sessionIds.count
                ? group.sessionIds[afterIndex] : nil
            _ = try? environment.workspaceController.insertSessionBefore(
                sessionId: sid, beforeSessionId: anchor, in: workspaceID)
        }
    }

    private func isFirstNonBlank(_ sid: String, in group: SidebarGroup) -> Bool {
        group.sessionIds.first == sid
    }

    private func isLast(_ sid: String, in group: SidebarGroup) -> Bool {
        group.sessionIds.last == sid
    }

    // MARK: M6.6（B4）⑤：添加工作区（选择目录即全部）

    private func addWorkspace(from url: URL) {
        // 挂载名 = 目录名清洗（isValidMountName 词汇：字母/数字/-/_/.）。
        let sanitized = url.lastPathComponent.map { ch -> Character in
            let ok = ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
            return ok ? ch : "-"
        }
        var name = sanitized.isEmpty ? "workspace" : String(sanitized)
        do {
            let entry = try MountedFoldersManager.shared.add(
                pickedURL: url, customName: name, userAllowWrite: true)
            finishAddWorkspace(entry: entry)
        } catch MountedFoldersManager.AddError.nameTaken {
            // 重名：追加短随机后缀重试一次（幂等性归 registry.create）。
            name += "-" + String(UUID().uuidString.prefix(4))
            do {
                let entry = try MountedFoldersManager.shared.add(
                    pickedURL: url, customName: name, userAllowWrite: true)
                finishAddWorkspace(entry: entry)
            } catch {
                addWorkspaceError = "挂载目录失败：\(String(describing: error))"
            }
        } catch {
            addWorkspaceError = "挂载目录失败：\(String(describing: error))"
        }
    }

    private func finishAddWorkspace(entry: MountedFolderEntry) {
        do {
            let guestPath = WanWoPaths.mountsLinuxDir + "/" + entry.name
            // dsh「选择目录就是添加工作区的全部」：create（幂等）→ 建会话
            // attach（selectedWorkspaceID 注入 cwd 落点——B3 既有链路）。
            let (ws, _) = try environment.workspaceController.create(
                path: guestPath, title: nil)
            environment.selectedWorkspaceID = ws.id
            expandedGroups.insert(ws.id)
            creating = true
            Task {
                if let summary = await environment.createSession() {
                    selection = .session(id: summary.id)
                }
                creating = false
            }
        } catch {
            addWorkspaceError = "注册工作区失败：\(String(describing: error))"
        }
    }

    // MARK: - 展示辅助

    /// dsh WorkspaceBrowser.tsx:116-121 compareSessionRecency 词汇（'time.ago'
    /// 「{t}前」+ time.* 单位词）：刚刚 / {n}分钟前 / {n}小时前 / {n}天前 /
    /// {n}个月前 / {n}年前。
    private func relativeTime(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 30 { return "\(days)天前" }
        let months = days / 30
        if months < 12 { return "\(months)个月前" }
        return "\(days / 365)年前"
    }

    private func isCurrent(_ summary: SessionSummary) -> Bool {
        if case .session(let current) = selection { return current == summary.id }
        return false
    }
}

// MARK: - M6.6（B4）③：行拖拽修饰（payload 可选——Ungrouped/平铺行不挂）

/// draggable + dropDestination 条件修饰收敛（payload nil = 既有行为零变化）。
/// 拖拽形态登记：draggable + dropDestination（iOS 16 触屏长按拖起）；另配
/// contextMenu 上移/下移兜底（行内菜单可达路径——批次报告标注）。
private struct SidebarDragModifiers: ViewModifier {
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
