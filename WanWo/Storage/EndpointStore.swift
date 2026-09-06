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
            endpoints = [EndpointConfig(name: "DeepSeek",
                                        baseURL: "https://api.deepseek.com",
                                        model: "deepseek-chat",
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

    // MARK: - 凭据（Keychain；配置文件永不存 key）

    func apiKey(for endpoint: EndpointConfig) -> String? {
        KeychainStore.load(account: endpoint.id.uuidString)
    }

    func setApiKey(_ key: String, for endpoint: EndpointConfig) {
        do {
            try KeychainStore.save(apiKey: key, account: endpoint.id.uuidString)
        } catch {
            Self.logger.error("keychain save failed: \(String(describing: error))")
        }
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
