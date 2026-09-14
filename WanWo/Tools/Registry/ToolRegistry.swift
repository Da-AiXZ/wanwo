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
//    · M5-B P4：PTC mode 收官——ToolPresentationMode 三值 + exposure 六值 +
//      run_code 保留名注册拒绝 + sdkSchemas 投影（渲染器见 ToolSdkRenderer）
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
    /// 本调用的生效沙箱模式（P1-3：approved 显式 > 会话末条 sandbox/mode >
    /// 新会话默认源 > 部署默认——四层解析在装配缝完成，此处为解析产物）。
    let sandboxMode: SandboxMode
    /// 提权审批通道（P1-3：审批只由 sandbox_permissions 提权请求触发；
    /// nil = 无审批服务合成 → 提权 fail closed 'unavailable' 逐字文案）。
    let escalationApprover: SandboxEscalationApprover?
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
    /// 呈现模式：内置默认 direct；MCP 工具覆写 deferred（F023，M4-C 落地）；
    /// hidden 不可见。
    var exposure: ToolExposure { get }
    /// tool_search 来源信息（M4-C2c 语料缝：MCP 工具携带 server 名；内置 nil）。
    var toolSearchSourceInfo: ToolSearchSourceInfo? { get }
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
    var toolSearchSourceInfo: ToolSearchSourceInfo? { nil }
    var timeoutMs: Int? { nil }
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }
    func presentCall(_ args: JSONValue) -> ToolCardIntent? { nil }
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? { nil }
}

/// 呈现模式（dsh exposure 词汇 + codex tools/tool_executor.rs:51-80 六值扩展。
/// M4-C 起 deferred 生效=MCP 工具默认——tool_search 组装步见 ToolSearchAssembly；
/// M5-B P4：direct/deferred 语义不变，directModelOnly/deferredModelOnly/
/// codeModeOnly 为 Code Mode 分面预留位（消费面登记待用），hidden 不变）。
enum ToolExposure: String, Sendable {
    case direct, deferred, hidden
    case directModelOnly, deferredModelOnly, codeModeOnly
}

extension ToolExposure {
    /// codex tool_executor.rs:83-85 is_direct：进初始模型可见清单。
    var isDirect: Bool { self == .direct || self == .directModelOnly }

    /// codex tool_executor.rs:88-90 is_deferred：可经 tool_search 发现。
    var isDeferred: Bool { self == .deferred || self == .deferredModelOnly }

    /// codex tool_executor.rs:93-98 is_available_in_code_mode：可参与
    /// code mode（run_code SDK 子派发可见）。
    var isAvailableInCodeMode: Bool {
        switch self {
        case .direct, .deferred, .codeModeOnly: return true
        case .directModelOnly, .deferredModelOnly, .hidden: return false
        }
    }
}

/// 注册表呈现模式（dsh ToolPresentationMode，index.ts:644 三值语义，语义段
/// :648-657 取证：native 只送 native schema；ptc 只送 run_code + 生成的 SDK
/// 段并把执行面 collapse 到同面——模型直调只可点名 run_code，run_code 的
/// SDK 子派发仍见全部可见工具；both 两种形态并存）。
enum ToolPresentationMode: String, Sendable {
    case native, ptc, both
}

/// 注册冲突错误（tryRegister 的可捕获路径；装配期 register 的 fatalError
/// 语义保留不动——错误类型通用，不属 MCP 域）。
struct ToolRegistryConflictError: Error, CustomStringConvertible {
    let name: String
    var description: String { "tool \"\(name)\" is already registered" }
}

/// run_code 保留名侵犯（dsh index.ts:1041-1046——保留无条件生效：任何 agent
/// 都可自选 code mode，缺省档下可占的名字在 preset 挂载瞬间即成碰撞）。
struct ToolRegistryReservedError: Error, CustomStringConvertible {
    let name: String
    var description: String {
        "tool name \"\(name)\" is reserved for the PTC mode presentation transport "
            + "and cannot be registered or shadowed"
    }
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
    /// run_code 保留名（dsh ptc.ts RUN_CODE_NAME 对应。注册面拒绝语义见
    /// register/tryRegister；保留 transport 本尊经 registerReservedTransport
    /// 入场——index.ts:914-925 "never enters the global layer"）。
    static let runCodeName = "run_code"

    /// 呈现模式（init 定档。WanWo 无 scope 链——dsh modeFor(scope) 的最近
    /// 作用域胜出链不适用，全局单档，登记差异；缺省 .both 为 WanWo 拍板
    /// 差异，dsh Config 缺省 native，index.ts:823）。
    let presentationMode: ToolPresentationMode

