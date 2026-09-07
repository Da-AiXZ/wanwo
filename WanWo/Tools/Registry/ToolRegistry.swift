//
//  ToolRegistry.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/tools/src/index.ts（ToolDefinition /
//  ToolRuntime / ToolRestriction / ToolGuard 单调否定 / executionMode fail-closed 分类）
//  + 10-design §5.3（AgentTool 协议 / ToolRegistry F012 / exposure 预留）。
//  移植要点（附录 B #3/#5）：
//    · guard 单调否定是硬不变量：guard 只有 deny 结果，无 allow，后注册不可翻转先前否定
//    · executionMode fail-closed：未知/未声明/抛错的 isConcurrencySafe 一律 exclusive
//    · schema 只暴露 name/description/parameters（timeoutMs 等元数据永不上 wire）
//    · PTC 部分跳过——M5.4 才做（exposure .deferred 预留，不注册 ToolSearch）
//

import Foundation

// MARK: - 工具输出

/// 工具执行的 canonical 结果（dsh ToolExecutionResult 的文本形态子集：
/// content 以单文本块承载；结构化失败身份 name/code 随行——失败一律合成错误结果
/// 回注模型，绝不抛穿 loop，§十三.2）。
struct ToolOutput: Equatable, Sendable {
    var text: String
    var isError: Bool
    var errorName: String?
    var errorCode: String?
    /// 工具私有呈现载荷（lossless JSON；落 tool/result.meta）。
    var meta: JSONValue?

    static func success(_ text: String, meta: JSONValue? = nil) -> ToolOutput {
        ToolOutput(text: text, isError: false, errorName: nil, errorCode: nil, meta: meta)
    }

    static func failure(_ message: String,
                        code: String = "TOOL_ERROR",
                        name: String = "ToolError") -> ToolOutput {
        ToolOutput(text: "Error: \(message)", isError: true,
                   errorName: name, errorCode: code, meta: nil)
    }
}

// MARK: - 工具执行上下文

/// 工具执行上下文（dsh ToolRunContext 的 WanWo 形态：会话身份 + 工作区访问 +
/// UI 流式缝；取消经 Task.isCancelled 协作检查）。
struct ToolExecutionContext: Sendable {
    let sessionId: String
    let turn: Int
    let step: Int
    let callId: String
    /// 会话工作区桶的宿主直读根（§7.5 数据源纪律：不经 iSH fork）。
    let workspace: WorkspaceFileAccess
    /// spill 落盘（F037；>50KB 大结果）。
    let spill: SpillStore
    /// shell 输出流式缝（callId → 工具卡实时追加）。
    let onShellLine: @Sendable (_ callId: String, _ line: String) -> Void
    /// 一次性 LLM 直调缝（web_search / 摘要类工具用；走当前 adapter）。
    let completeLLM: @Sendable (_ prompt: String, _ system: String?) async throws -> String
}

// MARK: - 卡片呈现意图

/// 工具卡呈现意图（dsh presentCall/presentResult 纯函数的 M2 素净版；
/// 正式卡片族 = M9 对照 dsh Web UI）。
struct ToolCardIntent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case generic, terminal, file, search, web, diff
    }

    var kind: Kind
    var title: String
    var detail: String?

    init(kind: Kind = .generic, title: String, detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

// MARK: - AgentTool 协议

/// 内置工具协议（dsh ToolDefinition 的 WanWo 形态）。
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema（object；lossless）。
    var parameters: JSONValue { get }
    /// 呈现模式：M2 全部 direct；MCP 工具默认 deferred（F023，M4）；hidden 不可见。
    var exposure: ToolExposure { get }
    /// 协作式超时预算（毫秒）；nil = 无 deadline（F019）。
    var timeoutMs: Int? { get }

    /// 并发安全分类：仅精确 true 参与 parallel 池；其余一律 exclusive（fail closed）。
    func isConcurrencySafe(_ args: JSONValue) -> Bool
    /// 待执行卡意图（纯函数：依赖且仅依赖 args——live 流式与 replay 复现同形）。
    func presentCall(_ args: JSONValue) -> ToolCardIntent?
    /// 完成卡意图（同上纯函数契约）。
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent?
    /// 执行。异步体须观察 Task 取消并在信号后收敛。
    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput
}

