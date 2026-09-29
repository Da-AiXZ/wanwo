//
//  CondensationWorkingSet.swift
//  WanWo
//
//  【M8 批2 · B1 件1/2/3/6】工作集投影与压缩纯函数族（语义移植 · OpenHands
//  software-agent-sdk）：
//    · 投影（sdk view/view.py View.from_events 语义）：按序应用 condensation/v1
//      tombstone——过滤 forgottenSeqs + 在 summaryOffset 插入派生摘要条目；派生条目
//      只在工作集不落盘（sdk CondensationSummaryEvent 不入主事件库，id 确定性派生
//      :51-76）；tombstone 丢弃即恢复全量（可撤销）+ 随行 llmResponseID（可审计）。
//    · 掩码（管线第一级零 LLM，sdk observation_masking_condenser.py 语义）：窗口外
//      旧工具结果替换占位文本——作为 View 变换先行执行，零持久化零 LLM 成本。
//    · 原子边界（sdk view/manipulation_indices 的万我等价简化 = 配对区间表，登记
//      b1-report.md）：遗忘区间不得拆散 tool-call↔tool-result 对 + 受保护前缀
//      （keepFirst，开头 system 段的万我等价——万我 system 不在事件流）永不忘。
//    · 触发三源（sdk llm_summarizing_condenser.py:136-203）：token 超限→HARD；
//      事件数超 max_size(240)→SOFT；未处理 CondensationRequest→HARD。
//    · 遗忘集选择（:278-352）：多原因取最严尾留数（:327-329）+ minimum_progress
//      守门（:408-439）。
//    · 序列化（B2 ContextSummarizer 输入）：逐事件文本 + seq 标注 + 字符上限。
//

import Foundation

// MARK: - 工作集投影

/// 工作集投影与压缩纯函数族（全部纯函数，禁副作用——投影不落盘、不改输入）。
enum CondensationWorkingSet {
    struct Policy: Equatable, Sendable {
        /// 视图开头最少保留事件数（sdk keep_first 默认 2；万我事件流无 system 事件，
        /// keepFirst 即"开头 system 段永不忘"的等价承载，登记）。
        var keepFirst = 2
        /// 事件数上限（超限触发 SOFT 压缩；sdk max_size 默认 240 = settings 语义）。
        var maxSize = 240
        /// 掩码注意力窗口（窗口外旧工具结果替换占位；sdk observation_masking
        /// attention_window=5）。
        var attentionWindow = 5
        /// 序列化单事件字符串上限（hard reset ×0.8 递减的基数；sdk 老版
        /// max_event_length=10_000 同源）。
        var maxEventChars = 10_000
        /// 最小压缩收益（遗忘数 < 工作集×0.1 视为无可压缩，sdk minimum_progress）。
        var minimumProgress = 0.1
        /// HARD token 预算 = 窗口解析链同源分母 × 本比率（Cline
        /// COMPACTION_TRIGGER_RATIO = 0.9 同源）。
        var tokenBudgetRatio = 0.9

        static let `default` = Policy()
    }

    /// 掩码占位文本（派单指定文案；sdk '<MASKED>' 语义）。
    static let maskPlaceholder = "<早期工具输出已折叠>"

    /// 单 tool-call arguments 序列化上限（Cline serializeConversation 块级
    /// 2000 字符 cap 同源——compaction-shared.ts:33）。
    static let toolCallArgumentsCap = 2_000

    /// arguments 归一（换行/制表 → 空格，单行 JSON 形态便于解析）+ 截断；
    /// 逗号/引号等 JSON 语义字符不动（B2 兜底提取按 JSON 解析）。
    static func normalizedArguments(_ arguments: String) -> String {
        let flattened = arguments
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(flattened.prefix(toolCallArgumentsCap))
    }

    // MARK: 投影（纯函数）

