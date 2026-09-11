//
//  MCPResourceTools.swift
//  WanWo
//
//  【M4-A 件8 · resources 三元元工具】参照物=codex 资源桥源码（dsh 无此件；
//  repos/codex-rust-v0.153.0-alpha.6 逐文件取证，件8 review 五处返工后重对拍）：
//    · core/src/tools/handlers/mcp_resource.rs——args 规范化 :326-344
//      （normalize_optional_string=trim+空归无 / normalize_required_string=
//      trim 后空→"<field> must be provided"）、cursor 无 server 拒绝 :89-91、
//      信封 :132-194（单 server 顶层 server 字段 :143-149；read {server,uri,
//      flatten(result)} :188-194；camelCase :133）、官方 description/schema
//      属性文案 mcp_resource_spec.rs :25/:53/:82（1:1 adopt，替代初版自创）；
//    · mcp_resource/{list_mcp_resources,list_mcp_resource_templates}.rs——
//      两 list 共用 ListResourceArgs.target：**templates 同样暴露 cursor 且
//      单 server 透传翻页**（gap3 笔记「templates 无 cursor」有误，源码纠正）；
//      单 server 失败文案 "resources/list failed: {err}"（list :81、
//      templates :82、read :86）；
//    · codex-mcp/src/binding_clients.rs:80-156——聚合=逐 server
//      collect_paginated，单 server 失败 warn! 日志+静默跳过（:147-149），
//      无 errors 数组（件8 review 返工 1）；
//    · codex-mcp/src/pagination.rs——防护常量 :9-13（100 页/2048 项/cursor
//      64KB/默认分页超时 30s）、collect_paginated :27-80：页数超限 Err :44-48、
//      条目超限 Err :54-58（**per-collect=per-server 预算**，非全局）、
//      nextCursor 64KB 跟随前校验 :64-68（返工 4）、**重复 cursor 环检测
//      :69-71**、整段 collect 30s 超时 :76-79；超限=硬失败非 truncated
//      （pagination_tests.rs 实证，返工 2）。
//  平台差异登记（lead 裁决保留）：条目信封嵌套 {server, resource|template}
//  （codex serde flatten 平铺——信息等价，形态差异）；聚合并发 JoinSet→串行
//  （每请求已有看门狗，性能非语义）；错误码 MCP_* 走 ToolOutput.failure
//  既有通道（codex RespondToModel 纯文案）；截断归管线 spill（F037）。
//  连接访问缝 MCPResourceConnecting：实现归多 server 装配（M4-B/件11）；
//  请求级失败（MCPRequestLevelFailure 标记）→ reportRequestFailure 转监督器
//  （裁决①，isCurrent 幂等）后 rethrow；超时/取消不报。lead 裁决：工具调用
//  路径 M4-B 装配时同款收口。
//

import Foundation
import MCP

// MARK: - 防护常量（codex pagination.rs:9-13 1:1）

/// 分页/条目/cursor 硬上限（codex MAX_MCP_CATALOG_PAGES=100 /
/// MAX_MCP_CATALOG_ITEMS=2048 / MAX_MCP_PAGINATION_CURSOR_BYTES=64KB /
/// DEFAULT_MCP_PAGINATION_TIMEOUT=30s）。条目预算 per-collect（per-server）。
enum MCPResourceGuard {
    /// 单 server 单次 collect 的最大页数（pagination.rs:9）。
    static let maxPages = 100
    /// 单 server 单次 collect 的最大条目数（pagination.rs:10；per-collect）。
    static let maxItems = 2048
    /// cursor 参数与 server 返回 nextCursor 的最大字节数（UTF-8）。
    static let maxCursorBytes = 64 * 1024
    /// 默认分页超时（pagination.rs:13；=AgentTool.timeoutMs 双层一致，
    /// 件5 惯例；fetch-all 路径=整段 collect 预算、单页路径=单请求看门狗）。
    static let requestTimeoutMs = 30_000
}

// MARK: - 请求级失败标记（裁决①语义随缝的分类件）

