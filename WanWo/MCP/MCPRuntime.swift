//
//  MCPRuntime.swift
//  WanWo
//
//  【M4-A 件11 · 装配点（M4-A 收口）】把件1-9 的全部缝实例化接通：
//    · 每 server 一 McpClient 实例（dsh index.ts apply 1:1——一生一连一
//      server）；命名空间所有者=本运行时（会话栈，MCPNamespaceRegistry 的
//      scope 语义：跨会话可复用同名 server、同栈内重复互斥）。
//    · 生命周期映射（呈报）：dsh environment=会话栈 的 WanWo 对应——每会话
//      栈一组连接，随栈销毁收尾；工具桥直接注册进本会话注册表（无跨代
//      client 引用悬挂问题）。
//    · 各缝落位：MCPToolBridge（registry+executor，imageProjector 恒 nil
//      本批=lead 派单）、MCPElicitationManager（router+authority+emitter
//      ——authority 接会话 PermissionCoordinator 旋钮=escalationApprover
//      同一读取面；emitter 接本会话 SessionWriter E1 写侧）、
//      MCPResourceConnecting 实现（serverNames/readyClient/reportRequest-
//      Failure 转发=件8 裁决①承诺的三 server 批次收口）。
//    · 激活不等会话栈（后台 TaskGroup 并发，cordis effect 并行对应）——
//      工具在初始同步完成时出现在注册表（dsh :184 await ready 的 WanWo
//      异步化，呈报）。
//

import Foundation
import MCP

// MARK: - elicitation authority 默认实现（件9 缝的装配半边）

/// policy 接会话权限旋钮（AppEnvironment.escalationApprover 同一读取面：
/// permission.knobs.approval）；prompt 自动批准恒 false=恒问人（件9 权限
/// 三档装配缝的默认档，fail closed——呈报）。
final class MCPSessionElicitationAuthority: MCPElicitationAuthority {
    private let permission: PermissionCoordinator

    init(permission: PermissionCoordinator) {
        self.permission = permission
    }

    func approvalPolicy() async -> ApprovalPolicy {
        permission.knobs.approval
    }

    func isPromptAutoApproved(serverName: String) async -> Bool {
        false
    }
}

// MARK: - 会话级 MCP 运行时

final class MCPRuntime: MCPResourceConnecting, @unchecked Sendable {

    private static let logger = AppLogger(category: "MCPRuntime")

    /// 一个已装配的 server 实例（装配后只读；收尾仅经 deactivate）。
    private struct Instance {
        let config: MCPClientConfig
        let client: McpClient
        let bridge: MCPToolBridge
    }

