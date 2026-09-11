//
//  MCPConfig.swift
//  WanWo
//
//  【语义移植 · dsh · M4-A 件1】出处：packages/mcp/mcp-client/src/index.ts
//  （配置模型：:35 默认 toolCallTimeoutMs 60_000、:38 serverName 正则
//  ^[A-Za-z0-9_-]{1,32}$、:113-134 Config schema 默认值）+ connection.ts
//  :27-90（ReconnectConfig / RECONNECT_DEFAULTS / resolveReconnectPolicy
//  显式校验——重连配置错误在加载时使该实例失败，不影响已存在实例）。
//  本批仅 streamable-http 变体（stdio 分支归 M4-B，红线 R6）。
//  常量 MAX_TIMER_DELAY_MS = 2_147_483_647 取自 dsh schedule runtime.ts:22
//  （全仓唯一定义，dsh-timeout 出口同名常量）。
//

import Foundation

// MARK: - 共享常量（dsh 值 1:1，命名 Swift 化）

/// MCP 语义层共享常量（dsh 锚点见各行注释；R3：值不许动）。
enum MCPConstants {
    /// 默认单次工具调用超时（index.ts:35 DEFAULT_TOOL_CALL_TIMEOUT_MS）。
    static let defaultToolCallTimeoutMs = 60_000

    /// dsh 全局定时器上限（schedule runtime.ts:22 MAX_TIMER_DELAY_MS）——
    /// reconnect 延迟的校验上界（connection.ts:76-81）。
    static let maxTimerDelayMs = 2_147_483_647
}

// MARK: - 配置错误

/// MCP 配置错误（dsh `throw new Error(message)` 的 WanWo 形态；消息语义
/// 1:1——R3 错误文案语义不动）。
struct MCPConfigurationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - 重连配置（connection.ts:27-45）

/// 自动重连配置（dsh ReconnectConfig：字段可选=缺省走 RECONNECT_DEFAULTS）。
struct MCPReconnectConfig: Sendable, Equatable {
    /// 断线后自动重连（默认 true）。
    var enabled: Bool?
    /// 首次重连延迟 ms；每次连续失败翻倍（默认 500）。
    var initialDelayMs: Int?
    /// 退避封顶 ms；也是重置尝试预算的稳定窗口（默认 30_000）。
    var maxDelayMs: Int?
    /// 一次断线内连续失败上限，超过即放弃（默认 10）。
    var maxAttempts: Int?

    /// dsh RECONNECT_DEFAULTS（connection.ts:40-45，冻结默认 1:1）。
    static let defaults = MCPReconnectConfig(
        enabled: true, initialDelayMs: 500, maxDelayMs: 30_000, maxAttempts: 10)
}

extension MCPReconnectConfig: Codable {
    private enum Keys: String, CodingKey {
        case enabled, initialDelayMs, maxDelayMs, maxAttempts
    }

    /// dsh connection.ts:66-70 语义 1:1：未知键=配置错误，加载即抛
    /// （「程序化构造可能绕过 schema，每个键都要再判」）。Codable 合成解码
    /// 会静默忽略未知键、与 dsh「加载即报错」相悖，故逐键核对。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        for key in container.allKeys where Keys(rawValue: key.stringValue) == nil {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(key.stringValue) is not a reconnect option"))
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        initialDelayMs = try container.decodeIfPresent(Int.self, forKey: .initialDelayMs)
        maxDelayMs = try container.decodeIfPresent(Int.self, forKey: .maxDelayMs)
        maxAttempts = try container.decodeIfPresent(Int.self, forKey: .maxAttempts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(initialDelayMs, forKey: .initialDelayMs)
        try container.encodeIfPresent(maxDelayMs, forKey: .maxDelayMs)
        try container.encodeIfPresent(maxAttempts, forKey: .maxAttempts)
    }
}

// MARK: - 解析后策略（connection.ts:52-53）

/// 全量解析后的重连策略（connection.ts ResolvedReconnectPolicy——加载时
/// 定死，监督器只读）。
struct MCPReconnectPolicy: Sendable, Equatable {
    let enabled: Bool
    let initialDelayMs: Int
    let maxDelayMs: Int
    let maxAttempts: Int
}