/// 请求级失败（client.send/await 抛出）的标记包裹——看门狗超时与任务取消
/// 不包裹（连接健康信号只认请求级失败；监督器 isCurrent 守卫使并发上报
/// 幂等，over-report 无害）。
struct MCPRequestLevelFailure: Error {
    let underlying: any Error
}

// MARK: - 连接访问缝（实现归多 server 装配，M4-B/件11 落地）

/// 三元元工具对「全部已配置 MCP server 连接集」的访问缝（codex
/// McpResourceClient 的 WanWo 缩形：跟随最新连接代际，无订阅/事件面）。
protocol MCPResourceConnecting: Sendable {
    /// 已配置 server 名集合（工具侧自行 sorted）。
    func serverNames() -> [String]
    /// 等待指定 server 的当前连接世代就绪并返回该世代 client（实现侧经
    /// McpConnectionSupervisor.awaitReady；disposed/未激活/未知 server→抛，
    /// fail closed）。
    func readyClient(named serverName: String) async throws -> Client
    /// 请求级失败上报转发（实现侧按 serverName 定位监督器调
    /// reportRequestFailure(generation:)；isCurrent 守卫保证幂等——未知
    /// server/世代已换时静默忽略）。
    func reportRequestFailure(serverName: String, generation: Client)
}

// MARK: - 宽松 wire 类型（件5 信任边界纪律同款）

/// resources/list、resources/templates/list 的 params（MCP 规范
/// {cursor?: string}；synthesized Codable 缺省省略 null 字段）。
struct RawCursorParams: Codable, Sendable {
    let cursor: String?
}

/// resources/read 的 params（MCP 规范 {uri: string} 必填）。
struct RawReadResourceParams: Codable, Sendable {
    let uri: String
}

/// resources/list 宽松结果（resources 数组缺失/null/非数组→工具侧空集）。
enum RawListResources: Method {
    static let name = "resources/list"
    typealias Parameters = RawCursorParams
    struct Result: Codable, Hashable, Sendable {
        let resources: Value?
        let nextCursor: String?
    }
}

/// resources/templates/list 宽松结果。
enum RawListResourceTemplates: Method {
    static let name = "resources/templates/list"
    typealias Parameters = RawCursorParams
    struct Result: Codable, Hashable, Sendable {
        let templates: Value?
        let nextCursor: String?
    }
}

/// resources/read 宽松结果（contents: TextResourceContents|BlobResourceContents
/// 数组；文本块 {uri, mimeType?, text?}、blob 块 {uri, mimeType?, blob?}）。
enum RawReadResource: Method {
    static let name = "resources/read"
    typealias Parameters = RawReadResourceParams
    struct Result: Codable, Hashable, Sendable {
        let contents: Value?
    }
}

// MARK: - 三元元工具

/// 资源三元工具工厂（codex 三 handler 的 WanWo AgentTool 形态）。装配点经
/// registry.register 逐个注册（环境级稳定注册，非世代换手——元工具不随
/// server 工具世代重建）。
enum MCPResourceTools {

    private static let logger = AppLogger(category: "MCPResourceTools")

    /// 构建三元（顺序即 codex handler 清单序）。注册归装配点。
    static func makeAll(connections: MCPResourceConnecting) -> [AgentTool] {
        [ListMcpResourcesTool(connections: connections),
         ListMcpResourceTemplatesTool(connections: connections),
         ReadMcpResourceTool(connections: connections)]
    }

    // MARK: 参数规范化（codex mcp_resource.rs:326-344 1:1）

