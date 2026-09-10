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
                    + "API Key 优先存 Keychain，侧载环境 Keychain 不可用时自动以沙箱文件兜底（ERR-016）；均不写入配置文件。")
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
    @State private var loaded = false
    /// ERR-016：凭据保存结果透出（存储层/失败原因）——失败时留在页面显示，不再静默。
    @State private var credentialNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("端点") {
                    TextField("名称（如 DeepSeek）", text: $name)
                    TextField("Base URL（https://api.deepseek.com）", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("model（如 deepseek-v4-flash）", text: $model)
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
                    // ERR-016：保存结果透出（Keychain/文件兜底/失败原因）。
                    if let notice = credentialNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(notice.hasPrefix("Key 保存失败") ? .red : .secondary)
                    }
                }
                // T2.4 P1-③：reasoning_effort 控件移除——配置页回归纯
                // 服务商配置（dsh 分层：settings models section 只管
                // provider/model 目录；推理等级在对话内 per-session 调整，
                // ModelSelect.tsx effort pane）。端点级字段废弃。
                // T2.6 件3（用户 #10）：thinking Toggle 移除——dsh
                // ui-settings-models 无 thinking 概念（grep 零命中），且开关
                // 语义已被会话级 effort 完整承载（effort off→wire
                // thinking:disabled、有值→enabled+档位，OpenAICompatAdapter
                // resolveThinking 链）；端点级 Toggle=同一事实双宿主（one home
                // per fact 违例）。EndpointConfig.thinking 字段+adapter 消费
                // 链保留（解码兼容；新写入恒 nil→request.thinking nil→effort
                // 决定 thinkingType）。
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
            // T2.4 P1-③：reasoningEffort 不回读——端点级字段废弃。
            // T2.6 件3：thinking 不回读（Toggle 已删；字段解码兼容恒 nil）。
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
        // T2.6 件3：不再写 thinking（Toggle 已删——thinking 开/关语义由会话级
        // effort 完整承载；编辑既有端点时旧值经 config 拷贝原样保留但语义废弃）。
        // T2.4 P1-③：不再写 reasoningEffort（端点级字段废弃；编辑既有端点时
        // 旧值经 config 拷贝原样保留但被会话级选择覆盖，新端点恒 nil）。

        if endpoint == nil {
            config.isEnabled = true
            store.add(config)
        } else {
            store.update(config)
        }
        if !apiKey.isEmpty {
            do {
                // ERR-016：保存结果透出；失败留在页面显示具体原因（原实现静默吞错，
                // 用户以为已保存、实际 Keychain 不可用）。
                credentialNotice = try store.setApiKey(apiKey, for: config)
            } catch {
                credentialNotice = "Key 保存失败：\((error as NSError).localizedDescription)"
                return
            }
        }
        dismiss()
    }
}
