//
//  ProvidersView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.2（设置 · Providers：BYOK 凭据、
//  模型启停）、§十一 M1.5（多端点配置管理：名称/base URL/key/model 增删改查 +
//  启用切换；key 入 Keychain）。§7.4 视觉素净占位。
//

import SwiftUI

struct ProvidersView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: EndpointStore

    @State private var showingAddSheet = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _store = ObservedObject(wrappedValue: environment.endpointStore)
    }

    var body: some View {
        List {
            Section {
                ForEach(store.endpoints) { endpoint in
                    endpointRow(endpoint)
                }
            } footer: {
                Text("OpenAI 兼容格式接入（base URL + API Key + model 自填，09 #16）。"
                    + "API Key 保存在 Keychain，不写入配置文件。")
            }
        }
        .navigationTitle("Providers")
        .toolbar {
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            EndpointEditSheet(store: store, endpoint: nil)
        }
        .sheet(item: $editingEndpoint) { endpoint in
            EndpointEditSheet(store: store, endpoint: endpoint)
        }
    }

    @State private var editingEndpoint: EndpointConfig?

    @ViewBuilder
    private func endpointRow(_ endpoint: EndpointConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(endpoint.name)
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { endpoint.isEnabled },
                    set: { enabled in store.setEnabled(enabled, for: endpoint) }))
                    .labelsHidden()
            }
            Text("\(endpoint.baseURL) · \(endpoint.model)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("编辑") { editingEndpoint = endpoint }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("删除", role: .destructive) { store.remove(endpoint) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
        }
    }
}

/// 端点编辑表单（新增与编辑共用）。
struct EndpointEditSheet: View {
    @ObservedObject var store: EndpointStore
    let endpoint: EndpointConfig?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var thinkingEnabled = false
    @State private var reasoningEffort: String = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("端点") {
                    TextField("名称（如 DeepSeek）", text: $name)
                    TextField("Base URL（https://api.deepseek.com）", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("model（如 deepseek-chat）", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("凭据") {
                    SecureField("API Key", text: $apiKey)
                    if endpoint != nil {
                        Text("留空则保留已保存的 Key。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("DeepSeek 扩展（可选透传，09 #16）") {
                    Toggle("thinking", isOn: $thinkingEnabled)
                    Picker("reasoning_effort", selection: $reasoningEffort) {
                        Text("（不发）").tag("")
                        Text("off").tag("off")
                        Text("low").tag("low")
                        Text("high").tag("high")
                        Text("max").tag("max")
                    }
                }
            }
            .navigationTitle(endpoint == nil ? "新增端点" : "编辑端点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.isEmpty || baseURL.isEmpty || model.isEmpty)
                }
            }
            .onAppear(perform: loadInitial)
        }
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        if let endpoint = endpoint {
            name = endpoint.name
            baseURL = endpoint.baseURL
            model = endpoint.model
            thinkingEnabled = endpoint.thinking == "enabled"
            reasoningEffort = endpoint.reasoningEffort ?? ""
            // Key 不回读显示（Keychain 值不进 UI 文本框；留空 = 保留）。
        }
    }

    private func save() {
        var normalizedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBase.hasSuffix("/") {
            normalizedBase.removeLast()
        }
        var config = endpoint ?? EndpointConfig(name: name, baseURL: normalizedBase, model: model)
        config.name = name
        config.baseURL = normalizedBase
        config.model = model
        config.thinking = thinkingEnabled ? "enabled" : nil
        config.reasoningEffort = reasoningEffort.isEmpty ? nil : reasoningEffort

        if endpoint == nil {
            config.isEnabled = true
            store.add(config)
        } else {
            store.update(config)
        }
        if !apiKey.isEmpty {
            store.setApiKey(apiKey, for: config)
        }
        dismiss()
    }
}