    /// normalize_optional_string：trim 后空串归无（codex :326-335）。
    /// required 语义（normalize_required_string :337-344）=归一化后空即拒，
    /// 文案 "<field> must be provided" 由调用点按字段名合成。
    static func normalizeOptional(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: 公共执行底座

    /// 单请求看门狗竞速（件5 callToolUncached 同款形态，泛型化；单页路径
    /// 预算=requestTimeoutMs）。请求级失败以 MCPRequestLevelFailure 标记
    /// 包裹，供调用方分类上报。
    private static func requestWithTimeout<M: Method>(_ client: Client,
                                                      _ request: Request<M>,
                                                      timeoutMs: Int) async throws -> M.Result {
        let box = MCPSettleOnce<Result<M.Result, any Error>>()
        Task {
            do {
                let context = try client.send(request)
                box.settle(.success(try await context.value))
            } catch {
                box.settle(.failure(MCPRequestLevelFailure(underlying: error)))
            }
        }
        let watchdog = Task { [timeoutMs] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            box.settle(.failure(MCPToolCallTimeoutError(timeoutMs: timeoutMs)))
        }
        let outcome = await withTaskCancellationHandler {
            await box.wait()
        } onCancel: {
            box.settle(.failure(CancellationError()))
        }
        watchdog.cancel()
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    /// 请求+失败上报收口：请求级失败→reportRequestFailure（裁决①）后原样
    /// rethrow；超时/取消直通不报（连接健康信号只认请求级）。
    private static func call<M: Method>(_ connections: MCPResourceConnecting,
                                        serverName: String,
                                        request: Request<M>) async throws -> M.Result {
        let client = try await connections.readyClient(named: serverName)
        do {
            return try await requestWithTimeout(client, request,
                                                timeoutMs: MCPResourceGuard.requestTimeoutMs)
        } catch let failure as MCPRequestLevelFailure {
            connections.reportRequestFailure(serverName: serverName, generation: client)
            throw failure.underlying
        }
    }

    /// codex collect_paginated（pagination.rs:27-80）的 Swift 移植：单 server
    /// 全页拉取，四重防护=硬失败（Err 语义，非截断）——页数上限 :44-48、
    /// 条目上限（per-collect）:54-58、nextCursor 64KB 跟随前校验 :64-68、
    /// 重复 cursor 环检测 :69-71；整段 collect 预算=requestTimeoutMs（:76-79
    /// tokio::time::timeout 对应=逐轮 deadline 检查，串行平台等价形态）。
    /// - Parameter fetch: 单页取回（cursor→[条目], nextCursor）。
    /// internal：件12 单测经 fetch 注入确定性多页序列（Client 无法离线伪造
    /// ——可见性放宽为可测性，语义零变更，呈报）。
    static func collectPaginated(connections: MCPResourceConnecting,
                                         serverName: String,
                                         method: String,
                                         fetch: @escaping @Sendable (String?) async throws
                                             -> ([JSONValue], String?)) async throws -> [JSONValue] {
        let deadline = Date().addingTimeInterval(
            TimeInterval(MCPResourceGuard.requestTimeoutMs) / 1000)
        var collected: [JSONValue] = []
        var cursor: String? = nil
        var seenCursors = Set<String>()
        var pageCount = 0
        while true {
            if pageCount == MCPResourceGuard.maxPages {                          // :44-48
                throw MCPConfigurationError(
                    "mcp-client(\(serverName)): \(method) exceeded the pagination " +
                    "limit of \(MCPResourceGuard.maxPages) pages")
            }
            pageCount += 1
            if Date() > deadline {                                               // :76-79
                throw MCPConfigurationError(
                    "mcp-client(\(serverName)): \(method) pagination timed out " +
                    "after \(MCPResourceGuard.requestTimeoutMs)ms")
            }
            let (items, nextCursor) = try await fetch(cursor)                    // :53
            if items.count > MCPResourceGuard.maxItems - collected.count {       // :54-58
                throw MCPConfigurationError(
                    "mcp-client(\(serverName)): \(method) exceeded the catalog " +
                    "limit of \(MCPResourceGuard.maxItems) items")
            }
            collected += items
            guard let nextCursor else { return collected }                       // :61-63
            if nextCursor.utf8.count > MCPResourceGuard.maxCursorBytes {         // :64-68
                throw MCPConfigurationError(
                    "mcp-client(\(serverName)): \(method) returned a pagination " +
                    "cursor exceeding \(MCPResourceGuard.maxCursorBytes) bytes")
            }
            if !seenCursors.insert(nextCursor).inserted {                        // :69-71
                throw MCPConfigurationError(
                    "mcp-client(\(serverName)): \(method) returned a repeated " +
                    "pagination cursor")
            }
            cursor = nextCursor
        }
    }

    /// Value? → [JSONValue]（宽松：缺失/null→空、非数组→空——件5 信任边界
    /// 哲学同款，声明 required 的字段在 server 有 bug 时可能缺席）。
    private static func items(_ raw: Value?) throws -> [JSONValue] {
        guard let raw else { return [] }
        let converted = try JSONValue(raw)
        if case .array(let arr) = converted { return arr }
        return []
    }

    /// JSONValue → 单行 JSON 文本（codex serialize_function_output :353 的
    /// 序列化面；截断归管线 spill F037，本件不截）。
    private static func jsonText(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    /// cursor 参数校验（64KB 硬上限；聚合模式禁 cursor——codex :89-91 原生
    /// 语义「cursor can only be used when a server is specified」，文案形态
    /// 保留本件版本，lead 件8 review 确认）。internal=件12 单测（可测性放宽）。
    static func validateCursor(_ cursor: String?) -> ToolOutput? {
        guard let cursor else { return nil }
        if cursor.utf8.count > MCPResourceGuard.maxCursorBytes {
            return .failure("mcp-client: cursor exceeds the \(MCPResourceGuard.maxCursorBytes) byte limit",
                            code: "MCP_CURSOR_TOO_LARGE", name: "McpResourceError")
        }
        return nil
    }

    /// 工具参数取 object（模型失当（裸值）时按 {} 走缺省路径，件5 :316-320
    /// 同款哲学）。
    private static func argsObject(_ args: JSONValue) -> [String: JSONValue] {
        args.objectValue ?? [:]
    }

    // MARK: list_mcp_resources

    struct ListMcpResourcesTool: AgentTool {
        let name = "list_mcp_resources"
        /// codex mcp_resource_spec.rs:25 官方 description 1:1。
        let description =
            "Lists resources provided by MCP servers. Resources allow servers " +
            "to share data that provides context to language models, such as " +
            "files, database schemas, or application-specific information. " +
            "Prefer resources over web search when possible."
        /// schema 属性文案=codex spec :9-20 1:1。
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object([
                    "type": .string("string"),
                    "description": .string("MCP server name. Omit to list resources " +
                                           "from every configured server."),
                ]),
                "cursor": .object([
                    "type": .string("string"),
                    "description": .string("Opaque cursor from a previous " +
                                           "list_mcp_resources call; omit for the first page."),
                ]),
            ]),
        ])
        /// 协作式预算（F019）=collect 预算同值（双层一致=件5 惯例）。
        let timeoutMs: Int? = MCPResourceGuard.requestTimeoutMs

