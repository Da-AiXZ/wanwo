//
//  Compactor.swift
//  WanWo
//
//  【语义移植 · dsh→OpenHands 迁移（M8 批2 件 B1）】本类自 M8 批2 起为压缩
//  门面（facade）：
//    · 计量/呈现面不变（T2.4 P0-2 / P1-5 / P2-⑦ 既有口径）：estimateText（M2
//      估计器）、estimateSession（与 DeriveFold 同一折叠）、usageAnchor 投影、
//      pressure → PressureInfo（ContextMeterView/ChatViewModel 数据源）、
//      contextWindow(for:)（M8 批1 件A1 窗口解析缝——压缩分母同源，接续用）。
//    · 压缩面迁移废弃旧两级雏形（prune 影子定价 + compaction/start→summary→end
//      锁三元组，出处 dsh compaction-basic/tool-result-pruner/tool-pairing）——
//      改走 OpenHands software-agent-sdk condenser 语义（CondensationEngine +
//      CondensationWorkingSet，见 Core/Context/Compaction/）：
//        - 压缩 = 追加 condensation/v1 tombstone（append-only 永不删）；
//        - 触发三源（sdk llm_summarizing_condenser.py:136-203）：token 超限
//          （预算 = contextWindow × 0.9）→HARD；事件数超 240→SOFT；
//          condensation-request→HARD；多原因取最严遗忘集；
//        - 掩码 condenser = 管线第一级零 LLM（投影内 View 变换，取代 prune）；
//        - HARD 失败 → hard reset（×0.8 ×5）；连续 3 次失败熔断停自动压缩；
//        - 摘要经冻结协议 ContextSummarizer（B2 提供 conformer，装配期注入）。
//    · 旧日志兼容：DeriveFold 对旧 compaction/summary 的折叠保留不动，老会话
//      照常重放（b1-report.md §1.2-5）。
//

import Foundation

/// 上下文压力与压缩（F036 → M8 批2 tombstone 地基）。
final class Compactor: @unchecked Sendable {
    struct Policy: Sendable {
        /// 上下文窗底线（无任何目录事实可解析时的最后兜底——DeepSeek chat
        /// 兼容底线；正常路径由 contextWindowResolver 解析目录/端点缺省，
        /// M8 批1 65.5k 根因修复后未配置窗口的模型不再落此值）。
        var defaultContextWindow = 65_536
        /// 呈现面阈值比率（ContextMeter 三档着色分母口径）——压缩触发面已改
        /// 用 CondensationWorkingSet.Policy.tokenBudgetRatio（0.9），本字段仅
        /// PressureInfo.thresholdTokens 呈现用，两口径分离（T2.4 P0-2 同款）。
        var thresholdRatio = 0.8
        /// 【迁移废弃·仅存 API 兼容】旧 retainRatio / prune / summaryMaxTokens
        /// 字段不再消费（旧两级雏形停写，b1-report.md §1.2-5）。
        var retainRatio = 0.16
        var pruneThresholdChars = 8_192
        var pruneHeadChars = 4_096
        var pruneTailChars = 1_024
        var summaryMaxTokens = 1_024

        static let pruneMarker = "\n\n[... tool result middle pruned ...]\n\n"
    }

    // MARK: - P2-⑦ 上下文构成（dsh contextBreakdown 投影 1:1 形态）
    //
    // 出处（packages/llm/token-meter/src/breakdown-projection.ts:58-88 +
    // projection.ts:59-66 + estimate.ts:77-90）：三段启发式构成 = 最新
    // request/header 的 system 与 tools（last-wins，无请求时为 0）+ 会话
    // 表面的消息计价。dsh projection.ts:50-57 明示「三段不求和等于锚定值，
    // 只呈现构成近似」——WanWo 同构：system/tools 以 WanWo M2 估计器计价
    // （与 usedTokens 同源，内部自洽；dsh 的 /4 固定密度为偏差登记）。

    /// 上下文构成三段（ContextMeter 面板 breakdown 行数据源）。
    struct Breakdown: Equatable, Sendable {
        /// 最新 request/header 系统提示词（无请求 → 0）。
        var systemTokens = 0
        /// 最新 request/header 工具 schema（无请求/空 → 0）。
        var toolsTokens = 0
        /// 会话表面（派生历史）消息计价。
        var messageTokens = 0
    }

