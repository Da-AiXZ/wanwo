//
//  PermissionsView.swift
//  WanWo
//
//  【按缝新写 · M3 T2 · T2.2 调整】规则管理 UI（CRUD、来源可溯）。
//  T2.2：本页定位收窄为「权限规则」独立入口（设置段导航 + PermissionDefaultsView
//  的分区链接可达）——原「权限」入口由新会话默认权限行接管（PermissionRow.tsx
//  语义，规则页不再冒充「权限」行）；read-only 挡自 T2.2 起可切换（hostTable）。
//  来源可溯：每条规则展示 source（审批沉淀 / 手工）与 origin 原文。
//  CRUD 形态：JSONL 追加模型 → 增（表单）/ 删（滑动删除+全量重写）/
//  查（列表）；改 = 删后重建（追加模型的等价形态，偏差登记见批次报告）。
//

import SwiftUI

struct PermissionsView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var rules: [PermissionRule] = []
    @State private var showingAddSheet = false

    private var store: PermissionRulesStore { environment.permissionRules }

    var body: some View {
        List {
            Section {
                ForEach(PermissionPresets.defaultTable, id: \.name) { spec in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.name)
                            .font(.headline)
                        Text("sandbox: \(spec.sandbox.rawValue) · approval: \(spec.approval.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(spec.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("权限预设")
            } footer: {
                Text("预设按会话切换：聊天输入 /permission 查看，/permission <预设名> 切换；"
                    + "当前会话也可用输入框挡位下拉切换。custom 为派生态，不可作为切换目标。")
            }

            Section {
                if rules.isEmpty {
                    Text("暂无规则")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
                .onDelete { indexSet in
                    for index in indexSet where rules.indices.contains(index) {
                        _ = store.remove(id: rules[index].id)
                    }
                    reload()
                }
            } header: {
                Text("权限规则")
            } footer: {
                Text("prefix 规则按命令 token 前缀匹配（同位多选一用 | 分隔）；network 规则按 host 精确匹配，禁通配。"
                    + "审批时点「允许并记住」会沉淀「审批沉淀」规则；解释器/提权等黑名单前缀永不沉淀。")
            }
        }
        .navigationTitle("权限规则")
        .toolbar {
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            PermissionRuleEditSheet(store: store, onSaved: { reload() })
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        rules = store.rules
    }

    @ViewBuilder
    private func ruleRow(_ rule: PermissionRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(rule.kind)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                Text(rule.verdict)
                    .font(.caption.bold())
                    .foregroundStyle(rule.verdict == "allow" ? Color.green
                                     : rule.verdict == "forbidden" ? Color.red : Color.orange)
                Spacer()
                Text(rule.source == "remembered" ? "审批沉淀" : "手工")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(rule.kind == "prefix"
                 ? (rule.pattern?.map { $0.joined(separator: "|") }
                     .joined(separator: " ") ?? "")
                 : (rule.host ?? ""))
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let origin = rule.origin, !origin.isEmpty {
                Text("来源：\(origin)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// 规则新增表单（修改 = 删除后重建——JSONL 追加模型的 CRUD 等价形态）。
struct PermissionRuleEditSheet: View {
    let store: PermissionRulesStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "prefix"
    @State private var prefixText = ""
    @State private var host = ""
    @State private var verdict = "allow"

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("类型", selection: $kind) {
                        Text("prefix（命令前缀）").tag("prefix")
                        Text("network（主机）").tag("network")
                    }
                }
                if kind == "prefix" {
                    Section("prefix 规则") {
                        TextField("命令前缀（如 npm run build）", text: $prefixText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("同位多选一用 | 分隔（如 npm|pnpm run build）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("network 规则") {
                        TextField("host（如 api.example.com 或 https://api.example.com）",
                                  text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("host 精确匹配，不支持通配（含 * 的规则永不命中）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("判定") {
                    Picker("verdict", selection: $verdict) {
                        Text("allow（放行）").tag("allow")
                        Text("prompt（询问）").tag("prompt")
                        Text("forbidden（拒绝）").tag("forbidden")
                    }
                }
            }
            .navigationTitle("新增规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(kind == "prefix"
                                  ? prefixText.trimmingCharacters(in: .whitespaces).isEmpty
                                  : host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedPrefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let rule: PermissionRule
        if kind == "prefix" {
            // 多选一语法：同位 token 以 | 分隔（npm|pnpm run build）。
            let pattern = trimmedPrefix
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { $0.split(separator: "|", omittingEmptySubsequences: true)
                    .map(String.init) }
            rule = PermissionRule(id: UUID().uuidString, kind: "prefix", pattern: pattern,
                                  host: nil, verdict: verdict, source: "manual",
                                  origin: trimmedPrefix, createdAtMs: now)
        } else {
            rule = PermissionRule(id: UUID().uuidString, kind: "network", pattern: nil,
                                  host: trimmedHost, verdict: verdict, source: "manual",
                                  origin: trimmedHost, createdAtMs: now)
        }
        _ = store.add(rule)
        onSaved()
        dismiss()
    }
}