        private let connections: MCPResourceConnecting

        init(connections: MCPResourceConnecting) {
            self.connections = connections
        }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            let params = Self.argsObject(args)
            // codex ListResourceArgs.normalized()（:69-74）——trim+空归无。
            let server = MCPResourceTools.normalizeOptional(params["server"]?.stringValue)
            let cursor = MCPResourceTools.normalizeOptional(params["cursor"]?.stringValue)
            if let rejection = MCPResourceTools.validateCursor(cursor) { return rejection }
            // codex :89-91——cursor 无 server 拒绝。
            if server == nil, cursor != nil {
                return .failure("mcp-client: 'cursor' requires 'server' — aggregate " +
                                "listing fetches every page up to the guard limits",
                                code: "MCP_CURSOR_REQUIRES_SERVER", name: "McpResourceError")
            }

            guard let server else {
                // 聚合（codex list_all_resources，binding_clients.rs:80-106）：
                // 逐 server collect_paginated，按 server 名排序拼接；单 server
                // 失败=warn 日志+静默跳过（collect_resource_results :147-149）。
                var entries: [JSONValue] = []
                for name in connections.serverNames().sorted() {
                    do {
                        let items = try await MCPResourceTools.collectAllResources(
                            connections, serverName: name)
                        entries += items.map { item in
                            JSONValue.object(["server": .string(name), "resource": item])
                        }
                    } catch {
                        MCPResourceTools.logger.warning(
                            "Failed to list resources for MCP server '\(name)': " +
                            "\(String(describing: error))")
                    }
                }
                // codex from_all_servers（:151-158）：server/nextCursor 缺省省略。
                return .success(MCPResourceTools.jsonText(.object(
                    ["resources": .array(entries)])))
            }

