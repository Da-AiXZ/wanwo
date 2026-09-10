//
//  Compactor.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/compaction/compaction-basic（压力/溢出触发、
//  阈值策略 thresholdRatio 0.8 / retainRatio 0.16、summarizeWithLlm、
//  compactIfNeeded/compactNow）+ compaction-tool-result-pruner（8192/4096/1024
//  字符预算 + PRUNE_MARKER）+ dsh packages/compaction/compaction/src/tool-pairing.ts
//  （tool-pairing 平衡校验：压缩范围不得拆散 tool/call ↔ tool/result 对）
//  + 10-design §5.7（Compactor F036）/ 附录 B #21/#22。
//  落盘词汇：compaction/start → compaction/summary → compaction/end（锁三元组）+
//  compaction/prune（prune 影子定价）。摘要经派生折叠取代影子范围（见
//  SessionWriter.deriveMessages），append-only 永不删（§十三.3）。
//

import Foundation

/// 上下文压力与压缩（F036）。
final class Compactor: @unchecked Sendable {
    struct Policy: Sendable {
        /// per-model 上下文窗（per-model policy；缺省 65536——DeepSeek chat 兼容底线）。
        var defaultContextWindow = 65_536
        var perModelContextWindows: [String: Int] = [:]
        var thresholdRatio = 0.8
        var retainRatio = 0.16
        // prune 字符预算（dsh DEFAULTS：8192/4096/1024）。
        var pruneThresholdChars = 8_192
        var pruneHeadChars = 4_096
        var pruneTailChars = 1_024
        /// 摘要单次输出上限。
        var summaryMaxTokens = 1_024

        static let pruneMarker = "\n\n[... tool result middle pruned ...]\n\n"
    }

    enum Trigger: String, Sendable {
        case pressure
        case manual
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
        /// 压缩触发口径：表面估算（M2 估算器；本批维持不动——dsh 触发面与
        /// 呈现面在 WanWo 分属两口径，偏差呈报）。
        var estimatedTokens: Int
        var thresholdTokens: Int
        /// 模型上下文窗（P1-5：dsh context-occupancy 占比分母——ContextMeter
        /// 环与面板以窗口为分母，阈值仅供压缩触发面使用）。
        var contextWindow: Int
        /// 上下文构成（P2-⑦；缺省空值——压缩内部压力检查不需要）。
        var breakdown: Breakdown = Breakdown()
        /// 0..1+（threshold 的比值；UI 三档着色）。
        var ratio: Double { thresholdTokens > 0 ? Double(usedTokens) / Double(thresholdTokens) : 0 }
    }

    let policy: Policy
    private let makeAdapter: @Sendable () async throws -> OpenAICompatAdapter
    private let lock = NSLock()
    /// 压缩锁（dsh compaction/start~end 持久锁的进程内映像：同一会话不并发压缩）。
    private var compacting = false

    private static let logger = AppLogger(category: "Compactor")

    init(policy: Policy = Policy(),
         makeAdapter: @escaping @Sendable () async throws -> OpenAICompatAdapter) {
        self.policy = policy
        self.makeAdapter = makeAdapter
    }

    // MARK: - 估算（token 计量的 M2 估计器；实报 usage 随 M8 TokenMeter 六分格补齐）

    /// 粗估：UTF-8 字节 / 3 + 每消息开销（CJK ≈1 token/字，英文偏保守高估）。
    static func estimateText(_ text: String) -> Int {
        max(1, text.utf8.count / 3)
    }

    /// 派生历史的整体估算（与 deriveMessages 同一折叠：影子范围不重复计价）。
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
    /// P1-5 ContextMeter 占比口径）。header = 最新 request/header（P2-⑦
    /// breakdown 的 system/tools 计价源；nil = 尚无请求，两段为 0）。
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

