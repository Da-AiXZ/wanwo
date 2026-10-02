//
//  ProviderEditorView.swift
//  WanWo
//
//  【m7-fix2 · E2 · 按用户 HTML 原型 1:1 重做】provider 行卡内联编辑面板
//  （原型 .edit-panel）。原型锚点（设置模型配置原型（带动画）.html）：
//    · 面板 #f5f5f7 圆角14，margin 0 10 10、pad 16/16/14（:238-244）；
//    · edit-title 14px semibold（:246-251）；
//    · 字段组=API 密钥（password，已配置占位「已配置 —— 输入新值可替换」，
//      框恒空、值永不回显 :1571-1575）；
//    · 「自定义设置」section-toggle（chev rotate 90° .42s :1577-1583）→
//      折叠区（API 地址 + 模型目录 field :1585-1615）；
//    · edit-actions 右对齐：取消 ghost / 保存 primary 黑底（:1617-1620）。
//
//  语义保留（批1 dsh 翻译件的最小变更/只写凭据/校验门——原型无语义冲突处
//  原样沿用）：
//    · 草稿=基线拷贝起笔，保存仅覆盖卡内可见字段（最小变更）；
//    · key 只写（保存成功后清空；describe 占位提示，拒绝只丢提示）；
//    · 保存门=目录行级校验 + 不可读容量 + 输入类型空勾；失败行内红字、
//      输入文本不丢。
//  平台适配（报告登记）：保存失败红行（.model-err 形态的行内错误）为原型
//  未画的必要报错位（原型 JS 无保存失败路径）。
//
//  iOS 16.6 红线自查：无 foregroundStyle、无双参 onChange、无 iOS17+ API。
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

/// 单提供方内联编辑面板（原型 .edit-panel 交互骨架 1:1）。
struct ProviderEditorView: View {

    // MARK: - 输入

