//
//  ToolSearchTool.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/tools/handlers/tool_search.rs
//  （ToolSearchHandler：handle_call :191-227 逐式对拍——query 非空校验 :206-211、
//  limit 默认 8 :212、limit>0 校验 :214-218、零语料回空 :220-222、search+输出
//  :224-226；ToolSearchHandlerCache :50-130——简化为语料全等缓存）+
//  handlers/tool_search_spec.rs:16-105（create_tool_search_tool：parameters
//  schema 逐字端口；C7 起 description 动态化 = 基座 + 来源清单渲染段——
//  Include 变体，WanWo 无 DeferredToolWorldState 特性词汇 → spec_plan.rs
//  :1396-1404 门控恒走 Include，取证见 ToolSearchSourceListing.swift 头；
//  渲染端口亦在彼文件）+
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
    /// description 三段式（codex tool_search_spec.rs:93-95 逐字拆解）：
    /// base + sourceSection（C7 来源清单渲染，codex :86-88 逐字）+
    /// discoveryInstructions。注意 Include 形态下 sourceSection 尾 \n 直接
    /// 衔接指引段（codex :87 format! 无额外空行）。
    private static let baseDescription =
        "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes "
        + "matching tools for the next model call."
    private static let discoveryInstructions =
        "Some of the tools may not have been provided to you upfront, and you should use this "
        + "tool (`tool_search`) to search for the required tools. For MCP tool discovery, always "
        + "use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`."
    /// 动态 description（缓存读取面）。死锁防线：ToolRegistry.schemas() 持
    /// registry 锁内调用本属性——缓存保证锁内零 registry 访问（corpusProvider
    /// → deferredTools() 会 NSLock 重入死锁，故 description 绝不现算）；
    /// 刷新只发生在语料换手时（= 来源集变化时，低频），同一注册集字节稳定
    /// （缓存前缀纪律：渲染纯函数 + 按名字节序，ToolSearchSourceListing）。
    var description: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedDescription
    }
    /// parameters schema（codex tool_search_spec.rs:21-32 逐字端口）。
    let parameters = JSONValue.schemaObject(
        properties: [
            "query": .stringSchema(description: "Search query for deferred tools."),
            "limit": .numberSchema(description: "Maximum number of tools to return. Defaults to 8."),
        ],
        required: ["query"])

    /// codex tools/src/tool_discovery.rs:7 TOOL_SEARCH_DEFAULT_LIMIT。
    /// ⚠️ 同步提醒（C1 review 登记级意见 2）：上方 parameters schema 中 limit
    /// 的 description 硬编码 "Defaults to 8."——若本值将来变更，必须同步改文案。
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
    /// C7：当前 description 渲染缓存（与 cachedCorpus 同源同手换新）。
    private var cachedDescription: String = ""

    init(corpusProvider: @escaping @Sendable () -> [ToolSearchInfo]) {
        self.corpusProvider = corpusProvider
        // C7：初始 description 由组装时语料快照渲染（init 在 registry 锁外
        // 调 provider——refresh() 组装序）。
        let initial = corpusProvider()
        self.cachedCorpus = initial
        self.cachedDescription = Self.makeDescription(initial)
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
        // C7：语料换手即 description 换新（来源集变化只发生在语料变化时）。
        cachedDescription = Self.makeDescription(corpus)
        Self.logger.info("tool_search engine rebuilt (corpus=\(corpus.count))")
        return engine
    }

    /// C7：description 三段合成（纯函数，同语料字节稳定）。
    private static func makeDescription(_ corpus: [ToolSearchInfo]) -> String {
        baseDescription
            + ToolSearchSourceListing.sourceSection(from: corpus.compactMap { $0.sourceInfo })
            + discoveryInstructions
    }

    /// C7：组装步随手同步（ToolSearchAssembly.refresh 每步以 registry 语料
    /// 快照调用；语料变化即同手刷新 description 缓存并失效引擎缓存——渲染
    /// 不滞后于注册面换代）。本方法锁内零 registry 访问，锁序 registry→tool
    /// 单向，无反转死锁面。
    func syncCorpus(_ corpus: [ToolSearchInfo]) {
        lock.lock()
        defer { lock.unlock() }
        guard cachedCorpus != corpus else { return }
        cachedCorpus = corpus
        cachedEngine = nil
        cachedDescription = Self.makeDescription(corpus)
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