            // 单 server（codex :76-86）：cursor 透传单页翻页，顶层 server 字段
            // （from_single_server :143-149），nextCursor camelCase 透传。
            guard connections.serverNames().contains(server) else {
                return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
            }
            do {
                let page = try await MCPResourceTools.call(
                    connections, serverName: server,
                    request: RawListResources.request(RawCursorParams(cursor: cursor)))
                let entries = try MCPResourceTools.items(page.resources).map { item in
                    JSONValue.object(["server": .string(server), "resource": item])
                }
                var payload: [String: JSONValue] = [
                    "server": .string(server),
                    "resources": .array(entries),
                ]
                if let nextCursor = page.nextCursor {
                    payload["nextCursor"] = .string(nextCursor)
                }
                return .success(MCPResourceTools.jsonText(.object(payload)))
            } catch {
                // codex :81 文案 1:1（"resources/list failed: {err}"）。
                return .failure("resources/list failed: \(String(describing: error))",
                                code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
            }
        }
    }

    // MARK: list_mcp_resource_templates

    struct ListMcpResourceTemplatesTool: AgentTool {
        let name = "list_mcp_resource_templates"
        /// codex mcp_resource_spec.rs:53 官方 description 1:1。
        let description =
            "Lists resource templates provided by MCP servers. Parameterized " +
            "resource templates allow servers to share data that takes parameters " +
            "and provides context to language models, such as files, database " +
            "schemas, or application-specific information. Prefer resource " +
            "templates over web search when possible."
        /// schema 属性文案=codex spec :36-47 1:1。cursor 与 resources 同款
        /// （源码纠正：gap3 笔记「templates 无 cursor」有误——共用
        /// ListResourceArgs.target，单 server 透传翻页）。
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object([
                    "type": .string("string"),
                    "description": .string("MCP server name. Omit to list resource " +
                                           "templates from every configured server."),
                ]),
                "cursor": .object([
                    "type": .string("string"),
                    "description": .string("Opaque cursor from a previous " +
                                           "list_mcp_resource_templates call; omit for " +
                                           "the first page."),
                ]),
            ]),
        ])
        let timeoutMs: Int? = MCPResourceGuard.requestTimeoutMs

        private let connections: MCPResourceConnecting

        init(connections: MCPResourceConnecting) {
            self.connections = connections
        }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            let params = Self.argsObject(args)
            let server = MCPResourceTools.normalizeOptional(params["server"]?.stringValue)
            let cursor = MCPResourceTools.normalizeOptional(params["cursor"]?.stringValue)
            if let rejection = MCPResourceTools.validateCursor(cursor) { return rejection }
            if server == nil, cursor != nil {
                return .failure("mcp-client: 'cursor' requires 'server' — aggregate " +
                                "listing fetches every page up to the guard limits",
                                code: "MCP_CURSOR_REQUIRES_SERVER", name: "McpResourceError")
            }

            guard let server else {
                var entries: [JSONValue] = []
                for name in connections.serverNames().sorted() {
                    do {
                        let items = try await MCPResourceTools.collectAllTemplates(
                            connections, serverName: name)
                        entries += items.map { item in
                            JSONValue.object(["server": .string(name), "template": item])
                        }
                    } catch {
                        MCPResourceTools.logger.warning(
                            "Failed to list resource templates for MCP server '\(name)': " +
                            "\(String(describing: error))")
                    }
                }
                return .success(MCPResourceTools.jsonText(.object(
                    ["resourceTemplates": .array(entries)])))
            }

            guard connections.serverNames().contains(server) else {
                return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
            }
            do {
                let page = try await MCPResourceTools.call(
                    connections, serverName: server,
                    request: RawListResourceTemplates.request(RawCursorParams(cursor: cursor)))
                let entries = try MCPResourceTools.items(page.templates).map { item in
                    JSONValue.object(["server": .string(server), "template": item])
                }
                var payload: [String: JSONValue] = [
                    "server": .string(server),
                    // codex ListResourceTemplatesPayload 字段名（camelCase :133/:165）。
                    "resourceTemplates": .array(entries),
                ]
                if let nextCursor = page.nextCursor {
                    payload["nextCursor"] = .string(nextCursor)
                }
                return .success(MCPResourceTools.jsonText(.object(payload)))
            } catch {
                // codex :82 文案 1:1。
                return .failure(
                    "resources/templates/list failed: \(String(describing: error))",
                    code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
            }
        }
    }

    // MARK: read_mcp_resource

    struct ReadMcpResourceTool: AgentTool {
        let name = "read_mcp_resource"
        /// codex mcp_resource_spec.rs:82 官方 description 1:1。
        let description =
            "Read a specific resource from an MCP server given the server name " +
            "and resource URI."
        /// schema 属性文案=codex spec :64-75 1:1。
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object([
                    "type": .string("string"),
                    "description": .string("MCP server name exactly as configured. " +
                                           "Must match the 'server' field returned by " +
                                           "list_mcp_resources."),
                ]),
                "uri": .object([
                    "type": .string("string"),
                    "description": .string("Resource URI to read. Must be one of the " +
                                           "URIs returned by list_mcp_resources."),
                ]),
            ]),
            "required": .array([.string("server"), .string("uri")]),
        ])
        let timeoutMs: Int? = MCPResourceGuard.requestTimeoutMs

        private let connections: MCPResourceConnecting

        init(connections: MCPResourceConnecting) {
            self.connections = connections
        }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            let params = Self.argsObject(args)
            // codex normalize_required_string（:337-344）：归一化（trim+空归
            // 无）后空即拒，文案 "<field> must be provided"。
            guard let server = MCPResourceTools.normalizeOptional(
                params["server"]?.stringValue) else {
                return .failure("server must be provided",
                                code: "MCP_INVALID_ARGUMENTS", name: "McpResourceError")
            }
            guard let uri = MCPResourceTools.normalizeOptional(
                params["uri"]?.stringValue) else {
                return .failure("uri must be provided",
                                code: "MCP_INVALID_ARGUMENTS", name: "McpResourceError")
            }
            guard connections.serverNames().contains(server) else {
                return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
            }
            do {
                let result = try await MCPResourceTools.call(
                    connections, serverName: server,
                    request: RawReadResource.request(RawReadResourceParams(uri: uri)))
                // codex ReadResourcePayload（:188-194）：{server, uri, flatten
                // (result)}——uri 输入回显（件8 review 返工 3）；flatten→WanWo
                // contents 显式键（嵌套形态差异已登记）。
                let contents = (try? MCPResourceTools.items(result.contents)) ?? []
                return .success(MCPResourceTools.jsonText(.object([
                    "server": .string(server),
                    "uri": .string(uri),
                    "contents": .array(contents),
                ])))
            } catch {
                // codex :86 文案 1:1。
                return .failure("resources/read failed: \(String(describing: error))",
                                code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
            }
        }
    }

    // MARK: collect 调用面（单 server fetch-all）

    /// 单 server 资源全页拉取（collectPaginated 实例化：resources/list）。
    private static func collectAllResources(_ connections: MCPResourceConnecting,
                                            serverName: String) async throws -> [JSONValue] {
        try await collectPaginated(connections: connections, serverName: serverName,
                                   method: "resources/list") { cursor in
            let page = try await call(connections, serverName: serverName,
                                      request: RawListResources.request(
                                          RawCursorParams(cursor: cursor)))
            return (try items(page.resources), page.nextCursor)
        }
    }

    /// 单 server 模板全页拉取（collectPaginated 实例化：resources/templates/list）。
    private static func collectAllTemplates(_ connections: MCPResourceConnecting,
                                            serverName: String) async throws -> [JSONValue] {
        try await collectPaginated(connections: connections, serverName: serverName,
                                   method: "resources/templates/list") { cursor in
            let page = try await call(connections, serverName: serverName,
                                      request: RawListResourceTemplates.request(
                                          RawCursorParams(cursor: cursor)))
            return (try items(page.templates), page.nextCursor)
        }
    }
}
