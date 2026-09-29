//
//  SubagentTools.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 C · F045】出处（packages/subagent/ 逐文件对拍）：
//    - tool-subagent/src/index.ts:251-276 —— providerWording（继承上下文与
//      独立上下文两套 description/promptDescription 逐字）。
//    - index.ts:286-305 —— resolveDelegationRun（后台禁用拒绝 + continuable
//      缺省后台 / one-shot 缺省前台）。
//    - index.ts:379-467 —— 工具 schema（description 3-5 词 + prompt 必填 +
//      run_in_background）+ 输出三选一 background{jobId}|continuable{subagentId}|
//      foreground{runId,output} + render 文案逐字。
//    - index.ts:471-568 —— execute（前台 settleForegroundRun；后台 one-shot
//      jobs.start{kind:'subagent',owner=parent} + settleStart；后台 continuable
//      startContinuable）。
//    - index.ts:594-605 —— tool:<name> 提示段（continuable 后台缺省教学文）。
//    - tool-subagent-control/src/index.ts:28-116 —— send_message /
//      interrupt_agent（薄适配层：residency/cold-resume/祖先授权全归 runtime）。
//    - tool-subagent-control/src/list-agents.ts —— list_agents（children|
//      descendants；仅列 continuable）。
//    - multi_agents_v2/wait.rs + multi_agents_spec.rs:280-290/858-868 ——
//      wait_agent（M7.3 件 H 新增：主理人判定①"六工具仅 spawn/send_message/
//      interrupt/list_agents 与批1 重叠，仅新增 wait_agent"；spec description
//      逐字 + timeout 夹取 wait.rs:53-65 + 结果文案 from_outcome :139-159）。
//
//  万我适配裁定（登记）：
//    - model selection 面（provider/model/reasoning_effort 成对 + KV-cache
//      fork 警告）M7.2 无 per-child 路由缝——参数不接受，登记（KV-cache 警告
//      随面缺失整体不移植）。
//    - persona/toolFilter 请求字段不接受（已定适配③）。
//    - dsh exec.agent → WanWo ToolExecutionContext.sessionId（发起方会话身份）。
//    - fork 实例工具名 "fork"（dsh toolName 是 per-instance 配置面；spawn
//      实例用缺省 "subagent" 1:1）。
//    - statusOf（list-agents.ts:59-63 running|idle|ready）M7.2 无运行态查询缝
//      → 驻留= idle / 无驻留= ready 两档；M7.3 件 H 起 AgentLoop.currentPhase
//      查询缝在场 → running/idle/ready 三档完整承载（SubagentRuntime.statusOf）。
//    - exec.signal 取消观察 → ToolExecutionContext 无 signal 缝（工具协作式
//      取消经 registry timeout/Task 取消面，M7.2 不挂）。
//

import Foundation

// MARK: - 委派工具（tool-subagent 1:1）

/// 委派一个子 agent 任务（每个 provider 一个工具实例——dsh Config.provider
/// 1:1：WanWo 装配 spawn=one-shot/subagent、fork=continuable/fork 两实例）。
struct SubagentTool: AgentTool {
    let name: String
    let description: String
    let parameters: JSONValue

    private let providerName: String
    private let runtime: SubagentRuntime
    private let jobs: JobRegistryProtocol
    private let parentWriter: SessionWriter
    private let parentModelSelection: SessionModelSelection?
    private let backgroundMode: BackgroundMode
    private let maxDepth: Int?
    private let sandboxOverride: @Sendable () -> SandboxMode?

    enum BackgroundMode: String { case oneShot = "one-shot"; case continuable }

