//
//  McpClient.swift
//  WanWo
//
//  【M4-A 件1 · 骨架 + 件3 · 接线】dsh index.ts:146-188 apply 全语义：
//    ①加载即 resolveReconnectPolicy（index.ts:150——重连配置错误使本实例
//      加载即失败，任何 effect 注册之前）；
//    ②serverName 命名空间预留（index.ts:152-168——重复在加载时报错且不
//      影响已存在实例）；
//    ③activate（index.ts:173-184）：启动连接监督并等待首次连接+工具同步
//      settle；failOnStartupError=true 且失败时上抛（:185-187——调用方
//      决定实例失败，对应 Cordis 回滚语义）；返回首次尝试 outcome——
//      吞错场景（failOnStartupError=false）错误不上抛，由调用方据 outcome
//      判定记录成败（场景2 根因修复：dsh await ready promise 的 reason
//      在 WanWo 曾被丢弃，"activate() 未抛出"被误记成功）；
//    ④deactivate（index.ts:175-177 + :167）：Cordis 逆序 dispose——连接
//      监督 dispose 在先（世代关闭/静默/工具注销），命名空间释放在后。
//  工具同步经 MCPToolSyncing 缝注入（件4 提供实现；dsh 直接 import 的
//  syncTools，装配形态差异）。资源三元随件8；elicitation 决策链随件9
//  （activate(elicit:)——nil=不声明能力=fail closed）。
//  一个 McpClient 一生服务一个 server（dsh index.ts:4-5 每实例一连一
//  server 的语义）。
//

import Foundation
import MCP  // Client 类型（件11 MCPResourceConnecting 缝签名面；CI 工具链实证）

/// 单个 MCP server 的受监督客户端（dsh connection.ts ConnectionHandle 的
/// WanWo 形态；世代模型见 MCPConnection.swift）。
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

    /// 连接监督句柄（index.ts:173 startConnection；activate/deactivate
    /// 生命周期串行调用，仍加锁防御并发误用——fail closed）。
    private let lifecycleLock = NSLock()
    private var connection: McpConnectionSupervisor?

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

    /// 激活（index.ts:173-187 apply 后半 1:1）：启动连接监督，阻塞等待首次
    /// 连接+工具发现 settle（Cordis 消费者在 fiber 激活后立即观察到工具）。
    /// failOnStartupError=true 且首次尝试失败时上抛（回滚=调用方放弃本实例）；
    /// 否则错误已被监督器记日志、重连循环自主运转。
    ///
    /// - Parameter toolSync: 工具同步缝（件4 实现）。
    /// - Parameter elicit: elicitation 决策链缝（件9；nil=不声明能力——
    ///   fail closed，件5 imageProjector 同款装配纪律）。
    /// - Returns: 首次尝试 outcome（error 非 nil = 首次 connect+初始同步
    ///   未成功——吞错场景调用方据此记失败，场景2 根因修复的测试锚语义）。
    /// - Throws: 重复激活（fail closed，dsh apply 每实例一次）；或
    ///   failOnStartupError 语义下的首次失败（index.ts:186 文案 1:1）。
    @discardableResult
    func activate(toolSync: MCPToolSyncing,
                  elicit: MCPElicitationHandling? = nil) async throws -> MCPConnectionOutcome {
        let supervisor: McpConnectionSupervisor
        lifecycleLock.lock()
        if connection != nil {
            lifecycleLock.unlock()
            throw MCPConfigurationError("\(label): activate called twice — instance already active")
        }
        supervisor = McpConnectionSupervisor(
            config: config, policy: reconnectPolicy, toolSync: toolSync, elicit: elicit)
        connection = supervisor
        lifecycleLock.unlock()
        // index.ts:184 await connection.ready。
        let outcome = await supervisor.awaitReady()
        // index.ts:185-187——cause 无结构化对应物，消息内嵌（平台适配，汇报登记）。
        if let error = outcome.error, config.failOnStartupError {
            throw MCPConfigurationError(
                "\(label): initial connection or tool synchronization failed " +
                "(cause: \(String(describing: error)))")
        }
        // 吞错场景（failOnStartupError=false）错误随 outcome 返回——不再
        // 静默丢弃（dsh await ready promise reason 的 WanWo 对应消费点）。
        return outcome
    }

    /// 停用（index.ts:175-177 connection effect + :167 serverName effect）：
    /// Cordis 逆序 dispose——先停连接监督（停止重连、关世代、静默、注销
    /// 工具），再释放命名空间预留。
    func deactivate() async {
        lifecycleLock.lock()
        let supervisor = connection
        connection = nil
        lifecycleLock.unlock()
        await supervisor?.dispose()
        releaseNamespace()
    }

    /// 释放命名空间预留（index.ts:167 dispose 回调；由 deactivate 收尾调用，
    /// 亦可在未激活即丢弃时单独调用）。
    func releaseNamespace() {
        registry.release(ownerID: ownerID, serverName: config.serverName)
    }

    // MARK: 连接缝转发（M4-A 件11 MCPResourceConnecting 实现）

    /// 等待当前连接世代就绪并返回该世代 client（件8 readyClient 缝的实例
    /// 转发半边）。未激活/已停用→抛；世代在就绪等待后下行→抛（fail closed
    /// ——调用方按请求级失败路径处理）。
    func readyClient() async throws -> Client {
        lifecycleLock.lock()
        let supervisor = connection
        lifecycleLock.unlock()
        guard let supervisor else {
            throw MCPConfigurationError("\(label): not activated")
        }
        let outcome = await supervisor.awaitReady()
        if let error = outcome.error {
            throw error
        }
        guard let generation = supervisor.currentClient() else {
            throw MCPConfigurationError(
                "\(label): connection generation went down while awaiting readiness")
        }
        return generation
    }

    /// 请求级失败上报转发（件8 裁决①：监督器 isCurrent 守卫保证幂等）。
    func reportRequestFailure(generation: Client) {
        lifecycleLock.lock()
        let supervisor = connection
        lifecycleLock.unlock()
        supervisor?.reportRequestFailure(generation: generation)
    }
}
