//
//  ProvidersView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.2（设置 · Providers：BYOK 凭据、
//  模型启停）、§十一 M1.5（多端点配置管理：名称/base URL/key/model 增删改查 +
//  启用切换；key 入 Keychain）。§7.4 视觉素净占位。
//  【批3 B 增强】dsh ui-settings-models 语义（审计矩阵 §6.3）：
//    · B1 BYOK 首跑引导（DeepSeekOnboardingDialog.tsx:99-124——credentialOnly
//      复用编辑表单 + 「稍后配置」；确认态 UserDefaults 持久，键
//      wanwo.settings.byokOnboardingConfirmed，待迁移标注见报告）；
//    · B2 API 密钥状态点（实心=已配置 / 空心=缺失；role title 语义 → 辅助
//      功能标签）；
//    · B3 删除确认 Modal（有凭证/无凭证两版描述 + 删除中状态行；dsh conflict
//      文案无本地对应面——本地移除为同步操作无服务端冲突，取舍登记报告）；
//    · B4 API key 形校验（EndpointStore.apiKeyFailure——dsh apiKey.ts:12-58
//      四类裁剪，报告注明）；
//    · B5 discoverModels：核实不做（万我 provider 协议无 /v1/models 拉取面，
//      model 为静态字符串字段——LLM 层 grep 零命中，报告注明）。
//  【批3 A】本页原样迁入设置面板（SettingsPanelView contentBody 路由）；
//  navigationTitle 在面板容器内无 NavigationStack 时惰性（无害）。
//

import SwiftUI

