//
//  SubagentTypes.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 C · F045】出处（analysis/dsh-upstream-m5/packages/subagent/
//  逐文件对拍）：
//    - subagent/src/types.ts:130-136 —— SubagentCapabilities 五 bool（fail loud）。
//    - types.ts:145-201 —— SubagentStartRequest（label/prompt/parent/signal/
//      maxDepth/outputSchema/toolFilter/persona；agentOptions 由 WanWo 子栈
//      继承父路由承载——M7.2 无 per-child model 选项缝，登记）。
//    - types.ts:252-297 —— SubagentStopReasonMap 五值 merge-extensible（未知
//      按失败——tool-subagent stopReasonError default 分支语义）+
//      SubagentResult{output, structured?, diagnostic?(≤4096B 脱敏), stopReason}。
//    - types.ts:308-334 —— SubagentRun{id, result, dispose 幂等}。
//    - depth.ts:28-51   —— delegationDepthOf（header 权威 + runtime 可加深，
//      读取 = max 单调地板）+ assertSubagentMaxDepth。
//    - child-agent.ts:31-58 —— SubagentDepthError + resolveChildDepth（parent+1，
//      超 maxDepth 抛错）。
//    - child-agent.ts:171-175 —— SUBAGENT_DELEGATION_CONTEXT 逐字。
//    - descriptor.ts:48-91 —— descriptor v3（版本化 + 字段白名单 + 首条权威）。
//
//  万我适配裁定（登记）：
//    - dsh SessionHeader{parentSession, origin, delegationDepth, seeded} →
//      子日志 lineage extensionEvent kind="subagent/lineage"（SessionHeaderLine
//      位于路径外 JsonlEventLog.swift——改头需跨路径报批；语义等价：两者均
//      durable replay，delegationDepthOf 的读取源换为 lineage fold）。
//    - descriptor/lineage 事件在子会话创建窗口直写（dsh 为 initial turn
//      turn-enclosed append——万我创建窗口先于首个 turn，登记）。
//    - SubagentResult.output：dsh ContentBlock[] → WanWo 文本（最终 assistant
//      消息 text 拼接——同一选择规则的文本面）。
//    - persona/toolFilter：万我 M7.2 无对应缝——SubagentStartRequest 不含，
//      声明登记（简报已定适配③）。
//

import Foundation

// MARK: - 能力（types.ts:130-136）

/// START-TIME 能力五 bool（fail loud：请求需要的能力缺失 → 带类型拒绝，
/// 绝不 accepted-then-ignored）。
struct SubagentCapabilities: Equatable, Sendable {
    var agentOptions: Bool
    var outputSchema: Bool
    var depthLimit: Bool
    var toolFilter: Bool
    var persona: Bool

    /// 万我 in-process 双 provider 的能力面（spawn/fork 原件全 true；
    /// agentOptions/toolFilter/persona 在万我 M7.2 由调用面不接受——
    /// 能力位与 dsh 1:1，接受面裁剪登记）。
    static let inProcess = SubagentCapabilities(
        agentOptions: true, outputSchema: true, depthLimit: true,
        toolFilter: true, persona: true)
}

// MARK: - 停止原因（types.ts:252-266 merge-extensible）

/// 五个已知值 + 未知按失败（tool-subagent :168-171 default 分支语义）。
enum SubagentStopReason: Equatable, Sendable {
    case completed
    case aborted
    case error
    case maxTokens
    case refusal
    /// 后端可合并的新变体（消费方一律按失败处理）。
    case unknown(String)

    /// dsh turn/end reason → stop reason（in-process-driver :50-67 toStopReason
    /// 1:1：blocked=拒绝；error/interrupted/无=error）。
    init(turnEndReason: TurnEndReason?) {
        switch turnEndReason {
        case .completed: self = .completed
        case .maxTokens: self = .maxTokens
        case .aborted: self = .aborted
        case .blocked: self = .refusal
        case .error, .interrupted, .none: self = .error
        }
    }

