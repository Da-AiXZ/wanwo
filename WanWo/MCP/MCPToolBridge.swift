//
//  MCPToolBridge.swift
//  WanWo
//
//  【M4-A 件4 · 工具同步两阶段 + 命名契约】dsh tools.ts 移植（出处：
//  packages/mcp/mcp-client/src/tools.ts）：
//    · :47-57/:98-118 命名契约 publicToolName（mcp__<serverName>__<rawName>、
//      有损规范化+SHA256(serverName\0rawName) 前 12hex、干净名不加 hash）；
//    · :73-78 uncached tools/list（Swift SDK listTools 无 TS 侧 per-page
//      输出校验缓存——uncached 语义由 SDK 实现差异天然成立，平台适配）；
//    · :120-194 两阶段 syncTools（Phase1 fetch 构建下一世代不触碰注册表；
//      Phase2 swap 先注销旧代再注册新代，冲突整代回滚）。
//  执行语义（uncached tools/call、taskRequired 拒绝、isError→throw、
//  结果投影）= MCPToolExecuting 缝，件5 实现——与件3→件4 的
//  MCPToolSyncing 缝同一工作模式。装配差异：dsh 直接 import ToolRuntime
//  与 cordis ctx；WanWo 由实现自带对接 ToolRegistry 与 AppLogger
//  （件3 汇报已登记的形态差异，类型语义不动）。
//

import Foundation
import CryptoKit
import MCP

// MARK: - 执行缝（件5 实现）

/// dsh tools.ts:304-362 createExecutor 的缝化：执行语义（rawName 上 wire、
/// taskRequired 拒绝、isError 映射、结果投影）由件5 实现；同步结构（件4）
/// 只构建定义并持有缝引用。签名即件5 所需参数全量，件5 落地时不再改缝。
protocol MCPToolExecuting: Sendable {
    func execute(client: Client,
                 rawName: String,
                 taskRequired: Bool,
                 options: MCPToolBridgeOptions,
                 args: JSONValue,
                 context: ToolExecutionContext) async throws -> ToolOutput
}

// MARK: - 命名契约（tools.ts:47-57/98-118）

/// DeepSeek 函数名契约：至多 64 字符。线上协议常量，非配置（tools.ts:50）。
private let maxPublicNameLength = 64

/// 有损规范化时追加的 SHA-256 身份哈希 hex 位数（tools.ts:56）。
private let toolNameHashHexLength = 12

/// 仅 `[A-Za-z0-9_-]` 合法（tools.ts:53 INVALID_NAME_CHARS 的补集判定）。
private func isPublicNameChar(_ c: Character) -> Bool {
    ("a"..."z").contains(c) || ("A"..."Z").contains(c)
        || ("0"..."9").contains(c) || c == "_" || c == "-"
}

/// 模型可见公共名的确定性纯函数（dsh publicToolName 1:1，tools.ts:98-118）：
/// 干净情形 `mcp__<serverName>__<rawName>` 原样；字符替换或超长截断（任何
/// 有损规范化）时追加 `SHA256(serverName + "\0" + rawName)` 前 12 hex，使
/// 不同 MCP 身份永不坍缩为同一公共名。rawName 仅上 wire（tools/call），
/// 公共名永不解析还原（tools.ts:6-10 契约）。
func publicToolName(serverName: String, rawName: String) -> String {
    let joined = "mcp__\(serverName)__\(rawName)"                                // :113
    let normalized = String(joined.map { isPublicNameChar($0) ? $0 : "_" })      // :114
    if normalized == joined && normalized.count <= maxPublicNameLength {         // :115
        return normalized
    }
    // :116——\0 分隔符（createHash utf8 语义；Swift "\0" 即 NUL，utf8 编码）。
    let identity = Data("\(serverName)\0\(rawName)".utf8)
    let digest = SHA256.hash(data: identity)
    let hash = digest.prefix(toolNameHashHexLength / 2)
        .map { String(format: "%02x", $0) }.joined()
    // :117——截断到 64-12-1 字符 + "_" + 12hex。
    let keep = maxPublicNameLength - toolNameHashHexLength - 1
    return "\(normalized.prefix(keep))_\(hash)"
}

// MARK: - 工具定义（tools.ts:245-273 createDefinition 的注册面）

/// MCP server 工具的 WanWo ToolRegistry 定义（dsh ToolDefinition 注册面：
/// name/description/parameters；执行经 MCPToolExecuting 缝=件5）。
/// 协议默认取用：exposure=.direct（简报清单外检查：deferred 归 M4-C，本批
/// 按现有 ToolRegistry 正常注册）、isConcurrencySafe=false（fail closed——
/// MCP 工具并发安全性未知）、presentCall/presentResult=nil（M9 卡片族）。
struct WanWoMCPServerTool: AgentTool {
    let name: String
    let description: String
    let parameters: JSONValue
    /// dsh call timeout 的 AgentTool 预算镜像（F019 协作式 deadline；SDK 层
    /// 超时由件5 executor 内做——两层预算一致性随件5 呈报）。
    let timeoutMs: Int?

    private let client: Client
    private let rawName: String
    private let taskRequired: Bool
    private let options: MCPToolBridgeOptions
    private let executor: MCPToolExecuting