    init(providerName: String,
         toolName: String,
         runtime: SubagentRuntime,
         jobs: JobRegistryProtocol,
         parentWriter: SessionWriter,
         parentModelSelection: SessionModelSelection? = nil,
         backgroundMode: BackgroundMode,
         maxDepth: Int? = 3,
         sandboxOverride: @escaping @Sendable () -> SandboxMode? = { nil }) {
        let isContinuable = backgroundMode == .continuable
        self.providerName = providerName
        self.runtime = runtime
        self.jobs = jobs
        self.parentWriter = parentWriter
        self.parentModelSelection = parentModelSelection
        self.backgroundMode = backgroundMode
        self.maxDepth = maxDepth
        self.sandboxOverride = sandboxOverride
        let wording = Self.providerWording(inheritsParentContext: isContinuable)
        // 工具 description = providerWording + 后台缺省教学句（:381-388 逐字）。
        self.description = wording.description + (isContinuable
            ? " This tool runs in the background by default, immediately returns a durable subagent id, and keeps the child conversation available for later turns. When that run settles, the runtime sends the parent a notice containing its outcome and any final assistant message; `send_message` steers the child's nearest step while it is running and starts a turn while it is idle. Set `run_in_background: false` only when your next action depends on receiving the result."
            : " This call waits for the result by default. Set `run_in_background: true` to return a job id; collect with `job_output` and stop with `job_kill`.")
        self.name = toolName
        self.parameters = .schemaObject(
            properties: [
                "description": .object([
                    "type": .string("string"),
                    "description": .string("A short (3-5 word) description of the delegated task, for display."),
                ]),
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string(wording.promptDescription),
                ]),
                "run_in_background": .object([
                    "type": .string("boolean"),
                    "description": .string(backgroundMode == .continuable
                        ? "Whether to run in the background and return a durable subagent id immediately. Defaults to true. Set false to wait for the result when your next action depends on it."
                        : "Whether to run as a background job and return its id. Defaults to false; collect with job_output or stop with job_kill."),
                ]),
            ],
            required: ["description", "prompt"])
    }

    /// Children never mutate the parent session（:468-470 isConcurrencySafe）。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    /// 模型面措辞（providerWording :251-276 逐字）。
    private static func providerWording(inheritsParentContext: Bool)
        -> (description: String, promptDescription: String) {
        if inheritsParentContext {
            return (
                "Delegate a task to a subagent that inherits this conversation: a child agent seeded with all "
                    + "completed turns so far (it does not see the current in-flight turn). Use this when the subtask "
                    + "builds on this conversation's context — a follow-up analysis, "
                    + "a review, a continuation — without consuming this conversation's context for the work itself. "
                    + "You receive its result, not its intermediate steps.",
                "The task for the subagent. It already sees this conversation's completed turns, so build on them "
                    + "freely and state only what is new."
            )
        }
        return (
            "Delegate a self-contained task to a subagent (a separate agent that works in its own context) "
                + "to offload focused, independent work — research, a scoped "
                + "implementation, an analysis — so it does not consume this conversation's context. The subagent "
                + "returns its result, not its intermediate steps. Give it a "
                + "complete, standalone prompt: it does not see this conversation.",
            "The complete, self-contained task for the subagent. It does not share this "
                + "conversation's context, so include everything it needs."
        )
    }

    /// Resolve the model's optional scheduling request（resolveDelegationRun
    /// :286-305 1:1：后台禁用拒绝；continuable 缺省后台 / one-shot 缺省前台）。
    private func resolveDelegationRun(_ args: JSONValue,
                                      backgroundEnabled: Bool) throws -> Bool {
        let requested = args.field("run_in_background")?.boolValue
        guard backgroundEnabled else {
            if requested == true {
                throw SubagentError(
                    message: "run_in_background is disabled for this tool instance (enableRunInBackground: false)")
            }
            return false
        }
        return requested ?? (backgroundMode == .continuable)
    }

    /// 委派请求组装（:514-523 字段裁剪形态：maxDepth/persona/toolFilter 面）。
    private func makeRequest(label: String, prompt: String) throws -> SubagentStartRequest {
        try SubagentDepth.assertSubagentMaxDepth(maxDepth)
        let events = parentWriter.events
        let durableDepth = SubagentLineage.read(events: events)?.delegationDepth
        let parentDepth = try SubagentDepth.delegationDepthOf(durableDepth: durableDepth,
                                                              runtimeDepth: nil)
        return SubagentStartRequest(
            label: label, prompt: prompt,
            parentSessionId: parentWriter.id,
            parentCwd: parentWriter.header.cwd,
            parentDepth: parentDepth,
            maxDepth: maxDepth,
            sandboxModeOverride: sandboxOverride(),
            modelSelection: parentModelSelection)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let label = args.field("description")?.stringValue,
              let prompt = args.field("prompt")?.stringValue else {
            return .failure("description and prompt are required", code: "SUBAGENT_ERROR",
                            name: "SubagentError")
        }
        let request = try makeRequest(label: label, prompt: prompt)
        let parentLogEvents = parentWriter.events
        let runInBackground = try resolveDelegationRun(args, backgroundEnabled: true)

        if runInBackground {
            if backgroundMode == .continuable {
                // Resolves at inbox acceptance（:527-536）：子回合自此自治，
                // 本调用既不等待也不收集结果。
                let started = try await runtime.startContinuable(
                    provider: providerName, request: request,
                    parentLogEvents: parentLogEvents)
                return .success("started subagent \(started.childId)", meta: .object([
                    "kind": .string("continuable"),
                    "subagentId": .string(started.childId),
                ]))
            }
            // One-shot background child（:538-560）：job preflight 先于 starter
            // spawn；starter 同步发起 runtime.start 并以 hooks 承载取消与结算。
            let jobId = try jobs.start(JobStart(
                kind: .subagent, label: label, ownerSessionId: ctx.sessionId,
                run: { [runtime, providerName, request, parentLogEvents] in
                    let flags = BackgroundStartFlags()
                    let startTask = Task<SubagentRun, Error> {
                        try await runtime.start(provider: providerName,
                                                request: request,
                                                parentLogEvents: parentLogEvents)
                    }
                    return JobHooks(
                        cancel: { _ in
                            flags.cancelled = true
                            startTask.cancel()
                        },
                        done: {
                            // settleStart :143-153：取消不得把 failed cleanup
                            // 归一为 cleanly killed。
                            do {
                                let run = try await startTask.value
                                return await SubagentSettlement.settleRun(run)
                            } catch {
                                if flags.cancelled && !(error is SubagentError) {
                                    return JobOutcome(status: .killed)
                                }
                                return JobOutcome(status: .failed,
                                                  detail: String(describing: error))
                            }
                        })
                }))
            return .success("started background subagent job \(jobId)", meta: .object([
                "kind": .string("background"),
                "jobId": .string(jobId),
            ]))
        }

        // Foreground（:563-567）：等结果 + settleForegroundRun。
        let run = try await runtime.start(provider: providerName, request: request,
                                          parentLogEvents: parentLogEvents)
        let result: SubagentResult
        do {
            result = try await run.result.value
        } catch {
            await run.dispose()
            throw error
        }
        await run.dispose()
        if let error = SubagentSettlement.stopReasonError(result) {
            // isError 承载；partial output 随错误行到达父侧（:209-224 语义）。
            return .failure(SubagentSettlement.withDiagnosticAndPartialText(error, result),
                            code: "SUBAGENT_RUN_FAILED", name: "SubagentError")
        }
        return .success(result.output, meta: .object([
            "kind": .string("foreground"),
            "runId": .string(run.id),
        ]))
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Delegate subagent",
                       detail: args.field("description")?.stringValue)
    }
}

