//
//  MCPServerStore.swift
//  WanWo
//
//  【M4-A 件11 · 配置存储】出处：OpenMinis src/ios/Agent/Session/MCPStore.swift
//  :26-53（MCPServerConfig 结构）/:247-266（servers.json 双端读写形态
//  {"mcpServers": {<name>: {...}}}）/:272-336（逐条容忍解码——单条损坏跳过
//  +记日志，不整表丢弃）。UI 遵 OpenMinis（R7）；凭据面按 lead 派单：API
//  Key/token 不入 JSON——Keychain（沿 WanWo KeychainStore 模式，独立
//  service）；文件位置沿 Application Support 约定（config/mcp-servers/servers.json）。
//  原子写沿既有文件工具纪律（.atomic，EndpointStore.persist 同款）。
//  最小集裁剪（lead 派单）：本批仅 streamable-http（url/headers/enabled/
//  note）；OAuth/JSON 导入/createdAt/updatedAt/session overrides/云同步/
//  stdio 字段（command/args/env/startupTimeoutSeconds）不做——读侧容忍
//  但不回写（WanWo 为唯一写者、无 CLI 共写者，round-trip 丢未知键呈报）。
//

import Foundation

/// 一个 MCP server 条目（servers.json 键=serverName）。
struct MCPServerEntry: Identifiable, Equatable, Sendable {
    /// servers.json 键（`mcp__<serverName>__<rawName>` 的 serverName 段；
    /// 形态校验在 clientConfig(for:) 落——MCPClientConfig.isValidServerName）。
    var id: String
    /// Streamable HTTP 端点（本批唯一传输变体）。
    var url: String
    /// 启用态（文件缺省 true——OpenMinis ServerEntry.enabled 语义）。
    var enabled: Bool
    var note: String?
    /// 非敏感自定义头（凭据类值不入 JSON——走 Keychain authToken）。
    var headers: [String: String]
}

/// MCP server 配置仓库（JSON 文件 + Keychain 凭据；EndpointStore 同款形态）。
@MainActor
final class MCPServerStore: ObservableObject {
    @Published private(set) var servers: [MCPServerEntry]

    private let fileURL: URL
    private static let logger = AppLogger(category: "MCPServerStore")
    /// MCP server 凭据独立 service（与端点凭据 com.wanwo.endpoint 隔离）。
    private static let credentialService = "com.wanwo.mcp"

    init(fileURL: URL) {
        self.fileURL = fileURL
        servers = Self.readServersFromDisk(fileURL: fileURL)
    }

    // MARK: - 磁盘读写（OpenMinis MCPStore 形态）