    var wireName: String {
        switch self {
        case .completed: return "completed"
        case .aborted: return "aborted"
        case .error: return "error"
        case .maxTokens: return "max-tokens"
        case .refusal: return "refusal"
        case .unknown(let raw): return raw
        }
    }
}

// MARK: - 请求与结果（types.ts:145-201 / :271-297）

/// ONE-SHOT 委派请求（万我文本 prompt 形态；signal = 取消经 Task/旗标承载，
/// 万我由 SubagentRun.dispose 与 ToolExecutionContext 取消融合，登记）。
struct SubagentStartRequest: Sendable {
    /// Optional short display label persisted with the child.
    var label: String?
    /// Content delivered as the child's user message.
    var prompt: String
    /// Spawning agent 的会话 id（lineage 记录用）。
    var parentSessionId: String
    /// 父的工作目录（子会话 cwd 继承——dsh childSessionMeta :146-148）。
    var parentCwd: String?
    /// 父的委派深度（durable 地板）。
    var parentDepth: Int
    /// Optional absolute delegation-depth cap for the child.
    var maxDepth: Int?
    /// 父的显式沙箱覆盖（captureDelegatedPolicyOverrides——仅显式 override，
    /// 永不部署缺省/一次性 stamp；child-agent.ts:242-247。万我 PermissionCoordinator
    /// 无显式/缺省区分缝——knob 直传，登记见 QA-3 P1-5 报告）。
    var sandboxModeOverride: SandboxMode?
    /// 父会话模型选择（QA-3 P1-6：fork 前缀跨端点 KV-cache 失效修复——子栈
    /// 与父同路由。万我扩展字段，dsh 无对应——dsh 经 agentOptions 承载，登记）。
    var modelSelection: SessionModelSelection?

    init(label: String? = nil, prompt: String, parentSessionId: String,
         parentCwd: String?, parentDepth: Int, maxDepth: Int? = nil,
         sandboxModeOverride: SandboxMode? = nil,
         modelSelection: SessionModelSelection? = nil) {
        self.label = label
        self.prompt = prompt
        self.parentSessionId = parentSessionId
        self.parentCwd = parentCwd
        self.parentDepth = parentDepth
        self.maxDepth = maxDepth
        self.sandboxModeOverride = sandboxModeOverride
        self.modelSelection = modelSelection
    }
}

/// 终局结果（types.ts:271-297；WanWo 文本 output，登记见头注）。
struct SubagentResult: Equatable, Sendable {
    /// The child's final assistant output（最终非空 assistant 消息的 text）。
    var output: String
    /// Structured result（M7.2 无 outputSchema 缝——恒 nil，登记）。
    var structured: JSONValue?
    /// Provider-authored, non-assistant failure detail（≤4096 UTF-8 字节）。
    var diagnostic: String?
    /// Why the run ended. A non-`completed` reason means output may be partial.
    var stopReason: SubagentStopReason
}

// MARK: - 深度（depth.ts / child-agent.ts 1:1）

/// Thrown when starting a child would exceed the requested depth cap
///（child-agent.ts:32-37）。
struct SubagentDepthError: Error, Equatable {
    var attemptedDepth: Int
    var maxDepth: Int
}

/// 委派深度记账（depth.ts:28-36 + child-agent.ts:49-58 1:1）。
enum SubagentDepth {
    /// Read an agent's delegation depth——durable 权威（万我 lineage 事件）
    /// 与 runtime 值的单调地板：max(header, runtime)（depth.ts:28-36 1:1）。
    static func delegationDepthOf(durableDepth: Int?, runtimeDepth: Int?) throws -> Int {
        if let runtimeDepth, runtimeDepth < 0 {
            throw SubagentDepthError(attemptedDepth: runtimeDepth, maxDepth: 0)
        }
        return max(durableDepth ?? 0, runtimeDepth ?? 0)
    }