/// 后台启动取消旗标（settleStart 的 signal.aborted 承载）。
private final class BackgroundStartFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

// MARK: - 控制工具（tool-subagent-control 1:1）

/// send_message：直接 continuable 子（或驻留子回直接父）的消息投递薄适配层
///（residency/cold-resume/授权全归 SubagentRuntime.sendMessage）。
struct SendMessageAgentTool: AgentTool {
    let name = "send_message"
    let description = "Send a message to a direct continuable child by its agent id. If you are a resident continuable child, "
        + "you may also target your direct parent. If the target is still working, the message steers its nearest step; "
        + "if it is idle, the message starts a turn. This call returns no answer from the agent — only confirmation "
        + "that the message was delivered. A failure means the message was NOT delivered."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "agent_id": .object([
                "type": .string("string"),
                "description": .string("The agent id of your direct continuable child, or your direct parent when you are a resident continuable child."),
            ]),
            "message": .object([
                "type": .string("string"),
                "description": .string("The message to deliver to the agent."),
            ]),
        ],
        required: ["agent_id", "message"])

    let runtime: SubagentRuntime

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let agentId = args.field("agent_id")?.stringValue,
              let message = args.field("message")?.stringValue else {
            return .failure("agent_id and message are required", code: "SUBAGENT_ERROR",
                            name: "SubagentError")
        }
        do {
            let messageId = try await runtime.sendMessage(
                from: ctx.sessionId, to: agentId, text: message)
            return .success("message delivered to agent \(agentId)", meta: .object([
                "messageId": .string(messageId),
            ]))
        } catch let error as SubagentError {
            return .failure(error.message, code: error.code, name: "SubagentError")
        }
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Message subagent",
                       detail: args.field("agent_id")?.stringValue)
    }
}