    struct PressureInfo: Equatable, Sendable {
        /// UI 呈现口径（T2.4 P0-2）：usage 锚点投影——provider 真实占用 +
        /// 表面 signed movement（dsh context-occupancy usedTokens =
        /// projectedTokens ?? pressureTokens；无 usage 锚点 → 退回表面估算）。
        var usedTokens: Int
        /// 压缩触发口径：表面估算（M2 估算器；M8 批2 起为工作集口径——
        /// 投影含 tombstone 过滤 + 掩码变换，与请求构造同一折叠）。
        var estimatedTokens: Int
        var thresholdTokens: Int
        /// 模型上下文窗（P1-5：dsh context-occupancy 占比分母——ContextMeter
        /// 环与面板以窗口为分母，阈值仅供呈现面使用）。
        var contextWindow: Int
        /// 上下文构成（P2-⑦；缺省空值——压缩内部压力检查不需要）。
        var breakdown: Breakdown = Breakdown()
        /// 0..1+（threshold 的比值；UI 三档着色）。
        var ratio: Double { thresholdTokens > 0 ? Double(usedTokens) / Double(thresholdTokens) : 0 }
    }

    let policy: Policy
    private let makeAdapter: @Sendable () async throws -> OpenAICompatAdapter
    /// M8 批1 件A1：模型窗口解析缝（目录派生数据源，替代祖传
    /// perModelContextWindows 前缀 contains 表）。语义 = dsh modelInfoFor
    /// （llm-deepseek/adapter.ts:393-430）：精确 id 匹配 + 连接缺省窗口兜底。
    /// 注入端（AppEnvironment）经 EndpointCatalogSnapshot 消费端点目录；
    /// 返回 nil = 无任何目录事实 → policy 底线。
    private let contextWindowResolver: (@Sendable (String) -> Int?)?
    /// M8 批2 件 B2 消费缝：摘要器（冻结协议 ContextSummarizer——B2 提供
    /// LLM 结构化摘要器与 basic 兜底 conformer，装配期注入；nil = 摘要不可用，
    /// SOFT 推迟 / HARD 兜底链失败计熔断）。锁保护（@unchecked Sendable 纪律）。
    private var summarizerStorage: (any ContextSummarizer)?
    private let lock = NSLock()
    /// 压缩锁（旧 compaction/start~end 持久锁的进程内映像：同一会话不并发压缩）。
    private var compacting = false
    /// M8 批2：压缩引擎（触发编排 / hard reset / 熔断 / 审计）。
    private let engine = CondensationEngine()
    /// 压缩落地观察缝（M8 批2 件B3 缝②承载——AppEnvironment 注入
    /// SessionNotesRecorder 消费；记录已随 append 落盘后才发射）。
    var onCondensation: ((CondensationRecord) -> Void)?

    private static let logger = AppLogger(category: "Compactor")

    /// 摘要器注入缝（B2 装配期调用；幂等覆盖语义——后写胜）。
    func setSummarizer(_ summarizer: (any ContextSummarizer)?) {
        lock.lock()
        summarizerStorage = summarizer
        lock.unlock()
    }

    private var summarizer: (any ContextSummarizer)? {
        lock.lock()
        defer { lock.unlock() }
        return summarizerStorage
    }

    init(policy: Policy = Policy(),
         contextWindowResolver: (@Sendable (String) -> Int?)? = nil,
         summarizer: (any ContextSummarizer)? = nil,
         makeAdapter: @escaping @Sendable () async throws -> OpenAICompatAdapter) {
        self.policy = policy
        self.contextWindowResolver = contextWindowResolver
        self.summarizerStorage = summarizer
        self.makeAdapter = makeAdapter
        // M8 批2 件 B1：condensation 两 kind 注册（GoalEvents 同款幂等守卫；
        // 重名 fatal 由注册表门保）。AppEnvironment 不可改的等价适配：Compactor
        // 在 makeAgentStack 装配期构造，语义同为装配期注册——主理人合并后可在
        // AppEnvironment.swift:1085 后补规范调用点（b1-report.md §1.2-2 / §5）。
        CondensationEvents.register()
    }

    // MARK: - 估算（token 计量的 M2 估计器；实报 usage 随 M8 TokenMeter 六分格补齐）

    /// 粗估：UTF-8 字节 / 3 + 每消息开销（CJK ≈1 token/字，英文偏保守高估）。
    static func estimateText(_ text: String) -> Int {
        max(1, text.utf8.count / 3)
    }

    /// 派生历史的整体估算（与 DeriveFold 同一折叠：影子范围不重复计价；
    /// M8 批2 起经 DeriveFold 的工作集投影——tombstone 过滤 + 掩码变换后计价，
    /// 即"工作集 token"，与请求构造同口径）。
    static func estimateSession(_ events: [SessionEvent]) -> Int {
        let fold = DeriveFold(events)
        var total = 0
        for message in fold.messages {
            total += 4 + estimateText(message.content)
            if let calls = message.toolCalls {
                for call in calls { total += estimateText(call.arguments) + 8 }
            }
        }
        return total
    }