    /// Reject a recursion cap that cannot represent an exact delegation depth
    ///（depth.ts:42-51）。
    static func assertSubagentMaxDepth(_ maxDepth: Int?) throws {
        if let maxDepth, maxDepth < 0 {
            throw SubagentDepthError(attemptedDepth: 0, maxDepth: maxDepth)
        }
    }

    /// Resolve the child's delegation depth and enforce an optional cap
    ///（child-agent.ts:49-58 1:1：parent+1；超 maxDepth 抛 SubagentDepthError）。
    static func resolveChildDepth(parentDepth: Int, maxDepth: Int?) throws -> Int {
        let childDepth = parentDepth + 1
        if let maxDepth, childDepth > maxDepth {
            throw SubagentDepthError(attemptedDepth: childDepth, maxDepth: maxDepth)
        }
        return childDepth
    }
}

// MARK: - lineage 事件（dsh childSessionMeta 的万我承载）

/// 子会话 durable 身份与谱系（dsh SessionHeader meta
/// parentSession/origin/delegationDepth/seeded 的 extensionEvent 等价承载）。
enum SubagentLineage {
    /// wire type = "extension/subagent/lineage"。
    static let eventKind = "subagent/lineage"

    struct Record: Equatable, Sendable {
        var parentSession: String
        var delegationDepth: Int
        /// Whether this child inherits a parent-log prefix（含显式空）。
        var seeded: Bool
        /// 本子会话的 agent path（M7.3 件 H：Supervisor 恢复树重建的持久
        /// path 权威——codex stored_thread.agent_path 等价承载。可选字段：
        /// schema requiredFields 不含（ExtensionEventRegistry 校验只查
        /// required，额外字段放行——实证 ExtensionEventRegistry.swift:155-171），
        /// 旧日志缺省 nil = 恢复时按 label 重派生，登记）。
        var agentPath: String?
    }

    static func payload(for record: Record) -> JSONValue {
        var fields: [String: JSONValue] = [
            "origin": .string("subagent"),
            "parentSession": .string(record.parentSession),
            "delegationDepth": .int(record.delegationDepth),
            "seeded": .bool(record.seeded),
        ]
        if let agentPath = record.agentPath {
            fields["agentPath"] = .string(agentPath)
        }
        return .object(fields)
    }

    /// 从子日志读 lineage（首条权威；无 → nil = 顶层会话）。
    static func read(events: [SessionEvent]) -> Record? {
        for event in events {
            if case .extensionEvent(eventKind, let payload) = event.payload {
                guard let parentSession = payload.field("parentSession")?.stringValue,
                      let depth = payload.field("delegationDepth")?.intValue,
                      let seeded = payload.field("seeded")?.boolValue else { return nil }
                return Record(parentSession: parentSession, delegationDepth: depth,
                              seeded: seeded,
                              agentPath: payload.field("agentPath")?.stringValue)
            }
        }
        return nil
    }
}

// MARK: - descriptor（descriptor.ts 1:1）

/// Durable subagent-child descriptor：版本化 + 字段白名单 + 首条权威
///（descriptor.ts:48-91/317-323）。logOnly：不进模型历史，压缩存活。
enum SubagentDescriptor {
    static let eventKind = "subagent/descriptor"
    /// Current descriptor format version（descriptor.ts:48）。
    static let version = 3

    enum Mode: String, Equatable, Sendable {
        case oneShot = "one-shot"
        case continuable
    }

    struct Record: Equatable, Sendable {
        var mode: Mode
        /// The `ctx.subagents` provider name that established the child.
        var provider: String
        /// The initial delegation's short description（durable 枚举标签）。
        var label: String?
        var agentProvider: String?
        var agentModel: String?
        var agentReasoningEffort: String?
        var persona: String?
        var toolFilter: ToolRestriction?
    }

