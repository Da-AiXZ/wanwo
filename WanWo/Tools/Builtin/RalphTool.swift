//
//  RalphTool.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F048】model-facing 前台 Ralph 循环工具
//  （packages/workflow/tool-ralph/src/index.ts 逐文件对拍）：
//    - index.ts:88-175    —— RALPH_SCRIPT String.raw 逐字内嵌（固定编排：
//      模型只供数据，不可改循环/provider 路由/schema/交接校验；maxRounds
//      缺省 256——批3 派单裁定：07 清单 64 过时）。
//    - index.ts:78-82     —— RALPH_META（ralph-loop）。
//    - index.ts:177-182   —— DESCRIPTION 逐字。
//    - index.ts:206-215   —— resolveMaxRounds（文案逐字）。
//    - index.ts:218-230   —— requireFreshProvider（三段文案逐字）。
//    - index.ts:245-331   —— readReport/readRunResult 防御性解码（键集排序
//      精确匹配 / budget-limited 须 roundsStarted==maxRounds / 首轮
//      round-failed lastReport 必须 null / 16384 交接帽）。
//    - index.ts:333-390   —— stopReasonError / TRUNCATION_NOTICE /
//      boundResult / renderResult / renderRoundFailure（文案逐字）。
//    - index.ts:403-476   —— apply（tool:ralph 提示段 + 工具注册 + execute：
//      objective trim 非空 → resolveMaxRounds → requireFreshProvider →
//      engine.start{script, meta, args:{objective,maxRounds,maxHandoffChars},
//      subagentProvider, maxTotalAgents: maxRounds}）。
//
//  万我适配裁定（登记）：
//    - RALPH_SCRIPT 经 WorkflowEngine 执行；schema 交接经 QA-7 缝①落地：
//      SubagentStartRequest.outputSchema（本批自落）→ SubagentInProcessDriver
//      .readResult 按报告 schema 解析+校验 → SubagentResult.structured →
//      agent() 钩子取得结构化对象 → 脚本 validateReport 二次校验（帽面）。
//    - exec.agent/exec.signal 桥同 WorkflowTool 裁定（sessionId 恒在 /
//      Task 取消桥；:456 启动前已 aborted 即检由
//      withTaskCancellationHandler 对已取消 Task 立即触发 onCancel 承载）。
//    - resolveConfig（:185-203）为装配期校验——万我 init precondition
//      承载（部署错配 = fatal loud，dsh apply throw 同 spirit）。
//    - JSON.stringify 键序差异（JS 插入序 vs Swift 排序）不影响解码——
//      readReport 键集比对自行排序，rendering 经 JSONEncoder sortedKeys；
//      length 判定按 Swift Character count（JS UTF-16 length，登记）。
//

import Foundation

// MARK: - 报告词汇（index.ts:47-71）

/// One round's structured report（reportSchema 五字段）。
struct RalphRoundReport: Equatable, Sendable {
    enum Status: String, Sendable {
        case `continue`, complete, blocked
    }

    var status: Status
    var summary: String
    var evidence: [String]
    var nextSteps: [String]
    var blocker: String
}

/// The run-shaped terminal result（index.ts:57-63——complete/blocked/
/// budget-limited；budget-limited 在 Swift 编码为 status .`continue`（其
/// report 期望 'continue' 形状），renderResult 的 .continue 分支即
/// budget-limited 信封——登记）。
struct RalphRunResult: Equatable, Sendable {
    var status: RalphRoundReport.Status
    var roundsStarted: Int
    var report: RalphRoundReport
}

/// An ordinary child failure terminal（index.ts:65-69；lastReport undefined
/// 与 null 在 Swift 同收敛为 nil——两处判定位均已分支，登记）。
struct RalphRoundFailure: Equatable, Sendable {
    var roundsStarted: Int
    var lastReport: RalphRoundReport?
}

/// The fixed script's terminal value（index.ts:71 联合）。
enum RalphTerminalResult: Equatable, Sendable {
    case run(RalphRunResult)
    case roundFailed(RalphRoundFailure)
}

// MARK: - 工具（index.ts:410-476 defineTool 1:1）

/// model-facing 前台 Ralph 循环：每轮一枚全新 structured-output 子 agent，
/// 只携带不可变目标与上一轮有界结构化交接。
struct RalphTool: AgentTool {

    let name = "ralph"
    let description: String
    let parameters: JSONValue

