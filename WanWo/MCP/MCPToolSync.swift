//
//  MCPToolSync.swift
//  WanWo
//
//  【M4-A 件3 · 工具同步缝】dsh tools.ts 的类型缝 1:1（出处：
//  packages/mcp/mcp-client/src/tools.ts:29-38）。dsh 的 syncTools 直接
//  import ToolRuntime 与 cordis Context；WanWo 以协议缝注入（件4 提供
//  实现），使连接监督（件3）与工具桥接（件4）解耦——装配形态差异，
//  类型与参数语义 1:1 不动。
//

import Foundation
import MCP

// MARK: - 冲突处置模式（tools.ts:32）

/// 注册表冲突的处置模式（dsh `registrationFailure: 'contain' | 'throw'`）。
/// 命名适配：dsh 字面量 `'throw'` 在 Swift 是关键字，映射为 `throwError`
/// （件3 汇报平台适配清单项）。
enum MCPRegistrationFailure: Sendable {
    /// 冲突被包含：跳过该工具、记日志，同步继续（containment 语义）。
    case contain
    /// 冲突使本次同步失败上抛（仅 startup 严格模式使用）。
    case throwError
}

// MARK: - 工具桥接选项（tools.ts:30-35）

/// dsh ToolBridgeOptions 1:1：同步时影响工具桥接行为的已解析选项。
struct MCPToolBridgeOptions: Sendable {
    /// 注册表冲突是包含还是使本次同步失败（tools.ts:32）。
    var registrationFailure: MCPRegistrationFailure
    /// 稳定本地命名空间（tools.ts:33；公共名 `mcp__<serverName>__<rawName>` 段）。
    var serverName: String
    /// 单次工具调用超时 ms（tools.ts:34；来自 config.toolCallTimeoutMs）。
    var toolCallTimeoutMs: Int
}

// MARK: - 同步世代状态（tools.ts:38）

/// 当前注册集的注销器，按公共工具名键控（dsh `ToolDisposers =
/// Map<string, () => void>` 1:1）。仅 enqueueSync 与 dispose 换手该映射
/// （connection.ts:142-143 注释语义；串行链保证无并发换手）。
typealias MCPToolDisposers = [String: @Sendable () -> Void]

// MARK: - 工具同步缝（tools.ts:144-149）

/// dsh `syncTools(client, ctx, opts, previous)` 的 WanWo 缝化：两阶段
/// 同步（先取列表构建下一世代、后换手注册集）由件4 实现；ctx 携带的
/// ToolRuntime 注册表与 logger 由实现自带，不进缝签名。
///
/// 实现契约（dsh tools.ts:150-149 语义，件4 落地）：
/// - 不得改动 `previous`（读旧传参，换手由调用方写回）；
/// - 返回的注销器键集 = 本世代实际注册的公共名全集。
protocol MCPToolSyncing: Sendable {
    func syncTools(client: Client,
                   options: MCPToolBridgeOptions,
                   previous: MCPToolDisposers) async throws -> MCPToolDisposers
}