    /// 逐条容忍解码（OpenMinis readServersFromDisk FIX 1 语义）：mcpServers
    /// 对象逐条独立解码，单条损坏跳过+记日志，不整表丢弃。按名称排序稳定。
    private static func readServersFromDisk(fileURL: URL) -> [MCPServerEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["mcpServers"] as? [String: Any] else {
            logger.error("servers.json unparseable at \(fileURL.path) — ignoring")
            return []
        }
        var entries: [MCPServerEntry] = []
        for (name, raw) in rawServers.sorted(by: { $0.key < $1.key }) {
            guard let obj = raw as? [String: Any], let entry = entry(name: name, from: obj) else {
                logger.error("skipping malformed MCP server entry '\(name)'")
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    /// 单条解析（OpenMinis serverConfig 语义子集）：enabled 缺省 true 且
    /// 尊重 `disabled: true` 别名（Claude-Desktop 兼容写法）；本批仅 http
    /// 形态（command/args/env 等条目=非本批变体，跳过+记日志）。
    private static func entry(name: String, from obj: [String: Any]) -> MCPServerEntry? {
        guard let url = obj["url"] as? String, !url.isEmpty else {
            if obj["command"] != nil {
                logger.info("skipping stdio MCP server '\(name)' — stdio variant lands with M4-B")
            }
            return nil
        }
        let enabled: Bool
        if let disabled = obj["disabled"] as? Bool {
            enabled = !disabled
        } else {
            enabled = (obj["enabled"] as? Bool) ?? true
        }
        let headers = (obj["headers"] as? [String: String]) ?? [:]
        return MCPServerEntry(id: name, url: url, enabled: enabled,
                              note: obj["note"] as? String, headers: headers)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var map: [String: [String: Any]] = [:]
            for server in servers {
                var entry: [String: Any] = [
                    "enabled": server.enabled,
                    "url": server.url,
                ]
                if let note = server.note { entry["note"] = note }
                if !server.headers.isEmpty { entry["headers"] = server.headers }
                map[server.id] = entry
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["mcpServers": map],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // 原子写：并发读者（未来 CLI/对端）永不见半写文件（OpenMinis :365-367）。
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("servers.json persist failed: \(String(describing: error))")
        }
    }

    // MARK: - CRUD

    func upsert(_ entry: MCPServerEntry) {
        if let index = servers.firstIndex(where: { $0.id == entry.id }) {
            servers[index] = entry
        } else {
            servers.append(entry)
        }
        servers.sort { $0.id < $1.id }
        persist()
    }

    func remove(id: String) {
        servers.removeAll { $0.id == id }
        KeychainStore.delete(account: Self.credentialAccount(id),
                             service: Self.credentialService)
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        persist()
    }

    /// 启用条目的连接配置解析（逐条容忍：非法条目跳过并给出失败原因——
    /// 读侧 FIX 1 纪律在配置消费面的延伸）。
    func resolvedClientConfigs() -> (configs: [MCPClientConfig], failures: [String]) {
        var configs: [MCPClientConfig] = []
        var failures: [String] = []
        for entry in servers where entry.enabled {
            do {
                configs.append(try clientConfig(for: entry))
            } catch {
                failures.append(String(describing: error))
            }
        }
        return (configs, failures)
    }

    // MARK: - 配置→连接配置（凭据注入缝）

    /// serverName/url 形态校验 + Keychain token 注入 Authorization 头
    /// （条目显式 headers 的 Authorization 优先——用户自带凭据形态不覆写）。
    func clientConfig(for entry: MCPServerEntry) throws -> MCPClientConfig {
        guard MCPClientConfig.isValidServerName(entry.id) else {
            throw MCPConfigurationError(
                "mcp-server \"\(entry.id)\": serverName 必须匹配 [A-Za-z0-9_-]{1,32}")
        }
        guard let url = URL(string: entry.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw MCPConfigurationError(
                "mcp-server \"\(entry.id)\": url 必须是合法的绝对 http(s) URL")
        }
        var headers = entry.headers
        if let token = authToken(for: entry.id), !token.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("authorization") == .orderedSame }) {
            headers["Authorization"] = "Bearer \(token)"
        }
        return MCPClientConfig(transport: .streamableHTTP(url: entry.url, headers: headers),
                               serverName: entry.id)
    }

    // MARK: - 凭据（Keychain；永不入 servers.json——lead 派单凭据面）

    private static func credentialAccount(_ id: String) -> String { "mcp.\(id)" }

    func authToken(for id: String) -> String? {
        KeychainStore.load(account: Self.credentialAccount(id),
                           service: Self.credentialService)
    }

    func hasAuthToken(for id: String) -> Bool {
        !(authToken(for: id) ?? "").isEmpty
    }

    /// 保存凭据（覆盖写）。ERR-016 文件兜底不移植：MCP 凭据 Keychain-only
    /// ——无 token = 无 Authorization 头 = server 401 可见（fail closed，
    /// 呈报与 EndpointStore 双写差异）。
    func setAuthToken(_ token: String, for id: String) throws {
        try KeychainStore.save(apiKey: token,
                               account: Self.credentialAccount(id),
                               service: Self.credentialService)
    }

    func clearAuthToken(for id: String) {
        KeychainStore.delete(account: Self.credentialAccount(id),
                             service: Self.credentialService)
    }
}