    /// per-model 上下文窗（dsh resolveTargetPolicy 的 M2 形态）。
    func contextWindow(for model: String?) -> Int {
        guard let model else { return policy.defaultContextWindow }
        for (key, window) in policy.perModelContextWindows where model.contains(key) {
            return window
        }
        return policy.defaultContextWindow
    }

    // MARK: - 压力触发（pre-step 介入点）

    /// 步前压力检查：超阈值 → 先 prune 再摘要（事件全部落盘后返回 true）。
    /// 失败不抛穿 loop（调用方 catch 后继续回合，dsh「压缩失败继续 turn」语义）。
    /// 触发口径 = estimatedTokens（表面估算；T2.4 P0-2——呈现面锚真实 usage，
    /// 触发面维持 M2 估算不动，偏差呈报）。
    func compactIfNeeded(events: [SessionEvent], model: String?,
                         append: (SessionEvent.Payload, Bool) async throws -> Void) async -> Bool {
        let info = pressure(events: events, model: model)
        guard info.estimatedTokens >= info.thresholdTokens else { return false }
        Self.logger.info("compaction pressure: \(info.estimatedTokens) >= \(info.thresholdTokens)")
        return (try? await compact(events: events, model: model,
                                   forceThreshold: false, append: append)) ?? false
    }

    /// 手动 /compact（forceThreshold = true：低于阈值也强制做一次有效压缩）。
    /// 需经 AgentLoop.runMaintenance 串行化（idle 才可执行）。
    func compactNow(events: [SessionEvent], model: String?,
                    append: (SessionEvent.Payload, Bool) async throws -> Void) async throws -> Bool {
        try await compact(events: events, model: model, forceThreshold: true, append: append)
    }

    // MARK: - 核心流程

    private func compact(events: [SessionEvent], model: String?, forceThreshold: Bool,
                         append: (SessionEvent.Payload, Bool) async throws -> Void) async throws -> Bool {
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

        // 1. 模型无关 prune（dsh：prune 先落，重估后再决定是否摘要）。
        let prunedChars = try await pruneToolResults(events: events, append: append)
        if prunedChars > 0 {
            Self.logger.info("pruned \(prunedChars) chars from tool results")
        }

        // 2. 重估：仍超阈值（或手动强制）才做摘要。
        let fold = DeriveFold(events)
        var used = Self.estimateSession(events)
        let threshold = Int(Double(contextWindow(for: model)) * policy.thresholdRatio)
        if !forceThreshold && used < threshold { return prunedChars > 0 }

        // 3. 选择可压缩范围（含 tool-pairing 平衡）。
        let range = Self.selectCompactableRange(events, retainTokens: max(0, used - Int(Double(contextWindow(for: model)) * policy.retainRatio)))
        guard let range else { return prunedChars > 0 }

        // 4. LLM 摘要（dsh summarizeWithLlm：一次性直调，复用当前路由；复用 KV
        //    cache 的前缀复用策略随 M8 补齐——M2 直接构造独立请求）。
        let transcript = Self.transcript(for: events, range: range)
        let summaryText = try await summarize(transcript: transcript)

        // 5. 落盘压缩锁三元组（dsh compaction/start → summary → end）。
        let compactionId = "cmp-\(UUID().uuidString)"
        try await append(.compactionStart(compactionId: compactionId, turn: nil), false)
        let shadowedTokens = range.seqList.reduce(0) { acc, seq in
            acc + Self.estimateNode(events: events, seq: seq)
        }
        try await append(
            .compactionSummary(compactionId: compactionId, summary: summaryText,
                               shadowedRangeStart: range.seqList.first ?? 0,
                               shadowedRangeEnd: range.seqList.last ?? 0,
                               shadowedSeqs: range.seqList,
                               shadowedTokenCount: shadowedTokens),
            false)
        try await append(.compactionEnd(compactionId: compactionId, turn: nil, error: nil), false)
        used = 0 // 供后续断言；实际重估由调用方做
        Self.logger.info("compaction done: shadowed \(range.seqList.count) nodes, ~\(shadowedTokens) tokens")
        return true
    }

