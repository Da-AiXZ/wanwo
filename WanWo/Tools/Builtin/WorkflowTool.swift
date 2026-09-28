//
//  WorkflowTool.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】model-facing `workflow` 工具
//  （packages/workflow/tool-workflow/src/index.ts 逐文件对拍）：
//    - index.ts:137-149   —— DESCRIPTION 逐字（脚本契约 = 模型面 spec：
//      meta 块 + 五钩子精确语义 + schema 子集声明）。
//    - index.ts:219-255   —— parameters schema（script 必填 / meta 必填
//      {name/description 必填 + whenToUse/phases} / args 可选 object）。
//    - index.ts:179-192   —— stopReasonError（非 completed → isError 结果
//      三分支文案逐字；本 port 经 throw → ToolPipeline 合成 failure）。
//    - index.ts:195-202   —— renderResult（JSON.stringify 2 缩进 +
//      maxResultChars 截断通知 `\n… [truncated: N more characters]`）。
//    - index.ts:211-215   —— tool:workflow 提示段（仅用户明确要求时用）。
//    - index.ts:271-330   —— execute（exec.agent 缺失 fail loud / 引擎 start →
//      await run.result → 非 completed throw → 返回 {runId, agentsStarted,
//      result}；finally 恒 dispose）。
//
//  万我适配裁定（登记）：
//    - dsh exec.agent → ToolExecutionContext.sessionId + 构造注入的
//      parentWriter（发起方会话身份/深度/cwd——SubagentTool 同款缝）。
//      exec.agent 缺失面（非 agent 调用方直调）在万我不存在——
//      ToolExecutionContext 恒带 sessionId，guard 不移植，登记。
//    - dsh exec.signal abort 桥 → ToolExecutionContext 无 signal 缝
//      （SubagentTools 同裁定）；Task 取消经 withTaskCancellationHandler
//      桥到 run.cancel('parent step aborted')（取消语义保真）。
//    - recorder 四事件（index.ts:72-130 tool-workflow/run-start 等 session
//      追加）→ 引擎 listener 注册表承载（addWorkflowListener）——会话归档
//      在装配段闭合成 recorder 等价面，工具层不再自持 recorder，登记。
//    - presentCall rawInput（script 原文）→ ToolCardIntent 无 rawInput 槽，
//      detail 缺省（M9 卡片族补齐），登记。
//    - JSON.stringify(value, null, 2) → JSONEncoder prettyPrinted（缩进
//      2 空格 + 键排序；JS UTF-16 length → Swift Character count，登记）。
//

import Foundation

// MARK: - 工具（index.ts:216-333 defineTool 1:1）

/// model-facing `workflow` 工具：运行编排 subagent 的 JavaScript 脚本并返回
/// 脚本终值。schema/生命周期归本工具；解析/执行/上限/取消在引擎。
struct WorkflowTool: AgentTool {

    let name = "workflow"
    let description: String
    let parameters: JSONValue

    /// 引擎（校验+装配+事件；执行核心在 WorkflowExecution）。
    private let engine: WorkflowEngine
    /// 发起方会话写面（lineage 深度 / cwd / 归属）。
    private let parentWriter: SessionWriter
    /// 子会话绝对委派深度帽（SubagentTool 同缺省）。
    private let maxDepth: Int?
    /// 渲染结果上限（index.ts:41 maxResultChars 缺省 50000）。
    private let maxResultChars: Int

    init(engine: WorkflowEngine,
         parentWriter: SessionWriter,
         maxDepth: Int? = 3,
         maxResultChars: Int = 50_000) {
        self.engine = engine
        self.parentWriter = parentWriter
        self.maxDepth = maxDepth
        self.maxResultChars = maxResultChars
        self.description = Self.description
        self.parameters = Self.parametersSchema
    }

