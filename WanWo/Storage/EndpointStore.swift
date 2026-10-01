//
//  EndpointStore.swift
//  WanWo
//
//  【按设计新写】出处：10-design §5.5 v2.1 接入口径（09 决策 #16）+ §十一 M1.5：
//  OpenAI 兼容多端点配置管理——多套 base URL/key/model 并存与启停（F053 最小面）。
//  配置 JSON 落盘（无敏感值），API key 入 Keychain（KeychainStore，按 endpoint id）。
//  【M8 批1 件A1/A2 扩展】EndpointConfig 扩模型目录（models + 端点级缺省
//  窗口/输出上限 + displayName，dsh DeepSeekCatalogModel/Config 语义）；
//  密钥面迁移 CredentialStore route ref（dsh deriveKeyRef 语义），旧 uuid
//  账目读兜底。目录快照宿主供 Compactor 窗口解析（65.5k 根因修复）。
//

import Foundation

/// 一套 OpenAI 兼容端点配置。
struct EndpointConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// 端点基址（如 https://api.deepseek.com，不含 /chat/completions）。
    var baseURL: String
    /// 模型名。2026-09 有效线：deepseek-v4-flash / deepseek-v4-pro（04-ai-agent-knowledge §5.4）；
    /// 旧 deepseek-chat / deepseek-reasoner 已于 2026-07-24 下线，禁止再作默认值/示例值。
    var model: String
    var isEnabled: Bool
    /// DeepSeek 扩展透传（09 #16）：thinking enabled|disabled，可选。
    var thinking: String?
    /// DeepSeek 扩展透传（09 #16）：reasoning effort off|low|high|max，可选。
    var reasoningEffort: String?
    /// M8 批1 件A1：模型目录（nil = 继承内置缺省——万我 BYOK 内置目录空集
    /// 起步 → 单模型行为；编辑即 override，重置回继承 = 置回 nil——dsh
    /// DeepSeekModelsEditor.tsx:267-286 继承/已自定义/重置语义）。
    var models: [ModelCatalogEntry]?
    /// 端点级缺省上下文窗（nil = 1_000_000，dsh DEFAULT_CONTEXT_WINDOW
    /// llm-deepseek/adapter.ts:140；目录项缺窗口时兜底）。
    var defaultContextWindow: Int?
    /// 端点级缺省单次输出上限（nil = 256_000，dsh DEFAULT_MAX_TOKENS :142）。
    var defaultMaxTokens: Int?
    /// 显示名（nil = 用 name；dsh displayName ?? route 语义 pi-ai
    /// config.ts:450，万我 route 语义由 name 承载）。
    var displayName: String?

    init(id: UUID = UUID(), name: String, baseURL: String, model: String,
         isEnabled: Bool = true, thinking: String? = nil, reasoningEffort: String? = nil,
         models: [ModelCatalogEntry]? = nil, defaultContextWindow: Int? = nil,
         defaultMaxTokens: Int? = nil, displayName: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.isEnabled = isEnabled
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.models = models
        self.defaultContextWindow = defaultContextWindow
        self.defaultMaxTokens = defaultMaxTokens
        self.displayName = displayName
    }
}

/// 端点目录线程安全快照宿主（M8 批1 件A1 Compactor 缝：压缩线程免
/// MainActor 跳转读取；@unchecked Sendable + NSLock——SessionModelSelection
/// 同款线程模型）。EndpointStore persist 面统一刷新 = 下一请求即最新目录
/// （dsh per-request resolution 的进程内映像）。
final class EndpointCatalogSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [EndpointConfig] = []

    func replace(_ endpoints: [EndpointConfig]) {
        lock.lock()
        defer { lock.unlock() }
        self.endpoints = endpoints
    }

    /// 模型上下文窗解析（dsh llm-deepseek/adapter.ts:398-400 modelInfoFor
    /// 语义：精确 id 匹配 + 本连接缺省窗口兜底；无前缀猜测）。
    /// - endpointID 非空：限定会话所选端点——任何请求模型都以该端点缺省
    ///   窗口兜底（未登记模型不再落 65_536，65.5k 根因修复）。
    /// - endpointID 空：全目录精确 id 扫描，均未命中 = nil（调用方回落
    ///   Compactor policy 底线）。
    func contextWindow(for modelID: String, endpointID: UUID?) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let endpointID,
           let endpoint = endpoints.first(where: { $0.id == endpointID }) {
            let entry = endpoint.models?.first(where: { $0.id == modelID })
            return ModelCatalog.resolvedContextWindow(
                entry, defaultContextWindow: endpoint.defaultContextWindow)
        }
        for endpoint in endpoints {
            if let entry = endpoint.models?.first(where: { $0.id == modelID }) {
                return ModelCatalog.resolvedContextWindow(
                    entry, defaultContextWindow: endpoint.defaultContextWindow)
            }
        }
        return nil
    }
}