    init(publicName: String,
         description: String,
         parameters: JSONValue,
         timeoutMs: Int?,
         client: Client,
         rawName: String,
         taskRequired: Bool,
         options: MCPToolBridgeOptions,
         executor: MCPToolExecuting) {
        self.name = publicName
        self.description = description
        self.parameters = parameters
        self.timeoutMs = timeoutMs
        self.client = client
        self.rawName = rawName
        self.taskRequired = taskRequired
        self.options = options
        self.executor = executor
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        try await executor.execute(
            client: client, rawName: rawName, taskRequired: taskRequired,
            options: options, args: args, context: ctx)
    }
}

// MARK: - 两阶段同步（tools.ts:120-194 syncTools 1:1）

/// dsh syncTools 的 MCPToolSyncing 实现（件3 缝的落地）。ctx 语义（dsh
/// ctx.tools 注册表 + ctx.logger）由实现自带对接 ToolRegistry/AppLogger。
final class MCPToolBridge: MCPToolSyncing {

    private static let logger = AppLogger(category: "MCPToolBridge")

    private let registry: ToolRegistry
    private let executor: MCPToolExecuting

    /// - Parameters:
    ///   - registry: 环境级工具注册表（dsh ctx.tools 的 WanWo 对应物）。
    ///   - executor: 执行缝（件5 实现；冲突回滚后注销器仍可安全调用）。
    init(registry: ToolRegistry, executor: MCPToolExecuting) {
        self.registry = registry
        self.executor = executor
    }

    func syncTools(client: Client,
                   options: MCPToolBridgeOptions,
                   previous: MCPToolDisposers) async throws -> MCPToolDisposers {
        // ---- Phase 1: fetch（:150-175）——注册表零触碰地构建下一世代。
        // 数组保留 server 列表序（dsh Map 插入序 1:1——Phase2 按序注册）。
        var definitions: [(name: String, tool: AgentTool)] = []
        var seenNames = Set<String>()
        var cursor: String? = nil
        repeat {
            // :154——Swift SDK listTools 每次 send 全量解码、无 TS 侧 per-page
            // 输出校验缓存：uncached 语义由 SDK 实现差异天然成立（平台适配）。
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {                                                 // :155
                let publicName = publicToolName(
                    serverName: options.serverName, rawName: tool.name)              // :156
                guard seenNames.insert(publicName).inserted else {                   // :157
                    throw MCPConfigurationError(
                        "mcp-client(\(options.serverName)): server listed tool " +
                        "\"\(tool.name)\" more than once — invalid tool list")
                }
                definitions.append((publicName, try makeDefinition(
                    client: client, tool: tool,
                    publicName: publicName, options: options)))                      // :162-172
            }
            cursor = page.nextCursor                                                 // :174
        } while cursor != nil                                                        // :175
        // fetch 任一失败在此抛出，上一代注册集分毫未动（:127-128 契约）。

        // ---- Phase 2: swap（:177-193）——先注销上一代，再注册新代。
        for dispose in previous.values { dispose() }                                 // :178
        var disposers: MCPToolDisposers = [:]
        do {
            for (publicName, definition) in definitions {
                disposers[publicName] = try registry.tryRegister(definition)         // :182
            }
        } catch {
            // :184-188——`mcp__<serverName>__` 限定名上的冲突只可能是外来注册
            // 占据了本 server 的命名空间。整代回滚：模型只见完整世代或零工具，
            // 绝不部分（:185-187 注释语义）。
            for dispose in disposers.values { dispose() }
            // :189
            Self.logger.error(
                "mcp-client(\(options.serverName)): tool registration failed, " +
                "no tools registered: \(String(describing: error))")
            // :190-191——初始严格同步可上抛使其父事务拒绝；常规重同步 contain
            // 返回空集。
            if options.registrationFailure == .throwError { throw error }
            return [:]
        }
        return disposers
    }

    /// dsh :162-172 createDefinition 调用的定义构建（注册面 1:1；执行面=缝）。
    private func makeDefinition(client: Client,
                                tool: Tool,
                                publicName: String,
                                options: MCPToolBridgeOptions) throws -> AgentTool {
        // SDK 0.12.1 的 Tool 未建模 execution.taskSupport（Tool 结构无该字段，
        // 上游缺口已呈报登记）→ taskRequired 信息不可得，本批恒 false；
        // 件5 的拒绝路径完整保留（当前不可达），SDK 升级后由真实值驱动。
        let taskRequired = false
        // inputSchema lossless 桥接（SDK Value 即 JSON 值类型；转换失败按
        // fetch 失败抛出→保持上一代不动，fail closed）。
        let schema = try JSONValue(tool.inputSchema)
        return WanWoMCPServerTool(
            publicName: publicName,
            description: tool.description ?? "",                                     // :167
            parameters: schema,
            timeoutMs: options.toolCallTimeoutMs,
            client: client,
            rawName: tool.name,
            taskRequired: taskRequired,
            options: options,
            executor: executor)
    }
}

// MARK: - Value 桥接

extension JSONValue {
    /// SDK Value → WanWo JSONValue（经 Codable lossless 桥接：Value 即 JSON
    /// 值类型，JSONEncoder/Decoder 往返；签名 throws 仅为 fail closed 严谨——
    /// 实际不可失败）。
    init(_ value: MCP.Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
