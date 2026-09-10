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
//  单层会话列表（workspaces 分组需产品实体——本批不做，派单既定）；
//  搜索=本地标题过滤（WanWo 无 session.search 远程缝——呈报）；
//  ViewOptionsMenu 缺位呈报（groupBy 需 workspaces 实体、manual 需 order
//  持久化缝，均属 ia-audit §3.5 M9 候选）。
//  iPad 分栏形态保留（NavigationSplitView sidebar 列，内部重排）。
//  M0 回归入口（ShellTestView）保留在「诊断」段（M0 验收仍可过；
//  ia-audit §3.1 三段语义维持，M9 收口降级为诊断子项或 DEBUG-only）。
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

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            newSessionButton
            browseHeader
            sessionList
            Divider()
            footArea
        }
        .task { await reload() }
        .onChange(of: environment.sessionsRevision) { _ in
            Task { await reload() }
        }
        // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
        // P2-⑫：呈现由 confirmationDialog 改居中模态（dsh SettingsRoot/
        // WorkspaceBrowser 删除确认对话框形态——透明底全屏 + 居中卡片）。
        // P1-6 未点名此遮罩（用户仅点两处完全权限确认框）——保持现状。
        .fullScreenCover(isPresented: Binding(get: { pendingDeleteOffsets != nil },
                                             set: { if !$0 { pendingDeleteOffsets = nil } })) {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
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
    /// label——与品牌行同写通 newSession 一径）。
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

    // MARK: - 浏览区（dsh WorkspaceBrowser.tsx:1072-1181 header + 列表）

    /// section header：「会话」label（'section.sessions' 逐字）+ 搜索框。
    /// ViewOptionsMenu 缺位呈报（见文件头注）。
    private var browseHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("会话")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            searchField
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

    /// 会话列表：本地过滤 + List（滑动删除既有交互承载）；空态两词源出
    /// dsh 词典（无查询「暂无会话」/ 有查询「无匹配会话」）。
    private var sessionList: some View {
        let rows = filteredSummaries
        return List {
            ForEach(rows) { summary in
                sessionRow(summary)
            }
            .onDelete { indexSet in
                // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
                pendingDeleteOffsets = indexSet
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty {
                Text(query.isEmpty ? "暂无会话" : "无匹配会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 单行会话：标题（dsh blank 行语义「新会话」）+ 相对时间（time.ago
    /// 词典）+ 琥珀警示点 + 选中高亮（dsh currentId 高亮语义）。
    private func sessionRow(_ summary: SessionSummary) -> some View {
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
    }

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

    /// 本地标题过滤（dsh :877 normalizedQuery trim 语义；远程内容搜索缺位呈报）。
    private var filteredSummaries: [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return summaries }
        return summaries.filter {
            ($0.title ?? "新会话").localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: - foot（dsh SidebarRoot.tsx:211-219）

    /// 底部钉住区：设置段（Providers / 权限）+ 诊断段（Shell 测试 / 事件流）
    /// ——三段语义维持（ia-audit §3.1），M9 收口时 ShellTestView 降级。
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
            footButton("权限", icon: "lock.shield") {
                // M3 T2.2：设置·新会话默认权限行（PermissionRow.tsx 1:1；
                // P1-4 后唯一权限入口——规则 CRUD 页随 F022 砍除）。
                selection = .permissionDefaults
            }
            Text("诊断")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            footButton("Shell 测试（M0）", icon: "terminal") {
                selection = .shellTest
            }
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
        let ids = offsets.map { summaries[$0].id }
        Task {
            for id in ids {
                await environment.deleteSession(id: id)
            }
        }
    }
}
