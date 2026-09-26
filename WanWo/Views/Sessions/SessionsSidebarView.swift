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
//  section header :1072-1181（「工作区/会话」label + 搜索）、orderBy.updated
//  语义 :116-121（updatedAt 降序 + Session id 升序 tie-break）、
//  空态/搜索态词汇 :436-438/:783-785（'empty.none'「暂无会话」/
//  'search.noMatches'「无匹配会话」）、相对时间词典 :65-71（'time.ago'「{t}前」）。
//
//  【M6.6 B4 增量改造（§9 左侧栏欠账 6 项）——M3 以来稳定面保持增量，不推倒重写】
//    ① 工作区分组树（groups 行 + 组内会话 + Ungrouped 桶）+ 平铺模式保留；
//    ② 每组 5 条折叠 + 「展开其余 N 个会话」（COLLAPSED_SESSION_LIMIT=5；
//      blank 占位不计限额）；
//    ③ 拖拽排序（组内 insertSessionBefore；工作区行 → insertBefore）；
//    ④ 行操作补齐（F072）：重命名 / 归档（archivedAtMs 行隐去）；
//    ⑤ section header 三钮：搜索 / 视图选项 / 添加工作区；
//    ⑥ blank 占位会话（title nil → 「新会话」行）。
//
//  【UI 对齐批 1（C 左栏对齐清单）增量——语义源 dsh WorkspaceBrowser.tsx
//  + Rows.tsx + tree.ts + WorkspacePicker.tsx，逐项锚点见各成员注释】
//    C1  + 弹层 addOnly：header + → 应用内 Menu（单项「添加工作区」）→ 选中
//        才进目录流（WorkspacePicker.tsx:101-118）；目录流期间菜单禁用（flowBusy）。
//    C2  组行 +：hover/操作区加 +，点击 = 展开该组 + startSession(组 id)
//        （WorkspaceBrowser.tsx:508-513, Rows.tsx:187-194）。
//    C3  blank 规则翻转（tree.ts:131）：blank 仅当它是当前选中会话才可见；
//        当前 blank 在其账户 + flat 账户双置顶（promotedBlank :847-864）；
//        blank 行无相对时间无 ⋯菜单（Rows.tsx:457-461，显示「新会话」标题）。
//    C4  排序账户（:96-161/865-872）：每工作区 + FLAT 各一本地
//        账户（SidebarOrderAccounts）；「按更新」模式活动提升（新活动会话
//        一次性置顶 :137-149）+ 切到 updated 全量重排；retainAccountKeys 回收。
//    C5  搜索内联展开（:1078-1133）：点击图标展开；查询状态跨树存活（不随
//        收起清空）；本地过滤 = 标题 + 所属工作区名子串，blank 排除；查询
//        消毒（去 NUL + 500 code units）。Escape/外部点击收起——Escape 为
//        web 键盘态，触屏无对应（不可抗力省略），外部点击收起已实现。
//    C6  组展开态持久化（:291-294）：per-key 显式状态（expanded/collapsed
//        双集合 = dsh groupExpansion Record 显式 0-or-5 折算）+ 当前会话所在
//        组自动展开（仅未显式碰过的组）。
//    C7  工作区重命名对话框查重（:970-973）+ 删除工作区确认对话框（确认保持
//        到列表渲染出无该 id 才关，防 stale frame :1053-1067；删除中状态行）。
//    C8  文案/形态：分组视图标题「工作区」（平铺视图「会话」，:1075）；去掉
//        组行计数徽标；会话行 blank 外保留相对时间 + ⋯菜单。fork 不做（待
//        拍板项——Rows.tsx:385-386 語义已存档）。
//    C9  悬停卡不移植（iPad 触屏不可抗力）：复制路径/信息保留在长按
//        contextMenu。
//    C10 归档维持现状（无恢复入口——用户已拍板）。
//  诊断区旧 ShellTestView 入口保持 DEBUG-only（B4 既有裁定不动）。
//

import SwiftUI

struct SessionsSidebarView: View {
    @ObservedObject var environment: AppEnvironment
    @Binding var selection: RootSelection