// MARK: - 解析步骤（connection.ts:65-90）

/// dsh resolveReconnectPolicy 1:1：从原始 reconnect 配置到监督器实际运行的
/// 策略——每个默认值与边界在此再判一遍，配置错误使该实例在加载时失败
/// （fail closed；connection.ts:55-60 注释原文语义）。
enum MCPReconnectResolver {
    /// - Parameters:
    ///   - config: 原始 reconnect 配置；nil = 全默认。
    ///   - path: 诊断前缀（dsh 形如 `mcp-client(<serverName>): reconnect`）。
    static func resolve(_ config: MCPReconnectConfig?,
                        path: String) throws -> MCPReconnectPolicy {
        let defaults = MCPReconnectConfig.defaults
        let enabled = config?.enabled ?? defaults.enabled!
        let initialDelayMs = config?.initialDelayMs ?? defaults.initialDelayMs!
        let maxDelayMs = config?.maxDelayMs ?? defaults.maxDelayMs!
        let maxAttempts = config?.maxAttempts ?? defaults.maxAttempts!
        // connection.ts:76-78：正的有限数值且 ≤ MAX_TIMER_DELAY_MS。
        // （Swift Int 恒有限，「有限」半边由类型结构保证。）
        guard initialDelayMs > 0, initialDelayMs <= MCPConstants.maxTimerDelayMs else {
            throw MCPConfigurationError(
                "\(path).initialDelayMs must be a positive finite number no greater than \(MCPConstants.maxTimerDelayMs)")
        }
        // connection.ts:79-81
        guard maxDelayMs > 0, maxDelayMs <= MCPConstants.maxTimerDelayMs else {
            throw MCPConfigurationError(
                "\(path).maxDelayMs must be a positive finite number no greater than \(MCPConstants.maxTimerDelayMs)")
        }
        // connection.ts:82-84
        guard initialDelayMs <= maxDelayMs else {
            throw MCPConfigurationError(
                "\(path).initialDelayMs must be less than or equal to maxDelayMs")
        }
        // connection.ts:85-87：正整数（Swift Int 恒整数，保 ≥1）。
        guard maxAttempts >= 1 else {
            throw MCPConfigurationError(
                "\(path).maxAttempts must be a positive integer")
        }
        return MCPReconnectPolicy(
            enabled: enabled, initialDelayMs: initialDelayMs,
            maxDelayMs: maxDelayMs, maxAttempts: maxAttempts)
    }
}

// MARK: - 客户端配置（index.ts:75-98 streamable-http 分支）

/// 传输变体（dsh index.ts:97-98 Config 联合；本批只有 streamable-http，
/// stdio 分支随 M4-B 追加）。
enum MCPTransport: Sendable, Equatable {
    /// Streamable HTTP（SSE）（index.ts:75-95 StreamableHttpConfig）。
    case streamableHTTP(url: String, headers: [String: String])
}

/// 单个 MCP server 的连接配置（index.ts:76-95 StreamableHttpConfig 的
/// WanWo 形态；默认值=index.ts:113-134 schema 默认 1:1）。
struct MCPClientConfig: Sendable, Equatable {
    /// 传输变体与端点。
    var transport: MCPTransport
    /// 稳定本地命名空间（`mcp__<serverName>__<rawName>` 的 serverName 段）。
    var serverName: String
    /// 单次工具调用超时 ms（index.ts:121/131 默认 60_000）。
    var toolCallTimeoutMs: Int = MCPConstants.defaultToolCallTimeoutMs
    /// 初始连接或工具同步失败时是否使激活失败（index.ts:69-70/132 默认 false）。
    var failOnStartupError: Bool = false
    /// 自动重连策略；nil = 全默认（index.ts:93-94/133）。
    var reconnect: MCPReconnectConfig? = nil

    /// serverName 形态校验（index.ts:38 SERVER_NAME_PATTERN =
    /// `^[A-Za-z0-9_-]{1,32}$`，刻意小于公共工具名预算 64）。
    static func isValidServerName(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
