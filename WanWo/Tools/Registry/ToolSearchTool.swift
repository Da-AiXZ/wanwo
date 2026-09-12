//
//  ToolSearchTool.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/tools/handlers/tool_search.rs
//  （ToolSearchHandler：handle_call :191-227 逐式对拍——query 非空校验 :206-211、
//  limit 默认 8 :212、limit>0 校验 :214-218、零语料回空 :220-222、search+输出
//  :224-226；ToolSearchHandlerCache :50-130——简化为语料全等缓存）+
//  handlers/tool_search_spec.rs:16-105（create_tool_search_tool：基座 description
//  与 parameters schema 逐字端口；来源清单 512KB 渲染 = C7，本件取 Omit 变体基座）+
//  tools/src/tool_discovery.rs:7（TOOL_SEARCH_DEFAULT_LIMIT = 8）。
//  F023 语义（10-design:397-403/:648）：Deferred 工具注册即可执行，不进请求
//  tools 数组；模型经本元工具（本地 BM25）按需发现，命中 spec 回注后下一轮
//  即可调用（C5 激活面）。
//  平台差异登记：
//    · codex 查询空/limit 0 走 FunctionCallError::RespondToModel → WanWo 以
//      ToolOutput.failure 合成错误结果承载（文案逐字保真，§十三.2 不抛穿 loop）
//    · 中止/失败回空 output 保持配对（R5；codex parallel.rs:222 语义）
//    · ToolSearchOutput{tools:[LoadableToolSpec]}（namespace coalesce）→ WanWo
//      无 namespace 词汇，输出 = function spec object 的 JSON 数组文本
//    · 组装面（零 deferred 零开销、tryRegister 换手）= C2；本件只提供语料缝
//

import Foundation

/// tool_search 元工具（F023 环 4）。exposure = .direct（协议默认——元工具必须
/// 恒可调用，与 mcp_server_config 等「模型管理 MCP 的元工具」同一死锁防线，
/// 10-design 清单外暴露项 5）。
final class ToolSearchTool: AgentTool, @unchecked Sendable {

    let name = "tool_search"
    /// 基座 description（codex tool_search_spec.rs:93-95 Omit 变体逐字端口；
    /// C7 在其后追加来源清单段）。
    let description = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes "
        + "matching tools for the next model call.\n\nSome of the tools may not have been provided to you "
        + "upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP "
        + "tool discovery, always use `tool_search` instead of `list_mcp_resources` or "
        + "`list_mcp_resource_templates`."
    /// parameters schema（codex tool_search_spec.rs:21-32 逐字端口）。
    let parameters = JSONValue.schemaObject(
        properties: [
            "query": .stringSchema(description: "Search query for deferred tools."),
            "limit": .numberSchema(description: "Maximum number of tools to return. Defaults to 8."),
        ],
        required: ["query"])

    /// codex tools/src/tool_discovery.rs:7 TOOL_SEARCH_DEFAULT_LIMIT。
    static let defaultLimit = 8

    /// 语料缝：组装面（C2）按当前 registry 的 deferred 工具集提供 ToolSearchInfo
    /// 列表（注册表变化 = provider 返回值变化 = 引擎重建，C7 换手语义复用）。
    private let corpusProvider: @Sendable () -> [ToolSearchInfo]

    private static let logger = AppLogger(category: "ToolSearchTool")

    // 语料全等缓存（codex ToolSearchHandlerCache 的简化形态——缓存命中条件 =
    // 语料 Equatable 全等；McpHandlerCache 双层缓存优化登记不做，brief 已登记）。
    private let lock = NSLock()
    private var cachedCorpus: [ToolSearchInfo] = []
    private var cachedEngine: ToolSearchEngine?

    init(corpusProvider: @escaping @Sendable () -> [ToolSearchInfo]) {
        self.corpusProvider = corpusProvider
    }

    /// codex ToolSearchHandler.supports_parallel_tool_calls → true。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // R5 fail closed：中止 → 回空 output 保持配对（codex parallel.rs:222：
        // 中止是空 output 非报错）。
        guard !Task.isCancelled else { return .success("[]") }

        let fields = args.objectValue ?? [:]
        // codex tool_search.rs:206-211（RespondToModel 文案逐字）。
        guard let query = fields["query"]?.stringValue else {
            return .failure("missing required parameter \"query\"", code: "INVALID_ARGS")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("query must not be empty", code: "INVALID_ARGS")
        }
        // codex :212-218：limit 默认 8；0 非法。
        let limit = fields["limit"]?.intValue ?? Self.defaultLimit
        guard limit > 0 else {
            return .failure("limit must be greater than zero", code: "INVALID_ARGS")
        }

        // codex :220-222：零语料回空（保持配对，非报错）。
        let corpus = corpusProvider()
        guard !corpus.isEmpty else { return .success("[]") }

        let engine = self.engine(for: corpus)
        let hits = engine.search(trimmed, limit: limit)
        let specs = hits.compactMap { hit in
            corpus.indices.contains(hit.id) ? corpus[hit.id].entry.output : nil
        }
        return .success(Self.renderOutput(specs))
    }

    /// 引擎缓存：语料 Equatable 全等即复用；否则重建（登记版
    /// ToolSearchHandlerCache——无 Immutable/Dynamic 双源，provider 全量快照）。
    private func engine(for corpus: [ToolSearchInfo]) -> ToolSearchEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine = cachedEngine, cachedCorpus == corpus {
            return engine
        }
        let engine = ToolSearchEngine(texts: corpus.map { $0.entry.searchText })
        cachedCorpus = corpus
        cachedEngine = engine
        Self.logger.info("tool_search engine rebuilt (corpus=\(corpus.count))")
        return engine
    }

    /// 命中输出渲染：function spec object 的 JSON 数组文本（JSONValue 编码
    /// object 按键排序——ERR-026 确定性纪律，逐次字节稳定）。
    private static func renderOutput(_ specs: [JSONValue]) -> String {
        guard !specs.isEmpty,
              let data = try? JSONEncoder().encode(JSONValue.array(specs)),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