    private let engine: WorkflowEngine
    private let runtime: SubagentRuntime
    private let parentWriter: SessionWriter
    private let maxDepth: Int?
    // index.ts:23-29 Config（resolved：resolveConfig :185-203 缺省+校验）。
    private let subagentProvider: String
    private let maxRoundsCeiling: Int
    private let maxHandoffChars: Int
    private let maxResultChars: Int

    /// - Precondition: 配置非法时 fatalError（装配期 loud——:190-201 文案）。
    init(engine: WorkflowEngine,
         runtime: SubagentRuntime,
         parentWriter: SessionWriter,
         subagentProvider: String = "spawn",
         maxRoundsCeiling: Int = 256,
         maxHandoffChars: Int = 16_384,
         maxResultChars: Int = 16_384,
         maxDepth: Int? = 3) {
        precondition(!subagentProvider.isEmpty && subagentProvider == subagentProvider.trimmingCharacters(in: .whitespaces),
                     "subagentProvider must be a non-empty normalized string")
        precondition(maxRoundsCeiling >= 1, "maxRounds must be a positive safe integer")
        precondition(maxHandoffChars >= 1, "maxHandoffChars must be a positive safe integer")
        precondition(maxResultChars >= 1, "maxResultChars must be a positive safe integer")
        self.engine = engine
        self.runtime = runtime
        self.parentWriter = parentWriter
        self.subagentProvider = subagentProvider
        self.maxRoundsCeiling = maxRoundsCeiling
        self.maxHandoffChars = maxHandoffChars
        self.maxResultChars = maxResultChars
        self.maxDepth = maxDepth
        self.description = Self.description
        self.parameters = Self.parametersSchema
    }

    /// DESCRIPTION（index.ts:177-182 逐字拼接）。
    static let description = "Run a foreground fresh-agent Ralph loop toward one immutable objective. "
        + "Use only when the direct human explicitly asks for Ralph or fresh-agent iteration. Each round "
        + "opens a new child with no parent conversation or prior child session; the shared workspace is "
        + "long-term memory, and only a bounded structured report crosses rounds. The call returns when "
        + "a worker reports completion or a concrete blocker, or at the round limit. Ordinary long-running same-session work "
        + "belongs to goal tools."

