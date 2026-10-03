//
//  MemorySettingsView.swift
//  WanWo
//
//  M7 件 G（F043）+ 件 I：设置 · 记忆 分区（codex memories 面的用户宿主）：
//    · 总开关（MemorySettings.isEnabled——触发三重门之一，默认开——拍板①）；
//    · 条目概览（stage1_outputs 条数 + 最近一次整合时刻——jobs 表 phase2 行）；
//    · 一键清空（账本两表清 + memory/ 目录树删 + 快照清单删——MemoryDatabase.
//      clearAll + MemoryStorage.clearAll 分工，注释见各自件头注）；
//    · 条目列表 + 查看/编辑/删除（落点⑩：数据源 = MemoryStorage.
//      listSettingEntries 只读目录面——MEMORY.md 区块 / raw_memories.md 条目 /
//      rollout_summaries/*.md / extensions/ad_hoc/notes/*.md；文档型条目编辑 =
//      区块拼接回写，文件型 = 整文重写/删除，见 MemoryStorage 同名 API）。
//  形态：List 子页（与既有六分区同容器纪律——ProvidersView 等先例）；条目详情
//  用 .sheet(item:) + 内嵌 NavigationStack（设置面板无 NavigationStack——
//  MountedFoldersSettingsView 命名卡先例）；触屏点击目标 ≥44pt。
//

import SwiftUI

