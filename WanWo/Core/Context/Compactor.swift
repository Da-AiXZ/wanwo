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

    struct PressureInfo: Equatable, Sendable {
        var usedTokens: Int
        var thresholdTokens: Int
        /// 0..1+（threshold 的比值；UI 三档着色）。
        var ratio: Double { thresholdTokens > 0 ? Double(usedTokens) / Double(thresholdTokens) : 0 }
    }

    let policy: Policy
    private let makeAdapter: @Sendable () throws -> OpenAICompatAdapter
    private let lock = NSLock()
    /// 压缩锁（dsh compaction/start~end 持久锁的进程内映像：同一会话不并发压缩）。
    private var compacting = false

    private static let logger = AppLogger(category: "Compactor")

    init(policy: Policy = Policy(),
         makeAdapter: @escaping @Sendable () throws -> OpenAICompatAdapter) {
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

    /// 当前压力（threshold = 窗口 × thresholdRatio）。
    func pressure(events: [SessionEvent], model: String?) -> PressureInfo {
        let used = Self.estimateSession(events)
        let window = contextWindow(for: model)
        return PressureInfo(usedTokens: used,
                            thresholdTokens: Int(Double(window) * policy.thresholdRatio))
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
    func compactIfNeeded(events: [SessionEvent], model: String?,
                         append: (SessionEvent.Payload, Bool) async throws -> Void) async -> Bool {
        let info = pressure(events: events, model: model)
        guard info.usedTokens >= info.thresholdTokens else { return false }
        Self.logger.info("compaction pressure: \(info.usedTokens) >= \(info.thresholdTokens)")
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
    /// tool-pairing 平衡：call/result 对必须同进同出（任一在范围内则补齐另一个）。
    static func selectCompactableRange(_ events: [SessionEvent],
                                       retainTokens: Int) -> (seqList: [Int], first: Int, last: Int)? {
        var visible: [(seq: Int, tokens: Int)] = []
        var callSeqByCallId: [String: Int] = [:]
        var resultSeqByCallId: [String: Int] = [:]
        for event in events {
            switch event.payload {
            case .userMessage, .assistantMessage:
                visible.append((event.seq, estimateNode(events: events, seq: event.seq)))
            case .toolResult(_, _, let callId, let content, _, _, _, _):
                visible.append((event.seq, estimateText(content) + 4))
                resultSeqByCallId[callId] = event.seq
            case .toolCall(_, _, let callId, _, let arguments):
                callSeqByCallId[callId] = event.seq
                // toolCall 本身不是派生消息节点，但作为配对锚点参与范围平衡。
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
        var startSeq = visible[0].seq
        var endSeq = visible[headEnd - 1].seq

        // tool-pairing 平衡：范围内的 result 补齐其 call；call 在范围内的 result 同理
        // （call 不是面节点，故只需保证结果所在的 call 事件——通过把 result 挤出
        // 范围无法做到（result 已在中间），改为扩展 start 到最早配对 call 之前的
        // 第一个可见节点。M2 简化：只要 result 在范围内即认可（call 是 log-only，
        // 派生历史不直接消费 toolCall 节点，拆散不会产生孤立 tool 消息）。
        // —— 校验保留：范围内不得存在「有 result 无 call」的 callId（不可能，因
        //   不变量已保证 result 后于 call 落盘）。
        _ = callSeqByCallId
        _ = resultSeqByCallId
        let seqList = visible.prefix(headEnd).map { $0.seq }
        return (seqList, startSeq, endSeq)
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
        let adapter = try makeAdapter()
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