    /// The script-authoring contract, embedded in the tool description. This
    /// IS the model-facing spec（index.ts:137-149 逐字）。
    static let description = """
        Run a JavaScript workflow script that orchestrates subagents at scale. Use this for work that fans out across many independent pieces — an audit over many files, a migration, multi-angle research, adversarial verification of findings — where you write the orchestration as a script instead of delegating turn by turn.

        The workflow's identity rides the `meta` parameter as JSON: required `name` (short kebab-case) and `description` strings, optional `whenToUse` string and `phases` array (`{title, detail?, provider?, model?}`). The `script` parameter is the plain JavaScript body ONLY (NOT TypeScript, and NO `export const meta` statement — meta is a parameter, not code), running with top-level await; end with `return <value>` — the value must be JSON-serializable and is this tool's result.

        Script-body hooks:
        - `agent(prompt, opts?): Promise<any>` — run one subagent to completion. Without `opts.schema` it resolves to the child's final text; with `opts.schema` (an object-rooted JSON Schema using ONLY type/properties/required/additionalProperties/items/enum/const/oneOf — no pattern/format/numeric bounds) it resolves to the validated object. Resolves `null` when the child fails (filter with `.filter(Boolean)`). Other opts: `label` (display), `phase` (progress group), and independent `provider`/`model` LLM target overrides (either may be provided alone). Anything else (`effort`/`isolation`/`agentType`) is rejected loudly.
        - `pipeline(items, ...stages): Promise<any[]>` — run each item through the stages independently with NO barrier between stages (prefer this for multi-stage work). Each stage receives `(prev, item, index)`. An ordinary stage throw drops that ITEM to `null` and skips its remaining stages.
        - `parallel(thunks): Promise<any[]>` — run zero-argument functions concurrently and await ALL of them (a barrier; use only when a stage genuinely needs every prior result together). A throwing thunk resolves to `null`.
        - `phase(title)` — start a progress phase; `log(message)` — narrate progress; `args` — the tool call's `args` input, verbatim.

        Misused hooks (bad arguments, unknown options, unsupported schemas, tripped caps) throw errors that ALWAYS kill the script — they never dissolve into a per-item `null`.

        Constraints: concurrency and total-agent caps apply; no filesystem, network, timers, or Node.js APIs are provided — the agents do the work, the script only coordinates them. The run executes in the foreground: this call returns when the whole script finishes.
        """