    @State private var summaries: [SessionSummary] = []
    /// dsh WorkspaceBrowser.tsx:875 query 状态（'search.placeholder'
    /// 「搜索会话…」）——WanWo 无 session.search 远程 API，本批=本地过滤
    /// （标题 + 所属工作区名；blank 排除，见 SidebarGroupingModel.filterSessions）。
    /// 查询状态跨树存活（:873-875 注释——收起搜索框不清空，:927 无关守卫）。
    @State private var query = ""
    /// 待确认删除的行号集（A6：滑动删除 → 确认对话框 → 执行）。
    @State private var pendingDeleteOffsets: IndexSet?

    // MARK: 工作区树状态（B4 既有）

    /// 工作区快照（workspaceController.follow 帧驱动）。
    @State private var workspaces: [WorkspaceRecord] = []
    /// 分组/平铺视图（dsh ViewOptionsMenu groupBy 维；M3 平铺保留）。
    @State private var grouped = true
    /// 排序（平铺模式生效；组内序 = 账本对账）。
    @State private var sort: SidebarSort = .updatedDesc
    /// 搜索框可见性（header 搜索钮切换——C5 内联展开）。
    @State private var searchVisible = false
    /// follow 订阅取消句柄。
    @State private var followCancel: (() -> Void)?
    /// 已归档会话集（归档行隐去）。
    @State private var archivedIDs: Set<String> = []
    /// 会话重命名目标（alert TextField 承载；dsh 会话重命名无查重——确认
    /// 当前自动标题=钉死，:992-995）。
    @State private var renameTarget: RenameTarget?
    @State private var renameDraft = ""
    /// 添加工作区流程（【工作区模型修正】输入项目名 alert + 失败横幅）。
    @State private var showingAddWorkspace = false
    @State private var newProjectName = ""
    @State private var addWorkspaceError: String?

    // MARK: UI 对齐批 1（C）新增状态

    /// 排序账户（C4——每工作区 + FLAT 各一；dsh
    /// sessionOrderByAccount/sessionUpdatedAtByAccount 同位）。
    @State private var orderAccounts = SidebarOrderAccounts()
    /// 上次对账时的排序模式（切到「按更新」触发全量重排——dsh :305,323）。
    @State private var lastAccountSort: SidebarSort?
    /// 已提升置顶的当前 blank（promotedBlank ref，:847-864 幂等判定）。
    @State private var promotedBlankRef: PromotedBlankRef?
    /// 组展开态持久化（C6——显式展开集合；dsh groupExpansion 持久 Record）。
    @AppStorage("sidebar.groupExpansion.expanded") private var expandedGroupsRaw = "[]"
    /// 显式折叠集合（= dsh groupExpansion 里的 false 值——挡住自动展开）。
    @AppStorage("sidebar.groupExpansion.collapsed") private var collapsedGroupsRaw = "[]"
    /// 工作区重命名对话框（C7 查重——dsh :965-990）。
    @State private var wsRenameTarget: WorkspaceRenameTarget?
    @State private var wsRenameDraft = ""
    @State private var wsRenameError: String?
    /// 工作区删除确认对话框（C7——dsh :1037-1068）。
    @State private var wsDeleteTarget: WorkspaceDeleteTarget?
    @State private var wsDeleting = false
    @State private var wsDeleteCommittedID: String?
    @State private var wsDeleteError: String?

    struct PromotedBlankRef: Equatable {
        let sessionID: String
        let accountKey: String
    }

    /// 会话重命名（alert 承载；工作区重命名走专用对话框 C7）。
    enum RenameTarget: Equatable {
        case session(id: String, current: String?)
    }

    struct WorkspaceRenameTarget: Equatable {
        let id: String
        let current: String
    }

    struct WorkspaceDeleteTarget: Equatable {
        let id: String
        let title: String
    }

    /// 当前选中会话 id（dsh list.current）。
    private var currentSessionID: String? {
        if case .session(let id) = selection { return id }
        return nil
    }