    // MARK: - prune（模型无关；dsh ToolResultPruner 语义）

    /// 对超预算 tool/result 做确定性头/中/尾剪枝：compaction/prune 影子定价 +
    /// tool/result 替换节点同步相邻落盘（dsh shadow-price 协议）。
    private func pruneToolResults(events: [SessionEvent],
                                  append: (SessionEvent.Payload, Bool) async throws -> Void) async throws -> Int {
        var charsRemoved = 0
        for event in events {
            guard case .toolResult(let turn, let step, let callId, let content,
                                   let isError, let errorName, let errorCode, _) = event.payload
            else { continue }
            guard content.count > policy.pruneThresholdChars else { continue }

            // 头/中/尾剪枝（Unicode 码点切分；dsh pruneContent 语义）。
            let removedStart = policy.pruneHeadChars
            let removedEnd = content.count - policy.pruneTailChars
            let head = String(content.prefix(removedStart))
            let tail = String(content.suffix(max(0, content.count - removedEnd)))
            let pruned = head + Policy.pruneMarker + tail

            // 影子定价 + 替换（同步相邻——协议要求 replacement 紧随定价事件）。
            try await append(
                .compactionPrune(shadowedSeqs: [event.seq],
                                 shadowedTokenCount: Self.estimateText(content)),
                false)
            try await append(
                .toolResult(turn: turn, step: step, callId: callId, content: pruned,
                            isError: isError, errorName: errorName, errorCode: errorCode,
                            meta: nil),
                false)
            charsRemoved += content.count - pruned.count
        }
        return charsRemoved
    }

    // MARK: - 范围选择 + tool-pairing 平衡（dsh selectCompactableRange / tool-pairing）

    /// 选择可压缩范围：模型可见节点按 seq 升序，保留尾部 ≤ retainTokens；
    /// tool-pairing 平衡（dsh tool-pairing.ts）：派生历史的 tool 对 =
    /// assistantMessage（含 toolCalls blocks）↔ toolResult——边界不得把这对拆散，
    /// 否则保留区出现孤立 tool 消息 → OpenAI 兼容端点 400
    /// "Messages with role 'tool' must be a response to a preceding message with
    /// 'tool_calls'"（ERR-017 真机实证）。原"M2 简化"注释的错误推理已删。
    static func selectCompactableRange(_ events: [SessionEvent],
                                       retainTokens: Int) -> (seqList: [Int], first: Int, last: Int)? {
        var visible: [(seq: Int, tokens: Int)] = []
        // callId → 承载该 call 的 assistantMessage 事件 seq（配对锚点的正确层级）。
        var assistantSeqByCallId: [String: Int] = [:]
        for event in events {
            switch event.payload {
            case .userMessage:
                visible.append((event.seq, estimateNode(events: events, seq: event.seq)))
            case .assistantMessage(_, _, let message, _, _):
                for case .toolCall(let callId, _, _) in message.content {
                    assistantSeqByCallId[callId] = event.seq
                }
                visible.append((event.seq, estimateNode(events: events, seq: event.seq)))
            case .toolResult(_, _, let callId, let content, _, _, _, _):
                visible.append((event.seq, estimateText(content) + 4))
                // 结果的配对 assistant 一定在它之前落盘（不变量），向前就近找。
                if assistantSeqByCallId[callId] == nil {
                    for previous in events.reversed() where previous.seq < event.seq {
                        if case .assistantMessage(_, _, let message, _, _) = previous.payload,
                           message.content.contains(where: { if case .toolCall(let id, _, _) = $0 { return id == callId }; return false }) {
                            assistantSeqByCallId[callId] = previous.seq
                            break
                        }
                    }
                }
            default:
                break
            }
        }
        guard !visible.isEmpty else { return nil }

        // 尾部保留 ≤ retainTokens。
        var tailTokens = 0
        var headEnd = visible.count
        while headEnd > 0 {
            let node = visible[headEnd - 1]
            if tailTokens + node.tokens > retainTokens && tailTokens > 0 { break }
            tailTokens += node.tokens
            headEnd -= 1
        }
        guard headEnd > 0 else { return nil }

        // tool-pairing 平衡：影子区 = visible.prefix(head)。若保留区中某
        // toolResult 的配对 assistantMessage 已被影子化，边界向前收缩（把该
        // assistant 挤回保留区），直至保留区不存在孤立 tool 消息。
        var head = headEnd
        while head > 0 {
            let shadowSeqs = Set(visible.prefix(head).map { $0.seq })
            var balanced = true
            for node in visible[head...] {
                guard case .toolResult(_, _, let callId, _, _, _, _, _) = events[node.seq].payload,
                      let assistantSeq = assistantSeqByCallId[callId],
                      shadowSeqs.contains(assistantSeq) else { continue }
                balanced = false
                break
            }
            if balanced { break }
            head -= 1
        }
        guard head > 0 else { return nil }
        let seqList = visible.prefix(head).map { $0.seq }
        return (seqList, seqList.first ?? 0, seqList.last ?? 0)
    }