    /// dsh ToolRestriction 的最小形态（{allow?, deny?}；万我 M7.2 不消费——
    /// descriptor 往返保持字段保真）。
    struct ToolRestriction: Equatable, Sendable {
        var allow: [String]?
        var deny: [String]?
    }

    // MARK: 编码（descriptor.ts:279-303 snapshotSubagentDescriptor 字段白名单）

    static func payload(for record: Record) -> JSONValue {
        var fields: [String: JSONValue] = [
            "version": .int(version),
            "mode": .string(record.mode.rawValue),
            "provider": .string(record.provider),
        ]
        if let label = record.label { fields["label"] = .string(label) }
        if let agentProvider = record.agentProvider {
            fields["agentProvider"] = .string(agentProvider)
        }
        if let agentModel = record.agentModel { fields["agentModel"] = .string(agentModel) }
        if let effort = record.agentReasoningEffort {
            fields["agentReasoningEffort"] = .string(effort)
        }
        if let persona = record.persona { fields["persona"] = .string(persona) }
        if let filter = record.toolFilter {
            var filterFields: [String: JSONValue] = [:]
            if let allow = filter.allow { filterFields["allow"] = .array(allow.map { .string($0) }) }
            if let deny = filter.deny { filterFields["deny"] = .array(deny.map { .string($0) }) }
            fields["toolFilter"] = .object(filterFields)
        }
        return .object(fields)
    }

    // MARK: 解码（descriptor.ts:202-256 parseSubagentDescriptor 1:1：字段白名单
    // 严格；其他版本返回 nil = 本运行时不可分类）

    static func parse(_ payload: JSONValue) throws -> Record? {
        guard let fields = payload.objectValue else {
            throw SubagentError(message: "persisted subagent descriptor payload must be an object")
        }
        guard let versionField = fields["version"]?.intValue else {
            throw SubagentError(message: "persisted subagent descriptor version must be a number")
        }
        guard versionField == version else { return nil }
        guard let modeRaw = fields["mode"]?.stringValue,
              let mode = Mode(rawValue: modeRaw) else {
            throw SubagentError(message: "persisted subagent descriptor mode must be \"one-shot\" or \"continuable\"")
        }
        let allowed: Set<String> = mode == .oneShot
            ? ["version", "mode", "provider", "label"]
            : ["version", "mode", "provider", "label", "agentProvider", "agentModel",
               "agentReasoningEffort", "persona", "toolFilter"]
        let unknown = Set(fields.keys).subtracting(allowed)
        if let unknown = unknown.first {
            throw SubagentError(
                message: "persisted subagent descriptor payload has unknown field \"\(unknown)\"")
        }
        guard let provider = fields["provider"]?.stringValue else {
            throw SubagentError(message: "persisted subagent descriptor provider must be a string")
        }
        func optionalString(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.stringValue else {
                throw SubagentError(message: "persisted subagent descriptor \(key) must be a string")
            }
            return text
        }
        if mode == .oneShot {
            return Record(mode: mode, provider: provider, label: try optionalString("label"),
                          agentProvider: nil, agentModel: nil, agentReasoningEffort: nil,
                          persona: nil, toolFilter: nil)
        }
        guard let label = fields["label"]?.stringValue else {
            throw SubagentError(message: "persisted subagent descriptor label must be a string")
        }
        var toolFilter: ToolRestriction?
        if fields["toolFilter"] != nil {
            guard let filterFields = fields["toolFilter"]?.objectValue else {
                throw SubagentError(message: "persisted subagent descriptor toolFilter must be an object")
            }
            let filterUnknown = Set(filterFields.keys).subtracting(["allow", "deny"])
            if let unknown = filterUnknown.first {
                throw SubagentError(
                    message: "persisted subagent descriptor toolFilter has unknown field \"\(unknown)\"")
            }
            func stringArray(_ key: String) throws -> [String]? {
                guard let value = filterFields[key] else { return nil }
                guard let items = value.arrayItems else {
                    throw SubagentError(message: "persisted subagent descriptor toolFilter.\(key) must be an array of strings")
                }
                guard items.allSatisfy({ $0.stringValue != nil }) else {
                    throw SubagentError(message: "persisted subagent descriptor toolFilter.\(key) must be an array of strings")
                }
                return items.compactMap { $0.stringValue }
            }
            let allow = try stringArray("allow")
            let deny = try stringArray("deny")
            if allow == nil && deny == nil {
                throw SubagentError(message: "persisted subagent descriptor toolFilter must declare allow and/or deny")
            }
            toolFilter = ToolRestriction(allow: allow, deny: deny)
        }
        return Record(mode: mode, provider: provider, label: label,
                      agentProvider: try optionalString("agentProvider"),
                      agentModel: try optionalString("agentModel"),
                      agentReasoningEffort: try optionalString("agentReasoningEffort"),
                      persona: try optionalString("persona"),
                      toolFilter: toolFilter)
    }