struct ProvidersView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: EndpointStore

    /// 【批3 B1】BYOK 首跑引导确认态（UserDefaults 持久；万我无统一设置域
    /// → 键直接落 UserDefaults.standard，迁移至 config 域随报告登记）。
    @AppStorage("wanwo.settings.byokOnboardingConfirmed")
    private var byokOnboardingConfirmed = false
    /// 单一 sheet 槽（同节点多 .sheet 在 iOS16 呈现层互踩：编辑页被引导页
    /// 顶掉/呈现损坏崩溃——2026-09-20 真机 .ips SIGABRT 实证路径）。
    private enum ActiveSheet: Identifiable {
        case onboarding, add, edit(EndpointConfig)
        var id: String {
            switch self {
            case .onboarding: return "onboarding"
            case .add: return "add"
            case .edit(let e): return e.id
            }
        }
    }
    @State private var activeSheet: ActiveSheet?
    /// 【批3 B3】删除确认 Modal 状态。
    @State private var pendingDelete: EndpointConfig?
    @State private var showingDeleteDialog = false
    @State private var deleteInFlight = false

    init(environment: AppEnvironment) {
        self.environment = environment
        _store = ObservedObject(wrappedValue: environment.endpointStore)
    }

    var body: some View {
        List {
            // 【批4】添加入口实体化：SettingsPanelView 容器无 NavigationStack，
            // .toolbar 的「+」在其中不渲染——改为 List 显式按钮行，两种容器
            // （面板 / RootView detail）下均可见可用（与 EventStreamView 同案）。
            Section {
                Button {
                    activeSheet = .add
                } label: {
                    Label("添加端点", systemImage: "plus.circle.fill")
                }
            }
            Section {
                ForEach(store.endpoints) { endpoint in
                    endpointRow(endpoint)
                }
            } footer: {
                Text("OpenAI 兼容格式接入（base URL + API Key + model 自填，09 #16）。"
                    + "API Key 优先存 Keychain，侧载环境 Keychain 不可用时自动以沙箱文件兜底（ERR-016）；均不写入配置文件。")
            }
            // 【批3 B3】删除中状态行（本地移除为同步操作，实践中转瞬即逝——
            // 状态机真实存在，报告注明）。
            if deleteInFlight {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在删除…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Providers")
        // 【批4】toolbar「+」保留（RootView detail 导航容器语境正常渲染），
        // 与上方「添加端点」实体行并存（面板语境由实体行承载）——同
        // EventStreamView 一致性方案。
        .toolbar {
            Button {
                activeSheet = .add
            } label: {
                Image(systemName: "plus")
            }
        }
        // 【批3 B1】BYOK 首跑引导 gate（DeepSeekOnboardingDialog.tsx:99-124）：
        // 用户未确认过且无任何端点持有凭据 → credentialOnly 引导卡。出厂默认
        // DeepSeek 端点恒存在（EndpointStore init）→「无已配置 provider」口径
        // = 无凭据端点（gate 纯函数 EndpointStore.byokOnboardingNeeded）。
        .onAppear {
            if activeSheet == nil, EndpointStore.byokOnboardingNeeded(
                confirmed: byokOnboardingConfirmed,
                endpointsWithCredential: credentialCount) {
                activeSheet = .onboarding
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            // 任何 provider 表单路径收尾都落确认态（引导只在"从未配置过凭据"
            // 时自动弹；落确认后不再自动弹——dsh onboardingLater 结束引导语义）。
            byokOnboardingConfirmed = true
        }) { sheet in
            switch sheet {
            case .onboarding:
                EndpointEditSheet(store: store, endpoint: nil,
                                  credentialOnly: true,
                                  cancelLabel: "稍后配置",
                                  submitLabel: "保存")
            case .add:
                EndpointEditSheet(store: store, endpoint: nil)
            case .edit(let endpoint):
                EndpointEditSheet(store: store, endpoint: endpoint)
            }
        }
        // 【批3 B3】删除确认 Modal（两版描述——有凭证/无凭证；原行卡直删
        // 撤除）。
        .confirmationDialog("删除端点", isPresented: $showingDeleteDialog,
                            titleVisibility: .visible,
                            presenting: pendingDelete) { endpoint in
            Button("删除", role: .destructive) {
                deleteInFlight = true
                Task {
                    store.remove(endpoint)
                    deleteInFlight = false
                    pendingDelete = nil
                }
            }
            .disabled(deleteInFlight)
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: { endpoint in
            Text(ProvidersView.deleteMessage(for: endpoint,
                                             hasCredential: hasCredential(endpoint)))
        }
    }

    // MARK: - 【批3 B1/B2/B3】辅助

    /// 端点是否已持有凭据（Keychain/文件兜底任一通道非空——dsh 行卡状态点口径）。
    private func hasCredential(_ endpoint: EndpointConfig) -> Bool {
        guard let key = store.apiKey(for: endpoint) else { return false }
        return !key.isEmpty
    }

    private var credentialCount: Int {
        store.endpoints.filter(hasCredential).count
    }

    /// 删除确认两版描述（dsh 删除 Modal：有凭证版点明凭据一并清除；
    /// nonisolated static——单测直呼）。
    nonisolated static func deleteMessage(for endpoint: EndpointConfig,
                                          hasCredential: Bool) -> String {
        hasCredential
            ? "「\(endpoint.name)」已配置 API Key，删除将一并清除凭据，且无法恢复。"
            : "删除端点「\(endpoint.name)」？此操作无法恢复。"
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: EndpointConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                keyStatusDot(hasCredential(endpoint))
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
                Button("编辑") { activeSheet = .edit(endpoint) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("删除", role: .destructive) {
                    pendingDelete = endpoint
                    showingDeleteDialog = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
    }

    /// 【批3 B2】API 密钥状态点（实心=已配置 / 空心=缺失；dsh role title
    /// 语义 → 辅助功能标签）。
    @ViewBuilder
    private func keyStatusDot(_ present: Bool) -> some View {
        if present {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel("已配置 API Key")
        } else {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 8, height: 8)
                .accessibilityLabel("未配置 API Key")
        }
    }
}

/// 端点编辑表单（新增与编辑共用）。
/// 【批3 B1】credentialOnly：BYOK 首跑引导形态——仅凭据分节（端点三字段
/// 出厂默认预填，DeepSeekOnboardingDialog ProviderEditor credentialOnly +
/// credentialRequired + autoFocusCredential 语义）；取消/提交钮文案可换
/// （引导卡 = 「稍后配置」/「保存」——dsh cancelLabelKey onboardingLater +
/// submitLabelKey onboardingSave 词汇）。
struct EndpointEditSheet: View {
    @ObservedObject var store: EndpointStore
    let endpoint: EndpointConfig?
    var credentialOnly: Bool = false
    var cancelLabel: String = "取消"
    var submitLabel: String = "保存"

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
                // 【批3 B1】引导形态仅凭据（端点三字段已出厂预填，不呈现）。
                if !credentialOnly {
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
                } else {
                    Section {
                        Text("添加一个 API Key 开始使用。")
                            .font(.subheadline)
                    }
                }
                Section("凭据") {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            .navigationTitle(credentialOnly ? "开始使用"
                             : (endpoint == nil ? "新增端点" : "编辑端点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelLabel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel) { save() }
                        .disabled(name.isEmpty || baseURL.isEmpty || model.isEmpty)
                }
            }
            .onAppear(perform: loadInitial)
        }
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        if credentialOnly && endpoint == nil {
            // 【批3 B1】出厂默认预填（EndpointStore init 同源三字段——引导卡
            // 只收 Key，端点身份由默认值承载）。
            name = "DeepSeek"
            baseURL = "https://api.deepseek.com"
            model = "deepseek-v4-flash"
        }
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
        // 【批3 B4】API key 形校验（dsh apiKey.ts:12-58 四类裁剪——空=通过
        // 保留已存 / 纯空白=keyRequired / 环境变量行·引号包裹·非可打印 ASCII
        // =keyIllegalCharacters）。失败留在页面显示具体原因，不落盘。
        if !apiKey.isEmpty, let failure = EndpointStore.apiKeyFailure(apiKey) {
            credentialNotice = failure == "keyRequired"
                ? "API Key 不能为空白字符。"
                : "API Key 含非法字符：形如环境变量行（NAME=value）、引号包裹，或包含非可打印/非 ASCII 字符。"
            return
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
