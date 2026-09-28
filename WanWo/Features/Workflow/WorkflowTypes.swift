//
//  WorkflowTypes.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】Workflow seam 词汇（packages/workflow/
//  workflow/src/{types,runtime-types,index}.ts + workflow-worker-thread/src/
//  {meta,index}.ts 逐文件对拍）：
//    - types.ts:28-37   —— WorkflowPhase（title/detail?/provider?/model?）。
//    - types.ts:46-55   —— WorkflowMeta（name/description 必填 + whenToUse?/
//      phases?；字段词汇 = Claude Code dynamic-workflows meta block）。
//    - types.ts:63      —— WorkflowStopReason 闭集 completed/cancelled/error。
//    - types.ts:72-87   —— WorkflowResult{value, stopReason, error?, agentsStarted}
//      （result 永不 reject；value 仅 completed 有意义）。
//    - types.ts:90-131  —— WorkflowRunInfo/WorkflowAgentInfo(seq 1-based)/
//      WorkflowAgentOutcome(completed|failed|cancelled)/WorkflowAgentEndInfo/
//      WorkflowResultInfo（end 事件载荷——刻意不含 result.value）。
//    - index.ts:94-148  —— WorkflowEventName 六事件 + WorkflowErrorCode
//      11 值 + WorkflowError（fatal 缺省 true；每个 catch 位显式）。
//    - meta.ts:13-82    —— validateMeta（未知字段逐名拒绝 + name/description
//      非空 + phases 形状；违反逐条列名 joined '; ' → META_INVALID；返回
//      NORMALIZED 拷贝——不 alias 调用方对象）。
//    - index.ts:31-49   —— Config 六旋钮缺省（provider 'spawn'/
//      maxConcurrentAgents 0=auto/maxTotalAgents 1000/maxItemsPerCall 4096/
//      syncTimeoutMs 5000/disposeGraceMs 5000）；:151-153 auto = min(16,
//      max(1, cores-2))；:92-104 resolveMaxTotalAgents 逐字文案。
//
//  万我适配裁定（登记）：
//    - WorkflowRunId branded string → Swift String（UUID 由引擎铸造）。
//    - WorkflowRun.request.parent: Agent → WorkflowParent{sessionId, depth,
//      cwd} 值快照（万我无 Agent 对象缝——子会话归属经 SubagentRuntime.start
//      的 parentSessionId/parentDepth/parentCwd 承载）。
//    - dsh start() 同步 throw（META_INVALID/SCRIPT_PARSE）→ Swift `async
//      throws`（SubagentRuntime.getProvider 为 actor 调用 + JSC 语法预检
//      需持有 context——调用面 await，校验语义/文案逐字不变，登记）。
//    - HarnessError 基类 → 独立 struct（WanWo 无 HarnessError；code 机器
//      可路由词汇 1:1）。
//

import Foundation

// MARK: - 元数据（types.ts:28-55）

/// One phase declared in a script's `meta.phases`（progress vocabulary only
/// ——phases 在 observers/UI 分组 agent；不施加执行结构）。
struct WorkflowPhaseDecl: Equatable, Sendable {
    /// The phase title; `phase()` calls match against it by exact string.
    var title: String
    /// Optional one-line description of what the phase does.
    var detail: String?
    /// Optional provider override this phase is expected to use (informational).
    var provider: String?
    /// Optional model override this phase is expected to use (informational).
    var model: String?
}

/// The script's identity block（plain JSON data；引擎在 body 运行前校验）。
struct WorkflowMeta: Equatable, Sendable {
    /// Short kebab-case workflow name (display + persistence key).
    var name: String
    /// One-line description of what the workflow does.
    var description: String
    /// Optional guidance on when this workflow applies (shown in listings).
    var whenToUse: String?
    /// Optional phase declarations matched by `phase()` calls.
    var phases: [WorkflowPhaseDecl]?
}

// MARK: - 结果（types.ts:63-131）

/// Why a run settled（闭集——引擎自有，消费方可穷举）。
enum WorkflowStopReason: String, Equatable, Sendable {
    /// the script ran to its final `return`.
    case completed
    /// the run was cancelled (caller `cancel()`).
    case cancelled
    /// the script threw / fatal WorkflowError / result materialization failed.
    case error
}

/// A settled run's outcome（`result` 永不 reject；value = plain host JSON）。
struct WorkflowResult: Equatable, Sendable {
    /// The script's return value（host JSON data；脚本无 return = .null）。
    var value: JSONValue
    /// Why the run settled.
    var stopReason: WorkflowStopReason
    /// The failure message（present iff stopReason != completed）。
    var error: String?
    /// How many `agent()` calls the run accepted over its whole lifetime。
    var agentsStarted: Int
}

/// Identifying detail for a run（每个 workflow/* 事件携带的不可变快照）。
struct WorkflowRunInfo: Equatable, Sendable {
    /// The run's id（引擎铸造 UUID）。
    var id: String
    /// The run's validated meta block.
    var meta: WorkflowMeta
}