/// interrupt_agent：请求取消一个后台 agent 的当前回合（祖先授权校验在
/// runtime——M7.2 直接父校验，transitive 登记未实现）。
struct InterruptAgentTool: AgentTool {
    let name = "interrupt_agent"
    let description = "Request cancellation of a background agent's current turn by its agent id. The target may be your "
        + "direct child or a deeper agent created under you. Only the current turn stops: messages already "
        + "queued for the agent stay parked until a later send_message, agents it started keep running, and "
        + "the agent itself stays available for follow-ups. This call returns as soon as the stop request is "
        + "accepted, so the target may keep running briefly; interrupting an agent that already finished is "
        + "an accepted no-op."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "agent_id": .object([
                "type": .string("string"),
                "description": .string("The agent id of the running agent to interrupt."),
            ]),
        ],
        required: ["agent_id"])

    let runtime: SubagentRuntime

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let agentId = args.field("agent_id")?.stringValue else {
            return .failure("agent_id is required", code: "SUBAGENT_ERROR",
                            name: "SubagentError")
        }
        do {
            _ = try await runtime.interrupt(childId: agentId,
                                            callerSessionId: ctx.sessionId)
            return .success("interrupt requested for agent \(agentId)", meta: .object([
                "accepted": .bool(true),
            ]))
        } catch let error as SubagentError {
            return .failure(error.message, code: error.code, name: "SubagentError")
        }
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Interrupt subagent",
                       detail: args.field("agent_id")?.stringValue)
    }
}