    var body: some View {
        // C7 两个对话框与主列分挂不同视图（SwiftUI 同视图链多 fullScreenCover
        // 呈现不可靠——官方指引每个 cover 挂独立视图；零尺寸 Color.clear 作
        // 挂点不影响布局）。
        ZStack {
            sidebarColumn
            workspaceRenameCover
            workspaceDeleteCover
        }
    }

    /// 主列（品牌行 + 新建钮 + 浏览区 + 列表 + foot；既有呈现链原样）。
    private var sidebarColumn: some View {
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
        .onChange(of: currentSessionID) { newValue in
            // C6：当前会话所在组自动展开（:291-294）+ C3：当前 blank 置顶提升。
            autoExpandCurrentGroup(newValue)
            syncPromotedBlank()
        }
        .onChange(of: workspaces) { newValue in
            // C7：删除确认保持到列表渲染出无该 id 才关（dsh :1041-1047
            // 防 stale frame——关早了会把 stale 列表帧漏给下一次添加手势）。
            if let committed = wsDeleteCommittedID,
               !newValue.contains(where: { $0.id == committed }) {
                wsDeleting = false
                wsDeleteCommittedID = nil
                wsDeleteTarget = nil
            }
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
        // B4 ④：会话重命名（dsh 无查重——确认当前自动标题=钉死，:992-995）。
        .alert(renameTitle, isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { commitSessionRename() }
        }
        // B4 ⑤→【工作区模型修正】：添加工作区 = 输入项目名（iSH 内建项目目录
        // ——文件 App 目录选择入口彻底删除）。
        .alert("新建项目", isPresented: $showingAddWorkspace) {
            TextField("项目名", text: $newProjectName)
            Button("取消", role: .cancel) { newProjectName = "" }
            Button("创建") { adoptWorkspace(name: newProjectName) }
        } message: {
            Text("将在万我的文件世界创建 /var/wanwo/projects/<项目名> 并开启新会话。")
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

    // MARK: UI 对齐批 1（C7）：工作区重命名 / 删除对话框（挂独立视图）

    /// 工作区重命名对话框（查重冲突报错——dsh :970-973, 1297-1299；IME
    /// composition 防误提交为 web 键盘态，触屏输入法由 UIKit 自管——
    /// 不可抗力省略）。
    private var workspaceRenameCover: some View {
        // 空形状占位挂点（覆盖呈现经 fullScreenCover 挂本视图）。
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(isPresented: Binding(
                get: { wsRenameTarget != nil },
                set: { if !$0 { wsRenameTarget = nil } })) {
                ZStack {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("重命名工作区")
                            .font(.system(size: 17, weight: .semibold))
                        TextField("名称", text: $wsRenameDraft)
                            .textFieldStyle(.roundedBorder)
                        if wsRenameDuplicate {
                            Text("已存在同名工作区「\(wsRenameTrimmed)」")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if let wsRenameError {
                            Text(wsRenameError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        HStack(spacing: 10) {
                            Spacer()
                            Button("取消") { wsRenameTarget = nil }
                                .buttonStyle(.bordered)
                            Button("保存") { commitWorkspaceRename() }
                                .buttonStyle(.borderedProminent)
                                .disabled(wsRenameBlocked)
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
    }

    /// 删除工作区确认对话框（dsh :1037-1068 + 删除中状态行 :1356；确认保持
    /// 到列表渲染出无该 id 才关——onChange(of: workspaces) 收口）。
    private var workspaceDeleteCover: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(isPresented: Binding(
                get: { wsDeleteTarget != nil },
                set: { if !$0 { wsDeleteTarget = nil } })) {
                ZStack {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("删除工作区？")
                            .font(.system(size: 17, weight: .semibold))
                        Text("「\(wsDeleteTarget?.title ?? "")」将连同其中全部会话与工作区文件一并删除，此操作不可恢复。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if wsDeleting {
                            // 删除中状态行（dsh 'delete.pending' :1356）。
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("删除中…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let wsDeleteError {
                            Text(wsDeleteError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        HStack(spacing: 10) {
                            Spacer()
                            Button("取消") { closeWorkspaceDelete() }
                                .buttonStyle(.bordered)
                                .disabled(wsDeleting)
                            Button("删除工作区") { confirmWorkspaceDelete() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .disabled(wsDeleting)
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
    }

    // MARK: - 品牌行 + 新建钮（dsh SidebarRoot.tsx:140-200）

    /// 品牌行：mark + name 双元素；点按 = 新会话（dsh :141-148「展开态品牌
    /// 即新建会话快捷径」）。UI 对齐批 1（A5）：改调 startSession()——
    /// workspace 驱动创建流（替换既有无条件 createSession）。
    private var brandRow: some View {
        Button {
            environment.workspaceNavigator.startSession()
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
    /// label）。UI 对齐批 1（A5）：startSession()——无工作区时清空选择落
    /// 空态项目选择页，不产生游离会话。
    private var newSessionButton: some View {
        Button {
            environment.workspaceNavigator.startSession()
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
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 浏览区 header（dsh WorkspaceBrowser.tsx:1072-1181 + 三钮）

    /// section header：C8 文案——分组视图「工作区」/ 平铺视图「会话」
    /// （dsh :1075 groupBy 条件）+ 搜索 / 视图选项 / 添加工作区 三钮。
    private var browseHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(grouped ? "工作区" : "会话")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // C5 搜索钮：内联展开输入框；展开/收起不清 query（跨树存活）。
                Button {
                    searchVisible.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("搜索会话")
                viewOptionsMenu
                addWorkspaceMenu
            }
            if searchVisible {
                searchField
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// 视图选项（分组-平铺 + 排序；dsh ViewOptionsMenu 语义）。
    /// 【批3 编译八】从 browseHeader 拆出——Menu 内嵌 Menu/Picker 是 SwiftUI
    /// 类型检查炸弹（:154 超时实证），拆为独立 @ViewBuilder 变量。
    @ViewBuilder
    private var viewOptionsMenu: some View {
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
    }

    /// C1 + 弹层 addOnly（WorkspacePicker.tsx:101-118）：应用内 Menu 单项
    /// 「添加工作区」，选中才进命名流；流程占用期间全禁用（flowBusy）。
    @ViewBuilder
    private var addWorkspaceMenu: some View {
        Menu {
            Button {
                newProjectName = ""
                showingAddWorkspace = true
            } label: {
                Label("添加工作区", systemImage: "folder.badge.plus")
            }
            .disabled(flowBusy)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12))
        }
        .accessibilityLabel("添加工作区")
    }

    /// 命名流占用（alert 打开 = 输入 pending——dsh flowBusy :86）。
    private var flowBusy: Bool {
        showingAddWorkspace
    }

    /// 搜索框（dsh :1079-1133 search 语义：placeholder + clear 按钮）。
    /// C5：收起不清 query；Escape 收起属 web 键盘态（触屏无对应，省略）。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索会话…", text: Binding(
                get: { query },
                set: { query = SidebarGroupingModel.sanitizeQuery($0) }))
                .textFieldStyle(.plain)
                .font(.callout)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                    searchVisible = false
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

    /// 渲染集合 = 查询过滤（标题+工作区名，blank 排除）+ 归档排除。
    private var filteredSummaries: [SessionSummary] {
        let base = summaries.filter { !archivedIDs.contains($0.id) }
        return SidebarGroupingModel.filterSessions(base, query: query,
                                                   workspaces: workspaces)
    }

    private var summariesByID: [String: SessionSummary] {
        Dictionary(uniqueKeysWithValues: filteredSummaries.map { ($0.id, $0) })
    }

    /// 分组视图模型（SidebarGroupingModel 纯逻辑——§9 ①②③⑦ + 批 1 C3/C4）。
    /// 「按更新」模式传排序账户（活动提升后的展示序）；「标题」模式沿用
    /// 既有计算排序（M3 稳定面零变化）。
    private var displayGroups: [SidebarGroup] {
        SidebarGroupingModel.deriveGroups(
            sessions: filteredSummaries,
            workspaces: workspaces,
            grouped: grouped,
            sort: sort,
            currentSessionID: currentSessionID,
            accountOrders: sort == .updatedDesc ? orderAccounts.ordersSnapshot : nil)
    }

    /// 会话列表：分组模式 = 工作区 Section 树（每组 5 条折叠）；平铺模式 =
    /// M3 既有单层列表原样（滑动删除承载）。C5：外部点击收起搜索（dsh
    /// :915-925——query 非空时只 blur 不收起的 web 焦点语义折算为不收起）。
    private var sessionList: some View {
        // 【批3 编译八】分组/平铺拆为独立变量 + AnyView 擦除——表达式超时
        // （:154）的机械消解；两分支本体零变化。
        if grouped {
            AnyView(groupedSessionList)
        } else {
            AnyView(flatSessionList)
        }
    }

    /// 分组树（每组 5 条折叠；组行 + 组内会话行 + 展开其余）。
    private var groupedSessionList: some View {
        List {
            ForEach(displayGroups) { group in
                groupSection(group)
            }
        }
        .listStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            collapseSearchOnOutsideTap()
        })
        .overlay {
            if displayGroups.allSatisfy({ $0.sessionIds.isEmpty }) {
                Text("暂无会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 平铺单层列表（M3 既有形态；滑动删除承载——onDelete 只在平铺挂）。
    private var flatSessionList: some View {
        List {
            let rows = filteredSummaries
            ForEach(rows) { summary in
                sessionRow(summary, group: nil)
            }
            .onDelete { indexSet in
                // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
                pendingDeleteOffsets = indexSet
            }
        }
        .listStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            collapseSearchOnOutsideTap()
        })
        .overlay {
            if filteredSummaries.isEmpty {
                Text(query.isEmpty ? "暂无会话" : "无匹配会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// C5 外部点击收起（dsh :915-925：外部点击 blur；query 为空才收起）。
    private func collapseSearchOnOutsideTap() {
        guard searchVisible, query.isEmpty else { return }
        searchVisible = false
    }

    /// M3 滑动删除确认卡的落点（批 1 重写时函数体误删而调用点保留——
    /// CI 35127800820 实证 cannot find 'delete' in scope。a② 搜索态 offset
    /// 错位修复语义原样：onDelete 的 offsets 是渲染行集（filteredSummaries）
    /// 的索引，映射回 id 含越界防御）。
    private func delete(at offsets: IndexSet) {
        let rows = filteredSummaries
        let ids = offsets.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        Task {
            for id in ids {
                await environment.deleteSession(id: id)
            }
        }
    }

    /// 一个分组 Section（工作区行 header + 组内会话行 + 折叠展开行）。
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
                    setGroupExpanded(group.id, true)
                } label: {
                    Text("展开其余 \(collapse.hiddenCount) 个会话")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if expanded,
                      group.sessionIds.count > SidebarGroupingModel.collapsedSessionLimit {
                // dsh 'sessions.collapse'（:579-581）——展开态回收折叠限额。
                Button {
                    setGroupExpanded(group.id, false)
                } label: {
                    Text("收起")
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

    /// 工作区行（折叠 chevron + 行操作 + 拖拽落点（insertBefore 销）。
    /// C8：去掉组行计数徽标（dsh 组行无计数）。
    /// 【工作区模型修正】Ungrouped 桶静态 tray 行已删——组恒为工作区组。
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
                // C2 组行 +（Rows.tsx:187-194）：展开该组 + 组内新建会话
                // （WorkspaceBrowser.tsx:508-513——onCreate = startSession）。
                Button {
                    setGroupExpanded(group.id, true)
                    environment.workspaceNavigator.startSession(workspaceID)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("在「\(group.title)」中新建会话")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleGroup(group.id)
            }
            // C7/C9：工作区行操作（dsh Rows.tsx:129-131 ⋯菜单 = 重命名/删除；
            // 悬停卡不移植——触屏不可抗力，操作保留在长按菜单）。
            .contextMenu {
                Button {
                    wsRenameTarget = WorkspaceRenameTarget(id: workspaceID,
                                                           current: group.title)
                    wsRenameDraft = group.title
                    wsRenameError = nil
                } label: {
                    Label("重命名工作区", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    wsDeleteTarget = WorkspaceDeleteTarget(id: workspaceID,
                                                           title: group.title)
                    wsDeleteError = nil
                } label: {
                    Label("删除工作区", systemImage: "trash")
                }
            }
            // 工作区行拖拽排序（③：insertBefore 语义——M6.5 dsh 契约）。
            .draggable("wanwo:workspace:\(workspaceID)")
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items: items, anchorGroup: group)
            }
        }
    }

    /// 单行会话：标题 + 相对时间（time.ago 词典）+ 琥珀警示点 + 选中高亮。
    /// C3：blank 行 = 「新会话」标题、无相对时间、无 ⋯菜单（Rows.tsx
    /// :457-461——blank 是临时占位，rename/fork/archive 皆无内容可作用）。
    /// B4 ④：contextMenu 重命名/归档/删除（仅非 blank）；③：draggable。
    private func sessionRow(_ summary: SessionSummary,
                            group: SidebarGroup?) -> some View {
        let blank = SidebarGroupingModel.isBlank(summary)
        return Button {
            selection = .session(id: summary.id)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(blank ? "新会话" : (summary.title ?? "新会话"))
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if !blank {
                        Text(relativeTime(summary.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
            if !blank {
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

    /// 底部钉住区：【批3 A】设置单入口（dsh SettingsRoot 语义——原六项列表
    /// 撤除，Providers/MCP/Skills/权限/外挂载/诊断六分区收拢进设置面板
    /// SettingsPanelView 左 nav；深链 wanwo://settings/permissions 落点同步改
    /// RootView openSettings(at: .permissions)，B1c 闭环勿断）。
    /// Shell 测试 M0 入口保留 DEBUG-only（回归面，非用户设置项——Release
    /// 侧栏仅「设置」一行，简报 A.1 口径）。
    private var footArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            footButton("设置", icon: "gearshape") {
                environment.openSettings()
            }
            #if DEBUG
            footButton("Shell 测试（M0）", icon: "terminal") {
                selection = .shellTest
            }
            #endif
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
        // C4：排序账户对账 + C3：当前 blank 置顶提升。
        syncAccounts()
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
                syncAccounts()
            }
        }
    }

    // MARK: UI 对齐批 1（C4/C3）：排序账户与 blank 置顶

    /// 各账户对账（dsh useEffect :303-329）：「按更新」模式下每工作区 +
    /// FLAT 各一账户 reconcile；retainAccountKeys 回收已删工作区账户
    /// （:865-872）。【工作区模型修正】UNGROUPED 账户随未分组桶删除。
    private func syncAccounts() {
        // 归档排除后的账户基线（dsh 账户口径不含 archived；查询过滤仅显示层）。
        let base = summaries.filter { !archivedIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        // retainAccountKeys（:865-872）：现存工作区 + FLAT 之外回收。
        orderAccounts.retain(keys: Set(workspaces.map(\.id))
            .union([SidebarGroupingModel.flatKey]))
        guard sort == .updatedDesc else { return }
        // 切到「按更新」→ 全量重排（dsh :305,323 sortByRecency）。
        let fullResort = (lastAccountSort != .updatedDesc)
        lastAccountSort = .updatedDesc
        for workspace in workspaces {
            let members = workspace.sessionIds.filter { byID[$0] != nil }
            orderAccounts.reconcile(accountKey: workspace.id,
                                    sessionIds: members,
                                    sessions: base,
                                    activityPromotion: true,
                                    fullResort: fullResort)
        }
        orderAccounts.reconcile(accountKey: SidebarGroupingModel.flatKey,
                                sessionIds: base.map(\.id),
                                sessions: base,
                                activityPromotion: true,
                                fullResort: fullResort)
        syncPromotedBlank()
    }

    /// promotedBlank（dsh :847-864）：当前 blank 会话在其账户 + flat 账户
    /// 双置顶（同一 blank/账户组合只提升一次——ref 幂等）。
    private func syncPromotedBlank() {
        let base = summaries.filter { !archivedIDs.contains($0.id) }
        guard let current = currentSessionID,
              let summary = base.first(where: { $0.id == current }),
              SidebarGroupingModel.isBlank(summary) else {
            promotedBlankRef = nil
            return
        }
        // 【工作区模型修正】会话必在工作区账本内（无游离会话）——无归属
        // 时不做账户提升（仅 flat 半边生效）。
        guard let accountKey = workspaces.first(where: { $0.sessionIds.contains(current) })?.id else {
            promotedBlankRef = nil
            return
        }
        if let ref = promotedBlankRef,
           ref.sessionID == current, ref.accountKey == accountKey {
            return
        }
        promotedBlankRef = PromotedBlankRef(sessionID: current, accountKey: accountKey)
        orderAccounts.promoteSessionToTop(
            current,
            accountKeys: [accountKey, SidebarGroupingModel.flatKey])
    }

    // MARK: UI 对齐批 1（C6）：组展开态持久化

    /// 有效展开集 = 显式展开 − 显式折叠（dsh groupExpansion Record 的
    /// true/false 显式值折算；缺席 = 从未碰过）。
    private var expandedGroups: Set<String> {
        var set = Self.decodeSet(expandedGroupsRaw)
        set.subtract(Self.decodeSet(collapsedGroupsRaw))
        return set
    }

    private func toggleGroup(_ id: String) {
        setGroupExpanded(id, !expandedGroups.contains(id))
    }

    /// dsh actions.setGroupExpanded——显式写 0-or-5 状态并持久化。
    /// 动画标准：组折叠/展开的行增删走 withAnimation + spring（丝滑不华丽）。
    private func setGroupExpanded(_ id: String, _ on: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            var expanded = Self.decodeSet(expandedGroupsRaw)
            var collapsed = Self.decodeSet(collapsedGroupsRaw)
            if on {
                expanded.insert(id)
                collapsed.remove(id)
            } else {
                expanded.remove(id)
                collapsed.insert(id)
            }
            expandedGroupsRaw = Self.encodeSet(expanded)
            collapsedGroupsRaw = Self.encodeSet(collapsed)
        }
    }

    /// 当前会话所在组自动展开（dsh :291-294——仅未显式碰过的组；用户显式
    /// 折叠过的组不再自动展开）。【工作区模型修正】会话必在工作区账本内，
    /// 无归属时无组可展开。
    private func autoExpandCurrentGroup(_ sessionID: String?) {
        guard let sessionID,
              let groupKey = workspaces
                .first(where: { $0.sessionIds.contains(sessionID) })?.id else {
            return
        }
        var expanded = Self.decodeSet(expandedGroupsRaw)
        let collapsed = Self.decodeSet(collapsedGroupsRaw)
        if !expanded.contains(groupKey), !collapsed.contains(groupKey) {
            expanded.insert(groupKey)
            expandedGroupsRaw = Self.encodeSet(expanded)
        }
    }

    private static func decodeSet(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(array)
    }

    private static func encodeSet(_ set: Set<String>) -> String {
        let sorted = set.sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    // MARK: B4 ④：重命名 / 归档

    private var renameTitle: String {
        switch renameTarget {
        case .session: return "重命名会话"
        case nil: return "重命名"
        }
    }

    private func commitSessionRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch renameTarget {
        case .session(let id, _):
            // 会话标题（F072 session.rename 折算：GRDB 索引标题直写——
            // 标题非模型上下文事实源，事件流侧由标题生成器同口径管理）。
            environment.database.setTitle(id: id, title: name)
            environment.sessionsRevision += 1
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
                // 锚 = 被落组自身（移到其前）。【工作区模型修正】组恒为工作区组。
                let anchor = anchorGroup.workspaceID
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

    // MARK: UI 对齐批 1（B4/C1/B）：添加工作区（【工作区模型修正】输入名字即全部）

    /// 添加流（与空态页共用 WorkspaceAdoption）：建 iSH 项目目录（幂等）+
    /// registry.create（幂等）→ startSession(新工作区)——「+ 的终点是开着的新
    /// 会话」。空名/清洗后为空 → 提示，不进创建流。
    private func adoptWorkspace(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newProjectName = ""
            return
        }
        do {
            let workspace = try WorkspaceAdoption.adopt(
                name: name, environment: environment)
            newProjectName = ""
            // dsh WorkspaceBrowser.tsx:1175-1178——onPick → startSession。
            environment.workspaceNavigator.startSession(workspace.id)
        } catch {
            newProjectName = ""
            addWorkspaceError = "添加工作区失败：\(error.localizedDescription)"
        }
    }

    // MARK: UI 对齐批 1（C7）：工作区重命名 / 删除

    private var wsRenameTrimmed: String {
        wsRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 重名查重（dsh :970-973：draft 非空 && 与原题不同 && 与任一工作区重名）。
    private var wsRenameDuplicate: Bool {
        guard let target = wsRenameTarget else { return false }
        return !wsRenameTrimmed.isEmpty
            && wsRenameTrimmed != target.current
            && workspaces.contains(where: { $0.title == wsRenameTrimmed })
    }

    private var wsRenameBlocked: Bool {
        guard let target = wsRenameTarget else { return true }
        return wsRenameTrimmed.isEmpty
            || wsRenameTrimmed == target.current
            || wsRenameDuplicate
    }

    private func commitWorkspaceRename() {
        guard let target = wsRenameTarget, !wsRenameBlocked else { return }
        do {
            _ = try environment.workspaceController.rename(id: target.id,
                                                           to: wsRenameTrimmed)
            wsRenameTarget = nil
        } catch {
            wsRenameError = "重命名失败：\(String(describing: error))"
        }
    }

    private func confirmWorkspaceDelete() {
        guard let target = wsDeleteTarget, !wsDeleting else { return }
        wsDeleting = true
        wsDeleteCommittedID = nil
        wsDeleteError = nil
        let workspaceID = target.id
        Task { @MainActor in
            // 批12+工作区删除 C（2026-09-26 用户裁决）：删工作区 = 连组内会话
            // 一起删（偏离 dsh delete 只删记录语义，用户裁决优先；删前留底 =
            // F070 会话 ZIP 导出，M9.3 排期）。工作区目录仅删 App 管控的
            // projects/<n> 内路径——用户经 DirectoryPicker 外选的真实目录
            // （iCloud 等）绝不触碰。
            var failure: String?
            let sessionIDs = workspaces.first(where: { $0.id == workspaceID })?
                .sessionIds ?? []
            for sid in sessionIDs {
                await environment.deleteSession(id: sid)
                if let err = environment.sessionActionError {
                    failure = err
                    environment.sessionActionError = nil
                    break
                }
            }
            if failure == nil {
                if let record = environment.workspaceRegistry.list()
                    .first(where: { $0.id == workspaceID }),
                   WanWoPaths.isProjectsGuestPath(record.path),
                   record.path != WanWoPaths.projectsLinuxDir,
                   let hostDir = WanWoPaths.projectsHostRoot(forGuestPath: record.path) {
                    try? FileManager.default.removeItem(at: hostDir)
                    IshExecutorBridge.setProjectDirectories(
                        environment.workspaceRegistry.list().map(\.path)
                            .filter { WanWoPaths.isProjectsGuestPath($0)
                                && $0 != WanWoPaths.projectsLinuxDir })
                }
                do {
                    if try environment.workspaceController.delete(id: workspaceID) {
                        // 确认保持到列表渲染出无该 id 才关（dsh :1053-1067——
                        // 防 stale frame）；由 onChange(of: workspaces) 收口。
                        wsDeleteCommittedID = workspaceID
                    } else {
                        // 幂等 no-op（id 已不存在）——直接收口关闭。
                        wsDeleting = false
                        wsDeleteTarget = nil
                    }
                } catch {
                    wsDeleting = false
                    wsDeleteError = "删除失败：\(String(describing: error))"
                }
            } else {
                wsDeleting = false
                wsDeleteError = failure
            }
        }
    }

    private func closeWorkspaceDelete() {
        guard !wsDeleting else { return }
        wsDeleteTarget = nil
        wsDeleteError = nil
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
