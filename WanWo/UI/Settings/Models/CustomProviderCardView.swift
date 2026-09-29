//
//  CustomProviderCardView.swift
//  WanWo
//
//  【m8 批1 A2 · 照 dsh 语义翻译】手声明新提供方卡（创建而非编辑）。
//  语义源：dsh ui-settings-models/src/client/CustomProviderCard.tsx:87-266
//  ——route id（小写 slug 正则 :48）/displayName/baseURL/key/模型目录；
//  三必填（:13 语义：万我无 protocol 面 → id、baseURL、至少一个模型）；
//  采纳同款行级校验器；提交门 hint 只说下一个未满足的闸（:110-129）。
//
//  平台适配（报告登记）：
//    · 万我端点标识=UUID，无 route slug 持久面：id 输入承担 dsh 的唯一性
//      校验与凭证名派生语义（对既有端点名做大小写不敏感唯一检查），
//      保存时 name = displayName（空则 id）。
//    · 新端点 model（单模型请求字段）= 首个非空模型 id：创建时用户刚声明
//      的目录首行即其请求意图，A4 会话选择接线前的过渡语义。
//    · baseURL 增加 http/https 前缀校验（dsh 占位符 https://… 的显式化）。
//

import SwiftUI

/// 手声明新提供方卡（dsh CustomProviderCard.tsx:87-266 交互骨架 1:1）。
struct CustomProviderCardView: View {

    // MARK: - 输入

    @ObservedObject var store: EndpointStore
    /// 已占用标识（既有端点名，大小写不敏感比对——dsh taken :53）。
    let taken: [String]
    /// 凭据缝（key 落存）。
    var credentialSeam: ProviderCredentialSeam?
    /// 探测缝（下传目录编辑器）。
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    /// 关闭卡；`changed` 报告是否已创建。
    let onClose: (Bool) -> Void
    /// 凭据存储描述透传（同 ProviderEditorView）。
    var onCredentialNotice: ((String?) -> Void)?

    // MARK: - 状态

    /// 路由 id 草稿（小写 slug——dsh ROUTE_PATTERN :48）。
    @State private var routeID = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var keyDraft = ""
    @State private var models: [ModelCatalogEntry] = []
    @State private var capacityBuffers: [String: String] = [:]
    @State private var busy = false
    @State private var failure: String?
    /// 配置已落地（key 写失败重试只走凭据，不再重建配置——dsh committed :94）。
    @State private var committed = false
    /// 已创建的端点实例（重试路径凭据绑定同一 UUID）。
    @State private var createdEndpoint: EndpointConfig?

    // MARK: - 校验（dsh :99-129 语义）