/// 端点配置仓库（JSON 文件 + Keychain 凭据）。
@MainActor
final class EndpointStore: ObservableObject {
    @Published private(set) var endpoints: [EndpointConfig]
    /// M3 T2.2：用户显式选定的活动端点（composer 模型挡位写侧；UserDefaults
    /// 持久——端点 JSON 为 [EndpointConfig] 数组格式，另立键避免破坏既有文件）。
    @Published private(set) var activeEndpointID: UUID?
    /// M8 批1 件A1：目录快照宿主（Compactor @Sendable 缝消费；let 常量引用，
    /// 任意线程可捕获；内容由 persist 面刷新）。
    let catalogSnapshot = EndpointCatalogSnapshot()
    /// M8 批1 件A2：密钥面（route ref 语义；后端可注入——测试纪律）。
    private let credentials: CredentialStore

    private let fileURL: URL
    private static let logger = AppLogger(category: "endpoints")
    private static let activeIDKey = "wanwo.activeEndpointID"
    /// 凭据文件兜底目录注入缝（CI修37；nil = 生产缺省派生不变——
    /// Application Support/credentials，存量文件兜底 key 位置不动）。
    /// 测试注入临时目录：单测不再向真实容器写/删 .key（testUnsetCredential-
    /// ClearsRouteRefAccount 曾是全测试面唯一触碰真实容器凭据文件的路径，
    /// CI 36812442298/36815196974 跨测试 Cocoa 260 读错误实证污染源头）。
    private let credentialDirectory: URL?

    init(fileURL: URL, credentialStore: CredentialStore = CredentialStore(),
         credentialDirectory: URL? = nil) {
        self.fileURL = fileURL
        self.credentials = credentialStore
        self.credentialDirectory = credentialDirectory
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([EndpointConfig].self, from: data),
           !loaded.isEmpty {
            endpoints = loaded
            catalogSnapshot.replace(endpoints)
        } else {
            // 出厂默认：DeepSeek OpenAI 兼容端点（09 #16 示例值，用户可在设置页修改）。
            // 模型取当前有效线（04 §5.4）；仅影响无配置文件的全新安装——
            // 已落盘的 endpoints JSON 原样加载，用户已配置的模型不被覆写。
            endpoints = [EndpointConfig(name: "DeepSeek",
                                        baseURL: "https://api.deepseek.com",
                                        model: "deepseek-v4-flash",
                                        isEnabled: true)]
            persist()
        }
        // 恢复显式选择（端点已不存在则弃用，回落首启用项）。
        if let raw = UserDefaults.standard.string(forKey: Self.activeIDKey),
           let id = UUID(uuidString: raw),
           endpoints.contains(where: { $0.id == id }) {
            activeEndpointID = id
        }
    }

    /// 当前启用的端点（显式选择优先；无效/未选回落首启用项——T2.2 前行为）。
    func activeEndpoint() -> EndpointConfig? {
        if let id = activeEndpointID,
           let explicit = endpoints.first(where: { $0.id == id && $0.isEnabled }) {
            return explicit
        }
        return endpoints.first(where: { $0.isEnabled })
    }

    /// 会话级选择解析（T2.4 P1-3：dsh ModelSelect.tsx per-session
    /// ModelSelection 语义——会话选择优先（端点仍启用时），缺省回落活动端点
    /// （App 级缺省）；返回端点已应用会话 effort 覆盖（nil = provider default
    /// 不透传）。EndpointConfig.reasoningEffort（端点级字段）由此废弃：
    /// 解析结果恒被会话值覆盖，旧落盘值不再生效。
    /// M8 批1 件A4：会话级模型覆盖（selection.modelID 非 nil 时覆盖
    /// resolved.model——下一请求即生效：adapter 按本次解析结果冻结，运行中
    /// step 不变，dsh ui-model-selection README「选择下一请求生效」语义；
    /// LlmCallConfig 两构造点（AgentLoop:1174 / ChatTurnRunner:90）读
    /// adapter.endpoint.model，零改动即消费）。
    func resolve(selection: SessionModelSelection.Value?) -> EndpointConfig? {
        if let selection,
           let endpoint = endpoints.first(where: { $0.id == selection.endpointID && $0.isEnabled }) {
            var resolved = endpoint
            resolved.reasoningEffort = selection.reasoningEffort
            if let modelID = selection.modelID, !modelID.isEmpty {
                resolved.model = modelID
            }
            return resolved
        }
        return activeEndpoint()
    }

    /// 设定活动端点（composer 模型挡位提交面；下一请求即生效——AgentLoop
    /// makeAdapter 按调用时 activeEndpoint 取用）。
    func setActive(_ endpoint: EndpointConfig) {
        guard endpoints.contains(where: { $0.id == endpoint.id }) else { return }
        activeEndpointID = endpoint.id
        UserDefaults.standard.set(endpoint.id.uuidString, forKey: Self.activeIDKey)
    }

