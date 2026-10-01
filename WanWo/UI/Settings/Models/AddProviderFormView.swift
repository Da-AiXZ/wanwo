//
//  AddProviderFormView.swift
//  WanWo
//
//  【m7-fix2 · E2 · 按用户 HTML 原型 1:1】「＋ 添加模型提供商」展开表单卡
//  （原型 .form-card，:970-1143 + :1677-1751）。
//  原型锚点：
//    · 表单卡 #fafafb 圆角18、pad 18/20/20（:316-322）；
//    · 两 tab（「第三方模型提供商」/「自定义模型 API」）：active=白底描边
//      +阴影 0 1 3 .07（:324-349）；面板切换=高度过渡（:351-356，本实现以
//      WOCollapsible 承载——两面板常挂、状态跨 tab 保留）；
//    · tab1：hint + 提供商自定义下拉 + API 密钥（password，占位「输入
//      API 密钥，或留空使用环境认证」）+「自定义设置」折叠区（API 地址+
//      模型目录）；
//    · tab2：hint + Provider ID（sub-hint 小写开头提示）+显示名称+API 地址
//      +API 协议下拉（三选项）+API 密钥+模型目录；
//    · 底部 form-actions：取消 ghost / 保存 primary（custom tab 保存钮文案
//      「创建提供商」——原型 switchTab :1726）。
//
//  数据面缺口（只登记不擅改，报告详）：
//    · 万我无 provider 目录数据面——tab1 预置下拉以 UI 静态表承载
//      （仅 OpenAI 兼容端点子集；选预置=预填 baseURL）；
//    · EndpointConfig 无「API 协议」字段——tab2 协议下拉仅 UI 展示不落盘
//      （万我唯一通道 OpenAI Chat Completions）。
//  校验/创建语义：沿用批1 CustomProviderCardView 的 route slug 正则、
//  baseURL 前缀校验、committed 两步语义（配置落地后 key 重试不再 add）。
//
//  iOS 16.6 红线自查：无 foregroundStyle、无双参 onChange、无 iOS17+ API。
//

import SwiftUI

/// 「＋ 添加模型提供商」表单卡（原型 .form-card 1:1）。
struct AddProviderFormView: View {

    // MARK: - 输入

    @ObservedObject var store: EndpointStore
    var credentialSeam: ProviderCredentialSeam?
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    /// 关闭表单；`changed` 报告是否已创建。
    let onClose: (Bool) -> Void
    /// 凭据存储描述透传（同 ProviderEditorView）。
    var onCredentialNotice: ((String?) -> Void)?

    // MARK: - 预置表（m7-fix2 M6①：UI 静态表下沉数据面 ProviderCatalog）

    /// 预置提供商（ProviderCatalog.presets 透传——每预置带 baseUrl + 内置
    /// 模型 id 表，dsh catalog.ts:186-190/:799-800 语义；候选只读）。
    static var presets: [ProviderCatalogPreset] { ProviderCatalog.presets }

    private static let apiProtocols = [
        "OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages",
    ]

    private static let routePattern = try! NSRegularExpression(
        pattern: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#)

    // MARK: - 状态

    enum Tab: Equatable { case preset, custom }
    @State private var activeTab: Tab = .preset

    // tab1（第三方模型提供商）
    @State private var presetID = Self.presets.first?.id ?? "openai"
    @State private var presetKey = ""
    @State private var presetAdvOpen = false
    @State private var presetBaseURL = "" // 「自定义设置」API 地址 override
    @State private var presetModels: [ModelCatalogEntry] = []
    @State private var presetBuffers: [String: String] = [:]

    // tab2（自定义模型 API）
    @State private var routeID = ""
    @State private var customName = ""
    @State private var customBaseURL = ""
    @State private var customProtocol = Self.apiProtocols[0]
    @State private var customKey = ""
    @State private var customModels: [ModelCatalogEntry] = []
    @State private var customBuffers: [String: String] = [:]

    @State private var busy = false
    @State private var failure: String?
    /// 配置已落地（key 写失败重试只走凭据，不再重建配置——dsh committed 语义）。
    @State private var committed = false
    @State private var createdEndpoint: EndpointConfig?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabsRow
                .padding(.bottom, 16)

            // 面板高度过渡：两面板常挂 WOCollapsible（原型 .tab-panels
            // height .5s 的等价承载；状态跨 tab 保留）。
            WOCollapsible(open: activeTab == .preset) { presetPanel }
            WOCollapsible(open: activeTab == .custom) { customPanel }

            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundColor(WOMP.red)
                    .padding(.top, 10)
            }