    /// 装配后只读（init 内两段式赋值：先空占位、实例构建完覆写——owner=self
    /// 需要全部存储属性先初始化完毕）。
    private var instances: [Instance] = []
    /// elicitation 决策链（件9；本会话栈内单例——router 供 M4-B UI 投递）。
    let elicit: MCPElicitationManager
    /// 激活状态记录器（App 级共享；写侧跳主 actor——@Published 主线程纪律）。
    private let lastActivation: MCPLastActivationStore
    /// - Parameters:
    ///   - configs: 已解析启用的连接配置（MCPServerStore.resolvedClientConfigs）。
    ///   - registry: 本会话工具注册表（工具桥注册目标）。
    ///   - namespaces: App 级命名空间注册表（dsh 模块级 WeakMap 对应）。
    ///   - permission: 本会话权限协调器（elicitation authority 读取面）。
    ///   - writer: 本会话事件写柄（E1 mcp/elicitation 事件汇）。
    ///   - lastActivation: 激活状态记录器（M4-A 验收增补方案甲——设置页
    ///     "上次激活"直显；每次会话栈构建都覆盖写最新结果）。
    init(configs: [MCPClientConfig],
         registry: ToolRegistry,
         namespaces: MCPNamespaceRegistry,
         permission: PermissionCoordinator,
         writer: SessionWriter,
         lastActivation: MCPLastActivationStore) {
        // E1 事件汇：写侧门（SessionWriter.append 内 schema 校验）fail closed
        // ——写入失败仅降级审计（AppLogger.warning），不影响决策链应答。
        let emitter: MCPElicitationEventEmitter = { [weak writer] payload in
            guard let writer else { return }
            do {
                _ = try await writer.append(
                    .extensionEvent(kind: MCPElicitationEvents.kind, payload: payload))
            } catch {
                Self.logger.warning(
                    "mcp/elicitation event write failed (audit degraded): " +
                    "\(String(describing: error))")
            }
        }
        self.elicit = MCPElicitationManager(
            router: MCPElicitationRouter(),
            authority: MCPSessionElicitationAuthority(permission: permission),
            eventEmitter: emitter)
        self.lastActivation = lastActivation
        var built: [Instance] = []
        for config in configs {
            do {
                // owner=self：同栈重复 serverName 加载即失败（dsh index.ts
                // :154-168 文案 1:1），跨会话栈互不影响（scope 级互斥语义）。
                let client = try McpClient(config: config,
                                           registry: namespaces,
                                           owner: self)
                let bridge = MCPToolBridge(
                    registry: registry,
                    executor: MCPToolExecutor(imageProjector: nil))   // 本批恒 nil（派单）
                built.append(Instance(config: config, client: client, bridge: bridge))
            } catch {
                Self.logger.error(
                    "mcp-server \(config.serverName): instance load failed: " +
                    "\(String(describing: error))")
            }
        }
        instances = built
    }

    // MARK: - 激活/停用

    /// 后台激活全部实例（每实例 activate=连接+初始工具同步 settle；失败仅
    /// 记日志——failOnStartupError 语义下该 server 无工具，会话栈继续，
    /// 平台适配呈报：dsh 使实例加载失败即插件失败，WanWo 会话栈不因单个
    /// MCP server 失败而整体降级）。
    func activateAll() async {
        await withTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask { [elicit, lastActivation] in
                    do {
                        try await instance.client.activate(toolSync: instance.bridge,
                                                           elicit: elicit)
                        // 激活成功记录（覆盖写=最新一次会话栈构建的结果）。
                        let name = instance.config.serverName
                        Task { @MainActor in
                            lastActivation.recordSuccess(serverName: name)
                        }
                    } catch {
                        let name = instance.config.serverName
                        let summary = MCPLastActivationStore.userFacingSummary(error)
                        Self.logger.error(
                            "mcp-server \(name): " +
                            "activation failed: \(String(describing: error))")
                        // 激活失败记录（用户可读摘要；设置页直读定位根因）。
                        Task { @MainActor in
                            lastActivation.recordFailure(serverName: name,
                                                         message: summary)
                        }
                    }
                }
            }
        }
    }

    /// 停用全部实例（世代关闭/静默/工具注销——dsh dispose 语义）。
    func deactivateAll() async {
        for instance in instances {
            await instance.client.deactivate()
        }
    }

    /// Swift 无 async deinit：后台收尾（fire-and-forget；命名空间弱键随
    /// owner 释放由 registry 惰性清退——WeakMap 语义兜底）。呈报登记。
    deinit {
        let instances = self.instances
        guard !instances.isEmpty else { return }
        Task {
            for instance in instances {
                await instance.client.deactivate()
            }
        }
    }

    // MARK: - MCPResourceConnecting（件8 三元元工具的连接缝实现）

    func serverNames() -> [String] {
        instances.map(\.config.serverName).sorted()
    }

    func readyClient(named serverName: String) async throws -> Client {
        guard let instance = instances.first(where: { $0.config.serverName == serverName }) else {
            throw MCPConfigurationError("mcp: unknown server \"\(serverName)\"")
        }
        return try await instance.client.readyClient()
    }

    /// 请求级失败上报转发（件8 裁决①收口：isCurrent 守卫保证幂等；未知
    /// server 静默忽略）。
    func reportRequestFailure(serverName: String, generation: Client) {
        instances.first(where: { $0.config.serverName == serverName })?
            .client.reportRequestFailure(generation: generation)
    }
}