    /// 按序应用全部 tombstone + 掩码 View 变换，产出工作集（不落盘、不改输入）。
    /// 投影后数组含合成派生摘要条目（seq 负数标记）——DeriveFold 以
    /// `<compaction-summary>` user 消息呈现。
    static func projected(_ events: [SessionEvent],
                          policy: Policy = .default) -> [SessionEvent] {
        let tombs = tombstones(in: events)
        var workingSet: [SessionEvent]
        if tombs.isEmpty {
            workingSet = events
        } else {
            var forgotten = Set<Int>()
            // (插入点 seq, tombstone)——按 tombstone 落盘序，插入点升序排列。
            var insertions: [(offset: Int, record: CondensationRecord)] = []
            for record in tombs {
                forgotten.formUnion(record.forgottenSeqs)
                if let summary = record.summary, !summary.isEmpty,
                   let offset = record.summaryOffset {
                    insertions.append((offset, record))
                }
            }
            insertions.sort { $0.offset < $1.offset }

            workingSet = []
            workingSet.reserveCapacity(events.count)
            var syntheticSeq = -1
            var insertionIndex = 0
            for event in events {
                while insertionIndex < insertions.count,
                      insertions[insertionIndex].offset <= event.seq {
                    workingSet.append(derivedSummaryEvent(insertions[insertionIndex].record,
                                                          seq: syntheticSeq))
                    syntheticSeq -= 1
                    insertionIndex += 1
                }
                // 原始事件永不删——遗忘只在投影过滤（tombstone 语义）。
                if forgotten.contains(event.seq) { continue }
                // tombstone 元事件本身不进模型可见面（View = 事件流的模型
                // 投影；Condensation 事件是宿主审计元数据——OpenHands view
                // 语义：tombstone 只在事件流作审计，模型只见合成摘要）。
                if case .extensionEvent(let eventKind, _) = event.payload,
                   eventKind == CondensationEvents.condensationKind {
                    continue
                }
                workingSet.append(event)
            }
            while insertionIndex < insertions.count {
                workingSet.append(derivedSummaryEvent(insertions[insertionIndex].record,
                                                      seq: syntheticSeq))
                syntheticSeq -= 1
                insertionIndex += 1
            }
        }
        return masked(workingSet, attentionWindow: policy.attentionWindow)
    }

    /// 派生摘要条目（合成 compaction/summary 载荷；seq 负数标记合成、永不落盘；
    /// shadowedSeqs 留空——DeriveFold 的影子集合收集不受扰）。
    static func derivedSummaryEvent(_ record: CondensationRecord, seq: Int) -> SessionEvent {
        SessionEvent(
            seq: seq,
            timeMs: record.createdAtMs,
            payload: .compactionSummary(
                compactionId: record.id,
                summary: record.summary ?? "",
                shadowedRangeStart: record.summaryOffset ?? 0,
                shadowedRangeEnd: record.forgottenSeqs.last ?? record.summaryOffset ?? 0,
                shadowedSeqs: [],
                shadowedTokenCount: 0),
            ignorable: true)
    }

    // MARK: tombstone / request 解析（事件流只读扫描）

    /// 事件流中全部 tombstone（落盘序）。
    static func tombstones(in events: [SessionEvent]) -> [CondensationRecord] {
        var records: [CondensationRecord] = []
        for event in events {
            if case .extensionEvent(let kind, let payload) = event.payload,
               kind == CondensationEvents.condensationKind,
               let record = CondensationRecord.decode(payload) {
                records.append(record)
            }
        }
        return records
    }

    /// 未处理的压缩请求（sdk view.unhandled_condensation_request 语义）：
    /// 最后一条 request 事件晚于最后一条 tombstone（tombstone 落地即清位）。
    static func unhandledRequest(in events: [SessionEvent]) -> CondensationRequestMeta? {
        var lastTombstoneSeq = -1
        var lastRequest: (seq: Int, meta: CondensationRequestMeta)?
        for event in events {
            if case .extensionEvent(let kind, let payload) = event.payload {
                if kind == CondensationEvents.condensationKind {
                    lastTombstoneSeq = event.seq
                } else if kind == CondensationEvents.requestKind,
                          let meta = CondensationRequestMeta.decode(payload) {
                    lastRequest = (event.seq, meta)
                }
            }
        }
        guard let lastRequest, lastRequest.seq > lastTombstoneSeq else { return nil }
        return lastRequest.meta
    }