    // MARK: - 增删改查

    func add(_ endpoint: EndpointConfig) {
        var endpoint = endpoint
        // P2-1 收口（review batch1）：目录落盘前过生产归一化门（trim/去重/
        // 非正容量清 nil）——UI 两条路径（ProviderEditor/CustomProviderCard）
        // 在此单点收敛，不再各修各的。
        if let models = endpoint.models {
            endpoint.models = ModelCatalog.sanitized(models)
        }
        endpoints.append(endpoint)
        persist()
    }

    func update(_ endpoint: EndpointConfig) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        var endpoint = endpoint
        if let models = endpoint.models {
            endpoint.models = ModelCatalog.sanitized(models)
        }
        endpoints[index] = endpoint
        persist()
    }

    func remove(_ endpoint: EndpointConfig) {
        endpoints.removeAll(where: { $0.id == endpoint.id })
        // 凭据三清（route ref + 旧 uuid 账目 + 文件兜底；幂等）。
        unsetCredential(for: endpoint)
        // 显式选择随端点移除清退（回落首启用项）。
        if activeEndpointID == endpoint.id {
            activeEndpointID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
        }
        persist()
    }

    func setEnabled(_ enabled: Bool, for endpoint: EndpointConfig) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index].isEnabled = enabled
        persist()
    }

    // MARK: - 凭据（M8 批1 件A2：CredentialStore route ref 语义 +
    // Keychain/沙箱文件兜底；配置文件永不存 key）

    // ERR-016：TrollStore 等侧载环境的假签名可能缺 keychain-access-groups
    // entitlement，Keychain 写/读会整体失败（errSecMissingEntitlement -34018 等），
    // 而原实现 setApiKey 静默吞错 → 用户以为已保存、新建对话时读不到 → 降级横幅。
    // 双层方案：Keychain 成功照用；失败/读不到时以 App 沙箱文件兜底
    // （仅本设备本 App 可读；自用场景下权衡可接受，安全注记见 10-design §5.5）。
    // M8 批1 迁移：Keychain 主通道改走 CredentialStore route ref
    // （routeApiKeyRef(endpoint.id)，dsh store.ts:113-115 deriveKeyRef 语义）；
    // 旧 uuid 账目（KeychainStore 直存时代）读兜底保留——存量用户 key 不失。
    private var credentialFallbackDir: URL {
        if let credentialDirectory { return credentialDirectory }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("credentials", isDirectory: true)
    }

    private func credentialFileURL(for endpoint: EndpointConfig) -> URL {
        credentialFallbackDir.appendingPathComponent("endpoint-\(endpoint.id.uuidString).key")
    }

    private func writeCredentialFile(_ key: String, for endpoint: EndpointConfig) throws {
        let dir = credentialFallbackDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try key.write(to: credentialFileURL(for: endpoint), atomically: true, encoding: .utf8)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var url = credentialFileURL(for: endpoint)
        try? url.setResourceValues(resources)
    }

    /// 端点密钥读（route ref → 旧 uuid 账目兜底 → 沙箱文件兜底）。
    func apiKey(for endpoint: EndpointConfig) -> String? {
        let ref = CredentialStore.routeApiKeyRef(endpoint.id.uuidString)
        if let key = credentials.value(for: ref), !key.isEmpty {
            return key
        }
        if let key = KeychainStore.load(account: endpoint.id.uuidString), !key.isEmpty {
            return key
        }
        return try? String(contentsOf: credentialFileURL(for: endpoint), encoding: .utf8)
    }

    /// 密钥读视图（dsh describe 语义：已配置布尔——永不含值；A2 行卡状态点
    /// 数据源）。
    func credentialConfigured(for endpoint: EndpointConfig) -> Bool {
        apiKey(for: endpoint)?.isEmpty == false
    }

    /// 端点凭据三清（M8 批1 件A2；A2 删除流"先 unset 凭据再 remove 端点"
    /// 两步幂等可重试语义消费）：route ref 账目 + 旧 uuid 账目（KeychainStore
    /// 直存时代存量）+ 沙箱文件兜底，幂等无失败路径（dsh removeCredential
    /// "unset 幂等、成功即 undefined"——内部 try? 吞存储层失败，文件不存在
    /// 视为已清）。remove() 亦走本缝。
    func unsetCredential(for endpoint: EndpointConfig) {
        credentials.unset(ref: CredentialStore.routeApiKeyRef(endpoint.id.uuidString))
        KeychainStore.delete(account: endpoint.id.uuidString)
        try? FileManager.default.removeItem(at: credentialFileURL(for: endpoint))
    }

    /// 保存凭据。主通道 = CredentialStore route ref；Keychain 失败自动落
    /// 文件兜底；两者都失败才抛错。
    /// - Returns: 实际存储方式描述（供 UI 显示，让用户知道 Key 存到了哪一层）。
    @discardableResult
    func setApiKey(_ key: String, for endpoint: EndpointConfig) throws -> String {
        let ref = CredentialStore.routeApiKeyRef(endpoint.id.uuidString)
        var credentialError: Error?
        do {
            try credentials.set(ref: ref, value: key)
        } catch {
            credentialError = error
        }
        // 文件兜底始终写：Keychain 可能成功但日后读不出（重装/访问组变化），
        // 双写保证读取侧任一通道可用即得。
        try writeCredentialFile(key, for: endpoint)
        if let error = credentialError {
            let code = (error as NSError).code
            Self.logger.error("credential save failed (fell back to file): \(String(describing: error))")
            return "已保存（文件兜底；Keychain 不可用 err \(code)）"
        }
        return "已保存（Keychain + 文件双写）"
    }

    // MARK: - 【批3 B1/B4】BYOK gate + API key 形校验（dsh apiKey.ts 裁剪）

    /// BYOK 首跑引导 gate 纯函数（DeepSeekOnboardingDialog.tsx:99-124 语义——
    /// 无任何已配置 provider 且未确认过 → 引导；「稍后配置」/保存均落确认态）。
    /// 出厂默认 DeepSeek 端点恒存在（init 兜底）→「无已配置 provider」口径
    /// = 无任何端点持有凭据（ProvidersView credentialCount 供数）。
    nonisolated static func byokOnboardingNeeded(confirmed: Bool,
                                                 endpointsWithCredential: Int) -> Bool {
        !confirmed && endpointsWithCredential == 0
    }

    /// API key 形校验（dsh apiKey.ts:12-58 四类，按 EndpointStore 字段裁剪
    /// ——报告注明：万我无 ENV 来源面，keyRequired 对应 dsh keyBlank 词汇）：
    ///   · 空串 = 通过（UI 层「留空保留已存」语义天然对齐 dsh 空=通过）；
    ///   · 纯空白（trim 后空）= keyRequired；
    ///   · `NAME=value` 环境变量行 / 引号包裹 / 含非可打印 ASCII（LEGAL
    ///     `/^[\x21-\x7E]+$/` 之外，含非 ASCII）= keyIllegalCharacters。
    nonisolated static func apiKeyFailure(_ raw: String) -> String? {
        // dsh apiKey.ts:26——空串 = 通过（保留已存）。
        if raw.isEmpty { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // dsh apiKey.ts:29——trim 后空 = 必填缺失（简报 B4 词汇 keyRequired）。
        if trimmed.isEmpty { return "keyRequired" }
        // ENV_LINE（apiKey.ts:20）：大写开头名 + `=` 后非 `=`（防 base64
        // padding 形态误判）。
        if trimmed.range(of: "^[A-Z][A-Z0-9_]*=[^=]",
                         options: .regularExpression) != nil {
            return "keyIllegalCharacters"
        }
        // isQuoted（apiKey.ts:23-26）：三种引号整串包裹。
        if let first = trimmed.first, let last = trimmed.last, trimmed.count >= 2,
           (first == "\"" && last == "\"")
               || (first == "'" && last == "'")
               || (first == "`" && last == "`") {
            return "keyIllegalCharacters"
        }
        // LEGAL_API_KEY（apiKey.ts:12）：仅可打印 ASCII（0x21-0x7E）。
        for scalar in trimmed.unicodeScalars where !(0x21...0x7E).contains(scalar.value) {
            return "keyIllegalCharacters"
        }
        return nil
    }

    // MARK: - 预置内置目录只读消费（m7-fix2 M6②；dsh catalogModels(provider)
    // 语义——catalog.ts:186-190；候选语义只读，绝不静默写配置）

    /// 端点对应的预置内置模型目录（dsh catalogModels：未收录 = 空集）。
    /// 匹配键 = 端点 name（预置创建时 name=preset.id，AddProviderFormView
    /// savePreset 语义；出厂 DeepSeek 端点 name 亦命中，大小写不敏感）。
    /// 消费方：ModelSelectView dock 模型菜单（用户目录 ∪ 内置目录，discovery
    /// .ts:208-216 installed 语义）。
    func builtinCatalog(for endpoint: EndpointConfig) -> [ModelCatalogEntry] {
        ProviderCatalog.builtinModels(forProvider: endpoint.name)
    }

    // MARK: - 持久化

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(endpoints)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("endpoint config persist failed: \(String(describing: error))")
        }
        // 目录快照刷新（Compactor 缝数据源；读失败/写失败都照常刷新——
        // 快照以内存 endpoints 为准）。
        catalogSnapshot.replace(endpoints)
    }
}
