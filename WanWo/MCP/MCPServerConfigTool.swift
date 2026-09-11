//
//  MCPServerConfigTool.swift
//  WanWo
//
//  【M4-B B7 块1 · AI 配置工具】mcp_server_config——模型侧的 MCP server
//  配置查询/写入缝（lead 派单四块之一）。设计定案（B7 派单+review 口径）：
//    · 白名单单字段：startup_timeout_seconds（1-900 整数，锚点=minis
//      config.py:32/:34、MCPConstants max/default，MCPServerStore.swift:158
//      读侧同值域）——其余配置面（command/args/env/cwd/凭据）不开放。
//    · 省略 startup_timeout_seconds = 纯查询：查询无门（dsh fs-sandbox
//      index.ts:1-27「Reads pass through untouched」语义——围栏只拦
//      mutation，read-only 档下查询照常）。
//    · 写入走审批缝（P1-3）：SandboxGate.resolveMode（SandboxGate.swift:64）
//      成对校验→approveEscalation 四值结算；standing 模式 read-only 拒绝
//      （denial marker + hint marker，SandboxEscalation.swift:54/:59 逐字，
//      code FS_SANDBOX_DENIED 对位 fs mapError SandboxGate.swift:160）；
//      'never' 政策确定性 rejected、ask→ApprovalCoordinator 弹窗；
//      standing danger-full-access 过 fence（「danger 直通」）。
//    · http 条目写入拒绝（fail closed——startup_timeout_seconds 是平台层
//      stdio 字段，对 streamable-http 无语义）。
//    · 生效语义（B7 返工修正）：config 是会话栈构建时捕获的快照
//      （supervisor.config let）——写入只落 servers.json（MCPServerStore.
//      upsert），仅对新会话栈生效，重连不拾取新值；结果文案向模型明示，
//      避免其引导用户重连→仍超时→困惑循环。
//    · 反馈闭环（B7 块2 配套）：stdio 慢启动超时错误的 hint 指向本工具
//      （MCPConnection.swift hint 文案）——模型看到超时→查本工具（含
//      lastActivation 的 spawn 失败原因，MCPLastActivationStore 直通本仓
//      错误文案）→调大→重连。
//    · @MainActor 访问：store（MCPServerStore）与 lastActivation
//      （MCPLastActivationStore）均为 @MainActor 隔离，工具体经
//      `await MainActor.run` 快照/写回；timeoutMs 600s（写入含真人审批
//      等待窗口，远宽于普通工具）。
//

import Foundation

/// mcp_server_config：MCP server 配置的查询/写入工具（B7 块1）。
struct MCPServerConfigTool: AgentTool {

    let name = "mcp_server_config"
    let description =
        "View or update the local configuration of a configured MCP server. " +
        "Without 'startup_timeout_seconds' this is a read-only query returning " +
        "the server's transport, configured and effective startup timeout, and " +
        "the last activation result (including the spawn failure reason when the " +
        "server failed to start). Provide 'startup_timeout_seconds' (1-900) to " +
        "update a stdio server's startup timeout — useful when a server times " +
        "out during startup. The change is persisted and takes effect for newly " +
        "spawned sessions only (configuration is captured as a snapshot when a " +
        "session stack is built — reconnecting does not pick it up). Updating a " +
        "configuration is a sandboxed mutation: it is " +
        "denied in read-only mode and may require user approval via " +
        "sandbox_permissions."