/// list_agents：按 durable id 与 label 列出 continuable 后台子（children 缺省
/// / descendants 全树；快照不是投递承诺——send_message 才做权威检查）。
struct ListAgentsTool: AgentTool {
    let name = "list_agents"
    let description = "List your continuable background subagents by durable id and label. Use it to recall which ones "
        + "you started, not to poll for completion — you are told when one finishes. Status comes from the live "
        + "registry: running means the agent is working right now, idle means it is loaded but between turns "
        + "(it may be waiting on agents it started), and ready means it exists only in storage — resumable, not "
        + "terminal, and not a result waiting to be collected; a `send_message` steers a running child at its nearest "
        + "step boundary or starts a turn for an idle or ready child, and a direct child remains a `send_message` "
        + "candidate in every status. The snapshot is not a delivery "
        + "promise — `send_message` performs the authoritative check and may still fail. Children that could "
        + "not be read are reported as diagnostics instead of being silently dropped. Scope `descendants` "
        + "walks the whole tree below you in stable pre-order, annotating each entry with its durable direct-parent "
        + "session id and depth. You may use `send_message` only for depth-1 entries; deeper entries are "
        + "candidates for `interrupt_agent` only."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "scope": .object([
                "type": .string("string"),
                "enum": .array([.string("children"), .string("descendants")]),
                "description": .string("children (default) lists direct children only; descendants walks the complete tree below you."),
            ]),
        ],
        required: [])

    let runtime: SubagentRuntime

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let scope = args.field("scope")?.stringValue ?? "children"
        guard scope == "children" || scope == "descendants" else {
            return .failure("scope must be \"children\" or \"descendants\"",
                            code: "SUBAGENT_ERROR", name: "SubagentError")
        }
        let entries = await runtime.listAgents(callerSessionId: ctx.sessionId,
                                               includeDescendants: scope == "descendants")
        if entries.isEmpty {
            return .success("(no subagents)", meta: .array([]))
        }
        let lines = entries.map { entry -> String in
            // M7.3：status 三档（runtime phase 查询——running/idle/ready）。
            let at = scope == "descendants"
                ? " parent=\(ctx.sessionId) depth=\(entry.depth)"
                : ""
            return "\(entry.subagentId) [\(entry.status)]\(at) — \(entry.label)"
        }
        return .success(lines.joined(separator: "\n"), meta: .array(
            entries.map { entry in
                .object([
                    "kind": .string("child"),
                    "id": .string(entry.subagentId),
                    "label": .string(entry.label),
                    "status": .string(entry.status),
                ])
            }))
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "List subagents")
    }
}

/// wait_agent：等任意存活 agent 的 mailbox 活动（M7.3 件 H 新增——codex
/// multi_agents_v2/wait.rs 1:1；主理人判定①：批1 工具词汇之外唯一新增工具）。
/// 等待-唤醒基于 AgentLoop.waitForInboxActivity（watch 通道语义，不轮询）；
/// timeout 语义（wait.rs:53-65）：>max 拒绝 / <min 上夹至 min / 缺省 30s。
struct WaitAgentTool: AgentTool {
    let name = "wait_agent"
    let description = "Wait for a mailbox update from any live agent, including queued messages and final-status notifications. The wait also ends early when new user input is steered into the active turn. Does not return the content; returns either a summary of which agents have updates (if any), an interruption summary for steered input, or a timeout summary if no activity arrives before the deadline."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "timeout_ms": .object([
                "type": .string("number"),
                "description": .string("Timeout in milliseconds. Defaults to "
                    + "\(SubagentGovernance.defaultWaitTimeoutMs), min "
                    + "\(SubagentGovernance.minWaitTimeoutMs), max "
                    + "\(SubagentGovernance.maxWaitTimeoutMs)."),
            ]),
        ],
        required: [])

    private let parentLoop: AgentLoop

    init(parentLoop: AgentLoop) {
        self.parentLoop = parentLoop
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // wait.rs:52 parse_arguments + :57-65 夹取语义 1:1。
        let requestedMs: Int64?
        if let field = args.field("timeout_ms") {
            if let intValue = field.intValue {
                requestedMs = Int64(intValue)
            } else if let doubleValue = field.doubleValue {
                requestedMs = Int64(doubleValue)
            } else {
                return .failure("timeout_ms must be a number",
                                code: "WAIT_TIMEOUT_INVALID", name: "SubagentError")
            }
        } else {
            requestedMs = nil
        }
        let effectiveMs: Int64
        if let requestedMs {
            if requestedMs > SubagentGovernance.maxWaitTimeoutMs {
                // RespondToModel 等价（wait.rs:58-61）。
                return .failure(
                    "timeout_ms must be at most \(SubagentGovernance.maxWaitTimeoutMs)",
                    code: "WAIT_TIMEOUT_INVALID", name: "SubagentError")
            }
            effectiveMs = max(requestedMs, SubagentGovernance.minWaitTimeoutMs)
        } else {
            effectiveMs = SubagentGovernance.defaultWaitTimeoutMs
        }

        // wait_for_activity（wait.rs:187-205）：watch 通道挂起至活动/超时。
        let outcome = await parentLoop.waitForInboxActivity(timeoutMs: effectiveMs)
        // WaitAgentResult.from_outcome（wait.rs:139-159）1:1：三分支消息 +
        // 夹取提示行 + timed_out 旗标。恒 success（wait.rs:167 success_for_logging）。
        let base: String
        var timedOut = false
        switch outcome {
        case .mailbox: base = "Wait completed."
        case .steer: base = "Wait interrupted by new input."
        case nil:
            base = "Wait timed out."
            timedOut = true
        }
        var message = base
        if let requestedMs, requestedMs < effectiveMs {
            message += "\n\nRequested timeout of \(requestedMs)ms was clamped to "
                + "the minimum of \(effectiveMs)ms."
        }
        return .success(message, meta: .object([
            "timed_out": .bool(timedOut),
        ]))
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Wait for subagents")
    }
}