    /// 单节点估算（影子定价用）。
    static func estimateNode(events: [SessionEvent], seq: Int) -> Int {
        guard seq >= 0, seq < events.count else { return 0 }
        switch events[seq].payload {
        case .userMessage(let text): return 4 + estimateText(text)
        case .assistantMessage(_, _, let message, _, _):
            let text = message.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                if case .reasoning(let t) = block { return t }
                return nil
            }.joined()
            var total = 4 + estimateText(text)
            for case .toolCall(_, _, let arguments) in message.content {
                total += estimateText(arguments) + 8
            }
            return total
        case .toolResult(_, _, _, let content, _, _, _, _): return 4 + estimateText(content)
        default: return 0
        }
    }

    /// 摘要输入转录（范围内模型可见内容；单节点截断 2000 字符防爆输入）。
    static func transcript(for events: [SessionEvent], range: (seqList: [Int], first: Int, last: Int)) -> String {
        var lines: [String] = []
        for seq in range.seqList {
            guard seq < events.count else { continue }
            switch events[seq].payload {
            case .userMessage(let text):
                lines.append("[user] \(String(text.prefix(2000)))")
            case .assistantMessage(_, _, let message, _, _):
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined()
                let calls = message.content.compactMap { block -> String? in
                    if case .toolCall(let id, let name, _) = block { return "\(name)(\(id))" }
                    return nil
                }
                lines.append("[assistant] \(String(text.prefix(2000)))"
                    + (calls.isEmpty ? "" : " [tool calls: \(calls.joined(separator: ", "))]"))
            case .toolResult(_, _, let callId, let content, _, _, _, _):
                lines.append("[tool result \(callId)] \(String(content.prefix(2000)))")
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// LLM 摘要（dsh summarizeWithLlm 的 M2 形态：一次性直调，maxTokens 上限）。
    private func summarize(transcript: String) async throws -> String {
        let adapter = try await makeAdapter()
        let system = """
        You are a conversation summarizer. Condense the following agent conversation \
        transcript into a compact summary that preserves: the user's goals and constraints, \
        key decisions made, important file paths and commands, current progress, and \
        outstanding next steps. Write in the same language as the conversation. \
        Output ONLY the summary text.
        """
        let request = LLMRequest(
            baseURL: adapter.endpoint.baseURL,
            apiKey: adapter.apiKey,
            model: adapter.endpoint.model,
            system: system,
            messages: [ChatMessage(role: .user, content: transcript)],
            maxTokens: policy.summaryMaxTokens,
            thinking: "disabled",
            purpose: "compaction")
        var summary = ""
        let stream = adapter.stream(request)
        for try await chunk in stream {
            if case .textDelta(_, let text) = chunk {
                summary += text
            }
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw LLMError(message: "compaction summary was empty", code: "EMPTY_SUMMARY")
        }
        return trimmed
    }
}
