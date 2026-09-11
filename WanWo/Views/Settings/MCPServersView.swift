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
    /// 方案乙最小化：诊断文件 URL（ShareLink 导出；init 时一次性取定——
    /// 文件路径 App 生命周期内不变）。
    private let diagnosticsFileURL: URL

    init(environment: AppEnvironment) {
        self.environment = environment
        _store = ObservedObject(wrappedValue: environment.mcpServerStore)
        _lastActivation = ObservedObject(wrappedValue: environment.mcpLastActivation)
        diagnosticsFileURL = MCPDiagnosticsLog.shared.url
    }

    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    serverRow(server)
                }
            } footer: {
                Text("Streamable HTTP 或 stdio 子进程接入（stdio 在 guest 内启动）。"
                    + "HTTP 凭据 Token 优先存 Keychain，不写入配置文件；"
                    + "增删改在下一个会话栈构建时生效。"
                    + "stdio 脚本请放在 /var/wanwo/shared/——MCP server 进程只可见全局目录，"
                    + "会话工作区（/var/wanwo/workspace/ 等）对其不可见。")
            }
            // M4-B 场景2 取证（方案乙最小化）：诊断日志导出——JSONL 事件流
            // （激活/退出/回收/重连），环形 ~100KB，错误文案已净化（无凭据）。
            Section {
                ShareLink(item: diagnosticsFileURL) {
                    Label("导出诊断日志", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("最近一次复现的 MCP 事件流（激活/进程退出/回收/重连），"
                    + "供问题定位；不含凭据。")
            }
        }
        .navigationTitle("MCP")
        .onAppear { MCPDiagnosticsLog.shared.ensureFile() }
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
            Text(Self.targetSummary(server))
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

    /// 行摘要：http=url、stdio=命令+参数（OpenMinis MCPIntegrationsView row
    /// 「url or command」target 摘要同款语义，issue-ledger:411 daemon list 行）。
    private static func targetSummary(_ server: MCPServerEntry) -> String {
        if let command = server.command {
            let argText = server.args.isEmpty ? "" : " " + server.args.joined(separator: " ")
            return command + argText
        }
        return server.url ?? ""
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
    @State private var isStdio = false
    @State private var url: String = ""
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var envText: String = ""
    @State private var cwdText: String = ""
    @State private var startupText: String = ""
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
                    // 传输形态（M4-B B1）：编辑态锁定（形态变更=删旧建新，
                    // 与「名称即主键不可改」同一纪律）。
                    Picker("类型", selection: $isStdio) {
                        Text("Streamable HTTP").tag(false)
                        Text("stdio 子进程").tag(true)
                    }
                    .disabled(entry != nil)
                    if isStdio {
                        TextField("命令（guest 内路径，如 /usr/bin/python3）", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("参数（空格分隔，可选）", text: $argsText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("环境变量（每行 K=V，可选）", text: $envText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                            .font(.caption)
                        TextField("工作目录（可选）", text: $cwdText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("启动超时秒（可选，默认 60，上限 900）", text: $startupText)
                            .keyboardType(.numberPad)
                    } else {
                        TextField("URL（https://example.com/mcp）", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("备注（可选）", text: $note)
                } header: {
                    Text("服务器")
                } footer: {
                    Text("stdio 脚本请放在 /var/wanwo/shared/——MCP server 进程只可见"
                        + "全局目录，会话工作区（/var/wanwo/workspace/ 等）对其不可见。")
                }
                if !isStdio {
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
                }
                if isStdio {
                    Section {
                        Text("stdio server 在 guest（iSH）内启动；启动超时按 server 配置"
                            + "（默认 60s，慢启动 server 如 uvx 首次装包可调大）。"
                            + "增删改在下一个会话栈构建时生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    isStdio = entry.isStdio
                    url = entry.url ?? ""
                    command = entry.command ?? ""
                    argsText = entry.args.joined(separator: " ")
                    envText = entry.env.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                    cwdText = entry.cwd ?? ""
                    startupText = entry.startupTimeoutSeconds.map(String.init) ?? ""
                    note = entry.note ?? ""
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MCPClientConfig.isValidServerName(trimmedName) else {
            errorText = "名称必须匹配 [A-Za-z0-9_-]{1,32}。"
            return
        }
        var updated: MCPServerEntry
        if isStdio {
            // stdio 形态（dsh index.ts:50-73 StdioConfig；args 切分=minis
            // main.py:420 空格切分同款；env 逐行 K=V）。
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else {
                errorText = "命令不能为空。"
                return
            }
            let args = argsText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var env: [String: String] = [:]
            for line in envText.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else {
                    errorText = "环境变量行必须是 K=V 形态：\(trimmed)"
                    return
                }
                env[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
            }
            let trimmedCwd = cwdText.trimmingCharacters(in: .whitespacesAndNewlines)
            var startup: Int?
            let trimmedStartup = startupText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStartup.isEmpty {
                guard let parsed = Int(trimmedStartup),
                      (1...MCPConstants.maxStartupTimeoutSeconds).contains(parsed) else {
                    errorText = "启动超时必须是 1-\(MCPConstants.maxStartupTimeoutSeconds) 的整数。"
                    return
                }
                startup = parsed
            }
            // 编辑态：名称即主键不可改（改名=删旧建新，最小集不做改名迁移）。
            updated = entry ?? MCPServerEntry(id: trimmedName, url: nil, enabled: true,
                                              note: nil, headers: [:], command: trimmedCommand,
                                              args: args, env: env,
                                              cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
                                              startupTimeoutSeconds: startup)
            updated.command = trimmedCommand
            updated.args = args
            updated.env = env
            updated.cwd = trimmedCwd.isEmpty ? nil : trimmedCwd
            updated.startupTimeoutSeconds = startup
        } else {
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else {
                errorText = "URL 不能为空。"
                return
            }
            updated = entry ?? MCPServerEntry(id: trimmedName, url: trimmedURL,
                                              enabled: true, note: nil, headers: [:],
                                              command: nil, args: [], env: [:],
                                              cwd: nil, startupTimeoutSeconds: nil)
            updated.url = trimmedURL
        }
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.note?.isEmpty == true { updated.note = nil }
        do {
            // Token 仅 http 形态（stdio 凭据走 env 字段，不入 Keychain token 面）。
            if !isStdio, !token.isEmpty {
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
