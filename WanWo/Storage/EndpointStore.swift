//
//  EndpointStore.swift
//  WanWo
//
//  【按设计新写】出处：10-design §5.5 v2.1 接入口径（09 决策 #16）+ §十一 M1.5：
//  OpenAI 兼容多端点配置管理——多套 base URL/key/model 并存与启停（F053 最小面）。
//  配置 JSON 落盘（无敏感值），API key 入 Keychain（KeychainStore，按 endpoint id）。
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

    init(id: UUID = UUID(), name: String, baseURL: String, model: String,
         isEnabled: Bool = true, thinking: String? = nil, reasoningEffort: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.isEnabled = isEnabled
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
    }
}

/// 端点配置仓库（JSON 文件 + Keychain 凭据）。
@MainActor
final class EndpointStore: ObservableObject {
    @Published private(set) var endpoints: [EndpointConfig]

    private let fileURL: URL
    private static let logger = AppLogger(category: "endpoints")

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([EndpointConfig].self, from: data),
           !loaded.isEmpty {
            endpoints = loaded
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
    }

    /// 当前启用的端点（M1：取第一个启用项；多路由路由策略随 F053 完整化）。
    func activeEndpoint() -> EndpointConfig? {
        endpoints.first(where: { $0.isEnabled })
    }

    // MARK: - 增删改查

    func add(_ endpoint: EndpointConfig) {
        endpoints.append(endpoint)
        persist()
    }

    func update(_ endpoint: EndpointConfig) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
        persist()
    }

    func remove(_ endpoint: EndpointConfig) {
        endpoints.removeAll(where: { $0.id == endpoint.id })
        KeychainStore.delete(account: endpoint.id.uuidString)
        persist()
    }

    func setEnabled(_ enabled: Bool, for endpoint: EndpointConfig) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index].isEnabled = enabled
        persist()
    }

    // MARK: - 凭据（Keychain 优先 + 沙箱文件兜底；配置文件永不存 key）

    // ERR-016：TrollStore 等侧载环境的假签名可能缺 keychain-access-groups
    // entitlement，Keychain 写/读会整体失败（errSecMissingEntitlement -34018 等），
    // 而原实现 setApiKey 静默吞错 → 用户以为已保存、新建对话时读不到 → 降级横幅。
    // 双层方案：Keychain 成功照用；失败/读不到时以 App 沙箱文件兜底
    // （仅本设备本 App 可读；自用场景下权衡可接受，安全注记见 10-design §5.5）。
    private var credentialFallbackDir: URL {
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

    func apiKey(for endpoint: EndpointConfig) -> String? {
        if let key = KeychainStore.load(account: endpoint.id.uuidString), !key.isEmpty {
            return key
        }
        return try? String(contentsOf: credentialFileURL(for: endpoint), encoding: .utf8)
    }

    /// 保存凭据。Keychain 失败自动落文件兜底；两者都失败才抛错。
    /// - Returns: 实际存储方式描述（供 UI 显示，让用户知道 Key 存到了哪一层）。
    @discardableResult
    func setApiKey(_ key: String, for endpoint: EndpointConfig) throws -> String {
        var keychainError: Error?
        do {
            try KeychainStore.save(apiKey: key, account: endpoint.id.uuidString)
        } catch {
            keychainError = error
        }
        // 文件兜底始终写：Keychain 可能成功但日后读不出（重装/访问组变化），
        // 双写保证读取侧任一通道可用即得。
        try writeCredentialFile(key, for: endpoint)
        if let kcError = keychainError {
            let code = (kcError as NSError).code
            Self.logger.error("keychain save failed (fell back to file): \(String(describing: kcError))")
            return "已保存（文件兜底；Keychain 不可用 err \(code)）"
        }
        return "已保存（Keychain + 文件双写）"
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
    }
}