    private static let routePattern = try! NSRegularExpression(
        pattern: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#)

    private var routeInvalid: Bool {
        !routeID.isEmpty
            && Self.routePattern.firstMatch(in: routeID,
                                            range: NSRange(routeID.startIndex..., in: routeID)) == nil
    }

    private var routeTaken: Bool {
        taken.contains { $0.lowercased() == routeID.lowercased() }
    }

    private var baseURLInvalid: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !(trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"))
    }

    /// key 形校验（空=通过——可走提供方自身鉴权的合法留空，dsh :106-109）。
    private var keyFailure: String? {
        guard !keyDraft.isEmpty,
              let key = EndpointStore.apiKeyFailure(keyDraft) else { return nil }
        return key == "keyRequired"
            ? "输入 API Key；若此提供方无需密钥可留空。"
            : "API Key 格式无效：形如环境变量行（NAME=value）、引号包裹，或含非可打印字符。"
    }

    private var modelFailure: ModelCatalogValidation.Failure? {
        ModelCatalogValidation.validate(models)
    }

    private var keyValue: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 就绪门（dsh ready :110-112）：id 合法未占用 + baseURL 合法 + ≥1 模型
    /// + 行级校验过 + key 校验过。
    private var ready: Bool {
        !routeID.isEmpty && !routeInvalid && !routeTaken
            && !baseURL.isEmpty && !baseURLInvalid
            && !models.isEmpty && modelFailure == nil
            && keyFailure == nil
    }

    /// 唯一值得一行话的阻塞闸（dsh hint :115-129——已就绪/凭据/id 各有
    /// 自身行时不重复发声）。
    private var hint: String? {
        if failure != nil || ready || keyFailure != nil
            || routeID.isEmpty || routeInvalid || routeTaken {
            return nil
        }
        if baseURL.isEmpty { return "自定义提供方需要 Base URL。" }
        if baseURLInvalid { return "Base URL 须以 http:// 或 https:// 开头。" }
        if let failure = modelFailure {
            return "模型 \(failure.index + 1)：\(validationText(failure.key))"
        }
        return "自定义提供方需要至少一个模型。"
    }

    // MARK: - Body

    /// 表单字段壳（label + content 纵排——ProviderEditorView.field 同款；
    /// 本文件独立私有副本，private 不跨文件共享）。
    private func field<Content: View>(label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义提供方")
                .font(.subheadline.weight(.semibold))
            field(label: "提供方 ID") {
                TextField("acme-gateway", text: $routeID,
                          prompt: Text("acme-gateway").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(profileDisabled)
                    .accessibilityLabel("提供方 ID")
            }
            if routeInvalid || routeTaken {
                Text(routeInvalid
                     ? "以小写字母开头；其后为小写字母、数字和连字符。"
                     : "已有提供方使用此 ID。")
                    .font(.footnote)
                    .foregroundColor(.red)
            } else {
                Text("小写标识符，以字母开头；在请求中唯一命名此提供方，并作为其凭据名。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            field(label: "显示名") {
                TextField(displayNamePlaceholder, text: $displayName,
                          prompt: Text(displayNamePlaceholder).foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .disabled(profileDisabled)
                    .accessibilityLabel("显示名")
            }
            field(label: "Base URL") {
                TextField("https://gateway.example/v1", text: $baseURL,
                          prompt: Text("https://gateway.example/v1").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(profileDisabled)
                    .accessibilityLabel("Base URL")
            }
            if baseURLInvalid {
                Text("Base URL 须以 http:// 或 https:// 开头。")
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            field(label: "API Key") {
                SecureField("输入 API Key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(busy)
                    .accessibilityLabel("API Key")
            }
            if let keyFailure {
                Text(keyFailure)
                    .font(.footnote)
                    .foregroundColor(.red)
            } else {
                Text("留空则此提供方以其他方式鉴权。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ModelCatalogEditorView(
                models: models,
                overridden: true,
                defaultContextWindow: nil,
                defaultMaxTokens: nil,
                disabled: profileDisabled,
                discoverModels: discoverModels,
                probeBaseURL: baseURL.isEmpty ? nil : baseURL,
                probeAPIKey: keyValue.isEmpty ? nil : keyValue,
                onChange: { next in models = next },
                onReset: { models = []; capacityBuffers.removeAll() },
                capacityBuffers: $capacityBuffers)
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            footer
        }
        .padding(.vertical, 8)
    }

    /// 配置字段在创建落地后停用（dsh profileDisabled :97）。
    private var profileDisabled: Bool { busy || committed }

    private var displayNamePlaceholder: String {
        routeID.isEmpty ? "显示名" : routeID
    }

    private var footer: some View {
        HStack {
            Button("取消") { onClose(committed) }
                .frame(minHeight: 44)
                .disabled(busy)
            Spacer()
            Button {
                Task { await create() }
            } label: {
                Text(busy ? "创建中…" : "创建提供方")
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(busy || !ready)
        }
    }

    // MARK: - 创建（dsh createOnce :131-171 两步语义）

    private func create() async {
        busy = true
        failure = nil
        defer { busy = false }
        if !committed {
            let endpoint = EndpointConfig(
                name: displayName.isEmpty ? routeID : displayName,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: models.first(where: { !$0.id.isEmpty })?.id ?? "")
            var stored = endpoint
            stored.models = models
            store.add(stored)
            createdEndpoint = stored
            // 配置已落地；其后 key 写失败的重试不得再走这条 add（dsh
            // committed :155-163 同语义——重试路径只剩凭据一步）。
            committed = true
        }
        if !keyValue.isEmpty, let seam = credentialSeam, let created = createdEndpoint {
            do {
                let notice = try seam.set(created, keyValue)
                onCredentialNotice?(notice)
            } catch {
                failure = "Key 保存失败：\((error as NSError).localizedDescription)"
                return
            }
        }
        onClose(true)
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