    @ObservedObject var store: EndpointStore
    /// 编辑基线（加载快照；保存=基线拷贝仅覆盖卡内字段）。
    let endpoint: EndpointConfig
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
        VStack(alignment: .leading, spacing: 0) {
            // edit-title（原型 14px semibold，下距 15）。
            Text(draft.displayName ?? draft.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(WOMP.text)
                .padding(.bottom, 15)

            keyField

            if !credentialOnlyMode {
                WOSectionToggle(title: "自定义设置", open: $customExpanded)
                    .padding(.top, 4)

                WOCollapsible(open: customExpanded) {
                    VStack(alignment: .leading, spacing: 15) {
                        WOProtoField("API 地址") {
                            WOProtoInput(placeholder: "提供商默认", text: baseURLBinding)
                                .keyboardType(.URL)
                        }
                        ModelCatalogEditorView(
                            models: draft.models ?? [],
                            overridden: draft.models != nil,
                            defaultContextWindow: draft.defaultContextWindow,
                            defaultMaxTokens: draft.defaultMaxTokens,
                            disabled: busy,
                            discoverModels: discoverModels,
                            probeBaseURL: probeBaseURL,
                            probeAPIKey: probeAPIKey,
                            onChange: { next in draft.models = next },
                            onReset: { draft.models = nil; capacityBuffers.removeAll() },
                            capacityBuffers: $capacityBuffers)
                    }
                    .padding(.top, 6) // 原型 #advSettings content padding-top 6
                }
                .padding(.top, 10)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundColor(WOMP.red)
                    .padding(.top, 10)
            }

            // edit-actions（右对齐：取消 ghost / 保存 primary）。
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                WOProtoButton(title: "取消", kind: .ghost) { cancelEdits() }
                    .disabled(busy)
                WOProtoButton(title: "保存", kind: .primary) {
                    Task { await apply() }
                }
                .disabled(busy || submitBlocked)
            }
            .padding(.top, 16)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16)) // 原型 pad 16/16/14
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(WOMP.editPanelBg))
        .onAppear(perform: loadInitial)
        .task { await describeKey() }
    }

    // MARK: - 字段

    /// API 密钥（只写密码框；占位按 describe 态——原型 :1571-1575 + dsh :345-349）。
    private var keyField: some View {
        WOProtoField("API 密钥") {
            VStack(alignment: .leading, spacing: 6) {
                WOProtoInput(placeholder: keyPlaceholder, text: $keyDraft, secure: true)
                    .disabled(busy || keyLocked)
                if let keyFailure {
                    Text(keyFailure)
                        .font(.system(size: 12.5))
                        .foregroundColor(WOMP.red)
                }
            }
        }
    }

    /// 占位符：已配置→「已配置 —— 输入新值可替换」；只读→环境提供；
    /// 否则「输入 API 密钥」。
    private var keyPlaceholder: String {
        if keyLocked { return "由启动环境提供（只读）" }
        if credential?.configured == true { return "已配置 —— 输入新值可替换" }
        return "输入 API 密钥，或留空使用环境认证"
    }

    /// describe 拒写（writable=false）→ key 框锁死。
    private var keyLocked: Bool { credential?.writable == false }

    // MARK: - 绑定

    private var baseURLBinding: Binding<String> {
        Binding(get: { draft.baseURL }, set: { draft.baseURL = $0 })
    }

    // MARK: - 探测缝参数（表单当前值语义）

    private var probeBaseURL: String? {
        draft.baseURL.isEmpty ? endpoint.baseURL : draft.baseURL
    }

    private var probeAPIKey: String? {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // m7-fix2 M1②（IMG_2516 根因②）：dsh ModelListEditor.tsx:8-10「表单
        // 当前值优先」——但「已配置——输入新值可替换」态的框恒空，此前空字段
        // 直传 nil → 匿名探测 → 401 必败。修 = 输入值非空 ? 输入值 : 已存
        // key（EndpointStore.apiKey 只读；nil = 从未配置 → 匿名探测仍成立，
        // dsh discovery.ts:244-246 语义不变）。
        if !trimmed.isEmpty { return trimmed }
        return store.apiKey(for: endpoint)
    }

    // MARK: - 保存门（dsh :504-507 同构 + 输入类型空勾门）

    /// 引导姿态已随原型重做退役（原型行卡编辑面板即唯一配置路径——报告登记）。
    private var credentialOnlyMode: Bool { false }

    private var keyFailure: String? {
        guard !keyDraft.isEmpty,
              let key = EndpointStore.apiKeyFailure(keyDraft) else { return nil }
        switch key {
        case "keyRequired": return "API 密钥不能为空白字符。"
        default: return "API 密钥格式无效：形如环境变量行（NAME=value）、引号包裹，或含非可打印字符。"
        }
    }

    /// 第一个不可读容量缓冲（NaN 在屏保留、保存按行报错；Int? 容量无法编码
    /// NaN 的平台适配——批1 语义原样）。
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

    /// 输入类型空勾行（数据面 MODEL_MODALITIES_EMPTY 的 UI 闸）。
    private var emptyModalityRow: Int? {
        draft.models?.firstIndex { model in
            (model.inputModalities ?? ["text"]).isEmpty
        }
    }

    private var submitBlocked: Bool {
        if keyFailure != nil { return true }
        if let failure = ModelCatalogValidation.validate(draft.models) { return true }
        if unreadableCapacity != nil { return true }
        if emptyModalityRow != nil { return true }
        return false
    }

    // MARK: - 保存（dsh applyOnce :247-293 最小变更语义）

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        // 基线拷贝起笔：卡外字段（isEnabled/thinking/reasoningEffort/id/model）
        // 原样保留，保存仅覆盖卡内可见字段（最小变更等价）。
        draft = endpoint
    }

    private func describeKey() async {
        guard let seam = credentialSeam else { return }
        // describe 是占位提示而非编辑前置（拒绝只丢提示）。
        credential = seam.describe(endpoint)
    }

    /// 取消 = 放弃编辑并收起（m7-fix2 M3②；原型 closeEditPanel :1644-1648
    /// 语义：取消/保存同一收起路径）。未保存草稿整组丢弃：草稿回基线、
    /// key 草稿/容量缓冲/折叠态/报错清零（面板常挂 WOCollapsible，@State
    /// 不随收起销毁——必须显式复位，否则重开会见残稿）。
    private func cancelEdits() {
        draft = endpoint
        keyDraft = ""
        capacityBuffers.removeAll()
        // 批6 审查 P2-1：显式动画事务（WOCollapsible 动画作用域重构后
        // 不再依赖隐式兜底——取消时自定义设置段展开态同曲线收合）。
        withAnimation(WOMP.ease(WOMP.durCollapse)) {
            customExpanded = false
        }
        failure = nil
        onClose(false)
    }

    private func apply() async {
        busy = true
        failure = nil
        defer { busy = false }
        // ① 目录行级校验（提交门的同源重查）。
        if let validationFailure = ModelCatalogValidation.validate(draft.models) {
            failure = "模型 \(validationFailure.index + 1)：\(Self.validationText(validationFailure.key))"
            return
        }
        if let bad = unreadableCapacity {
            let label = bad.field == "contextWindow" ? "上下文窗口" : "最大输出"
            failure = "模型 \(bad.index + 1)：\(label)须为正数，如 131072、256K、1M。"
            return
        }
        if let emptyRow = emptyModalityRow {
            failure = "模型 \(emptyRow + 1)：输入类型至少勾选一项（文本/图片）。"
            return
        }
        // 触屏路径 id 归一（onSubmit 近似的兜底；validate 同源）。
        draft.models = draft.models?.map { model in
            var copy = model
            copy.id = copy.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        // ② 配置写（最小变更：基线拷贝仅覆盖卡内可见字段）。
        var next = draft
        let normalizedBase = next.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.baseURL = normalizedBase.hasSuffix("/")
            ? String(normalizedBase.dropLast()) : normalizedBase
        store.update(next)
        draft = next
        // ③ 凭据写（key 非空才写——恒空框=保留已存）。
        let keyValue = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyValue.isEmpty, let seam = credentialSeam {
            do {
                let notice = try seam.set(next, keyValue)
                onCredentialNotice?(notice)
            } catch {
                failure = "密钥保存失败：\((error as NSError).localizedDescription)"
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
