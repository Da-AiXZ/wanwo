//
//  MCPResourceTools.swift
//  WanWo
//
//  【M4-A 件8 · resources 三元元工具】参照物=codex 资源桥（dsh 无此件——
//  dsh mcp-client 只同步 tools；gap3 缺口 3 的补齐形态，analysis/
//  06-codex-gap3-mcp-full-primitives.md §4.7+§八.2/§八.7）：
//    · list_mcp_resources(server?, cursor?)——不指定 server 时聚合全部
//      server 并按名排序（codex ListMcpResourcesHandler 形态），指定时
//      cursor 透传翻页；
//    · list_mcp_resource_templates(server?)——聚合/单 server 均拉全页
//      （codex handler 无 cursor 参数）；
//    · read_mcp_resource(server, uri)——双必填，contents JSON 透出
//      （codex：输出 JSON 序列化后按截断策略截断——截断归 WanWo 管线
//      spill（F037），本件不截）。
//  防护常量（codex pagination §4.3/§七.9）：100 页/2048 项/cursor 64KB
//  硬上限+默认分页超时 30s——恶意或失控 server 不拖死宿主。
//  协议方法（MCP 规范 2025-06-18）：resources/list / resources/templates/
//  list / resources/read。wire 解码沿用件5 信任边界纪律（宽松 Value?+
//  缺失/非数组→空，z.record 哲学同款）。
//  平台适配/设计呈报（汇报逐项）：连接访问缝 MCPResourceConnecting（实现
//  归多 server 装配）；请求级失败经 reportRequestFailure 回传监督器（裁决①
//  语义，isCurrent 幂等）；聚合模式 cursor 不支持（要求显式 server）；错误
//  码/描述文案自创（codex 原文未收录）；output JSON 信封 {server, resource}
//  自创（read 需 server 寻址，列表必须携带来源）；isConcurrencySafe 默认
//  false（与 MCP 工具族一致，fail closed）。
//

import Foundation
import MCP

// MARK: - 防护常量（codex pagination §4.3/§七.9）

/// 分页/条目/cursor 硬上限（codex MAX_MCP_CATALOG_PAGES=100 /
/// MAX_MCP_CATALOG_ITEMS=2048 / cursor 64KB；30s=codex 默认分页超时）。
enum MCPResourceGuard {
    /// 单 server 单次列取的最大页数。
    static let maxPages = 100
    /// 单次聚合列取的最大条目数（超出截断，truncated 标记）。
    static let maxItems = 2048
    /// cursor 参数最大字节数（UTF-8）。
    static let maxCursorBytes = 64 * 1024
    /// 单请求看门狗超时（codex 默认分页超时 30s；=AgentTool.timeoutMs，
    /// 双层预算一致=件5 惯例）。
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

    /// 构建三元（顺序即 codex handler 清单序）。注册归装配点。
    static func makeAll(connections: MCPResourceConnecting) -> [AgentTool] {
        [ListMcpResourcesTool(connections: connections),
         ListMcpResourceTemplatesTool(connections: connections),
         ReadMcpResourceTool(connections: connections)]
    }

    // MARK: 公共执行底座

    /// 单请求看门狗竞速（件5 callToolUncached 同款形态，泛型化；双层预算
    /// =requestTimeoutMs）。请求级失败以 MCPRequestLevelFailure 标记包裹，
    /// 供调用方分类上报。
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

    /// Value? → [JSONValue]（宽松：缺失/null→空、非数组→空——件5 信任边界
    /// 哲学同款，声明 required 的字段在 server 有 bug 时可能缺席）。
    private static func items(_ raw: Value?) throws -> [JSONValue] {
        guard let raw else { return [] }
        let converted = try JSONValue(raw)
        if case .array(let arr) = converted { return arr }
        return []
    }