    /// parameters schema（index.ts:219-255 1:1 面）。
    private static let parametersSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "script": .object([
                "type": .string("string"),
                "required": .bool(true),
                "description": .string("The plain-JS workflow script body (top-level await allowed; NO `export const meta` statement; end with `return <json-value>`)."),
            ]),
            "meta": .object([
                "type": .string("object"),
                "required": .bool(true),
                "description": .string("The workflow identity block (plain JSON — never code)."),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "required": .bool(true),
                        "description": .string("Short kebab-case workflow name."),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "required": .bool(true),
                        "description": .string("One-line description of what the workflow does."),
                    ]),
                    "whenToUse": .object([
                        "type": .string("string"),
                        "description": .string("Optional guidance on when this workflow applies."),
                    ]),
                    "phases": .object([
                        "type": .string("array"),
                        "description": .string("Optional phase declarations matched by phase() calls."),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "required": .bool(true),
                                    "description": .string("The phase title phase() calls match by exact string."),
                                ]),
                                "detail": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional one-line description of the phase."),
                                ]),
                                "provider": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional provider override this phase is expected to use."),
                                ]),
                                "model": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional model override this phase is expected to use."),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            "args": .object([
                "type": .string("object"),
                "description": .string("Optional JSON input exposed to the script as the `args` global (wrap a bare list as a field, e.g. {\"files\": [...]})."),
            ]),
        ]),
        "required": .array([.string("script"), .string("meta")]),
    ])

    /// Children never mutate the parent session（dsh 工具族同纪律）。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    /// The pending-state card（index.ts:163-169：generic 卡，meta.name 题）。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        guard let metaName = args.field("meta")?.field("name")?.stringValue else {
            return ToolCardIntent(title: "workflow")
        }
        return ToolCardIntent(title: "workflow: \(metaName)")
    }

    /// The completed-state card（index.ts:172-176：保留 pending 题）。
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? {
        presentCall(args)
    }

    // MARK: execute（index.ts:271-330）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // exec.agent 缺失 guard（:272-278）在万我不存在——ToolExecutionContext
        // 恒带 sessionId（见头注登记）；此处的"agent 调用方"即会话本体。

        // 1. meta 解析（engine.start 内 validateWorkflowMeta 再校验——此处
        //    先行 shape 解码取 WorkflowMeta 结构；META_INVALID 文案同源）。
        guard let script = args.field("script")?.stringValue,
              let metaJSON = args.field("meta") else {
            return .failure("script and meta are required", code: "INVALID_ARGUMENT",
                            name: "WorkflowError")
        }
        let meta = try validateWorkflowMeta(metaJSON)

        // 2. 父会话快照（SubagentTool.makeRequest 同款缝：durable 地板深度）。
        try SubagentDepth.assertSubagentMaxDepth(maxDepth)
        let events = parentWriter.events
        let durableDepth = SubagentLineage.read(events: events)?.delegationDepth
        let parentDepth = try SubagentDepth.delegationDepthOf(durableDepth: durableDepth,
                                                              runtimeDepth: nil)
        let parent = WorkflowParent(
            sessionId: ctx.sessionId,
            depth: parentDepth,
            cwd: parentWriter.header.cwd)

        // 3. run 启动（index.ts:283-289：args 仅在提供时传；signal 桥万我经
        //    Task 取消面，见下）。
        let run = try await engine.start(WorkflowStartRequest(
            script: script,
            meta: meta,
            args: args.field("args"),
            subagentProvider: nil,
            maxTotalAgents: nil,
            parent: parent))

        // 4. abort 桥（:296-299）：父 step 中止 → 整 run 取消。万我 signal
        //    缝 → Task cancellation 桥（登记）。
        let result: WorkflowResult = await withTaskCancellationHandler {
            await run.result.value
        } onCancel: {
            run.cancel("parent step aborted")
        }

        // 5. 非 completed → isError（:301-309 stopReasonError 三分支）。
        if let error = Self.stopReasonError(result) {
            await run.dispose()
            throw WorkflowToolError(message: error)
        }

        // 6. finally 恒 dispose（:315-329——result 结算后善后有界收敛）。
        await run.dispose()

        // 7. 返回 {runId, agentsStarted, result}（:310-314）。
        let rendered = Self.renderResult(
            name: meta.name, agentsStarted: result.agentsStarted,
            value: result.value, maxChars: maxResultChars)
        return .success(rendered, meta: .object([
            "runId": .string(run.id),
            "agentsStarted": .int(result.agentsStarted),
            "result": result.value,
        ]))
    }

    // MARK: 渲染面（index.ts:179-202 1:1）

    /// A non-`completed` stop reason means the script did not finish cleanly
    ///（三分支文案逐字；closed union —— exhaustive by construction）。
    static func stopReasonError(_ result: WorkflowResult) -> String? {
        switch result.stopReason {
        case .completed:
            return nil
        case .cancelled:
            if let error = result.error {
                return "workflow run was cancelled (\(error))"
            }
            return "workflow run was cancelled"
        case .error:
            return "workflow run failed: \(result.error ?? "unknown error")"
        }
    }

    /// Render the run's outcome text: the meta name, agent count, and the JSON
    /// value (capped)（:195-202 逐语义；stringify 经 JSONEncoder）。
    static func renderResult(name: String, agentsStarted: Int,
                             value: JSONValue, maxChars: Int) -> String {
        let rendered = Self.prettyJSON(value)
        let clipped = rendered.count > maxChars
            ? "\(rendered.prefix(maxChars))\n… [truncated: \(rendered.count - maxChars) more characters]"
            : rendered
        let plural = agentsStarted == 1 ? "" : "s"
        return "workflow \"\(name)\" completed (\(agentsStarted) agent\(plural)).\nReturn value:\n\(clipped)"
    }

    /// JSON.stringify(value, null, 2) 等价（键排序 + 2 空格缩进）。
    static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// 工具层抛错（经 ToolPipeline 合成 isError 结果——模型可见违规原因）。
struct WorkflowToolError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - 装配面（index.ts:204-215 apply 1:1：提示段 + 工具注册）

/// tool-workflow 的 WanWo 装配入口（AppEnvironment Workflow 段调用）。
enum WorkflowTools {
    /// 注册 `workflow` 工具 + `tool:workflow` 提示段。注册冲突可捕获
    /// （幂等重装配安全——SubagentTools 同纪律）。
    static func registerAll(into registry: ToolRegistry,
                            assembler: PromptAssembler,
                            engine: WorkflowEngine,
                            parentWriter: SessionWriter) {
        do {
            _ = try registry.tryRegister(WorkflowTool(
                engine: engine, parentWriter: parentWriter))
        } catch {
            // 同名工具已在场（重装配）= 幂等 no-op；其他冲突按可捕获路径吞并。
        }
        // Usage policy ships with the tool（index.ts:211-215 文案逐字）。
        assembler.section(PromptSection(
            name: "tool:workflow",
            order: SECTION_ORDERS.toolWorkflow,
            text: "Use the workflow tool ONLY when the user explicitly asks for a workflow or for large multi-agent orchestration: you write a JavaScript script (the tool description documents the exact format) that fans work out across many subagents with phases and structured results. For one or two delegations, prefer plain subagent calls."))
    }
}