/// One `agent()` call's identity（workflow/agent-start 载荷）。
struct WorkflowAgentInfo: Equatable, Sendable {
    /// 1-based sequence number of this `agent()` call within the run.
    var seq: Int
    /// The display label (the `label` option, or a prompt snippet).
    var label: String
    /// The phase this agent belongs to（`phase` option，否则当前 phase() title）。
    var phase: String?
    /// The child agent's id on the subagent seam.
    var childId: String
}

/// How one `agent()` call settled（子失败脚本见 null；run 取消=cancelled）。
enum WorkflowAgentOutcome: String, Equatable, Sendable {
    case completed, failed, cancelled
}

/// One `agent()` call's settlement（workflow/agent-end 载荷）。
struct WorkflowAgentEndInfo: Equatable, Sendable {
    var seq: Int
    var label: String
    var phase: String?
    var childId: String
    /// How the call settled.
    var outcome: WorkflowAgentOutcome

    init(info: WorkflowAgentInfo, outcome: WorkflowAgentOutcome) {
        self.seq = info.seq
        self.label = info.label
        self.phase = info.phase
        self.childId = info.childId
        self.outcome = outcome
    }
}

/// A settled run's outcome as event data（workflow/end 载荷 = WorkflowResult
/// 去掉 value——观察者不得拿到调用方 result value 的可变别名）。
struct WorkflowResultInfo: Equatable, Sendable {
    var stopReason: WorkflowStopReason
    var error: String?
    var agentsStarted: Int
}

// MARK: - 事件（index.ts:94-101）

/// The full set of `workflow/*` event names（引擎进程内回调分发的全集合）。
enum WorkflowEventName: String, CaseIterable, Sendable {
    case start = "workflow/start"
    case phase = "workflow/phase"
    case log = "workflow/log"
    case agentStart = "workflow/agent-start"
    case agentEnd = "workflow/agent-end"
    case end = "workflow/end"
}

/// 事件第二载荷（dsh 各事件签名差异的 Swift 关联值承载）。
enum WorkflowEventDetail: Sendable {
    case none
    case title(String)
    case message(String)
    case agent(WorkflowAgentInfo)
    case agentEnd(WorkflowAgentEndInfo)
    case result(WorkflowResultInfo)
}

// MARK: - 错误（index.ts:108-148）

/// Machine-routable fatal workflow failures（普通子 agent 失败溶 per-item
/// null，不属于这些 fatal code）。
enum WorkflowErrorCode: String, Equatable, Sendable {
    case scriptParse = "SCRIPT_PARSE"
    case metaInvalid = "META_INVALID"
    case invalidArgument = "INVALID_ARGUMENT"
    case unsupportedOption = "UNSUPPORTED_OPTION"
    case unsupportedSchema = "UNSUPPORTED_SCHEMA"
    case agentCap = "AGENT_CAP"
    case itemCap = "ITEM_CAP"
    case agentStart = "AGENT_START"
    case agentResult = "AGENT_RESULT"
    case resultUnserializable = "RESULT_UNSERIALIZABLE"
    case cancelled = "CANCELLED"
    /// Watchdog 同步片超时（dsh vm runInContext timeout 的映射；dsh 无独立
    /// code——超时走 error stopReason；万我 code 面自拟登记，message 语义对齐）。
    case scriptTimeout = "SCRIPT_TIMEOUT"
}

/// Typed error for workflow-seam failures（`fatal` 驱动组合子纪律：
/// parallel()/pipeline() 重抛 fatal——拼错的选项或触顶的上限必须响亮杀死
/// 脚本；per-item null 只留给子运行失败与普通 stage 错误）。每个
/// WorkflowErrorCode 都是 fatal；flag 的存在让每个 catch 位显式。
struct WorkflowError: Error, Equatable {
    var message: String
    var code: WorkflowErrorCode
    /// Whether combinators must propagate this error instead of nulling the item.
    var fatal: Bool = true

    init(message: String, code: WorkflowErrorCode, fatal: Bool = true) {
        self.message = message
        self.code = code
        self.fatal = fatal
    }
}

// MARK: - 请求与运行柄（runtime-types.ts:19-49）

/// 父会话快照（dsh request.parent: Agent 的值形态等价承载）。
struct WorkflowParent: Equatable, Sendable {
    /// 父会话 id（子会话 lineage 记录 + 归属）。
    var sessionId: String
    /// 父的委派深度（SubagentDepth 地板单调语义的输入）。
    var depth: Int
    /// 父的工作目录（子会话 cwd 继承——dsh childSessionMeta :146-148）。
    var cwd: String?
}