    /// 最近一次摘要正文（增量折叠的 previousSummary——Cline
    /// agentic-compaction.ts:139-151 语义）。
    static func latestSummary(in events: [SessionEvent]) -> String? {
        tombstones(in: events).compactMap(\.summary).last
    }

    // MARK: 掩码（管线第一级零 LLM）

    /// 窗口外旧工具结果替换占位（View 变换，零持久化）。错误结果保留
    /// （万我登记：错误小且诊断价值高——observation_masking 全掩码的偏差）。
    static func masked(_ projected: [SessionEvent], attentionWindow: Int) -> [SessionEvent] {
        guard attentionWindow > 0 else { return projected }
        // 仅模型可见位置计窗（sdk view 语义：窗口按视图事件计）。
        var visibleIndices: [Int] = []
        visibleIndices.reserveCapacity(projected.count)
        for (index, event) in projected.enumerated() where isModelVisible(event.payload) {
            visibleIndices.append(index)
        }
        guard visibleIndices.count > attentionWindow else { return projected }
        let cutoff = visibleIndices[visibleIndices.count - attentionWindow]
        var result = projected
        var changed = false
        for index in 0..<cutoff {
            guard case .toolResult(let turn, let step, let callId, _, let isError,
                                   let errorName, let errorCode, let meta) = result[index].payload,
                  !isError else { continue }
            result[index] = SessionEvent(
                seq: result[index].seq, timeMs: result[index].timeMs,
                payload: .toolResult(turn: turn, step: step, callId: callId,
                                     content: maskPlaceholder, isError: isError,
                                     errorName: errorName, errorCode: errorCode, meta: meta),
                ignorable: result[index].ignorable)
            changed = true
        }
        return changed ? result : projected
    }

    /// 模型可见载荷判定（投影/计数/掩码共用口径）。
    static func isModelVisible(_ payload: SessionEvent.Payload) -> Bool {
        switch payload {
        case .userMessage, .assistantMessage, .toolResult, .compactionSummary:
            return true
        default:
            return false
        }
    }

    /// 工作集模型可见事件数（sdk len(view) 口径）。
    static func modelVisibleCount(_ workingSet: [SessionEvent]) -> Int {
        workingSet.lazy.filter { isModelVisible($0.payload) }.count
    }

    // MARK: 触发三源（sdk :136-203）

