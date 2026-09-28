//
//  MemoryPhase1.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6）：
//    - memories/write/src/phase1.rs —— run() 四步（claim → 逐 job sample →
//      三态落账 → 汇总）；job::run（:228-281：raw_memory/rollout_summary 全空 =
//      succeeded_no_output；否则 succeeded）；job::result 三函数（failed =
//      mark_stage1_job_failed + JOB_RETRY_DELAY；no_output/succeeded 1:1）；
//      job::sample（:284-326：load_rollout → serialize_filtered → build_stage_one_
//      input_message → 裸流式调用 → serde 严格解码 → 逐字段 redact）。
//    - memories/write/src/lib.rs stage_one 常量 —— CONCURRENCY_LIMIT=8
//      （buffer_unordered）；REASONING_EFFORT=Low。
//  万我适配（登记）：
//    - 裸 LLM 调用缝：codex stream_stage_one_prompt（runtime.rs 裸 ModelClient
//      流式，非完整 agent）→ 万我注入 complete 闭包（AppEnvironment 装配 =
//      OpenAICompatAdapter.stream 聚合 textDelta——同 Compactor.completeLLM 的
//      裸调用拓扑，不经 AgentLoop）。
//    - 输出解析：codex 走 output_schema strict 约束；OpenAI 兼容 wire 无 schema
//      约束面——解析端做等价承接：剥 ```json 围栏 → 首尾花括号切片 →
//      MemoryStage1Output 严格解码（deny_unknown_fields 等价——未知键即拒）。
//    - 候选枚举/水位判定不在本件（MemoryDatabase.filterEligibleStage1Candidates
//      + MemoryTrigger 宿主枚举——账本头注登记的两步拆分）。
//

import Foundation

/// Phase1 抽取器（actor——与 Phase2/触发器共享账本；本件自身无并发共享态，
/// actor 化为调用面串行语义锚）。
actor MemoryPhase1 {

    /// 裸 LLM 调用缝（AppEnvironment 装配；返回模型最终文本）。
    typealias CompleteLLM = @Sendable (_ request: LLMRequest) async throws -> String

    /// 单 job 的 rollout 输入（宿主枚举 + 序列化产物）。
    struct JobInput: Sendable {
        var claim: MemoryStage1Claim
        /// serialize_filtered_rollout_response_items 产物（已 redact）。
        var rolloutContents: String
        /// 会话事实源路径标签（stage_one_input {{ rollout_path }}）。
        var rolloutPath: String
        /// 会话 cwd（stage_one_input {{ rollout_cwd }}）。
        var rolloutCwd: String
        /// 模型上下文窗（nil = 无元数据 → DEFAULT_ROLLOUT_TOKEN_LIMIT）。
        var contextWindowTokens: Int?
    }

    private let database: MemoryDatabase
    private let complete: CompleteLLM

    init(database: MemoryDatabase, complete: @escaping CompleteLLM) {
        self.database = database
        self.complete = complete
    }

    /// run() 主体：对已抢占候选并行抽取（buffer_unordered(CONCURRENCY_LIMIT)）
    /// 并三态落账。返回 (claimed, succeeded, noOutput, failed) 统计（metrics 面）。
    @discardableResult
    func run(inputs: [JobInput]) async -> (claimed: Int, succeeded: Int,
                                           noOutput: Int, failed: Int) {
        // buffer_unordered(CONCURRENCY_LIMIT) 等价：TaskGroup + 滑动窗口
        // （子任务闭包只捕获 let——滑动指针在本任务内推进）。
        var outcomes: [JobOutcome] = []
        await withTaskGroup(of: JobOutcome.self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < inputs.count else { return }
                let input = inputs[nextIndex]
                nextIndex += 1
                group.addTask { await self.runJob(input) }
            }
            for _ in 0..<MemoryConstants.concurrencyLimit { enqueueNext() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                enqueueNext()
            }
        }
        let succeeded = outcomes.filter { $0 == .succeededWithOutput }.count
        let noOutput = outcomes.filter { $0 == .succeededNoOutput }.count
        let failed = outcomes.filter { $0 == .failed }.count
        return (inputs.count, succeeded, noOutput, failed)
    }

    /// 单 job 结果三态（phase1.rs JobOutcome 1:1）。
    private enum JobOutcome { case succeededWithOutput, succeededNoOutput, failed }

    /// 单 job（job::run 1:1）。
    private func runJob(_ input: JobInput) async -> JobOutcome {
        do {
            let message = MemoryRollout.buildStageOneInputMessage(
                rolloutContents: input.rolloutContents,
                rolloutPath: input.rolloutPath,
                rolloutCwd: input.rolloutCwd,
                contextWindowTokens: input.contextWindowTokens)
            let request = LLMRequest(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                system: MemoryTemplates.stageOneSystem,
                messages: [ChatMessage(role: .user, content: message)],
                reasoningEffort: MemoryConstants.stageOneReasoningEffort,
                purpose: "memory-stage1")
            let text = try await complete(request)
            let output = try Self.parseStage1Output(text)
            // redact 逐字段（phase1.rs :321-323 次序）。
            let rawMemory = MemoryRedactor.redact(output.rawMemory)
            let rolloutSummary = MemoryRedactor.redact(output.rolloutSummary)
            let rolloutSlug = output.rolloutSlug.map { MemoryRedactor.redact($0) }
            if rawMemory.isEmpty || rolloutSummary.isEmpty {
                try database.markStage1JobSucceededNoOutput(
                    threadId: input.claim.threadId,
                    sourceUpdatedAt: input.claim.sourceUpdatedAt)
                return .succeededNoOutput
            }
            try database.markStage1JobSucceeded(
                threadId: input.claim.threadId,
                sourceUpdatedAt: input.claim.sourceUpdatedAt,
                rawMemory: rawMemory,
                rolloutSummary: rolloutSummary,
                rolloutSlug: rolloutSlug)
            return .succeededWithOutput
        } catch {
            try? database.markStage1JobFailed(
                threadId: input.claim.threadId,
                sourceUpdatedAt: input.claim.sourceUpdatedAt,
                reason: String(describing: error),
                retryDelaySeconds: MemoryConstants.jobRetryDelaySeconds)
            return .failed
        }
    }

    // MARK: - 装配注入（连接事实——AppEnvironment init 期赋值，运行期只读）

    private var baseURL = ""
    private var apiKey = ""
    private var model = ""

    /// 装配期注入连接事实（EndpointStore 解析产物；actor 隔离赋值一次）。
    func configure(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - 输出解析

    /// 模型文本 → Stage1Output：剥围栏 → 花括号切片 → 严格解码
    /// （deny_unknown_fields 等价；fail closed = 抛错走 failed 臂）。
    static func parseStage1Output(_ text: String) throws -> MemoryStage1Output {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ```json 围栏剥离（模型面围栏常见形态；codex schema 约束下无围栏）。
        if body.hasPrefix("```") {
            body = body.dropFirst(3)
            if body.hasPrefix("json") { body = body.dropFirst(4) }
            if let fenceEnd = body.range(of: "```", options: .backwards) {
                body = String(body[..<fenceEnd.lowerBound])
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = body.firstIndex(of: "{"),
              let end = body.lastIndex(of: "}"), start < end else {
            throw MemoryError(message: "stage-1 output is not a JSON object")
        }
        let slice = String(body[start...end])
        guard let data = slice.data(using: .utf8) else {
            throw MemoryError(message: "stage-1 output is not utf8")
        }
        return try JSONDecoder().decode(MemoryStage1Output.self, from: data)
    }

    // MARK: - 私有
}