            // form-actions（底部右对齐）。
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                WOProtoButton(title: "取消", kind: .ghost) { onClose(committed) }
                    .disabled(busy)
                WOProtoButton(title: activeTab == .custom ? "创建提供商" : "保存",
                              kind: .primary) {
                    Task { await save() }
                }
                .disabled(busy || !ready)
            }
            .padding(.top, 20)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20)) // 原型 pad 18/20/20
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(WOMP.formCardBg))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(WOMP.lineSoft, lineWidth: 1))
        .padding(.top, 14) // 原型 .form-card margin-top 14
        // m7-fix2 M7（preset→baseURL 预填，dsh 语义）：选中预置即把预置 URL
        // 显进「自定义设置·API 地址」字段——用户可改（改后即自定义覆盖）；
        // :224 生效值合成逻辑原样保留（字段清空仍回落预置表）。
        .onAppear {
            if presetBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                presetBaseURL = Self.presets.first(where: { $0.id == presetID })?.baseURL ?? ""
            }
        }
        .onChange(of: presetID) { newValue in
            // 切换预置 = 换默认地址（iOS16 单参 onChange；红线自查）。
            presetBaseURL = Self.presets.first(where: { $0.id == newValue })?.baseURL ?? ""
        }
    }

    // MARK: Tabs（原型 :324-349：active=白底描边+阴影）

    private var tabsRow: some View {
        HStack(spacing: 6) {
            tabButton("第三方模型提供商", tab: .preset)
            tabButton("自定义模型 API", tab: .custom)
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ title: String, tab: Tab) -> some View {
        let isActive = activeTab == tab
        return Button {
            withAnimation(WOMP.ease(0.5)) { activeTab = tab }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(isActive ? WOMP.text : WOMP.text2)
                .padding(.horizontal, 16)
                .frame(minHeight: 44) // 触屏命中（原型 8px pad 视觉由内层撑）
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.white : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? WOMP.line : Color.clear, lineWidth: 1))
                .shadow(color: isActive ? Color.black.opacity(0.07) : .clear,
                        radius: 3, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: tab1 面板（第三方模型提供商）

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("从内置目录中选择 OpenAI、Anthropic、Kimi 等提供商，填入其 API 密钥即可使用。")
                .font(.system(size: 12.8))
                .foregroundColor(WOMP.text2)
                .lineSpacing(4)
                .padding(.bottom, 2)

            WOProtoField("提供商") {
                WOSelect(options: Self.presets.map(\.id), selection: $presetID)
            }

            WOProtoField("API 密钥") {
                WOProtoInput(placeholder: "输入 API 密钥，或留空使用环境认证",
                             text: $presetKey, secure: true)
                    .disabled(busy)
            }

            WOSectionToggle(title: "自定义设置", open: $presetAdvOpen)
                .padding(.top, 4)

            WOCollapsible(open: presetAdvOpen) {
                VStack(alignment: .leading, spacing: 16) {
                    WOProtoField("API 地址") {
                        WOProtoInput(placeholder: "提供商默认", text: $presetBaseURL)
                            .keyboardType(.URL)
                    }
                    ModelCatalogEditorView(
                        models: presetModels,
                        overridden: true,
                        defaultContextWindow: nil,
                        defaultMaxTokens: nil,
                        disabled: busy,
                        discoverModels: discoverModels,
                        probeBaseURL: effectivePresetBaseURL.isEmpty ? nil : effectivePresetBaseURL,
                        probeAPIKey: presetKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty ? nil : presetKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        onChange: { next in presetModels = next },
                        onReset: { presetModels = []; presetBuffers.removeAll() },
                        capacityBuffers: $presetBuffers)
                }
                .padding(.top, 6)
            }
        }
    }

    /// 生效 baseURL：字段值（M7 预填后字段恒非空；用户可改=自定义覆盖语义
    /// 不变——字段即「自定义设置覆盖 > 预置表」合成的显式形态；字段清空仍
    /// 回落预置表，尾斜杠剥离）。
    private var effectivePresetBaseURL: String {
        let custom = presetBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = custom.isEmpty ? (Self.presets.first(where: { $0.id == presetID })?.baseURL ?? "") : custom
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: tab2 面板（自定义模型 API）

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接中转站、自部署服务或其他兼容 OpenAI / Anthropic 协议的接口，需填写 API 地址、协议和模型。")
                .font(.system(size: 12.8))
                .foregroundColor(WOMP.text2)
                .lineSpacing(4)
                .padding(.bottom, 2)

            WOProtoField("Provider ID") {
                VStack(alignment: .leading, spacing: 0) {
                    WOProtoInput(placeholder: "acme-gateway", text: $routeID)
                        .disabled(profileDisabled)
                    if routeInvalid || routeTaken {
                        Text(routeInvalid
                             ? "以小写字母开头；其后为小写字母、数字和连字符。"
                             : "已有提供方使用此 ID。")
                            .font(.system(size: 12))
                            .foregroundColor(WOMP.red)
                            .padding(.top, 8)
                    } else {
                        Text("以小写字母开头的标识，在请求中唯一标识该提供商，并用于派生凭据名。")
                            .font(.system(size: 12))
                            .foregroundColor(WOMP.text3)
                            .lineSpacing(3)
                            .padding(.top, 8)
                    }
                }
            }

            WOProtoField("显示名称") {
                WOProtoInput(placeholder: "显示名称", text: $customName)
                    .disabled(profileDisabled)
            }

            WOProtoField("API 地址") {
                WOProtoInput(placeholder: "https://gateway.example/v1", text: $customBaseURL)
                    .keyboardType(.URL)
                    .disabled(profileDisabled)
            }

            WOProtoField("API 协议") {
                WOSelect(options: Self.apiProtocols, selection: $customProtocol)
                    .disabled(profileDisabled)
            }

            WOProtoField("API 密钥") {
                WOProtoInput(placeholder: "输入 API 密钥", text: $customKey, secure: true)
                    .disabled(busy)
            }

            ModelCatalogEditorView(
                models: customModels,
                overridden: true,
                defaultContextWindow: nil,
                defaultMaxTokens: nil,
                disabled: profileDisabled,
                discoverModels: discoverModels,
                probeBaseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? nil : customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                probeAPIKey: customKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? nil : customKey.trimmingCharacters(in: .whitespacesAndNewlines),
                onChange: { next in customModels = next },
                onReset: { customModels = []; customBuffers.removeAll() },
                capacityBuffers: $customBuffers)
        }
    }

    // MARK: - 校验（批1 语义原样迁移）

    private var routeInvalid: Bool {
        !routeID.isEmpty
            && Self.routePattern.firstMatch(in: routeID,
                                            range: NSRange(routeID.startIndex..., in: routeID)) == nil
    }

    private var routeTaken: Bool {
        store.endpoints.contains { $0.name.lowercased() == routeID.lowercased() }
    }

    private var baseURLInvalid: Bool {
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !(trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"))
    }

    private var keyFailure: String? {
        let draft = activeTab == .preset ? presetKey : customKey
        guard !draft.isEmpty, let key = EndpointStore.apiKeyFailure(draft) else { return nil }
        return key == "keyRequired"
            ? "API 密钥不能为空白字符。"
            : "API 密钥格式无效：形如环境变量行（NAME=value）、引号包裹，或含非可打印字符。"
    }

    /// 不可读容量（两 tab 共用同一保存门）。
    private var unreadableCapacity: Bool {
        let buffers = activeTab == .preset ? presetBuffers : customBuffers
        return buffers.contains { _, text in
            CapacityFormatting.parseCapacity(text)?.isNaN == true
        }
    }

    /// 空模态行。
    private var hasEmptyModality: Bool {
        let models = activeTab == .preset ? presetModels : customModels
        return models.contains { ($0.inputModalities ?? ["text"]).isEmpty }
    }

    /// 就绪门（activeTab 各自口径）。
    private var ready: Bool {
        guard keyFailure == nil, !unreadableCapacity, !hasEmptyModality else { return false }
        if activeTab == .preset {
            if let failure = ModelCatalogValidation.validate(presetModels) { return false }
            return !presetModels.isEmpty
        }
        if committed { return false }
        return !routeID.isEmpty && !routeInvalid && !routeTaken
            && !baseURLInvalid && !customModels.isEmpty
            && ModelCatalogValidation.validate(customModels) == nil
    }

    /// 配置字段在创建落地后停用（dsh profileDisabled 语义）。
    private var profileDisabled: Bool { busy || committed }

    // MARK: - 保存（preset=保存 / custom=创建提供商；两步 committed 语义）

    private func save() async {
        busy = true
        failure = nil
        defer { busy = false }

        // 目录校验（activeTab 同源重查）。
        let models = activeTab == .preset ? presetModels : customModels
        if let failure = ModelCatalogValidation.validate(models) {
            self.failure = "模型 \(failure.index + 1)：\(validationText(failure.key))"
            return
        }

        if activeTab == .preset {
            await savePreset()
        } else {
            await saveCustom()
        }
    }

    private func savePreset() async {
        guard !committed else { return }
        guard let preset = Self.presets.first(where: { $0.id == presetID }) else {
            failure = "请选择提供商。"
            return
        }
        guard !presetModels.isEmpty else {
            failure = "请至少添加一个模型（可用「获取可用模型」拉取）。"
            return
        }
        // 创建（模型三字段：name=预置 id、baseURL=生效值、model=首个目录项）。
        let endpoint = EndpointConfig(
            name: preset.id,
            baseURL: effectivePresetBaseURL,
            model: presetModels.first(where: { !$0.id.isEmpty })?.id ?? "",
            models: presetModels)
        store.add(endpoint)
        createdEndpoint = endpoint
        committed = true
        // 凭据写（key 非空才写；失败保留表单重试——只剩凭据一步）。
        if await writeKeyIfNeeded() { onClose(true) }
    }

    private func saveCustom() async {
        guard !committed else { return }
        // 创建（name=displayName 空则 id；models 必填）。
        let endpoint = EndpointConfig(
            name: customName.isEmpty ? routeID : customName,
            baseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: customModels.first(where: { !$0.id.isEmpty })?.id ?? "",
            models: customModels)
        store.add(endpoint)
        createdEndpoint = endpoint
        committed = true
        if await writeKeyIfNeeded() { onClose(true) }
    }

    /// key 落存（非空才写；失败置 failure 返回 false 供重试——重试路径只剩
    /// 凭据一步，不再走 add）。
    private func writeKeyIfNeeded() async -> Bool {
        let key = (activeTab == .preset ? presetKey : customKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let seam = credentialSeam, let created = createdEndpoint else {
            return true
        }
        do {
            let notice = try seam.set(created, key)
            onCredentialNotice?(notice)
            return true
        } catch {
            failure = "密钥保存失败：\((error as NSError).localizedDescription)"
            return false
        }
    }

    private func validationText(_ key: ModelCatalogValidation.Key) -> String {
        switch key {
        case .modelIdRequired: return "模型 ID 必填。"
        case .modelIdDuplicate: return "模型 ID 必须唯一。"
        case .modelNameInvalid: return "显示名不能为空。"
        case .modelContextInvalid: return "上下文窗口须为正数，如 131072、256K、1M。"
        case .modelMaxTokensInvalid: return "最大输出须为正数，如 8192、64K、1M。"
        }
    }
}