    struct TriggerDecision: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case tokens   // token 超限 → HARD
            case events   // 事件数超 max_size → SOFT
            case request  // 未处理 CondensationRequest → HARD
        }

        var reasons: Set<Reason>
        var requirement: CondensationRequirement
        var requestReason: CondensationRequestMeta.Reason?
    }

    /// 触发评估（纯函数）。workingSetTokens 由调用方供给（Compactor.estimateSession
    /// ——与请求构造同一折叠口径）；tokenBudget = 窗口解析分母 × policy.tokenBudgetRatio。
    static func evaluateTrigger(events: [SessionEvent], workingSetTokens: Int,
                                tokenBudget: Int,
                                policy: Policy = .default) -> TriggerDecision {
        var reasons: Set<TriggerDecision.Reason> = []
        if workingSetTokens > tokenBudget { reasons.insert(.tokens) }
        if modelVisibleCount(projected(events, policy: policy)) > policy.maxSize {
            reasons.insert(.events)
        }
        let request = unhandledRequest(in: events)
        // 分级（sdk :175-203）：TOKENS→HARD（继续发请求会先崩）；REQUEST→HARD
        // （用户/系统明确要求）；仅 EVENTS→SOFT（历史管理启发式，可推迟）。
        var requirement: CondensationRequirement = .soft
        if reasons.contains(.tokens) || request != nil { requirement = .hard }
        if request != nil { reasons.insert(.request) }
        return TriggerDecision(reasons: reasons, requirement: requirement,
                               requestReason: request?.reason)
    }

    // MARK: 遗忘集选择（sdk :278-352）

    /// 选择遗忘集（seq 升序）。多原因取最严尾留数（:327-329）；配对区间对齐
    /// （不拆 tool 对）+ 受保护前缀永不忘；minimum_progress 守门（收益太小
    /// 返回 nil = NoCondensationAvailable，SOFT 推迟 / HARD 走 hard reset）。
    static func selectForgottenSeqs(events: [SessionEvent],
                                    reasons: Set<TriggerDecision.Reason>,
                                    tokenBudget: Int,
                                    policy: Policy = .default) -> [Int]? {
        let workingSet = projected(events, policy: policy)
        // 模型可见节点（seq + token 估算）；派生摘要条目冻结不重折
        //（Cline basic-compaction :395-421 上轮压缩产物冻结语义）。
        var nodes: [(seq: Int, tokens: Int, synthetic: Bool)] = []
        for event in workingSet where isModelVisible(event.payload) {
            let synthetic: Bool = event.seq < 0
            nodes.append((event.seq, nodeTokens(event), synthetic))
        }
        guard nodes.count > policy.keepFirst else { return nil }

        // 尾部保留数 per reason（sdk :299-325）。
        var tailKeeps: [Int] = []
        if reasons.contains(.request) {
            // 目标规模 len(view)//2（:299-305）。
            tailKeeps.append(max(0, nodes.count / 2 - policy.keepFirst - 1))
        }
        if reasons.contains(.events) {
            // 目标规模 max_size//2。
            tailKeeps.append(max(0, policy.maxSize / 2 - policy.keepFirst - 1))
        }
        if reasons.contains(.tokens) {
            // 压到当前总量一半（万我简化：tail 保留 total/2 的 token 量）。
            // batch2-review P2#1 登记：与 sdk tokens_to_reduce = total -
            // max_tokens//2 数学不等价（sdk 以 max_tokens 一半为目标，本实现
            // 以当前总量一半为目标）→ 收敛慢一拍可接受；逐节点累加替代
            // sdk 二分 get_suffix_length_for_token_reduction 同登记。
            let total = nodes.reduce(0) { $0 + $1.tokens }
            let target = total / 2
            var acc = 0
            var count = 0
            for node in nodes.reversed() {
                if acc >= target { break }
                acc += node.tokens
                count += 1
            }
            tailKeeps.append(max(0, count))
        }
        guard let tailKeep = tailKeeps.min() else { return nil }
        let candidateEnd = nodes.count - tailKeep
        guard candidateEnd > policy.keepFirst else { return nil }

        // 候选遗忘 = 受保护前缀之后的节点（派生摘要条目排除——冻结）。
        var forgotten = Set(nodes[policy.keepFirst..<candidateEnd]
            .filter { !$0.synthetic }
            .map { $0.seq })
        // 原子边界对齐（件2）：不拆 tool 对 + 受保护前缀永不忘。
        let protected = Set(nodes.prefix(policy.keepFirst).map { $0.seq })
        forgotten = alignForgotten(forgotten, keepProtected: protected, in: events)
        guard !forgotten.isEmpty else { return nil }
        // 守门：收益太小留到下一步（sdk :408-439）。
        if Double(forgotten.count) < Double(nodes.count) * policy.minimumProgress {
            return nil
        }
        return forgotten.sorted()
    }

    /// 配对区间对齐（件2；sdk manipulation_indices 的万我等价简化，登记）：
    /// 遗忘集收缩至不拆散任何 tool-call↔tool-result 对——对内任一端在保留区
    /// 则整对挤回保留区（与旧 Compactor.selectCompactableRange 同向、OpenHands
    /// find_next 前移等价）；受保护前缀 seq 强制移出遗忘集。
    static func alignForgotten(_ forgotten: Set<Int>, keepProtected: Set<Int>,
                               in events: [SessionEvent]) -> Set<Int> {
        var assistantSeqByCallId: [String: Int] = [:]
        var resultSeqsByCallId: [String: [Int]] = [:]
        for event in events {
            switch event.payload {
            case .assistantMessage(_, _, let message, _, _):
                for case .toolCall(let callId, _, _) in message.content {
                    assistantSeqByCallId[callId] = event.seq
                }
            case .toolResult(_, _, let callId, _, _, _, _, _):
                resultSeqsByCallId[callId, default: []].append(event.seq)
            default:
                break
            }
        }
        var aligned = forgotten
        aligned.subtract(keepProtected)
        var changed = true
        while changed {
            changed = false
            for (callId, assistantSeq) in assistantSeqByCallId {
                let ends = Set([assistantSeq] + (resultSeqsByCallId[callId] ?? []))
                // 对内任一端在保留区 → 整对挤回保留区（遗忘收缩，不开洞于对内）。
                let keptEnds = ends.subtracting(aligned)
                if !keptEnds.isEmpty {
                    let before = aligned.count
                    aligned.subtract(ends)
                    if aligned.count != before { changed = true }
                }
            }
        }
        return aligned
    }

    // MARK: 序列化（B2 ContextSummarizer 输入）

    /// 工作集序列化（带 seq 标注）。forgottenSeqs 非 nil 时仅序列化该遗忘子集
    /// （正常压缩：被遗忘事件；hard reset：除保护前缀外全部）。capChars = 单事件
    /// 字符上限（hard reset ×0.8 递减重试的承载）。
    static func serializedEvents(_ events: [SessionEvent], forgottenSeqs: Set<Int>? = nil,
                                 capChars: Int, policy: Policy = .default) -> [String] {
        let workingSet = projected(events, policy: policy)
        var lines: [String] = []
        for event in workingSet where isModelVisible(event.payload) {
            if let forgottenSeqs, !forgottenSeqs.contains(event.seq) { continue }
            let cap = max(0, capChars)
            switch event.payload {
            case .userMessage(let text):
                lines.append("[seq=\(event.seq)] [user] \(String(text.prefix(cap)))")
            case .assistantMessage(_, _, let message, _, _):
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined()
                let calls = message.content.compactMap { block -> String? in
                    if case .toolCall(let id, let name, let arguments) = block {
                        // arguments 在位（B2 gap 裁决，Cline serializeConversation
                        // name(input) 语义 + callId 溯源）：`name(callId) {json}`，
                        // 多调用 " | " 分隔（比 ", " 抗 JSON 内逗号污染，登记）；
                        // 单 arguments 截 2000 字符（Cline 块级 cap 同源）。
                        return "\(name)(\(id)) \(Self.normalizedArguments(arguments))"
                    }
                    return nil
                }
                lines.append("[seq=\(event.seq)] [assistant] \(String(text.prefix(cap)))"
                    + (calls.isEmpty ? "" : " [tool calls: \(calls.joined(separator: " | "))]"))
            case .toolResult(_, _, let callId, let content, _, _, _, _):
                lines.append("[seq=\(event.seq)] [tool result \(callId)] \(String(content.prefix(cap)))")
            case .compactionSummary(let id, let summary, _, _, _, _):
                // 旧摘要语境行（增量折叠防漂移——sdk summarizing_system.j2
                // "which will include previous summaries" 语义）。
                lines.append("[seq=\(event.seq)] [previous summary \(id)] \(String(summary.prefix(cap)))")
            default:
                break
            }
        }
        return lines
    }

    // MARK: 节点估算（与 Compactor.estimateText 同源 M2 估计器）

    /// 单节点 token 估算（按值——投影后数组 seq 与下标不对应，不能用
    /// Compactor.estimateNode 的 seq 索引，登记）。
    static func nodeTokens(_ event: SessionEvent) -> Int {
        switch event.payload {
        case .userMessage(let text):
            return 4 + Compactor.estimateText(text)
        case .assistantMessage(_, _, let message, _, _):
            var total = 4
            for block in message.content {
                if case .text(let t) = block { total += Compactor.estimateText(t) }
                if case .reasoning(let t) = block { total += Compactor.estimateText(t) }
                if case .toolCall(_, _, let arguments) = block {
                    total += Compactor.estimateText(arguments) + 8
                }
            }
            return total
        case .toolResult(_, _, _, let content, _, _, _, _):
            return 4 + Compactor.estimateText(content)
        case .compactionSummary(_, let summary, _, _, _, _):
            return 4 + Compactor.estimateText(summary)
        default:
            return 0
        }
    }
}
