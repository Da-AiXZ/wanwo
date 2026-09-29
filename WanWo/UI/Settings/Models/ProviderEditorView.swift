//
//  ProviderEditorView.swift
//  WanWo
//
//  【m8 批1 A2 · 照 dsh 语义翻译】单提供方编辑卡。
//  语义源：dsh ui-settings-models/src/client/ProviderEditor.tsx:158-516
//  ——主字段=只写 key 密码框（describe 已配置则占位"已配置——输入新值可替换"，
//  框恒空、值永不回显 :365-377）；「自定义设置」收起区（<details> →
//  DisclosureGroup + 展开/收起动画，平台增强）：baseURL、displayName、
//  模型目录编辑器；写入=只对卡内可见字段变更（最小变更语义，pathOps
//  :113-130 的万我等价=基线拷贝仅覆盖卡内字段）；保存走 EndpointStore
//  持久化。
//
//  平台适配（报告登记）：
//    · 万我单层 JSON 全量重写（settings-full-survey §6.2）→ path ops 由
//      "从加载基线复制、仅覆盖卡内可见字段"承载——isEnabled/thinking/
//      reasoningEffort/id 等卡外字段原样保留，语义等价（最小变更）。
//    · reasoning effort/thinking 不在 provider 卡（dsh 头注 :14-19 语义：
//      per-model 能力）——万我此前已由批3/T2.4 摘除，本卡不再出现。
//    · EndpointConfig.model（单模型请求字段）本卡不动：目录→请求生效需
//      A4 会话侧选择接线，静默改写请求模型=越权（报告详）。
//

import SwiftUI

/// UI↔存储凭据缝（dsh credentials wire 三方法 describe/set/unset 语义，
/// credentials.ts:84-129——CredentialInfo 永不含值）。
/// A1 CredentialStore 落地后由其实现替换缺省构造（Keychain + 文件兜底直绑）。
struct ProviderCredentialSeam {
    /// CredentialStore.describe 语义：仅状态布尔，永不回传值。
    var describe: (EndpointConfig) -> CredentialInfo
    /// CredentialStore.set：返回存储方式描述（UI 透出，ERR-016 语义）。
    var set: (EndpointConfig, String) throws -> String
    /// CredentialStore.unset：幂等删除。
    var unset: (EndpointConfig) throws -> Void
}

/// 单提供方编辑卡（dsh ProviderEditor.tsx:158-516 交互骨架 1:1）。
struct ProviderEditorView: View {

    // MARK: - 输入

    @ObservedObject var store: EndpointStore
    /// 编辑基线（加载快照；保存=基线拷贝仅覆盖卡内字段）。
    let endpoint: EndpointConfig
    /// 引导姿态：仅凭据字段与动作，无提供方设置（dsh credentialOnly）。
    var credentialOnly: Bool = false
    /// 隐藏卡标题行（添加卡自绘提供方选择时用——dsh hideTitle）。
    var hideTitle: Bool = false
    /// 新输入 key 是否必填（引导卡=必填——dsh credentialRequired）。
    var credentialRequired: Bool = false
    /// key 字段初始聚焦。
    var autoFocusKey: Bool = false
    var cancelLabel: String = "取消"
    var submitLabel: String = "应用"
    var submitBusyLabel: String = "应用中…"
    /// 凭据缝（describe/set；unset 由删除流经 section 使用）。
    var credentialSeam: ProviderCredentialSeam?
    /// 探测缝（原样下传目录编辑器；nil=探测入口不渲染）。
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    /// 关闭卡；`changed` 报告是否有一次提交落地。
    let onClose: (Bool) -> Void
    /// 保存成功后透出凭据存储描述（"Keychain + 文件双写"/兜底警告），
    /// 由 section 并入 saved 轻提示。
    var onCredentialNotice: ((String?) -> Void)?

    // MARK: - 状态

