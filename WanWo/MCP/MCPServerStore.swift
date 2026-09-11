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
//  最小集裁剪（lead 派单）：M4-A 仅 streamable-http；M4-B B1 起 stdio 形态
//  落位（command/args/env/cwd + 平台层 startupTimeoutSeconds，1-900/默认 60
//  ——dsh 无对应物，锚点 minis config.py:32/:34）。条目级解码语义对位
//  OpenMinis MCPStore（逐条容忍），reconnect 子对象未知键拒绝=MCPReconnect-
//  Config（dsh connection.ts:66-70 1:1）；OAuth/JSON 导入/createdAt/updatedAt/
//  session overrides/云同步/stdio reconnect 字段不做——读侧容忍但不回写
//  （WanWo 为唯一写者、无 CLI 共写者，round-trip 丢未知键呈报）。
//

import Foundation

/// 一个 MCP server 条目（servers.json 键=serverName）。
/// 双形态（M4-B B1）：http（url 在场）与 stdio（command 在场）——形态判别
/// 沿 OpenMinis is_stdio（transport/stdio.py:32 同款「字段在场性」语义，
/// servers.json 不加显式 kind 键=保持 Claude-Desktop 兼容写法）。同条目
/// url 与 command 皆在场时以 command 为准（stdio 优先，与 entry() 解析
/// 分支顺序一致）。
struct MCPServerEntry: Identifiable, Equatable, Sendable {
    /// servers.json 键（`mcp__<serverName>__<rawName>` 的 serverName 段；
    /// 形态校验在 clientConfig(for:) 落——MCPClientConfig.isValidServerName）。
    var id: String
    /// Streamable HTTP 端点（http 形态；stdio 形态为 nil）。
    var url: String?
    /// 启用态（文件缺省 true——OpenMinis ServerEntry.enabled 语义）。
    var enabled: Bool
    var note: String?
    /// 非敏感自定义头（凭据类值不入 JSON——走 Keychain authToken；http 形态）。
    var headers: [String: String]
    // MARK: stdio 形态（dsh index.ts:50-73 StdioConfig 对应；M4-B B1）
    /// 可执行文件（guest 内路径；stdio 形态判别键）。
    var command: String?
    /// 参数直传无 shell 插值（index.ts:61 注释原文语义；minis main.py:420
    /// 空格切分同款）。
    var args: [String]
    /// 额外环境变量（与 scrub 后父环境合并=transport.ts:21-23，B2 接线）。
    var env: [String: String]
    /// 子进程工作目录（平台差异登记：dsh StdioConfig.cwd 必填，minis 实际
    /// 未传——WanWo 取可选，nil=guest 默认工作目录）。
    var cwd: String?
    /// 启动超时秒（平台层字段——dsh 无对应物，锚点=minis config.py:32/:34；
    /// nil=60s 默认；读侧非法值忽略+警告不静默）。
    var startupTimeoutSeconds: Int?

    /// stdio 形态判别（command 在场即 stdio——OpenMinis is_stdio 同款）。
    var isStdio: Bool { command != nil }
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
    /// 尊重 `disabled: true` 别名（Claude-Desktop 兼容写法）。M4-B B1 起
    /// 双形态：command 在场=stdio（形态判别先于 url——同条目双键时 stdio
    /// 优先），否则 url=http。startupTimeoutSeconds 值域 1-900（平台层，
    /// minis config.py:32/:34）：非法值忽略+警告（回默认，minis
    /// resolve_startup_timeout config.py:134-137 语义——不静默吞）。
    /// 条目内未知键容忍（OpenMinis 逐条容忍解码语义，件11 定案口径）——
    /// 与 dsh connection.ts:65-90 的「逐键再判」不同层：dsh 该语义落
    /// reconnect 子对象（MCPReconnectConfig init 已 1:1），servers.json
    /// 条目级对位是 OpenMinis MCPStore（R1 边界）。
    private static func entry(name: String, from obj: [String: Any]) -> MCPServerEntry? {
        let enabled: Bool
        if let disabled = obj["disabled"] as? Bool {
            enabled = !disabled
        } else {
            enabled = (obj["enabled"] as? Bool) ?? true
        }
        let note = obj["note"] as? String

        // stdio 形态（dsh index.ts:50-73 StdioConfig 对应）。
        if let command = obj["command"] as? String {
            guard !command.isEmpty else {
                logger.warning("skipping stdio MCP server '\(name)' — command is empty")
                return nil
            }
            var args: [String] = []
            if let raw = obj["args"] as? [Any] {
                for item in raw {
                    if let item = item as? String { args.append(item) }
                }
            }
            var env: [String: String] = [:]
            if let raw = obj["env"] as? [String: Any] {
                for (key, value) in raw {
                    if let value = value as? String { env[key] = value }
                }
            }
            let cwd = obj["cwd"] as? String
            let startup = Self.resolvedStartupTimeout(obj, name: name)
            return MCPServerEntry(id: name, url: nil, enabled: enabled, note: note,
                                  headers: [:], command: command, args: args,
                                  env: env, cwd: cwd, startupTimeoutSeconds: startup)
        }

        // http 形态。
        guard let url = obj["url"] as? String, !url.isEmpty else {
            return nil
        }
        let headers = (obj["headers"] as? [String: String]) ?? [:]
        return MCPServerEntry(id: name, url: url, enabled: enabled, note: note,
                              headers: headers, command: nil, args: [],
                              env: [:], cwd: nil, startupTimeoutSeconds: nil)
    }

