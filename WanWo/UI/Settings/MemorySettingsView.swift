//
//  MemorySettingsView.swift
//  WanWo
//
//  M7 件 G（F043）+ 件 I：设置 · 记忆 分区（codex memories 面的用户宿主）：
//    · 总开关（MemorySettings.isEnabled——触发三重门之一，默认开——拍板①）；
//    · 条目概览（stage1_outputs 条数 + 最近一次整合时刻——jobs 表 phase2 行）；
//    · 一键清空（账本两表清 + memory/ 目录树删 + 快照清单删——MemoryDatabase.
//      clearAll + MemoryStorage.clearAll 分工，注释见各自件头注）。
//  形态：List 子页（与既有六分区同容器纪律——ProvidersView 等先例）。
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
        .alert("清空全部记忆？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("该操作不可撤销：全部记忆条目、整合产物与账本将被删除。")
        }
    }

    private func refresh() {
        do {
            let entries = try environment.memoryDatabase.listEntries()
            entryCount = entries.count
            lastConsolidated = try environment.memoryDatabase.lastPhase2SuccessDate()
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
