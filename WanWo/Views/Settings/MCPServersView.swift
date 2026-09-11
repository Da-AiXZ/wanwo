//
//  MCPServersView.swift
//  WanWo
//
//  【M4-A 件11 · 最小设置页】交互参照 OpenMinis Views/MCP/MCPIntegrationsView
//  （dsh 无对应物——R7 UI 遵 OpenMinis；列表行=状态点+名称+transport 摘要，
//  添加/编辑 sheet 表单、删除）。SwiftUI 形态沿 WanWo Settings 族页面风格
//  （ProvidersView 同款：List+行内 Toggle/编辑/删除按钮+sheet Form）。
//  最小功能集（lead 派单）：server 列表（名称/URL/启用）+添加/编辑/删除+
//  状态展示；不做 OAuth/JSON 导入/.secret 移交（OpenMinis 有但非最小集）。
//  状态展示口径：行首状态点=启用态（OpenMinis row 同款）；M4-A 验收增补
//  （方案甲）：行尾"上次激活 ✓/✗"直显最近一次激活结果（实时连接状态仍归
//  M4-B/M9——呈报）。
//

import SwiftUI

struct MCPServersView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: MCPServerStore
    /// M4-A 验收增补（方案甲）：上次激活状态直显——激活链失败原本只落
    /// AppLogger/os.log（App 内零导出面），用户独自持机无法定位
    /// "为什么 mcp__* 工具不在"；现每 server 行尾直读最近一次激活结果。
    @ObservedObject private var lastActivation: MCPLastActivationStore

    @State private var showingAddSheet = false
    @State private var editingEntry: MCPServerEntry?

    init(environment: AppEnvironment) {
        self.environment = environment
        _store = ObservedObject(wrappedValue: environment.mcpServerStore)
        _lastActivation = ObservedObject(wrappedValue: environment.mcpLastActivation)
    }

    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    serverRow(server)
                }
            } footer: {
                Text("Streamable HTTP 接入。凭据 Token 优先存 Keychain，不写入配置文件；"
                    + "增删改在下一个会话栈构建时生效。")
            }
        }
        .navigationTitle("MCP")
        .toolbar {
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPServerEditSheet(store: store, entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            MCPServerEditSheet(store: store, entry: entry)
        }
    }

    @ViewBuilder
    private func serverRow(_ server: MCPServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 状态点=启用态（OpenMinis MCPIntegrationsView row 同款；
                // 实时连接状态归 M4-B/M9——呈报）。
                Circle()
                    .fill(server.enabled ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(server.id)
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in store.setEnabled(enabled, id: server.id) }))
                    .labelsHidden()
            }
            Text(server.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note = server.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let activation = lastActivation.entry(for: server.id) {
                Text(Self.activationText(activation))
                    .font(.caption2)
                    .foregroundStyle(activation.succeeded ? Color.green : Color.red)
                    .lineLimit(2)
            }
            HStack {
                Button("编辑") { editingEntry = server }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("删除", role: .destructive) { store.remove(id: server.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    /// 激活状态用户可读文案（lead 要求③——不暴露内部枚举名；失败原因取
    /// 本仓错误文案或 URLError 系统本地化描述，已过 sanitized 净化）。
    private static func activationText(_ entry: MCPLastActivationStore.Entry) -> String {
        let time = entry.time.formatted(.dateTime.hour().minute())
        if entry.succeeded {
            return "上次激活：✓ \(time)"
        }
        let reason = entry.message.map { " · \($0)" } ?? ""
        return "上次激活：✗ \(time)\(reason)"
    }
}

/// server 编辑表单（新增与编辑共用；EndpointEditSheet 同款形态）。
struct MCPServerEditSheet: View {
    @ObservedObject var store: MCPServerStore
    let entry: MCPServerEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var note: String = ""
    @State private var token: String = ""
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称（[A-Za-z0-9_-]{1,32}）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(entry != nil)
                    TextField("URL（https://example.com/mcp）", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $note)
                }
                Section("凭据") {
                    SecureField("Bearer Token（可选）", text: $token)
                    if let entry, store.hasAuthToken(for: entry.id) {
                        Text("已存有 Token；留空保留，清除用下方按钮。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("清除已存 Token", role: .destructive) {
                            store.clearAuthToken(for: entry.id)
                        }
                    }
                    Text("Token 存 Keychain（service com.wanwo.mcp），不写入配置文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(entry == nil ? "添加 MCP Server" : "编辑 MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let entry {
                    name = entry.id
                    url = entry.url
                    note = entry.note ?? ""
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MCPClientConfig.isValidServerName(trimmedName) else {
            errorText = "名称必须匹配 [A-Za-z0-9_-]{1,32}。"
            return
        }
        guard !trimmedURL.isEmpty else {
            errorText = "URL 不能为空。"
            return
        }
        // 编辑态：名称即主键不可改（改名=删旧建新，最小集不做改名迁移）。
        var updated = entry ?? MCPServerEntry(id: trimmedName, url: trimmedURL,
                                              enabled: true, note: nil, headers: [:])
        updated.url = trimmedURL
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.note?.isEmpty == true { updated.note = nil }
        do {
            if !token.isEmpty {
                try store.setAuthToken(token, for: updated.id)
            }
        } catch {
            errorText = "Token 保存失败：\((error as NSError).localizedDescription)"
            return
        }
        store.upsert(updated)
        dismiss()
    }
}