extension AgentTool {
    var exposure: ToolExposure { .direct }
    var timeoutMs: Int? { nil }
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }
    func presentCall(_ args: JSONValue) -> ToolCardIntent? { nil }
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? { nil }
}

/// 呈现模式（dsh exposure 词汇；M2 仅 direct/hidden 生效，deferred 为 M4 预留）。
enum ToolExposure: String, Sendable {
    case direct, deferred, hidden
}

// MARK: - 执行模式

/// 一笔待执行调度的并发模式（dsh ToolExecutionMode）。
enum ToolExecutionMode: Equatable, Sendable {
    case parallel
    case exclusive
}

// MARK: - ToolRegistry

/// 工具注册表（dsh ToolRuntime 的 M2 子集：register / guard 单调否定 /
/// executionMode / schemas；restrict 与 scoped 层随 M4 ToolSearch 一起补齐）。
final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: AgentTool] = [:]
    /// 单调否定 guard（dsh ToolGuard：返回拒绝理由；无 allow 结果）。
    private var guards: [@Sendable (_ name: String, _ args: JSONValue) -> String?] = []

    private static let logger = AppLogger(category: "ToolRegistry")

    /// 注册工具；重名即抛（dsh NamedEntries 唯一性；fail loud at wiring time）。
    func register(_ tool: AgentTool) {
        lock.lock()
        defer { lock.unlock() }
        if tools[tool.name] != nil {
            // 装配期错误：立即失败优于静默覆盖。
            fatalError("tool \"\(tool.name)\" is already registered")
        }
        tools[tool.name] = tool
        Self.logger.info("tool registered: \(tool.name)")
    }

    func get(_ name: String) -> AgentTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    /// 注册单调 guard（dsh ToolRuntime.guard）。
    func addGuard(_ guardFn: @escaping @Sendable (_ name: String, _ args: JSONValue) -> String?) {
        lock.lock()
        defer { lock.unlock() }
        guards.append(guardFn)
    }

    /// 第一条命中 guard 的拒绝理由（global 层序；单调：无 allow 路径）。
    func guardReason(name: String, args: JSONValue) -> String? {
        lock.lock()
        let snapshot = guards
        lock.unlock()
        for guardFn in snapshot {
            if let reason = guardFn(name, args) { return reason }
        }
        return nil
    }

    /// 模型可见 schema（exposure != .hidden；按名称字典序——dsh 缺省 toolOrder 语义）。
    func schemas() -> [ToolSchemaEntry] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values
            .filter { $0.exposure != .hidden }
            .map { ToolSchemaEntry(name: $0.name, description: $0.description,
                                   parameters: $0.parameters) }
            .sorted { $0.name < $1.name }
    }

    /// 全部已知工具名（含 hidden——toolOrder 校验的 pre-restriction 名集）。
    var knownNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tools.keys.sorted()
    }

    /// 并发模式分类（dsh executionMode：仅精确 true 为 parallel；异常/非 true/未声明
    /// 一律 exclusive——fail closed）。
    func executionMode(name: String, args: JSONValue) -> ToolExecutionMode {
        guard let tool = get(name), tool.exposure != .hidden else { return .exclusive }
        // 参数解析失败按 exclusive（dsh：解析在 scheduler 前完成，此处兜底）。
        guard isParallelEligible(tool, args) else { return .exclusive }
        return .parallel
    }

    private func isParallelEligible(_ tool: AgentTool, _ args: JSONValue) -> Bool {
        // isConcurrencySafe 协议默认 false；实现抛错时同样按 exclusive。
        return tool.isConcurrencySafe(args) == true
    }
}
