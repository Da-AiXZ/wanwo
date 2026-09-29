//
//  CondensationEngine.swift
//  WanWo
//
//  【M8 批2 · B1 件3/5/7】压缩引擎编排（语义移植 · OpenHands software-agent-sdk）：
//    · RollingCondenser.condense 模板方法（sdk base.py:159-198）：触发评估 →
//      正常压缩；NoCondensationAvailable 时 SOFT → 返回 nil 下步再试（:170-174），
//      HARD → hard_context_reset（:176-191）。
//    · hard reset（sdk llm_summarizing_condenser.py:355-405）：全工作集摘要
//      （保受保护前缀——开头 system 段等价），事件字符串上限 ×0.8 递减重试至 5 次。
//    · 熔断：连续 3 次失败停自动压缩（成功复位；手动/溢出恢复不受限）。
//    · 审计：每次压缩记录 llmResponseID/tokensBefore/tokensAfter 进 tombstone
//      载荷（sdk add_metadata/condenser_meta 语义的 WanWo 承载）。
//  LLM 摘要经冻结协议 ContextSummarizer（B2 提供 conformer；nil = 摘要不可用——
//  SOFT 视为失败推迟、HARD 走 hard reset 同样失败并计熔断，登记）。
//

import Foundation

/// 压缩引擎（线程安全：NSLock 保护熔断计数；压缩互斥由 Compactor 门面持有）。
final class CondensationEngine: @unchecked Sendable {
    /// 熔断阈值（派单：连续 3 次失败停自动压缩）。
    static let maxConsecutiveFailures = 3

    private let lock = NSLock()
    private var consecutiveFailures = 0