    /// startupTimeoutSeconds 解析（平台层——minis resolve_startup_timeout
    /// config.py:127- 语义裁剪：只认主字段 startupTimeoutSeconds，别名键
    /// （startup_timeout_sec/startupTimeout/handshakeTimeout/initializeTimeout，
    /// minis config.py:38 STARTUP_TIMEOUT_KEYS）不移植=最小集；非数字/越界
    /// →nil（回 60s 默认）+警告，不静默）。
    private static func resolvedStartupTimeout(_ obj: [String: Any],
                                               name: String) -> Int? {
        guard let raw = obj["startupTimeoutSeconds"] else { return nil }
        if let seconds = raw as? Int,
           (1...MCPConstants.maxStartupTimeoutSeconds).contains(seconds) {
            return seconds
        }
        logger.warning(
            "mcp-server '\(name)': startupTimeoutSeconds \(raw) is invalid — "
            + "using default \(MCPConstants.defaultStartupTimeoutSeconds)s "
            + "(accepted range 1...\(MCPConstants.maxStartupTimeoutSeconds))")
        return nil
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var map: [String: [String: Any]] = [:]
            for server in servers {
                // 双形态全字段回写（M4-B B1 清单外④修复：http 条目保存不得
                // 静默抹掉 stdio 条目字段；nil/空集合键省略——保持既有 http
                // 条目字节形态不变）。
                var entry: [String: Any] = ["enabled": server.enabled]
                if let url = server.url { entry["url"] = url }
                if !server.headers.isEmpty { entry["headers"] = server.headers }
                if let command = server.command { entry["command"] = command }
                if !server.args.isEmpty { entry["args"] = server.args }
                if !server.env.isEmpty { entry["env"] = server.env }
                if let cwd = server.cwd { entry["cwd"] = cwd }
                if let seconds = server.startupTimeoutSeconds {
                    entry["startupTimeoutSeconds"] = seconds
                }
                if let note = server.note { entry["note"] = note }
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
    /// 读侧 FIX 1 纪律在配置消费面的延伸）。failures 结构化携带 server 名
    /// （M4-A 验收增补：MCPLastActivationStore 逐 server 记录失败原因）。
    func resolvedClientConfigs()
        -> (configs: [MCPClientConfig], failures: [(server: String, reason: String)]) {
        var configs: [MCPClientConfig] = []
        var failures: [(server: String, reason: String)] = []
        for entry in servers where entry.enabled {
            do {
                configs.append(try clientConfig(for: entry))
            } catch {
                failures.append((entry.id, String(describing: error)))
            }
        }
        return (configs, failures)
    }

    // MARK: - 配置→连接配置（凭据注入缝）

    /// serverName/url/command 形态校验 + Keychain token 注入 Authorization 头
    /// （条目显式 headers 的 Authorization 优先——用户自带凭据形态不覆写）。
    /// M4-B B1：stdio 变体分支（dsh index.ts:50-73 StdioConfig 对应——
    /// command 必填非空；args/env 已在 entry() 解析层类型收窄；cwd 可空）。
    func clientConfig(for entry: MCPServerEntry) throws -> MCPClientConfig {
        guard MCPClientConfig.isValidServerName(entry.id) else {
            throw MCPConfigurationError(
                "mcp-server \"\(entry.id)\": serverName 必须匹配 [A-Za-z0-9_-]{1,32}")
        }
        if let command = entry.command {
            guard !command.isEmpty else {
                throw MCPConfigurationError(
                    "mcp-server \"\(entry.id)\": command 不能为空")
            }
            return MCPClientConfig(
                transport: .stdio(command: command, args: entry.args,
                                  env: entry.env, cwd: entry.cwd),
                serverName: entry.id)
        }
        guard let urlString = entry.url,
              let url = URL(string: urlString),
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
        return MCPClientConfig(transport: .streamableHTTP(url: urlString, headers: headers),
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