    // MARK: - usage 锚点投影（T2.4 P0-2：呈现面锚真实占用）

    /// usage 锚点（dsh token-meter usage-projection.ts:77-79 pressureFrom =
    /// uncached input + cacheRead + cacheWrite——provider 报告的最近请求 prompt
    /// 规模）+ 锚点时刻的表面估算值（dsh :169-179：usage 样本 stamp 于同事件
    /// 入表面之前，projected = 锚点 + 表面 signed movement——压缩影子化表面时
    /// 投影同步收缩，provider 报不出压缩用量也能即时反应）。
    struct UsageAnchor: Equatable, Sendable {
        var pressureTokens: Int
        var surfaceTokens: Int
    }

    /// 事件折叠：最后一条带 TokenUsage 的 assistant/message（last wins）。
    /// WanWo 解析层 inputTokens = prompt_tokens − cacheRead（uncached 桶）、
    /// 无 cacheWrite 桶（恒 0——dsh cacheWrite 桶缺席，P1-5 同口径登记）。
    static func usageAnchor(in events: [SessionEvent]) -> UsageAnchor? {
        var last: (pressure: Int, index: Int)?
        for (index, event) in events.enumerated() {
            if case .assistantMessage(_, _, _, let usage?, _) = event.payload {
                let pressure = usage.inputTokens + (usage.cacheReadTokens ?? 0)
                last = (pressure, index)
            }
        }
        guard let last else { return nil }
        return UsageAnchor(pressureTokens: last.pressure,
                           surfaceTokens: estimateSession(Array(events[...last.index])))
    }

    /// 当前压力（threshold = 窗口 × thresholdRatio；contextWindow 随行——
    /// P1-5 ContextMeter 占比口径；呈现面口径不变）。header = 最新
    /// request/header（P2-⑦ breakdown 的 system/tools 计价源；nil = 尚无请求）。
    func pressure(events: [SessionEvent], model: String?,
                  header: EpochHeader? = nil) -> PressureInfo {
        let estimated = Self.estimateSession(events)
        // usedTokens = usage 锚点投影（呈现面锚真实；dsh context-occupancy：
        // usedTokens = projectedTokens ?? pressureTokens，无锚点退表面估算）。
        let used: Int
        if let anchor = Self.usageAnchor(in: events) {
            used = max(0, anchor.pressureTokens + (estimated - anchor.surfaceTokens))
        } else {
            used = estimated
        }
        let window = contextWindow(for: model)
        // breakdown（dsh breakdown-projection.ts:63-83 语义：system/tools
        // 取最新 header last-wins；message = 表面计价，与 usedTokens 同一折叠）。
        var breakdown = Breakdown()
        breakdown.messageTokens = estimated
        if let system = header?.system {
            // dsh estimateSystemTokens（estimate.ts:77-80）：文本计价 + 角色开销 4。
            breakdown.systemTokens = Self.estimateText(system) + 4
        }
        if let tools = header?.tools, !tools.isEmpty {
            // dsh estimateToolsTokens（estimate.ts:87-90）：schema JSON 计价 + 4。
            if let data = try? JSONEncoder().encode(tools),
               let json = String(data: data, encoding: .utf8) {
                breakdown.toolsTokens = Self.estimateText(json) + 4
            }
        }
        return PressureInfo(usedTokens: used,
                            estimatedTokens: estimated,
                            thresholdTokens: Int(Double(window) * policy.thresholdRatio),
                            contextWindow: window,
                            breakdown: breakdown)
    }

    /// per-model 上下文窗（dsh resolveTargetPolicy 的 M2 形态；M8 批1 件A1
    /// 65.5k 根因修复）：解析缝（模型目录派生——精确 id 匹配 + 端点缺省窗口
    /// 兜底）→ nil 回落 policy 底线。祖传前缀 contains 猜测已删。
    func contextWindow(for model: String?) -> Int {
        guard let model, !model.isEmpty else { return policy.defaultContextWindow }
        return contextWindowResolver?(model) ?? policy.defaultContextWindow
    }

    /// HARD token 预算 = 窗口解析链同源分母 × 0.9（件3；Cline
    /// COMPACTION_TRIGGER_RATIO 同源）。
    func tokenBudget(for model: String?) -> Int {
        Int(Double(contextWindow(for: model))
            * CondensationWorkingSet.Policy.default.tokenBudgetRatio)
    }

    // MARK: - 压缩触发（M8 批2：三源 + 分级 + 熔断）

