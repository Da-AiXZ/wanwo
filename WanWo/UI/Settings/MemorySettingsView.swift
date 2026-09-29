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
struct MemorySettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var isEnabled: Bool = MemorySettings.isEnabled
    @State private var entryCount: Int = 0
    @State private var lastConsolidated: Date?
    @State private var confirmClear = false
    @State private var clearError: String?
    @State private var entries: [MemoryStorage.MemoryEntry] = []
    @State private var selectedEntry: MemoryStorage.MemoryEntry?

    var body: some View {
        List {
            Section("长期记忆") {
                Toggle("启用记忆", isOn: $isEnabled)
                Text("开启后，万我会定期把已结束会话中有复用价值的经验沉淀为长期记忆，并在后续对话中自动参考。默认开启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("状态") {
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
                                   storage: environment.memoryStorage) {
                refresh()
            }
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

    private func refresh() {
        do {
            let entries = try environment.memoryDatabase.listEntries()
            entryCount = entries.count
            lastConsolidated = try environment.memoryDatabase.lastPhase2SuccessDate()
            self.entries = try environment.memoryStorage.listSettingEntries()
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
            onMutated()
            dismiss()
        } catch {
            errorText = "删除失败：\(String(describing: error))"
        }
    }
}