    /// 自动压缩是否已熔断停用（成功复位）。
    var autoCompactionDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveFailures >= Self.maxConsecutiveFailures
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveFailures
    }

    private func recordSuccess() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
    }

    private func recordFailure() {
        lock.lock()
        consecutiveFailures += 1
        lock.unlock()
    }

    private static let logger = AppLogger(category: "CondensationEngine")

    // MARK: 主入口（触发评估由 Compactor 门面完成——门面持有窗口解析缝）

    /// 执行一次压缩。decision = 门面评估的触发决策（原因集 + 分级）。
    /// - Returns: tombstone（成功）；nil = 本次无可压缩（SOFT 推迟 / HARD 兜底链
    ///   也失败，熔断已计数）。
    /// - Throws: tombstone 落盘失败（append 抛穿）。
    func condense(events: [SessionEvent], decision: CondensationWorkingSet.TriggerDecision,
                  tokenBudget: Int, policy: CondensationWorkingSet.Policy,
                  summarizer: (any ContextSummarizer)?,
                  estimate: @Sendable ([SessionEvent]) -> Int,
                  append: (SessionEvent.Payload, Bool) async throws -> Void)
        async throws -> CondensationRecord? {
        guard !decision.reasons.isEmpty else { return nil }
        if decision.requirement == .hard {
            // HARD：正常压缩不可行 → hard reset 链（sdk base.py:176-191）。
            if let record = try await attemptNormal(events: events, reasons: decision.reasons,
                                                    tokenBudget: tokenBudget, policy: policy,
                                                    summarizer: summarizer, estimate: estimate,
                                                    append: append) {
                return record
            }
            guard let summarizer else { return nil }
            return try await hardReset(events: events, policy: policy, summarizer: summarizer,
                                       estimate: estimate, append: append)
        }
        // SOFT：一次正常压缩尝试，失败返回 nil 下步再试（sdk base.py:170-174）。
        return try await attemptNormal(events: events, reasons: decision.reasons,
                                       tokenBudget: tokenBudget, policy: policy,
                                       summarizer: summarizer, estimate: estimate,
                                       append: append)
    }

    // MARK: 正常压缩（sdk _generate_condensation :224-276 + 守门 :408-439）

    private func attemptNormal(events: [SessionEvent],
                               reasons: Set<CondensationWorkingSet.TriggerDecision.Reason>,
                               tokenBudget: Int, policy: CondensationWorkingSet.Policy,
                               summarizer: (any ContextSummarizer)?,
                               estimate: @Sendable ([SessionEvent]) -> Int,
                               append: (SessionEvent.Payload, Bool) async throws -> Void)
        async throws -> CondensationRecord? {
        guard let summarizer else {
            Self.logger.info("condensation skipped: no summarizer available")
            recordFailure()
            return nil
        }
        guard let forgotten = CondensationWorkingSet.selectForgottenSeqs(
            events: events, reasons: reasons, tokenBudget: tokenBudget, policy: policy) else {
            // 0 可忘 / minimum_progress 不足 → NoCondensationAvailable（sdk :408-439）。
            Self.logger.info("condensation unavailable: no viable forgetting set")
            recordFailure()
            return nil
        }
        let tokensBefore = estimate(events)
        // 增量折叠：旧摘要作 previousSummary（Cline :139-151 防摘要的摘要漂移）。
        let previous = CondensationWorkingSet.latestSummary(in: events)
        let serialized = CondensationWorkingSet.serializedEvents(
            events, forgottenSeqs: Set(forgotten),
            capChars: policy.maxEventChars, policy: policy)
        guard let summary = await summarizer.summarize(serializedEvents: serialized,
                                                       previousSummary: previous) else {
            Self.logger.warning("condensation summary failed (\(forgotten.count) events)")
            recordFailure()
            return nil
        }
        return try await landTombstone(events: events, forgotten: forgotten, summary: summary,
                                       tokensBefore: tokensBefore, estimate: estimate,
                                       append: append)
    }

    // MARK: hard reset（sdk :355-405）

    /// HARD 且正常压缩不可行：全工作集摘要（保受保护前缀），事件字符串上限
    /// ×0.8 递减重试至 5 次；全失败返回 nil（熔断计数，调用方终态报错）。
    func hardReset(events: [SessionEvent], policy: CondensationWorkingSet.Policy,
                   summarizer: any ContextSummarizer,
                   estimate: @Sendable ([SessionEvent]) -> Int,
                   append: (SessionEvent.Payload, Bool) async throws -> Void)
        async throws -> CondensationRecord? {
        let workingSet = CondensationWorkingSet.projected(events, policy: policy)
        // 可忘候选 = 受保护前缀之外的全部模型可见节点（派生摘要条目排除——冻结）。
        // 位置口径与 selectForgottenSeqs 一致：按模型可见位置计（keepFirst 语义）。
        var visibleSeqs: [Int] = []
        for event in workingSet where CondensationWorkingSet.isModelVisible(event.payload) {
            visibleSeqs.append(event.seq)
        }
        guard visibleSeqs.count > policy.keepFirst else {
            Self.logger.info("hard reset unavailable: nothing beyond protected prefix")
            recordFailure()
            return nil
        }
        let candidates = visibleSeqs[policy.keepFirst...].filter { $0 >= 0 }
        guard !candidates.isEmpty else {
            Self.logger.info("hard reset unavailable: nothing beyond protected prefix")
            recordFailure()
            return nil
        }
        // 原子边界对齐（不拆 tool 对 + 保护前缀永不忘）。
        let protected = Set(visibleSeqs.prefix(policy.keepFirst).filter { $0 >= 0 })
        let forgotten = CondensationWorkingSet.alignForgotten(
            Set(candidates), keepProtected: protected, in: events)
        guard !forgotten.isEmpty else {
            recordFailure()
            return nil
        }

        let tokensBefore = estimate(events)
        let previous = CondensationWorkingSet.latestSummary(in: events)
        var cap = policy.maxEventChars
        for attempt in 1...5 {
            let serialized = CondensationWorkingSet.serializedEvents(
                events, forgottenSeqs: forgotten, capChars: cap, policy: policy)
            if let summary = await summarizer.summarize(serializedEvents: serialized,
                                                        previousSummary: previous) {
                Self.logger.info("hard reset succeeded on attempt \(attempt) (cap=\(cap))")
                return try await landTombstone(events: events, forgotten: forgotten.sorted(),
                                               summary: summary, tokensBefore: tokensBefore,
                                               estimate: estimate, append: append)
            }
            cap = Int(Double(cap) * 0.8)
        }
        Self.logger.error("hard reset exhausted 5 attempts (cap \(policy.maxEventChars)→\(cap))")
        recordFailure()
        return nil
    }

    // MARK: tombstone 落盘 + 审计

    /// 落 tombstone（condensation/v1）+ 熔断复位 + 审计指标。
    private func landTombstone(events: [SessionEvent], forgotten: [Int], summary: String,
                               tokensBefore: Int,
                               estimate: @Sendable ([SessionEvent]) -> Int,
                               append: (SessionEvent.Payload, Bool) async throws -> Void)
        async throws -> CondensationRecord {
        var record = CondensationRecord(
            id: "cond-\(UUID().uuidString)",
            forgottenSeqs: forgotten,
            summary: summary,
            summaryOffset: forgotten.first,
            // 万我 ContextSummarizer 协议不回 response id（冻结契约禁改名）——
            // 恒 nil，可审计缺口呈报 b1-report.md。
            llmResponseID: nil,
            tokensBefore: tokensBefore,
            tokensAfter: 0,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        // tokensAfter = 投影后工作集估算（口径：模型实际可见面——遗忘过滤+
        // 合成摘要+tombstone 元事件排除后的 DeriveFold 估算；原实现误用
        // 全量原始事件+tombstone 估算，压缩后必大于 before，指标失真）。
        let simulated = SessionEvent(seq: -1, timeMs: record.createdAtMs,
                                     payload: .extensionEvent(
                                        kind: CondensationEvents.condensationKind,
                                        payload: record.payload))
        record.tokensAfter = estimate(
            CondensationWorkingSet.projected(events + [simulated]))
        try await append(.extensionEvent(kind: CondensationEvents.condensationKind,
                                         payload: record.payload), false)
        recordSuccess()
        Self.logger.info("condensation landed: forgot \(forgotten.count) events, "
            + "tokens \(record.tokensBefore)→\(record.tokensAfter)")
        return record
    }
}