// MARK: - 注册面（装配辅助）

/// tool-subagent + tool-subagent-control + list-agents + wait_agent 的
/// WanWo 装配入口。
enum SubagentTools {
    /// 注册全部委派/控制工具 + continuable 提示段（AppEnvironment.makeAgentStack
    /// 调用；spawn=one-shot/subagent、fork=continuable/fork 两实例）。注册冲突
    /// 可捕获（幂等重装配安全——MCP 资源三元同纪律）。
    /// - Parameters:
    ///   - sandboxOverride: 父沙箱供值缝（QA-3 P1-5：makeAgentStack 传
    ///     permission.knobs.sandbox 实时读——万我无显式 override 区分缝，
    ///     knob 直传，登记见报告）。
    ///   - modelSelection: 父会话模型选择（QA-3 P1-6：子栈同路由——KV-cache
    ///     fork 前缀跨端点失效修复）。
    ///   - parentLoop: 父 loop（M7.3 件 H：wait_agent 等待-唤醒底座）。
    static func registerAll(into registry: ToolRegistry,
                            assembler: PromptAssembler,
                            runtime: SubagentRuntime,
                            jobs: JobRegistryProtocol,
                            writer: SessionWriter,
                            parentLoop: AgentLoop,
                            modelSelection: SessionModelSelection? = nil,
                            sandboxOverride: @escaping @Sendable () -> SandboxMode? = { nil },
                            maxDepth: Int? = 3) {
        let candidates: [any AgentTool] = [
            SubagentTool(
                providerName: "spawn", toolName: "subagent", runtime: runtime,
                jobs: jobs, parentWriter: writer, parentModelSelection: modelSelection,
                backgroundMode: .oneShot, maxDepth: maxDepth,
                sandboxOverride: sandboxOverride),
            SubagentTool(
                providerName: "fork", toolName: "fork", runtime: runtime,
                jobs: jobs, parentWriter: writer, parentModelSelection: modelSelection,
                backgroundMode: .continuable, maxDepth: maxDepth,
                sandboxOverride: sandboxOverride),
            SendMessageAgentTool(runtime: runtime),
            InterruptAgentTool(runtime: runtime),
            ListAgentsTool(runtime: runtime),
            WaitAgentTool(parentLoop: parentLoop),
        ]
        for tool in candidates {
            do {
                _ = try registry.tryRegister(tool)
            } catch {
                // 同名工具已在场（重装配）= 幂等 no-op；其他冲突按可捕获路径
                // 吞并（装配侧呈现面归 AppEnvironment，登记）。
                continue
            }
        }
        // tool:<name> 提示段（:594-605；仅 continuable 后台缺省实例——fork）。
        assembler.section(PromptSection(
            name: "tool:fork",
            order: SECTION_ORDERS.toolSubagent,
            text: "Use fork in the background by default. Start independent delegations together in one assistant message and continue useful work while they run. Set `run_in_background: false` only when your next action depends on that subagent's result. When a background run settles, the runtime sends you a notice containing its outcome and any final assistant message."))
    }
}