    /// parameters schema（index.ts:413-423）。
    private static let parametersSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "objective": .object([
                "type": .string("string"),
                "required": .bool(true),
                "description": .string("The immutable completion objective for every fresh Ralph round."),
            ]),
            "maxRounds": .object([
                "type": .string("number"),
                "description": .string("Optional positive safe-integer round cap, bounded by the deployment ceiling."),
            ]),
        ]),
        "required": .array([.string("objective")]),
    ])

    /// Children never mutate the parent session。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    /// presentCall（index.ts:392-394：generic 卡题 'ralph'）。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "ralph")
    }

    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? {
        ToolCardIntent(title: "ralph")
    }

    // MARK: 固定编排（index.ts:88-175 String.raw 逐字内嵌）

    /// Fixed, deployment-owned orchestration. The model supplies data only;
    /// it cannot alter the loop, provider route, schema, or handoff validation.
    /// （Swift 原样字符串承载——`\n` 等转义保持字面，与 String.raw 同语义。）
    static let script = #"""
    const reportSchema = {
      type: 'object',
      properties: {
        status: { type: 'string', enum: ['continue', 'complete', 'blocked'] },
        summary: { type: 'string' },
        evidence: { type: 'array', items: { type: 'string' } },
        nextSteps: { type: 'array', items: { type: 'string' } },
        blocker: { type: 'string' },
      },
      required: ['status', 'summary', 'evidence', 'nextSteps', 'blocker'],
      additionalProperties: false,
    }

    function normalizedText(value) {
      return typeof value === 'string' && value.length > 0 && value === value.trim()
    }

    function normalizedList(value) {
      return Array.isArray(value) && value.every(normalizedText)
    }

    function validateReport(report) {
      if (report === null || typeof report !== 'object' || Array.isArray(report)) {
        throw new Error('Ralph child returned no structured round report')
      }
      if (!normalizedText(report.summary)) {
        throw new Error('Ralph round report summary must be non-empty and normalized')
      }
      if (!normalizedList(report.evidence) || !normalizedList(report.nextSteps)) {
        throw new Error('Ralph round report evidence and nextSteps must contain only non-empty normalized strings')
      }
      if (typeof report.blocker !== 'string' || report.blocker !== report.blocker.trim()) {
        throw new Error('Ralph round report blocker must be a normalized string')
      }
      switch (report.status) {
        case 'continue':
          if (report.nextSteps.length === 0 || report.blocker !== '') {
            throw new Error('a continuing Ralph report needs nextSteps and an empty blocker')
          }
          break
        case 'complete':
          if (report.evidence.length === 0 || report.nextSteps.length !== 0 || report.blocker !== '') {
            throw new Error('a complete Ralph report needs evidence, no nextSteps, and an empty blocker')
          }
          break
        case 'blocked':
          if (!normalizedText(report.blocker)) {
            throw new Error('a blocked Ralph report needs a concrete blocker')
          }
          break
        default:
          throw new Error('Ralph round report status is invalid')
      }
      const serialized = JSON.stringify(report)
      if (serialized.length > args.maxHandoffChars) {
        throw new Error('Ralph round report exceeds maxHandoffChars (' + serialized.length + ' > ' + args.maxHandoffChars + ')')
      }
      return report
    }

    let previous
    phase('Fresh-agent rounds')
    for (let round = 1; round <= args.maxRounds; round += 1) {
      const prior = previous === undefined ? '(none — this is the first round)' : JSON.stringify(previous)
      const prompt = [
        'You are one fresh worker in a foreground Ralph loop. You receive no parent conversation and no prior child session. Do not call the ralph tool: this round already is its worker.',
        'Immutable objective:\n' + args.objective,
        'Ralph round: ' + round + ' of ' + args.maxRounds + '.',
        'The shared workspace and its current working tree are the long-term memory and source of truth. Inspect them before acting, preserve existing work, perform concrete in-scope work, and verify what you change. Treat the previous report only as a bounded handoff; confirm it against the workspace.',
        'Previous structured handoff:\n' + prior,
        'Return one report with exact normalized strings. Use status continue with at least one nextSteps entry while useful work remains; complete only with concrete evidence and no nextSteps; blocked only when no meaningful progress is possible without human input or an external-state change. blocker must be empty unless blocked.',
      ].join('\n\n')
      const rawReport = await agent(prompt, {
        label: 'Ralph round ' + round,
        phase: 'Fresh-agent rounds',
        schema: reportSchema,
      })
      if (rawReport === null) {
        return { status: 'round-failed', roundsStarted: round, lastReport: previous ?? null }
      }
      const report = validateReport(rawReport)
      if (report.status === 'complete') return { status: 'complete', roundsStarted: round, report }
      if (report.status === 'blocked') return { status: 'blocked', roundsStarted: round, report }
      previous = report
    }
    return { status: 'budget-limited', roundsStarted: args.maxRounds, report: previous }
    """#

    /// RALPH_META（index.ts:78-82 1:1）。
    static let meta = WorkflowMeta(
        name: "ralph-loop",
        description: "Iterate toward one objective with a fresh child and bounded structured handoff per round.",
        whenToUse: nil,
        phases: [WorkflowPhaseDecl(
            title: "Fresh-agent rounds",
            detail: "One clean child context per Ralph round.",
            provider: nil, model: nil)])

    // MARK: execute（index.ts:435-473）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // 1. objective trim 非空（:440-441 文案逐字）。
        guard let rawObjective = args.field("objective")?.stringValue else {
            throw RalphToolError(message: "Ralph objective must be a non-empty string")
        }
        let objective = rawObjective.trimmingCharacters(in: .whitespaces)
        if objective.isEmpty {
            throw RalphToolError(message: "Ralph objective must be a non-empty string")
        }
        // 2. 轮帽解析（:206-215 文案逐字）。
        let maxRounds = try Self.resolveMaxRounds(args.field("maxRounds")?.intValue,
                                                  ceiling: maxRoundsCeiling)
        // 3. requireFreshProvider（:218-230 三段文案逐字；actor 查询面 await）。
        try await Self.requireFreshProvider(runtime, name: subagentProvider)

        // 4. 父会话快照（WorkflowTool 同款缝：durable 地板深度）。
        try SubagentDepth.assertSubagentMaxDepth(maxDepth)
        let events = parentWriter.events
        let durableDepth = SubagentLineage.read(events: events)?.delegationDepth
        let parentDepth = try SubagentDepth.delegationDepthOf(durableDepth: durableDepth,
                                                              runtimeDepth: nil)
        let parent = WorkflowParent(
            sessionId: ctx.sessionId,
            depth: parentDepth,
            cwd: parentWriter.header.cwd)

        // 5. run 启动（:445-453：args 三字段 + maxTotalAgents=maxRounds）。
        let run = try await engine.start(WorkflowStartRequest(
            script: Self.script,
            meta: Self.meta,
            args: .object([
                "objective": .string(objective),
                "maxRounds": .int(maxRounds),
                "maxHandoffChars": .int(maxHandoffChars),
            ]),
            subagentProvider: subagentProvider,
            maxTotalAgents: maxRounds,
            parent: parent))

        // 6. abort 桥（:454-456）。
        let result: WorkflowResult = await withTaskCancellationHandler {
            await run.result.value
        } onCancel: {
            run.cancel("parent step aborted")
        }

        // 7. 非 completed → isError（:459-461 文案逐字）。
        if let error = Self.stopReasonError(result) {
            await run.dispose()
            throw RalphToolError(message: error)
        }
        await run.dispose()

        // 8. 终值防御解码（:462 readRunResult）。
        let value = try Self.readRunResult(result.value,
                                           maxRounds: maxRounds,
                                           maxHandoffChars: maxHandoffChars)

        // 9. round-failed → isError（:463——渲染 recent handoff 的失败文本）；
        //    run 形状 → renderResult 信封（:464-468）。
        switch value {
        case .run(let runResult):
            return .success(Self.renderResult(runResult, maxChars: maxResultChars),
                            meta: .object([
                                "runId": .string(run.id),
                                "agentsStarted": .int(result.agentsStarted),
                                "result": result.value,
                            ]))
        case .roundFailed(let failure):
            throw RalphToolError(message: Self.renderRoundFailure(failure, maxChars: maxResultChars))
        }
    }

    // MARK: 帽解析（index.ts:206-215 文案逐字）

    /// Resolve one model-selected cap against the deployment ceiling。
    static func resolveMaxRounds(_ requested: Int?, ceiling: Int) throws -> Int {
        let value = requested ?? ceiling
        if value < 1 {
            throw RalphToolError(message: "Ralph maxRounds must be a positive safe integer")
        }
        if value > ceiling {
            throw RalphToolError(
                message: "Ralph maxRounds \(value) exceeds the deployment ceiling \(ceiling)")
        }
        return value
    }

    // MARK: fresh-provider 门（index.ts:218-230 文案逐字）

    /// Require the configured route to mean a genuinely fresh structured child
    ///（getProvider 为 actor 调用——async 面，文案逐字不变）。
    static func requireFreshProvider(_ runtime: SubagentRuntime, name: String) async throws {
        guard let provider = await runtime.getProvider(name) else {
            throw RalphToolError(message: "Ralph subagent provider \"\(name)\" is not registered")
        }
        guard provider.capabilities.outputSchema else {
            throw RalphToolError(message: "Ralph subagent provider \"\(name)\" does not support structured output")
        }
        guard !provider.inheritsParentContext else {
            throw RalphToolError(message: "Ralph subagent provider \"\(name)\" inherits parent context; Ralph requires a fresh provider")
        }
    }

    // MARK: 防御性解码（index.ts:232-331 1:1）

    private static func isRecord(_ value: JSONValue?) -> [String: JSONValue]? {
        value?.objectValue
    }

    private static func normalizedText(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.isEmpty && text == text.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedList(_ value: JSONValue?) -> Bool {
        guard let items = value?.arrayItems else { return false }
        return items.allSatisfy { normalizedText($0) }
    }

    /// 键集排序精确匹配（:247/:292/:297/:302/:310 `Object.keys().sort().join(',')`）。
    private static func sortedKeys(_ fields: [String: JSONValue]) -> String {
        fields.keys.sorted().joined(separator: ",")
    }

    /// Defensively decode the fixed script's report across a provider boundary
    ///（:245-278 文案逐字）。
    static func readReport(_ value: JSONValue, expectedStatus: RalphRoundReport.Status,
                           maxChars: Int) throws -> RalphRoundReport {
        guard let fields = isRecord(value),
              sortedKeys(fields) == "blocker,evidence,nextSteps,status,summary",
              fields["status"]?.stringValue == expectedStatus.rawValue,
              normalizedText(fields["summary"]),
              normalizedList(fields["evidence"]),
              normalizedList(fields["nextSteps"]),
              let blocker = fields["blocker"]?.stringValue,
              blocker == blocker.trimmingCharacters(in: .whitespaces) else {
            throw RalphToolError(message: "Ralph workflow returned a malformed round report")
        }
        guard let summary = fields["summary"]?.stringValue,
              let evidenceItems = fields["evidence"]?.arrayItems,
              let nextStepItems = fields["nextSteps"]?.arrayItems else {
            // 不可达（上方 normalizedText/normalizedList 已验证形状）——守类型。
            throw RalphToolError(message: "Ralph workflow returned a malformed round report")
        }
        let report = RalphRoundReport(
            status: expectedStatus,
            summary: summary,
            evidence: evidenceItems.map { $0.stringValue ?? "" },
            nextSteps: nextStepItems.map { $0.stringValue ?? "" },
            blocker: blocker)
        if expectedStatus == .`continue` && (report.nextSteps.isEmpty || report.blocker != "") {
            throw RalphToolError(message: "Ralph workflow returned an invalid continuing report")
        }
        if expectedStatus == .complete
            && (report.evidence.isEmpty || !report.nextSteps.isEmpty || report.blocker != "") {
            throw RalphToolError(message: "Ralph workflow returned an invalid completion report")
        }
        if expectedStatus == .blocked && !normalizedText(.string(report.blocker)) {
            throw RalphToolError(message: "Ralph workflow returned an invalid blocked report")
        }
        let chars = Self.compactJSON(Self.reportValue(report)).count
        if chars > maxChars {
            throw RalphToolError(
                message: "Ralph workflow returned an oversized handoff (\(chars) > \(maxChars))")
        }
        return report
    }

    /// Defensively decode the fixed script's terminal value（:281-331 文案逐字）。
    static func readRunResult(_ value: JSONValue, maxRounds: Int,
                              maxHandoffChars: Int) throws -> RalphTerminalResult {
        guard let fields = isRecord(value),
              let roundsStarted = fields["roundsStarted"]?.intValue,
              roundsStarted >= 1, roundsStarted <= maxRounds else {
            throw RalphToolError(message: "Ralph workflow returned a malformed terminal result")
        }
        switch fields["status"]?.stringValue {
        case "complete":
            guard sortedKeys(fields) == "report,roundsStarted,status" else {
                throw RalphToolError(message: "Ralph workflow returned a malformed terminal result")
            }
            return .run(RalphRunResult(
                status: .complete, roundsStarted: roundsStarted,
                report: try readReport(fields["report"] ?? .null,
                                       expectedStatus: .complete,
                                       maxChars: maxHandoffChars)))
        case "blocked":
            guard sortedKeys(fields) == "report,roundsStarted,status" else {
                throw RalphToolError(message: "Ralph workflow returned a malformed terminal result")
            }
            return .run(RalphRunResult(
                status: .blocked, roundsStarted: roundsStarted,
                report: try readReport(fields["report"] ?? .null,
                                       expectedStatus: .blocked,
                                       maxChars: maxHandoffChars)))
        case "budget-limited":
            guard sortedKeys(fields) == "report,roundsStarted,status" else {
                throw RalphToolError(message: "Ralph workflow returned a malformed terminal result")
            }
            if roundsStarted != maxRounds {
                throw RalphToolError(message: "Ralph workflow returned budget-limited before the round limit")
            }
            return .run(RalphRunResult(
                status: .`continue`, roundsStarted: roundsStarted,
                report: try readReport(fields["report"] ?? .null,
                                       expectedStatus: .`continue`,
                                       maxChars: maxHandoffChars)))
        case "round-failed":
            guard sortedKeys(fields) == "lastReport,roundsStarted,status" else {
                throw RalphToolError(message: "Ralph workflow returned a malformed terminal result")
            }
            if roundsStarted == 1 {
                // 首轮无 previous——lastReport 必须 null（:313-317）。
                guard fields["lastReport"] == .null else {
                    throw RalphToolError(message: "Ralph workflow returned an invalid first-round failure")
                }
                return .roundFailed(RalphRoundFailure(roundsStarted: roundsStarted, lastReport: nil))
            }
            if fields["lastReport"] == .null {
                throw RalphToolError(message: "Ralph workflow returned a round failure without its last handoff")
            }
            return .roundFailed(RalphRoundFailure(
                roundsStarted: roundsStarted,
                lastReport: try readReport(fields["lastReport"] ?? .null,
                                           expectedStatus: .`continue`,
                                           maxChars: maxHandoffChars)))
        default:
            throw RalphToolError(message: "Ralph workflow returned an unknown terminal status")
        }
    }

    // MARK: 渲染面（index.ts:333-390 文案逐字）

    /// A non-clean workflow finish is an error, never a partial Ralph success
    ///（:334-347 三分支文案逐字）。
    static func stopReasonError(_ result: WorkflowResult) -> String? {
        switch result.stopReason {
        case .completed:
            return nil
        case .cancelled:
            if let error = result.error {
                return "Ralph workflow was cancelled (\(error))"
            }
            return "Ralph workflow was cancelled"
        case .error:
            return "Ralph workflow failed: \(result.error ?? "unknown error")"
        }
    }

    /// Bound complete parent-facing text, including its envelope and truncation
    /// marker（:349-356 逐语义）。
    static func boundResult(_ text: String, maxChars: Int) -> String {
        let notice = "\n… [truncated]"
        if text.count <= maxChars { return text }
        if maxChars <= notice.count { return String(notice.prefix(maxChars)) }
        return String(text.prefix(maxChars - notice.count)) + notice
    }

    /// Render the fixed terminal envelope without presenting self-report as
    /// certification（:359-374 三分支文案逐字）。
    static func renderResult(_ result: RalphRunResult, maxChars: Int) -> String {
        let rounds = "\(result.roundsStarted) round\(result.roundsStarted == 1 ? "" : "s")"
        let pretty = WorkflowTool.prettyJSON(reportValue(result.report))
        let text: String
        switch result.status {
        case .complete:
            text = "Ralph worker reported completion after \(rounds).\nFinal report:\n\(pretty)"
        case .blocked:
            text = "Ralph worker reported a blocker after \(rounds).\nFinal report:\n\(pretty)"
        case .`continue`:
            text = "Ralph reached its \(rounds) limit; the worker reported work remaining.\nFinal report:\n\(pretty)"
        }
        return boundResult(text, maxChars: maxChars)
    }

    /// Render an ordinary child failure with the most recent durable handoff
    ///（:384-390 文案逐字）。
    static func renderRoundFailure(_ failure: RalphRoundFailure, maxChars: Int) -> String {
        let header = "Ralph round \(failure.roundsStarted) child failed before producing a structured report."
        let text: String
        if let lastReport = failure.lastReport {
            text = "\(header)\nLast successful handoff:\n\(WorkflowTool.prettyJSON(reportValue(lastReport)))"
        } else {
            text = "\(header)\nNo previous handoff was available."
        }
        return boundResult(text, maxChars: maxChars)
    }

    /// RalphRoundReport → JSONValue（JSON.stringify(report) 等价面）。
    static func reportValue(_ report: RalphRoundReport) -> JSONValue {
        .object([
            "status": .string(report.status.rawValue),
            "summary": .string(report.summary),
            "evidence": .array(report.evidence.map { .string($0) }),
            "nextSteps": .array(report.nextSteps.map { .string($0) }),
            "blocker": .string(report.blocker),
        ])
    }

    /// JSON.stringify(value) 紧凑面。
    static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// Ralph 工具层抛错（经 ToolPipeline 合成 isError 结果）。
struct RalphToolError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - 装配面（index.ts:403-409 apply：提示段 + 工具注册）

/// tool-ralph 的 WanWo 装配入口（AppEnvironment Workflow 段调用）。
enum RalphTools {
    /// Register the fixed Ralph tool and its explicit-ask usage policy。
    /// 注册冲突可捕获（幂等重装配安全）。
    static func registerAll(into registry: ToolRegistry,
                            assembler: PromptAssembler,
                            engine: WorkflowEngine,
                            runtime: SubagentRuntime,
                            parentWriter: SessionWriter,
                            subagentProvider: String = "spawn",
                            maxRoundsCeiling: Int = 256,
                            maxHandoffChars: Int = 16_384,
                            maxResultChars: Int = 16_384) {
        do {
            _ = try registry.tryRegister(RalphTool(
                engine: engine, runtime: runtime, parentWriter: parentWriter,
                subagentProvider: subagentProvider,
                maxRoundsCeiling: maxRoundsCeiling,
                maxHandoffChars: maxHandoffChars,
                maxResultChars: maxResultChars))
        } catch {
            // 同名工具已在场（重装配）= 幂等 no-op。
        }
        // Explicit-ask usage policy（index.ts:405-409 文案逐字）。
        assembler.section(PromptSection(
            name: "tool:ralph",
            order: SECTION_ORDERS.toolRalph,
            text: "Use the ralph tool ONLY when the direct human explicitly asks for a Ralph loop or fresh-agent iterative execution. Each Ralph round starts a fresh child with no conversation seed and uses the shared workspace as durable memory. Completion and blockers are worker reports, not independent evaluation. Use same-session goal tools for ordinary long-running objectives, and plain subagents or workflows for bounded delegation and fan-out."))
    }
}