/// 设置 · 记忆（SettingsPane.memory 路由落点）。
/// M8 批3 件 C2（项目化）：条目列举/编辑/删除按当前项目桶
/// （MemoryProjectLayout 消费；cwd 无法解析项目 = nil 回落 legacy 全局桶
/// ——批3 派单冻结口径）。账本计数（已沉淀条目）仍为全局 MemoryDatabase
/// 面（C1 账本参数化后接续，登记）。
struct MemorySettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var isEnabled: Bool = MemorySettings.isEnabled
    @State private var entryCount: Int = 0
    @State private var lastConsolidated: Date?
    @State private var confirmClear = false
    @State private var clearError: String?
    @State private var entries: [MemoryStorage.MemoryEntry] = []
    @State private var selectedEntry: MemoryStorage.MemoryEntry?
    /// 当前项目桶存储（refresh 时按当前选择重算；编辑/删除同桶）。
    @State private var bucketStorage: MemoryStorage?
    /// 当前记忆范围标签（设置页可读性——项目路径尾段或「全局」）。
    @State private var scopeLabel: String = ""

    var body: some View {
        List {
            Section("长期记忆") {
                Toggle("启用记忆", isOn: $isEnabled)
                Text("开启后，万我会定期把已结束会话中有复用价值的经验沉淀为长期记忆，并在后续对话中自动参考。默认开启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("状态") {
                if !scopeLabel.isEmpty {
                    LabeledContent("记忆范围", value: scopeLabel)
                }
                LabeledContent("已沉淀条目", value: "\(entryCount)")
                if let last = lastConsolidated {
                    LabeledContent("上次整合",
                                   value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("记忆条目") {
                if entries.isEmpty {
                    Text("暂无记忆条目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Text("清空全部记忆")
                }
                .disabled(entryCount == 0)
            } footer: {
                Text("删除全部记忆条目与整合产物（不影响会话记录）。")
            }
            if let clearError {
                Section {
                    Text(clearError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: isEnabled) { enabled in
            MemorySettings.isEnabled = enabled
        }
        .sheet(item: $selectedEntry) { entry in
            MemoryEntryDetailSheet(entry: entry,
                                   storage: bucketStorage ?? environment.memoryStorage,
                                   onMutated: { refresh() },
                                   onNotify: { environment.notifyMemoryChange($0) })
        }
        .alert("清空全部记忆？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("该操作不可撤销：全部记忆条目、整合产物与账本将被删除。")
        }
    }

    // MARK: - 条目行（触屏点击目标 ≥44pt）

    private func entryRow(_ entry: MemoryStorage.MemoryEntry) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: entry.kind))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.label)：\(entry.title)")
    }

    private func subtitle(_ entry: MemoryStorage.MemoryEntry) -> String {
        var parts: [String] = [entry.kind.label]
        if let session = entry.sourceSession {
            parts.append("来源 \(session.prefix(8))…")
        }
        if let date = entry.date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private static func icon(for kind: MemoryStorage.MemoryEntryKind) -> String {
        switch kind {
        case .memoryBlock: return "square.grid.2x2"
        case .rawMemory: return "doc.text"
        case .rolloutSummary: return "doc.badge.clock"
        case .adHocNote: return "note.text"
        }
    }

    // MARK: - 状态刷新 / 清空

    /// 当前会话 cwd 探针（.session 选择 → header cwd；轻量探针只读 header，
    /// 禁全量读流——AppEnvironment sessionNavProbe 同思路）。
    private static func sessionCwd(_ sessionID: String) -> String? {
        guard !sessionID.isEmpty,
              sessionID.allSatisfy({ $0.isLetter || $0.isNumber
                    || $0 == "-" || $0 == "_" }) else { return nil }
        let url = GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase, groupID: GroupStore.defaultGroupID)
            .appendingPathComponent("\(sessionID).jsonl")
        guard let probe = try? SessionLogScanner.probeLightweight(fileURL: url) else {
            return nil
        }
        return probe.header.cwd
    }

    /// 当前项目 cwd（当前会话 header cwd 投影——RootSelection 无 workspace
    /// 案，会话为中心导航；无当前会话 = nil → legacy 全局桶，登记）。
    private var currentProjectCwd: String? {
        guard let id = environment.appState.currentSessionId else { return nil }
        return Self.sessionCwd(id)
    }

    private func refresh() {
        do {
            let entries = try environment.memoryDatabase.listEntries()
            entryCount = entries.count
            lastConsolidated = try environment.memoryDatabase.lastPhase2SuccessDate()
            // M8 批3 件 C2：条目数据源 = 当前项目桶 MemoryStorage（桶根传入
            // 既有 listSettingEntries/updateSettingEntry/deleteSettingEntry 面
            // ——零 API 改动）。
            let cwd = currentProjectCwd
            // batch2/3-review P2-1 收口：清单 manifest 用桶内隐藏文件
            // （MemoryProjectLayout.storage(forCwd:)），不再误用全局
            // config/memory-snapshot.json；nil = legacy 全局桶原样。
            let storage = cwd.flatMap { MemoryProjectLayout.storage(forCwd: $0) }
                ?? MemoryProjectLayout.legacyStorage
            bucketStorage = storage
            scopeLabel = cwd.map { path in
                MemoryProjectLayout.memoryBucketURL(forCwd: path) != nil
                    ? String(path.split(separator: "/").last.map(String.init) ?? path)
                    : "全局（legacy）"
            } ?? "全局（legacy）"
            self.entries = try storage.listSettingEntries()
            clearError = nil
        } catch {
            clearError = "读取记忆状态失败：\(String(describing: error))"
        }
    }

    private func clearAll() {
        do {
            try environment.memoryDatabase.clearAll()
            try environment.memoryStorage.clearAll()
            clearError = nil
            environment.notifyMemoryChange("用户刚在设置中清空了全部长期记忆条目与整合产物，请不要再引用任何旧记忆。")
        } catch {
            clearError = "清空失败：\(String(describing: error))"
        }
        refresh()
    }
}

// MARK: - 条目详情（查看全文 / 编辑保存 / 删除单条）

/// .sheet(item:) 内容件（MountedFoldersSettingsView 命名卡同径：sheet 内自持
/// NavigationStack——设置面板容器无 NavigationStack、toolbar 不生效先例）。
private struct MemoryEntryDetailSheet: View {
    let entry: MemoryStorage.MemoryEntry
    let storage: MemoryStorage
    let onMutated: () -> Void
    /// 设置侧记忆变更 → 活跃会话静默系统纸条（A 组验收拍板；AppEnvironment.
    /// notifyMemoryChange 注释）。
    let onNotify: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var draft: String = ""
    @State private var errorText: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        Text(entry.fullText)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(entry.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(isEditing ? "预览" : "编辑") {
                        if !isEditing { draft = entry.fullText }
                        isEditing.toggle()
                    }
                    if isEditing {
                        Button("保存") { save() }
                    }
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            }
            .confirmationDialog("删除这条记忆条目？", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("该操作不可撤销。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func save() {
        do {
            try storage.updateSettingEntry(entry, newText: draft)
            errorText = nil
            isEditing = false
            onNotify("用户刚在设置中编辑了长期记忆条目「\(entry.relPath)」，内容已更新——后续请以最新内容为准。")
            onMutated()
            dismiss()
        } catch {
            errorText = "保存失败：\(String(describing: error))"
        }
    }

    private func delete() {
        do {
            try storage.deleteSettingEntry(entry)
            errorText = nil
            onNotify("用户刚在设置中删除了长期记忆条目「\(entry.relPath)」，请不要再引用它。")
            onMutated()
            dismiss()
        } catch {
            errorText = "删除失败：\(String(describing: error))"
        }
    }
}