    private let lock = NSLock()
    private var tools: [String: AgentTool] = [:]
    /// 单调否定 guard（dsh ToolGuard：返回拒绝理由；无 allow 结果）。
    private var guards: [@Sendable (_ name: String, _ args: JSONValue) -> String?] = []

    private static let logger = AppLogger(category: "ToolRegistry")

    init(presentationMode: ToolPresentationMode = .both) {
        self.presentationMode = presentationMode
    }

    /// 注册工具；重名即抛（dsh NamedEntries 唯一性；fail loud at wiring time）。
    /// run_code 保留名侵犯：装配期立即失败（dsh index.ts:1044-1046）。
    func register(_ tool: AgentTool) {
        if tool.name == Self.runCodeName {
            fatalError(ToolRegistryReservedError(name: tool.name).description)
        }
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

    /// 注册工具，重名抛错并返回注销器（dsh ctx.tools.register 语义 1:1：
    /// NamedEntries 唯一性抛错 + 返回 disposer——M4-A 件4 两阶段换手的
    /// 「冲突整代回滚」依赖可捕获错误与逐工具注销；装配期 fatalError 路径
    /// 经 register 保留不动，两者共存）。
    /// - Returns: 幂等注销器（dsh register disposer）。
    @discardableResult
    func tryRegister(_ tool: AgentTool) throws -> @Sendable () -> Void {
        lock.lock()
        defer { lock.unlock() }
        if tool.name == Self.runCodeName {
            throw ToolRegistryReservedError(name: tool.name)
        }
        if tools[tool.name] != nil {
            throw ToolRegistryConflictError(name: tool.name)
        }
        tools[tool.name] = tool
        Self.logger.info("tool registered: \(tool.name)")
        let name = tool.name
        return { [weak self] in self?.unregister(name) }
    }

    /// 注销一个工具（幂等；dsh register disposer 的执行语义）。
    func unregister(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard tools.removeValue(forKey: name) != nil else { return }
        Self.logger.info("tool unregistered: \(name)")
    }

    /// 注册保留 transport（dsh requireCodeTransport/index.ts:914-925——
    /// run_code 不进可过滤层：专用注册面绕过名称保留（保留本身即为其而设），
    /// 其余重复语义与 register 相同：重名装配期立即失败）。M5-B P3 的
    /// RunCodeTool 经此入场。
    func registerReservedTransport(_ tool: AgentTool) {
        lock.lock()
        defer { lock.unlock() }
        if tools[tool.name] != nil {
            fatalError("tool \"\(tool.name)\" is already registered")
        }
        tools[tool.name] = tool
        Self.logger.info("tool registered: \(tool.name)")
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

    /// 模型可见 schema（native/both：isDirect 全集——codex spec_plan.rs:530-542
    /// build_model_visible_specs `!exposure.is_direct() { continue }` 同构；
    /// ptc：只送 run_code 本名——dsh wireSchemas index.ts:986-990 1:1，此时
    /// native 名在 toolOrder 中无效（index.ts:656）。按名称字典序——dsh 缺省
    /// toolOrder 语义。deferred 工具经 tool_search 按需发现（F023，组装步见
    /// ToolSearchAssembly），hidden 永不可见）。
    func schemas() -> [ToolSchemaEntry] {
        lock.lock()
        defer { lock.unlock() }
        let direct = tools.values
            .filter { $0.exposure.isDirect }
            .map { ToolSchemaEntry(name: $0.name, description: $0.description,
                                   parameters: $0.parameters) }
            .sorted { $0.name < $1.name }
        if presentationMode == .ptc {
            return direct.filter { $0.name == Self.runCodeName }
        }
        return direct
    }

    /// M4-C2c：deferred 工具快照（tool_search 语料构建消费面；按名称字典序
    /// 确定性——ToolSearchTool 引擎缓存的全等判定随序稳定）。
    func deferredTools() -> [AgentTool] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values
            .filter { $0.exposure.isDeferred }
            .sorted { $0.name < $1.name }
    }

    /// PTC SDK 投影集（dsh index.ts:1229-1243 1:1——可参与 code mode 的可见
    /// 工具减 run_code 本名；按名称字典序。WanWo ToolOutput 无 schema 面，
    /// output 恒 nil → 成员渲染退化 `JsonValue`，登记④）。
    func sdkSchemas() -> [ToolSdkEntry] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values
            .filter { $0.exposure.isAvailableInCodeMode && $0.name != Self.runCodeName }
            .sorted { $0.name < $1.name }
            .map { ToolSdkEntry(name: $0.name, description: $0.description,
                                parameters: $0.parameters, output: nil) }
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