    /// 草稿：基线拷贝起笔（struct 值拷贝天然保留卡外字段）。
    @State private var draft = EndpointConfig(name: "", baseURL: "", model: "")
    /// 只写 key 草稿（框恒空起笔；保存成功后清空——值永不回显）。
    @State private var keyDraft = ""
    /// 凭据状态（describe 缝结果——占位符数据基础）。
    @State private var credential: CredentialInfo?
    @State private var busy = false
    @State private var failure: String?
    @State private var customExpanded = false
    /// 容量文本缓冲（父卡持有语义由目录编辑器约定——此处为宿主）。
    @State private var capacityBuffers: [String: String] = [:]
    @State private var loaded = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hideTitle {
                header
            }
            keyField
            if !credentialOnly {
                DisclosureGroup(isExpanded: expandedBinding) {
                    customizedBody
                        .padding(.top, 4)
                } label: {
                    Text("自定义设置")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.secondary)
                // 展开/收起动画（dsh <details> 的万我平台增强；Motion 纪律内）。
                .animation(WOMotion.standardSpring, value: customExpanded)
            }
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            footer
        }
        .padding(.vertical, 8)
        .onAppear(perform: loadInitial)
        .task { await describeKey() }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(get: { customExpanded }, set: { customExpanded = $0 })
    }

    // MARK: - 卡头（名称 + 路由）

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(draft.displayName ?? draft.name)
                .font(.subheadline.weight(.semibold))
            // 副行=端点地址（dsh 路由 id 副行 :485-487 的万我等价——
            // 无 route slug 面，以 baseURL 承载身份补足）。
            if !endpoint.baseURL.isEmpty {
                Text(endpoint.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - key 主字段（只写密码框，dsh :363-379）

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(keyPlaceholder, text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(disabled || keyLocked)
                .accessibilityLabel("API Key")
            if let keyFailure {
                Text(keyFailure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("留空则保留已保存的 Key。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 占位符：已配置→"已配置——输入新值可替换"；只读→环境提供；
    /// 否则"输入 API Key"（dsh keyPlaceholder :345-349 语义）。
    private var keyPlaceholder: String {
        if keyLocked { return "由启动环境提供（只读）" }
        if credential?.configured == true && !credentialRequired {
            return "已配置——输入新值可替换"
        }
        return credentialRequired ? "输入 API Key 开始使用" : "输入 API Key"
    }

    /// describe 拒写（writable=false）→ key 框锁死（dsh keyLocked :316）。
    private var keyLocked: Bool {
        credential?.writable == false
    }

    private var disabled: Bool { busy }

    // MARK: - 自定义设置收起区（dsh curatedFields :335-476）

    private var customizedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(label: "显示名") {
                TextField("显示名", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("显示名")
            }
            field(label: "Base URL") {
                TextField(baseURLPlaceholder, text: baseURLBinding)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Base URL")
            }
            ModelCatalogEditorView(
                models: draft.models ?? [],
                overridden: draft.models != nil,
                defaultContextWindow: draft.defaultContextWindow,
                defaultMaxTokens: draft.defaultMaxTokens,
                disabled: disabled,
                discoverModels: discoverModels,
                probeBaseURL: draft.baseURL.isEmpty ? endpoint.baseURL : draft.baseURL,
                probeAPIKey: keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                onChange: { next in draft.models = next },
                onReset: { draft.models = nil; capacityBuffers.removeAll() },
                capacityBuffers: $capacityBuffers)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.displayName ?? draft.name },
            set: {
                // 显示名编辑即 name（万我单层名；契约 displayName 消费点=
                // 行头显示 draft.displayName ?? name，本卡保持其 nil=继承）。
                draft.name = $0
                draft.displayName = nil
            })
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { draft.baseURL },
            set: { draft.baseURL = $0 })
    }

    /// baseURL 占位：出厂公开端点语义（dsh DEEPSEEK_PUBLIC_BASE_URL :46）。
    private var baseURLPlaceholder: String {
        "https://api.deepseek.com"
    }

    private func field<Content: View>(label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - 动作行（dsh EditorFooter：左取消右提交）

    private var footer: some View {
        HStack {
            Button(cancelLabel) {
                onClose(false)
            }
            .frame(minHeight: 44)
            .disabled(busy)
            Spacer()
            Button {
                Task { await apply() }
            } label: {
                Text(busy ? submitBusyLabel : submitLabel)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(submitDisabled)
        }
    }

    /// 提交门（dsh :504-507 同构）：key 形校验 + 目录行级校验 + 不可读容量。
    private var submitDisabled: Bool {
        if disabled || keyFailure != nil { return true }
        if credentialRequired && keyValue.isEmpty { return true }
        if !credentialOnly {
            if let failure = ModelCatalogValidation.validate(draft.models) { return true }
            if unreadableCapacity != nil { return true }
        }
        return false
    }

    /// key 形校验（EndpointStore.apiKeyFailure——dsh apiKey.ts 裁剪既有面）。
    private var keyFailure: String? {
        guard !keyDraft.isEmpty,
              let key = EndpointStore.apiKeyFailure(keyDraft) else { return nil }
        switch key {
        case "keyRequired": return "API Key 不能为空白字符。"
        default: return "API Key 格式无效：形如环境变量行（NAME=value）、引号包裹，或含非可打印字符。"
        }
    }

    /// 已去空白 key（dsh keyValue :222——空白粘贴剔除）。
    private var keyValue: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 第一个不可读容量缓冲（NaN 在屏保留、保存按行报错——dsh :94-123 +
    /// ModelListEditor :169-175 注释语义；Int? 容量无法编码 NaN 的平台适配）。
    private var unreadableCapacity: (index: Int, field: String)? {
        for (key, text) in capacityBuffers {
            guard let parsed = CapacityFormatting.parseCapacity(text), parsed.isNaN,
                  let dot = key.firstIndex(of: ":"),
                  let row = Int(key[key.startIndex..<dot]) else { continue }
            let field = String(key[key.index(after: dot)...])
            return (row, field)
        }
        return nil
    }

    // MARK: - 保存（dsh applyOnce :247-293 最小变更语义）

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        // 基线拷贝起笔：卡外字段（isEnabled/thinking/reasoningEffort/id/model）
        // 原样保留，保存仅覆盖卡内可见字段（pathOps :113-130 最小变更等价）。
        draft = endpoint
    }

    private func describeKey() async {
        guard let seam = credentialSeam else { return }
        // describe 是占位提示而非编辑前置（dsh :187-197——拒绝只丢提示）。
        let described = seam.describe(endpoint)
        credential = described
    }

    private func apply() async {
        busy = true
        failure = nil
        defer { busy = false }
        // ① 目录行级校验（提交门的同源重查——dsh :259-264）。
        if !credentialOnly {
            if let failure = ModelCatalogValidation.validate(draft.models) {
                self.failure = "模型 \(failure.index + 1)：\(Self.validationText(failure.key))"
                return
            }
            if let bad = unreadableCapacity {
                let label = bad.field == "contextWindow" ? "上下文窗口" : "最大输出"
                self.failure = "模型 \(bad.index + 1)：\(label)须为正数，如 131072、256K、1M。"
                return
            }
            // 触屏路径 id 归一（目录编辑器 onSubmit 近似的兜底；validate 同源）。
            draft.models = draft.models?.map { model in
                var copy = model
                copy.id = copy.id.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
        }
        // ② 配置写（最小变更：基线拷贝仅覆盖卡内可见字段）。
        var next = draft
        let normalizedBase = next.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.baseURL = normalizedBase.hasSuffix("/") ? String(normalizedBase.dropLast()) : normalizedBase
        if !credentialOnly {
            store.update(next)
        } else {
            // 引导姿态只收凭据：配置三字段为出厂预填，无需落写。
        }
        draft = next
        // ③ 凭据写（key 非空才写——恒空框=保留已存，dsh :287-291）。
        if !keyValue.isEmpty {
            let seam = credentialSeam
            do {
                if let seam {
                    let notice = try seam.set(next, keyValue)
                    onCredentialNotice?(notice)
                }
            } catch {
                failure = "Key 保存失败：\((error as NSError).localizedDescription)"
                return
            }
        }
        keyDraft = ""
        onClose(true)
    }

    private static func validationText(_ key: ModelCatalogValidation.Key) -> String {
        switch key {
        case .modelIdRequired: return "模型 ID 必填。"
        case .modelIdDuplicate: return "模型 ID 必须唯一。"
        case .modelNameInvalid: return "显示名不能为空。"
        case .modelContextInvalid: return "上下文窗口须为正数，如 131072、256K、1M。"
        case .modelMaxTokensInvalid: return "最大输出须为正数，如 8192、64K、1M。"
        }
    }
}