    /// JSONValue → 单行 JSON 文本（codex「输出 JSON 序列化」形态）。
    private static func jsonText(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    /// cursor 参数校验（64KB 硬上限；聚合模式禁 cursor——cursor 是 server
    /// 不透明页游标，跨 server 无意义，fail closed 拒绝而非静默忽略）。
    private static func validateCursor(_ cursor: String?) -> ToolOutput? {
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
        let description =
            "List resources exposed by connected MCP servers. Omit 'server' to " +
            "aggregate resources from every server (sorted by server name; the " +
            "server owning each resource is included per entry), or pass 'server' " +
            "to list a single server with pagination via 'cursor'. Use " +
            "'read_mcp_resource' to fetch a resource's contents."
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "cursor": .object(["type": .string("string")]),
            ]),
        ])
        /// 协作式预算（F019）=内部看门狗同值（双层一致=件5 惯例）。
        let timeoutMs: Int? = MCPResourceGuard.requestTimeoutMs

        private let connections: MCPResourceConnecting

        init(connections: MCPResourceConnecting) {
            self.connections = connections
        }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            let params = Self.argsObject(args)
            let server = params["server"]?.stringValue
            let cursor = params["cursor"]?.stringValue
            if let rejection = Self.validateCursor(cursor) { return rejection }
            // 聚合模式禁 cursor（fail closed，见 validateCursor 注）。
            if server == nil, cursor != nil {
                return .failure("mcp-client: 'cursor' requires 'server' — aggregate " +
                                "listing fetches every page up to the guard limits",
                                code: "MCP_CURSOR_REQUIRES_SERVER", name: "McpResourceError")
            }

            if let server {
                // 单 server：cursor 透传翻页（codex「指定时支持翻页」）。
                guard connections.serverNames().contains(server) else {
                    return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                    code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
                }
                do {
                    let page = try await Self.call(connections, serverName: server,
                                                   request: RawListResources.request(
                                                       RawCursorParams(cursor: cursor)))
                    let entries = try Self.items(page.resources).map { item in
                        JSONValue.object(["server": .string(server), "resource": item])
                    }
                    var result: [String: JSONValue] = ["resources": .array(entries)]
                    if let nextCursor = page.nextCursor {
                        result["nextCursor"] = .string(nextCursor)
                    }
                    return .success(Self.jsonText(.object(result)))
                } catch {
                    return .failure("mcp-client(\(server)): \(String(describing: error))",
                                    code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
                }
            }

            // 聚合：全部 server 按名排序，逐 server 拉全页（页数/条目双上限）；
            // 单 server 失败记入 errors 继续（部分结果可见，模型可对指定 server
            // 重试）。
            var entries: [JSONValue] = []
            var errors: [JSONValue] = []
            var truncated = false
            fetchLoop: for name in connections.serverNames().sorted() {
                var cursor: String? = nil
                var pages = 0
                while true {
                    if pages >= MCPResourceGuard.maxPages {
                        truncated = true
                        errors.append(.object([
                            "server": .string(name),
                            "error": .string("listing stopped after " +
                                             "\(MCPResourceGuard.maxPages) pages (guard limit)"),
                        ]))
                        continue fetchLoop
                    }
                    pages += 1
                    let page: RawListResources.Result
                    do {
                        page = try await Self.call(connections, serverName: name,
                                                   request: RawListResources.request(
                                                       RawCursorParams(cursor: cursor)))
                    } catch {
                        errors.append(.object([
                            "server": .string(name),
                            "error": .string(String(describing: error)),
                        ]))
                        continue fetchLoop
                    }
                    for item in (try? Self.items(page.resources)) ?? [] {
                        if entries.count >= MCPResourceGuard.maxItems {
                            truncated = true
                            break fetchLoop
                        }
                        entries.append(.object(["server": .string(name), "resource": item]))
                    }
                    cursor = page.nextCursor
                    if cursor == nil { break }
                }
            }
            let result: [String: JSONValue] = [
                "resources": .array(entries),
                "errors": .array(errors),
                "truncated": .bool(truncated),
            ]
            return .success(Self.jsonText(.object(result)))
        }
    }

    // MARK: list_mcp_resource_templates

    struct ListMcpResourceTemplatesTool: AgentTool {
        let name = "list_mcp_resource_templates"
        let description =
            "List resource templates (parameterized URI schemes) exposed by " +
            "connected MCP servers. Omit 'server' to aggregate templates from " +
            "every server (sorted by server name; the owning server is included " +
            "per entry), or pass 'server' to list a single server's templates."
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
            ]),
        ])
        let timeoutMs: Int? = MCPResourceGuard.requestTimeoutMs

        private let connections: MCPResourceConnecting

        init(connections: MCPResourceConnecting) {
            self.connections = connections
        }

        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
            // codex handler 无 cursor 参数——单/聚合模式均拉全页（上限封顶）。
            let params = Self.argsObject(args)
            let server = params["server"]?.stringValue

            if let server {
                guard connections.serverNames().contains(server) else {
                    return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                    code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
                }
                do {
                    let templates = try await Self.fetchAllTemplates(connections,
                                                                     serverName: server)
                    let entries = templates.map { item in
                        JSONValue.object(["server": .string(server), "template": item])
                    }
                    return .success(Self.jsonText(.object(["templates": .array(entries)])))
                } catch {
                    return .failure("mcp-client(\(server)): \(String(describing: error))",
                                    code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
                }
            }

            var entries: [JSONValue] = []
            var errors: [JSONValue] = []
            var truncated = false
            fetchLoop: for name in connections.serverNames().sorted() {
                do {
                    let templates = try await Self.fetchAllTemplates(connections,
                                                                     serverName: name)
                    for item in templates {
                        if entries.count >= MCPResourceGuard.maxItems {
                            truncated = true
                            break fetchLoop
                        }
                        entries.append(.object(["server": .string(name), "template": item]))
                    }
                } catch {
                    errors.append(.object([
                        "server": .string(name),
                        "error": .string(String(describing: error)),
                    ]))
                }
            }
            let result: [String: JSONValue] = [
                "templates": .array(entries),
                "errors": .array(errors),
                "truncated": .bool(truncated),
            ]
            return .success(Self.jsonText(.object(result)))
        }

        /// 单 server 全页拉取（页数上限封顶；条目上限由调用侧聚合统计）。
        private static func fetchAllTemplates(
            _ connections: MCPResourceConnecting, serverName: String
        ) async throws -> [JSONValue] {
            var collected: [JSONValue] = []
            var cursor: String? = nil
            var pages = 0
            while true {
                if pages >= MCPResourceGuard.maxPages {
                    throw MCPConfigurationError(
                        "mcp-client(\(serverName)): template listing stopped after " +
                        "\(MCPResourceGuard.maxPages) pages (guard limit)")
                }
                pages += 1
                let page = try await Self.call(connections, serverName: serverName,
                                               request: RawListResourceTemplates.request(
                                                   RawCursorParams(cursor: cursor)))
                collected += try Self.items(page.templates)
                cursor = page.nextCursor
                if cursor == nil { return collected }
            }
        }
    }

    // MARK: read_mcp_resource

    struct ReadMcpResourceTool: AgentTool {
        let name = "read_mcp_resource"
        let description =
            "Read the contents of one MCP resource. 'server' (the owning server " +
            "name as reported by 'list_mcp_resources') and 'uri' (the resource URI) " +
            "are both required. Returns the resource contents as JSON (text " +
            "contents carry 'text'; binary contents carry base64 'blob')."
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "server": .object(["type": .string("string")]),
                "uri": .object(["type": .string("string")]),
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
            guard let server = params["server"]?.stringValue, !server.isEmpty,
                  let uri = params["uri"]?.stringValue, !uri.isEmpty else {
                return .failure("mcp-client: 'server' and 'uri' are both required",
                                code: "MCP_INVALID_ARGUMENTS", name: "McpResourceError")
            }
            guard connections.serverNames().contains(server) else {
                return .failure("mcp-client: unknown MCP server \"\(server)\"",
                                code: "MCP_UNKNOWN_SERVER", name: "McpResourceError")
            }
            do {
                let result = try await Self.call(connections, serverName: server,
                                                 request: RawReadResource.request(
                                                     RawReadResourceParams(uri: uri)))
                // contents 信封自创（呈报）：{server, contents:[...]}——模型
                // 需 server+uri 二元组才能续读，来源随行。
                let contents = (try? Self.items(result.contents)) ?? []
                return .success(Self.jsonText(.object([
                    "server": .string(server),
                    "contents": .array(contents),
                ])))
            } catch {
                return .failure("mcp-client(\(server)): \(String(describing: error))",
                                code: "MCP_RESOURCE_REQUEST_FAILED", name: "McpResourceError")
            }
        }
    }
}