    /// schema：server 必填；startup_timeout_seconds 省略=查询；
    /// sandbox_permissions + justification = 审批缝字段
    /// （SandboxGate.escalationSchemaFields，noun 指明本工具的 mutation 名义）。
    /// 计算属性：字典合并无 `+` 运算符（Swift Dictionary 无 merge operator）
    /// ——properties 组装用 merge（冲突不可能：字段名不相交，取 current 兜底）。
    var parameters: JSONValue {
        var properties: [String: JSONValue] = [
            "server": .object([
                "type": .string("string"),
                "description": .string("MCP server name exactly as configured."),
            ]),
            "startup_timeout_seconds": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(MCPConstants.maxStartupTimeoutSeconds),
                "description": .string("New startup timeout in seconds " +
                                       "(1-\(MCPConstants.maxStartupTimeoutSeconds)) " +
                                       "for stdio servers; omit to query without " +
                                       "changing anything."),
            ]),
        ]
        properties.merge(
            SandboxGate.escalationSchemaFields(noun: "MCP server configuration change")) {
            current, _ in current
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array([.string("server")]),
        ])
    }

    /// 协作式预算（F019）：写入路径含真人审批等待，给足 10 分钟；
    /// 查询路径远低于此（本地内存快照，即时返回）。
    let timeoutMs: Int? = 600_000

    private let store: MCPServerStore
    private let lastActivation: MCPLastActivationStore

    init(store: MCPServerStore, lastActivation: MCPLastActivationStore) {
        self.store = store
        self.lastActivation = lastActivation
    }

    // MARK: - AgentTool

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let params = args.objectValue ?? [:]
        // codex normalize_required_string 语义同款（MCPResourceTools.swift:147
        // ——trim+空归无，归一化后空即拒）。
        guard let server = MCPResourceTools.normalizeOptional(
            params["server"]?.stringValue) else {
            return .failure("server must be provided",
                            code: "MCP_INVALID_ARGUMENTS", name: "McpConfigError")
        }
        // 参数形态：null 视同省略（模型传 null 表示「不写」——宽松 wire
        // 类型纪律）；在场必须整型（浮点/字符串=参数失当，fail closed 拒绝
        // ——不静默降级为查询，否则模型误判写入已生效）。
        let requestedSeconds: Int?
        switch params["startup_timeout_seconds"] {
        case .none, .some(.null):
            requestedSeconds = nil
        case .some(.int(let value)):
            requestedSeconds = value
        case .some:
            return .failure(
                "mcp-client: startup_timeout_seconds must be an integer between 1 " +
                "and \(MCPConstants.maxStartupTimeoutSeconds)",
                code: "MCP_INVALID_ARGUMENTS", name: "McpConfigError")
        }

        // MainActor 快照（读）：条目 + 最近激活结果。查询无门——任何 standing
        // 模式下都放行（dsh「Reads pass through untouched」）。
        let snapshot = await MainActor.run { () -> (entry: MCPServerEntry?,
                                                    activation: MCPLastActivationStore.Entry?) in
            let entry = store.servers.first { $0.id == server }
            let activation = lastActivation.entry(for: server)
            return (entry, activation)
        }
        guard let entry = snapshot.entry else {
            return .failure("mcp-client: unknown MCP server \"\(server)\"",
                            code: "MCP_UNKNOWN_SERVER", name: "McpConfigError")
        }

        // ── 查询路径（无门）──────────────────────────────────────────
        guard let seconds = requestedSeconds else {
            return .success(Self.jsonText(.object([
                "server": .string(server),
                "transport": .string(entry.isStdio ? "stdio" : "http"),
                "enabled": .bool(entry.enabled),
                "startupTimeoutSeconds": entry.startupTimeoutSeconds.map { .int($0) } ?? .null,
                "effectiveStartupTimeoutSeconds":
                    .int(entry.startupTimeoutSeconds
                         ?? MCPConstants.defaultStartupTimeoutSeconds),
                "lastActivation": Self.activationJSON(snapshot.activation),
                "note": .string("startup_timeout_seconds is omitted — this was a " +
                                "query; provide it (1-" +
                                "\(MCPConstants.maxStartupTimeoutSeconds)) to update " +
                                "a stdio server's startup timeout."),
            ])))
        }

        // ── 写入路径（fail closed 前置校验 → 审批缝 → 落盘）─────────
        // 值域校验（1-900，与 MCPServerStore.swift:162 读侧同值域；越界拒绝
        // 而非静默回默认——写入面比读侧更严，fail closed）。
        guard (1...MCPConstants.maxStartupTimeoutSeconds).contains(seconds) else {
            return .failure(
                "mcp-client: startup_timeout_seconds must be an integer between 1 " +
                "and \(MCPConstants.maxStartupTimeoutSeconds), got \(seconds)",
                code: "MCP_INVALID_ARGUMENTS", name: "McpConfigError")
        }
        // http 条目写入拒绝（startup_timeout_seconds 对 streamable-http 无语义
        // ——fail closed，不静默接受）。
        guard entry.isStdio else {
            return .failure(
                "mcp-client: startup_timeout_seconds applies to stdio servers " +
                "only; \"\(server)\" is an HTTP (streamable-http) server",
                code: "MCP_INVALID_ARGUMENTS", name: "McpConfigError")
        }

        // 审批缝（P1-3）：成对校验→approveEscalation 四值结算。approver 缺失
        // /'never' 政策在 resolveMode 内确定性 rejected（fail closed）。
        let mode: SandboxMode
        switch await SandboxGate.resolveMode(tool: name, args: args,
                                             standingMode: ctx.sandboxMode,
                                             subject: "MCP server configuration change",
                                             callId: ctx.callId,
                                             approver: ctx.escalationApprover) {
        case .success(let resolved): mode = resolved
        case .failure(let failure):
            return .failure(failure.message, code: "SANDBOX_ESCALATION_ERROR",
                            name: "McpConfigError")
        }
        // standing read-only 拒绝（denial marker + hint 逐字，dsh mapError
        // SandboxGate.swift:160 形态——原文案整体替换，isError）。
        guard mode != .readOnly else {
            return .failure(sandboxDenialMarker(mode) + "\n"
                + escalationHintMarker("MCP server configuration change"),
                code: "FS_SANDBOX_DENIED", name: "McpConfigError")
        }

        // 落盘：写回前重读条目（fence 可能等待真人审批数分钟——审批期间
        // 条目可能被设置页改动，TOCTOU 防护：以重读态为准校验形态并打补丁，
        // 不用陈旧快照整体覆盖）。其余字段保留，仅替换 startup_timeout_seconds
        // （MCPServerStore.upsert 幂等覆盖 + 原子 persist）。
        // 重读后条目消失/已改形态 → 拒绝（fail closed，不做条件式半写）。
        let persisted = await MainActor.run { () -> Bool in
            guard let fresh = store.servers.first(where: { $0.id == server }),
                  fresh.isStdio else { return false }
            var updated = fresh
            updated.startupTimeoutSeconds = seconds
            store.upsert(updated)
            return true
        }
        guard persisted else {
            return .failure(
                "mcp-client: MCP server \"\(server)\" changed while the update " +
                "was pending approval — re-query with this tool and retry",
                code: "MCP_CONFIG_RACE", name: "McpConfigError")
        }

        return .success(Self.jsonText(.object([
            "server": .string(server),
            "transport": .string("stdio"),
            "startupTimeoutSeconds": .int(seconds),
            "effectiveStartupTimeoutSeconds": .int(seconds),
            "takesEffect": .string("for newly spawned sessions only — the " +
                                   "configuration is captured as a snapshot when " +
                                   "a session stack is built; start a new session " +
                                   "to apply"),
        ])))
    }

    /// 待执行卡意图（纯函数：依赖且仅依赖 args）。写入调用展示目标 server
    /// 与新值；查询只展示 server。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let params = args.objectValue ?? [:]
        guard let server = MCPResourceTools.normalizeOptional(
            params["server"]?.stringValue) else { return nil }
        if let seconds = params["startup_timeout_seconds"]?.intValue {
            return ToolCardIntent(kind: .generic, title: name,
                                  detail: "\(server) → startup \(seconds)s")
        }
        return ToolCardIntent(kind: .generic, title: name, detail: server)
    }

    // MARK: - 私有序列化

    /// lastActivation 条目 → JSONValue（无记录=null；时间本地时区 ISO8601
    /// 带偏移；message 已是 MCPLastActivationStore.sanitized 产物——spawn
    /// 失败原因直通本仓错误文案，模型可直接据此决定是否调大
    /// startup_timeout_seconds）。
    private static func activationJSON(_ entry: MCPLastActivationStore.Entry?) -> JSONValue {
        guard let entry else { return .null }
        var payload: [String: JSONValue] = [
            "succeeded": .bool(entry.succeeded),
            "time": .string(localTimestamp(entry.time)),
        ]
        if let message = entry.message {
            payload["message"] = .string(message)
        }
        return .object(payload)
    }

    /// 展示层本地时区时间戳（B9 验收反馈修正）：`.formatted(.iso8601)` 恒
    /// UTC——本地 00:49 显示 16:49，用户误判为旧记录。Entry.time 存储保持
    /// Date（绝对时刻）不变，仅此序列化点转本地时区+显式偏移（设置页
    /// MCPServersView 走 .dateTime FormatStyle 本地时区，无此问题）。
    /// 每调用现建 formatter（避免 static 非 Sendable 缓存；工具结果序列化
    /// 频度可忽略）。带偏移的 ISO8601 对模型同样可解析（不会引入歧义）。
    private static func localTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// JSONValue → 单行 JSON 文本（复用 MCPResourceTools.jsonText——internal
    /// 放宽先例=件12 collectPaginated；截断归管线 spill F037，本件不截）。
    private static func jsonText(_ value: JSONValue) -> String {
        MCPResourceTools.jsonText(value)
    }
}