    /// 步前压缩检查（pre-step 介入点）。触发三源评估（件3）：
    /// token 超限→HARD / 事件数超 240→SOFT / 未处理 condensation-request→HARD。
    /// 熔断（连续 3 次失败）停自动压缩；失败不抛穿 loop（dsh「压缩失败继续
    /// turn」语义）。触发口径 = 工作集 token 估算（同请求构造折叠）。
    func compactIfNeeded(events: [SessionEvent], model: String?,
                         append: (SessionEvent.Payload, Bool) async throws -> Void) async -> Bool {
        // 熔断：连续失败停自动压缩（手动/溢出恢复不受限）。
        guard !engine.autoCompactionDisabled else {
            Self.logger.warning("auto compaction disabled by breaker "
                + "(\(CondensationEngine.maxConsecutiveFailures) consecutive failures)")
            return false
        }
        let tokens = Self.estimateSession(events)
        let decision = CondensationWorkingSet.evaluateTrigger(
            events: events, workingSetTokens: tokens,
            tokenBudget: tokenBudget(for: model))
        guard !decision.reasons.isEmpty else { return false }
        Self.logger.info("condensation trigger: \(decision.reasons) "
            + "requirement=\(decision.requirement) tokens=\(tokens) "
            + "budget=\(tokenBudget(for: model))")
        return await runCondensation(events: events, decision: decision, append: append)
    }

    /// 手动 /compact（forceThreshold 语义迁移 = CondensationRequest(manual)：
    /// 落请求事件 + 无条件 HARD 压缩，低于阈值也做一次有效压缩；熔断不受限）。
    /// 需经 AgentLoop.runMaintenance 串行化（idle 才可执行）。
    func compactNow(events: [SessionEvent], model: String?,
                    append: (SessionEvent.Payload, Bool) async throws -> Void) async throws -> Bool {
        let request = CondensationRequestMeta(
            reason: .manual, requestedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        try await append(.extensionEvent(kind: CondensationEvents.requestKind,
                                         payload: request.payload), false)
        // 触发评估需见请求事件——闭包外以合成事件补齐（seq 顺延；投影按
        // seq 序判 unhandled 即 HARD；logOnly 事件零 token 影响，登记简化）。
        let synthetic = SessionEvent(
            seq: (events.last?.seq ?? -1) + 1, timeMs: request.requestedAtMs,
            payload: .extensionEvent(kind: CondensationEvents.requestKind,
                                     payload: request.payload))
        return await runCondensation(events: events + [synthetic], decision: nil,
                                     model: model, append: append)
    }

    /// 溢出恢复消费面（件4 catch-condense-retry）：condensation-request(overflow)
    /// 已由调用方落流（unhandled）→ 立即执行一次 HARD 压缩。熔断不受限。
    /// - Returns: tombstone 是否落地。
    func condensePendingRequest(events: [SessionEvent], model: String?,
                                append: (SessionEvent.Payload, Bool) async throws -> Void) async -> Bool {
        await runCondensation(events: events, decision: nil, model: model, append: append)
    }

    /// 引擎编排（互斥同旧 compact：同一会话不并发压缩）。
    private func runCondensation(events: [SessionEvent],
                                 decision: CondensationWorkingSet.TriggerDecision?,
                                 model: String?,
                                 append: (SessionEvent.Payload, Bool) async throws -> Void) async -> Bool {
        lock.lock()
        if compacting {
            lock.unlock()
            return false
        }
        compacting = true
        lock.unlock()
        defer {
            lock.lock()
            compacting = false
            lock.unlock()
        }
        let resolvedDecision: CondensationWorkingSet.TriggerDecision
        if let decision {
            resolvedDecision = decision
        } else {
            // compactNow / condensePendingRequest：请求事件已在流中——
            // 重估触发（unhandled request → HARD）。
            resolvedDecision = CondensationWorkingSet.evaluateTrigger(
                events: events, workingSetTokens: Self.estimateSession(events),
                tokenBudget: tokenBudget(for: model))
        }
        guard !resolvedDecision.reasons.isEmpty else { return false }
        let record = try? await engine.condense(
            events: events, decision: resolvedDecision,
            tokenBudget: tokenBudget(for: model),
            policy: CondensationWorkingSet.Policy.default,
            summarizer: summarizer,
            estimate: { Self.estimateSession($0) },
            append: append)
        if let record {
            // M8 批2 件B3 缝②（主理人合并）：压缩落地 → 常驻笔记联动
            // （activeContext 全文重写为摘要；消费方 try? 不阻断压缩）。
            onCondensation?(record)
        }
        return record != nil
    }
}