    /// Fold a persisted child log to its supported descriptor——首条权威
    ///（descriptor.ts:317-323 1:1：后写不可改写已声明组合）。
    static func fold(events: [SessionEvent]) -> Record? {
        for event in events {
            if case .extensionEvent(eventKind, let payload) = event.payload {
                return (try? parse(payload)) ?? nil
            }
        }
        return nil
    }
}

// MARK: - extensionEvent 注册面（装配期幂等注册）

/// 子 agent 域的 extensionEvent 注册（lineage = dsh SessionHeader meta 的
/// extensionEvent 改案承载；descriptor = descriptor.ts 事件 logOnly——两者
/// 均不进模型历史）。重名 fatal 由注册表强制，isRegistered 门保幂等。
enum SubagentEvents {
    /// 装配期注册（幂等；AppEnvironment.makeAgentStack 调用）。
    static func register() {
        let registry = ExtensionEventRegistry.shared
        guard !registry.isRegistered(SubagentLineage.eventKind) else { return }
        registry.register(ExtensionEventSchema(
            kind: SubagentLineage.eventKind,
            requiredFields: [
                ExtensionFieldSchema("origin", .string),
                ExtensionFieldSchema("parentSession", .string),
                ExtensionFieldSchema("delegationDepth", .int),
                ExtensionFieldSchema("seeded", .bool),
            ],
            projection: .logOnly))
        registry.register(ExtensionEventSchema(
            kind: SubagentDescriptor.eventKind,
            requiredFields: [
                ExtensionFieldSchema("version", .int),
                ExtensionFieldSchema("mode", .string),
                ExtensionFieldSchema("provider", .string),
            ],
            projection: .logOnly))
    }
}

// MARK: - 错误（subagent/src/error.ts 形态）

/// Stable-classified subagent seam error。
struct SubagentError: Error, Equatable {
    var message: String
    var code: String = "SUBAGENT_ERROR"

    init(message: String, code: String = "SUBAGENT_ERROR") {
        self.message = message
        self.code = code
    }
}

// MARK: - 委派范围声明（child-agent.ts:171-175 逐字）

/// Model-facing delegation-scope statement for every in-process child。
enum SubagentDelegation {
    static let contextText = "You are a delegated subagent: your permission scope was fixed when you were started and cannot be "
        + "widened from inside this session — operations that require approval are rejected automatically. "
        + "When the task needs access beyond that scope, do not retry the denied operation; state the "
        + "limitation in your reply so the delegating agent can handle it."

    /// 子会话委派纪律段（dsh applyChildComposition 子可见声明的 WanWo 承载：
    /// child-agent.ts:171-175 逐字文案进子 system 面——静态段落装配期注册）。
    static func promptSection() -> PromptSection {
        PromptSection(name: "subagent:delegation",
                      order: SECTION_ORDERS.subagentDelegation,
                      text: contextText)
    }
}