/// What a caller asks for when starting a workflow run（meta/args 为 plain
/// JSON data；parent 必备——脚本 spawn 的每个 agent 都归属该父）。
struct WorkflowStartRequest: Sendable {
    /// The plain-JS script body（top-level await；`return <json-value>` 结尾）。
    var script: String
    /// The workflow's identity block（引擎 shape-validated）。
    var meta: WorkflowMeta
    /// Optional input exposed verbatim to the script as the `args` global.
    var args: JSONValue?
    /// Optional engine-wide child-provider override for this run.
    var subagentProvider: String?
    /// Optional per-run total-child ceiling.
    var maxTotalAgents: Int?
    /// The agent on whose behalf the run executes（parent of every child）。
    var parent: WorkflowParent
}

// MARK: - 配置（worker index.ts:31-49 + :115-122 缺省 1:1）

/// Plugin config（全可选——缺省在此定死，dsh schemastery static Config 同位）。
struct WorkflowEngineConfig: Sendable {
    /// The `ctx.subagents` provider children run on（default `spawn`）。
    var provider: String = "spawn"
    /// Concurrent `agent()` ceiling；`0`（缺省）auto = `min(16, max(1, cores-2))`。
    var maxConcurrentAgents: Int = 0
    /// Total `agent()` calls one run may start——the runaway-loop backstop（1000）。
    var maxTotalAgents: Int = 1000
    /// Items accepted by a single `parallel()`/`pipeline()` call（4096）。
    var maxItemsPerCall: Int = 4096
    /// vm timeout for the script's initial synchronous slice（5000 ms；万我 =
    /// JSC Watchdog 时限，判定①1:1）。
    var syncTimeoutMs: Double = 5000
    /// How long after a cancellation an unsettled script may keep running
    /// before the run force-settles `cancelled`（5000 ms；also bounds dispose）。
    var disposeGraceMs: Double = 5000
}

/// The per-run limits the execution enforces（worker types.ts:16-25）。
struct WorkflowLimits: Equatable, Sendable {
    var maxConcurrentAgents: Int
    var maxTotalAgents: Int
    var maxItemsPerCall: Int
    var syncTimeoutMs: Double
}

// MARK: - meta 校验（meta.ts:13-82 1:1）

/// Validate a caller-provided meta value against the WorkflowMeta contract.
/// Throws META_INVALID naming every violation；返回 NORMALIZED 拷贝（引擎
/// 不 alias 调用方对象）。Meta 是 schema-checked JSON data——绝不在宿主侧
/// 求值脚本文本（meta.ts 模块注释语义）。
func validateWorkflowMeta(_ value: JSONValue) throws -> WorkflowMeta {
    var violations: [String] = []
    guard let record = value.objectValue else {
        throw WorkflowError(message: "invalid meta: meta must be an object",
                            code: .metaInvalid)
    }
    let known: Set<String> = ["name", "description", "whenToUse", "phases"]
    for key in record.keys where !known.contains(key) {
        violations.append("meta.\(key) is not a recognized field (name/description/whenToUse/phases)")
    }
    guard let name = record["name"]?.stringValue, !name.isEmpty else {
        violations.append("meta.name must be a non-empty string")
    }
    guard let description = record["description"]?.stringValue, !description.isEmpty else {
        violations.append("meta.description must be a non-empty string")
    }
    if let whenToUse = record["whenToUse"], whenToUse.stringValue == nil {
        violations.append("meta.whenToUse must be a string")
    }
    var phases: [WorkflowPhaseDecl] = []
    if let phasesValue = record["phases"] {
        if let phaseArray = phasesValue.arrayItems {
            for (index, phase) in phaseArray.enumerated() {
                guard let entry = phase.objectValue else {
                    violations.append("meta.phases[\(index)] must be an object")
                    continue
                }
                let phaseKnown: Set<String> = ["title", "detail", "provider", "model"]
                for key in entry.keys where !phaseKnown.contains(key) {
                    violations.append("meta.phases[\(index)].\(key) is not a recognized field")
                }
                guard let title = entry["title"]?.stringValue, !title.isEmpty else {
                    violations.append("meta.phases[\(index)].title must be a non-empty string")
                    continue
                }
                if let detail = entry["detail"], detail.stringValue == nil {
                    violations.append("meta.phases[\(index)].detail must be a string")
                }
                if let provider = entry["provider"], provider.stringValue == nil {
                    violations.append("meta.phases[\(index)].provider must be a string")
                }
                if let model = entry["model"], model.stringValue == nil {
                    violations.append("meta.phases[\(index)].model must be a string")
                }
                if violations.isEmpty {
                    phases.append(WorkflowPhaseDecl(
                        title: title,
                        detail: entry["detail"]?.stringValue,
                        provider: entry["provider"]?.stringValue,
                        model: entry["model"]?.stringValue))
                }
            }
        } else {
            violations.append("meta.phases must be an array")
        }
    }
    if !violations.isEmpty {
        throw WorkflowError(message: "invalid meta: \(violations.joined(separator: "; "))",
                            code: .metaInvalid)
    }
    return WorkflowMeta(
        name: name ?? "",
        description: description ?? "",
        whenToUse: record["whenToUse"]?.stringValue,
        phases: record["phases"] != nil ? phases : nil)
}
