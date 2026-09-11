//
//  McpClient.swift
//  WanWo
//
//  【M4-A 件1 · 骨架】dsh index.ts:146-188 apply 语义的 WanWo 承接点：
//    ①加载即 resolveReconnectPolicy（index.ts:150——重连配置错误使本实例
//      加载即失败，任何 effect 注册之前）；
//    ②serverName 命名空间预留（index.ts:152-168——重复在加载时报错且不
//      影响已存在实例）；
//    ③连接监督（世代模型/退避/5s 世代关闭超时）随件3 落入本类型（dsh =
//      startConnection 持有 client/transport 世代、重连循环与活注册集）；
//      Streamable HTTP 传输接线随件2；工具同步随件4；资源三元随件8；
//      elicitation 随件9。
//  一个 McpClient 一生服务一个 server（dsh index.ts:4-5 每实例一连一
//  server 的语义）。
//

import Foundation

/// 单个 MCP server 的受监督客户端（dsh connection.ts ConnectionHandle 的
/// WanWo 形态；世代模型见件3）。
final class McpClient: @unchecked Sendable {
    /// 连接配置（resolve 后只读）。
    let config: MCPClientConfig
    /// 解析后的重连策略（connection.ts:65-90——加载时定死，监督器只读）。
    let reconnectPolicy: MCPReconnectPolicy
    /// 诊断标签（connection.ts:124 `mcp-client(<serverName>)` 1:1）。
    let label: String

    /// 命名空间注册表（所有 McpClient 实例共享一张表——dsh 模块级 WeakMap）。
    private let registry: MCPNamespaceRegistry
    /// 所有者身份键（dispose 释放预留时使用；弱引用语义见 registry 注）。
    private let ownerID: ObjectIdentifier

    /// 加载校验 + 命名空间预留（index.ts:146-168 apply 前半 1:1——任何错误
    /// 使本实例在加载时失败，且不影响已存在实例）。
    ///
    /// - Parameters:
    ///   - config: 连接配置（streamable-http）。
    ///   - registry: 命名空间注册表（通常 = 环境级单例）。
    ///   - owner: 作用域所有者（dsh scopeOf(ctx) ?? ctx.root 的 WanWo 对应物，
    ///     通常为装载 server 集的环境对象）。
    init(config: MCPClientConfig,
         registry: MCPNamespaceRegistry,
         owner: AnyObject) throws {
        // serverName 形态校验（index.ts:116/127 .pattern(SERVER_NAME_PATTERN)）。
        guard MCPClientConfig.isValidServerName(config.serverName) else {
            throw MCPConfigurationError(
                "mcp-client: serverName \"\(config.serverName)\" must match [A-Za-z0-9_-]{1,32}")
        }
        // ① index.ts:150——reconnect 配置错误在加载时抛出（任何 effect 之前）。
        let policy = try MCPReconnectResolver.resolve(
            config.reconnect,
            path: "mcp-client(\(config.serverName)): reconnect")
        // ② index.ts:152-168——命名空间预留（重复=本实例加载失败）。
        try registry.reserve(owner: owner, serverName: config.serverName)
        self.config = config
        self.reconnectPolicy = policy
        self.label = "mcp-client(\(config.serverName))"
        self.registry = registry
        self.ownerID = ObjectIdentifier(owner)
    }

    /// 释放命名空间预留（index.ts:167 dispose 回调；连接监督 dispose 随件3
    /// 在此之上补世代关闭与工具注销）。
    func releaseNamespace() {
        registry.release(ownerID: ownerID, serverName: config.serverName)
    }
}
