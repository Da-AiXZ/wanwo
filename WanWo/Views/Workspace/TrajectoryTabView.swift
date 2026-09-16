//
//  TrajectoryTabView.swift
//  WanWo
//
//  【批2 2C 新写】轨迹页签（dsh ui-trajectory 台账版）。
//  语义源 = dsh packages/client/ui-trajectory（TrajectoryTable/TrajectoryCell
//  事件台账 + record inspector）。本批最小台账（派单简报 2C 口径）：
//    · 两列行（事件词汇 / 内容摘要）——复用 M2.8 事件流行投影口径；
//    · turn / assistant（step）两级折叠摘要行（轮次摘要行 → step 摘要行
//      → 原始记录）；
//    · 记录检查器（概述 / 参数 / 结果 / 计时 四 tab）；
//    · 本地过滤（词汇/摘要子串，大小写不敏感）；
//    · 虚拟化 = List 惰性渲染（简版）。
//  **时间线（四模式拖选缩放）明确降级不做**（体量不可抗力，登记后续）。
//  数据面：SessionLogScanner 只读 replay（EventStreamView 同款纪律——
//  纯 Data 读取、不开写句柄、不写任何事件/文件），扫描/投影放后台任务。
//

import SwiftUI

// MARK: - 台账投影（纯函数；单测面）

/// 事件流 → 台账（turn / step 两级分组 + 记录行）。
enum TrajectoryLedger {

    /// 一条台账记录（事件词汇 + 内容 + 检查器四面数据）。
    struct Record: Identifiable, Equatable {
        let id: Int            // = seq
        let seq: Int
        let timeMs: Int64
        /// 事件词汇（wire 名，dsh TrajectoryCell 第一列）。
        let wireType: String
        /// 概述单行（EventStreamRowBuilder 同口径精简版）。
        let summary: String
        /// 参数（tool/call 的 pretty JSON arguments；无 = nil）。
        let paramsText: String?
        /// 结果（tool/result 正文或错误身份 / assistant 正文首块；无 = nil）。
        let resultText: String?
        let isError: Bool
        /// 计时（配对时长 ms：tool call→result、stepStart→assistantMessage；
        /// 无 = nil）。
        let durationMs: Int64?
    }

    /// step（assistant）级摘要组（第二级折叠行）。
    struct StepGroup: Identifiable, Equatable {
        let id: String         // "t<turn>-s<step>"
        let turn: Int
        let step: Int
        var records: [Record] = []
        /// step 墙钟（stepStart → stepEnd；缺端点 = nil）。
        var durationMs: Int64?
        /// step usage 汇总（assistantMessage usage；无 = nil）。
        var usage: ConversationProjector.TurnUsageSummary?
    }

    /// turn 级摘要组（第一级折叠行）。
    struct TurnGroup: Identifiable, Equatable {
        let id: Int            // = turn（0 = 序外事件桶）
        var records: [Record] = []       // 无 step 归属的事件
        var stepGroups: [StepGroup] = [] // 按 step 升序
        var eventCount = 0
        /// 轮次墙钟（turnStart → turnEnd；缺 = nil）。
        var runMs: Int64?
        /// 轮次 token 汇总（billedInput + output；全零 = nil——dsh 无数据
        /// 组缺席语义）。具名结构体：Swift 元组不合 Equatable（CI 35121872255
        /// 实证 TurnGroup 自动合成失败），结构体走合成一致性。
        struct TokenSummary: Equatable {
            var billed: Int
            var output: Int
            static let zero = TokenSummary(billed: 0, output: 0)
        }
        var tokenSummary: TokenSummary?
    }

    // MARK: build

    /// 全事件流 → turn 组序列（纯函数；序外事件落 turn 0 桶）。
    /// 单遍落组 + 预扫描配对锚（tool call→result、stepStart→message、
    /// turnStart→turnEnd 时长在记录/组摘要上补算）。
    static func buildDirect(events: [SessionEvent]) -> [TurnGroup] {
        // 第一遍：配对锚 + turn 起止。
        var callStartMs: [String: Int64] = [:]
        var stepStartMs: [String: Int64] = [:]
        var turnStartMs: [Int: Int64] = [:]
        var turnEndMs: [Int: Int64] = [:]
        for event in events {
            switch event.payload {
            case .toolCall(_, _, let callId, _, _):
                callStartMs[callId] = event.timeMs
            case .stepStart(let t, let s):
                stepStartMs["\(t):\(s)"] = event.timeMs
            case .turnStart(let t):
                turnStartMs[t] = event.timeMs
            case .turnEnd(let t, _):
                turnEndMs[t] = event.timeMs
            default:
                break
            }
        }

        var groups: [Int: TurnGroup] = [:]
        var order: [Int] = []
        var currentTurn = 0
        var stepUsages: [String: ConversationProjector.TurnUsageSummary] = [:]

        func group(_ turn: Int) -> TurnGroup {
            if let g = groups[turn] { return g }
            let g = TurnGroup(id: turn)
            groups[turn] = g
            order.append(turn)
            return g
        }
        func setGroup(_ g: TurnGroup) { groups[g.id] = g }

        for event in events {
            let turnOfPayload: Int?
            let stepOfPayload: Int?
            switch event.payload {
            case .turnStart(let t): turnOfPayload = t; stepOfPayload = nil; currentTurn = t
            case .turnEnd(let t, _): turnOfPayload = t; stepOfPayload = nil
            case .stepStart(let t, let s): turnOfPayload = t; stepOfPayload = s; currentTurn = t
            case .stepEnd(let t, let s): turnOfPayload = t; stepOfPayload = s
            case .assistantMessage(let t, let s, _, _, _),
                 .toolCall(let t, let s, _, _, _),
                 .toolResult(let t, let s, _, _, _, _, _, _),
                 .llmRetry(_, let t, let s, _, _, _, _, _, _, _),
                 .llmRetryStarted(_, let t, let s, _),
                 .assistantChunk(let t, let s, _):
                turnOfPayload = t; stepOfPayload = s
            default:
                turnOfPayload = nil; stepOfPayload = nil
            }
            let owner = turnOfPayload ?? currentTurn
            var g = group(owner)
            g.eventCount += 1

            var record = makeRecord(event)
            // 配对时长补算（tool/result 与 assistantMessage）。
            switch event.payload {
            case .toolResult(_, _, let callId, _, _, _, _, _):
                if let start = callStartMs[callId] {
                    record = Record(id: record.id, seq: record.seq,
                                    timeMs: record.timeMs, wireType: record.wireType,
                                    summary: record.summary, paramsText: record.paramsText,
                                    resultText: record.resultText, isError: record.isError,
                                    durationMs: max(0, event.timeMs - start))
                }
            case .assistantMessage(let t, let s, _, _, _):
                if let start = stepStartMs["\(t):\(s)"] {
                    record = Record(id: record.id, seq: record.seq,
                                    timeMs: record.timeMs, wireType: record.wireType,
                                    summary: record.summary, paramsText: record.paramsText,
                                    resultText: record.resultText, isError: record.isError,
                                    durationMs: max(0, event.timeMs - start))
                }
            default:
                break
            }

            if let step = stepOfPayload {
                let key = "\(owner):\(step)"
                var sg = g.stepGroups.first(where: { $0.turn == owner && $0.step == step })
                    ?? StepGroup(id: key, turn: owner, step: step)
                sg.records.append(record)
                if case .assistantMessage(_, _, _, let usage, _) = event.payload, let usage {
                    var u = stepUsages[key]
                        ?? ConversationProjector.TurnUsageSummary(turn: owner)
                    u.inputTokens += usage.inputTokens
                    u.outputTokens += usage.outputTokens
                    if let read = usage.cacheReadTokens {
                        u.cacheReadTokens = (u.cacheReadTokens ?? 0) + read
                    }
                    if let reasoning = usage.reasoningTokens {
                        u.reasoningTokens = (u.reasoningTokens ?? 0) + reasoning
                    }
                    stepUsages[key] = u
                    sg.usage = stepUsages[key]
                }
                if case .stepEnd(let t, let s) = event.payload, t == owner, s == step,
                   let start = stepStartMs[key] {
                    sg.durationMs = max(0, event.timeMs - start)
                }
                g.stepGroups.removeAll { $0.turn == owner && $0.step == step }
                g.stepGroups.append(sg)
            } else {
                g.records.append(record)
            }
            // 轮次 token 汇总。
            if case .assistantMessage(_, _, _, let usage, _) = event.payload, let usage {
                var tokens = g.tokenSummary ?? .zero
                tokens.0 += usage.inputTokens + (usage.cacheReadTokens ?? 0)
                tokens.1 += usage.outputTokens
                g.tokenSummary = tokens
            }
            setGroup(g)
        }

        var out: [TurnGroup] = order.compactMap { groups[$0] }
        for idx in out.indices {
            if let start = turnStartMs[out[idx].id], let end = turnEndMs[out[idx].id] {
                out[idx].runMs = max(0, end - start)
            }
            out[idx].stepGroups.sort { $0.step < $1.step }
            if out[idx].tokenSummary == .zero { out[idx].tokenSummary = nil }
        }
        return out
    }

    // MARK: filter（本地过滤）

    /// 查询过滤：wireType / summary 子串（大小写不敏感）；命中记录重组成组，
    /// 空组剔除（组摘要计数随过滤集重算——过滤后数字反映过滤集）。空查询直通。
    static func filter(groups: [TurnGroup], query: String) -> [TurnGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        let needle = trimmed.lowercased()
        var out: [TurnGroup] = []
        for group in groups {
            let hitRecords = group.records.filter {
                $0.wireType.lowercased().contains(needle)
                    || $0.summary.lowercased().contains(needle)
            }
            var filtered = TurnGroup(id: group.id)
            filtered.records = hitRecords
            filtered.eventCount = hitRecords.count
            filtered.runMs = group.runMs
            var hitCount = hitRecords.count
            for var sg in group.stepGroups {
                sg.records = sg.records.filter {
                    $0.wireType.lowercased().contains(needle)
                        || $0.summary.lowercased().contains(needle)
                }
                guard !sg.records.isEmpty else { continue }
                hitCount += sg.records.count
                filtered.eventCount += sg.records.count
                filtered.stepGroups.append(sg)
            }
            // token/runMs 摘要只在无过滤条件时全显（有过滤=呈现命中集计数）。
            if hitCount > 0 { out.append(filtered) }
        }
        return out
    }

    // MARK: 记录投影

    /// 单事件 → 记录（概述口径 = EventStreamRowBuilder 精简版）。
    static func makeRecord(_ event: SessionEvent) -> Record {
        let params: String?
        let result: String?
        let isError: Bool
        var summary: String

        switch event.payload {
        case .turnStart(let t):
            params = nil; result = nil; isError = false
            summary = "turn \(t) 开始"
        case .turnEnd(let t, let reason):
            params = nil; result = nil; isError = false
            summary = "turn \(t) 结束 · \(turnReasonText(reason))"
        case .stepStart(let t, let s):
            params = nil; result = nil; isError = false
            summary = "turn \(t) · step \(s) 开始"
        case .stepEnd(let t, let s):
            params = nil; result = nil; isError = false
            summary = "turn \(t) · step \(s) 结束"
        case .userMessage(let text):
            params = nil; result = text.isEmpty ? nil : text
            isError = false
            summary = excerpt(text, 60)
        case .assistantMessage(_, _, let message, let usage, let interrupted):
            params = nil
            result = firstText(message)
            isError = false
            var parts: [String] = []
            if let body = result { parts.append(excerpt(body, 60)) }
            if let usage { parts.append("in \(usage.inputTokens) out \(usage.outputTokens)") }
            if interrupted { parts.append("interrupted") }
            summary = parts.joined(separator: " · ")
        case .assistantChunk(_, _, let chunk):
            params = nil; result = nil; isError = false
            summary = chunkSummaryText(chunk)
        case .toolCall(_, _, _, let name, let arguments):
            // 参数面 = 模型原始 JSON pretty 化（ConversationProjector.prettyJSON
            // 复用——畸形 JSON 兜底原文）。
            params = ConversationProjector.prettyJSON(arguments)
            result = nil; isError = false
            summary = "\(name) · \(excerpt(arguments, 80))"
        case .toolResult(_, _, let callId, let content, let err,
                         let errorName, let errorCode, _):
            params = nil
            result = content.isEmpty ? nil : content
            isError = err
            var parts = [excerpt(content, 60)]
            if let errorName, let errorCode { parts.append("\(errorName)/\(errorCode)") }
            parts.append("call \(callId.prefix(8))")
            summary = parts.joined(separator: " · ")
        case .llmRetry(_, let t, let s, let provider, let mode, _,
                       let retry, let maxRetries, let delayMs, let failure):
            params = nil; result = nil; isError = true
            summary = "turn \(t)/\(s) \(provider)/\(mode) 重试 \(retry) · 等 \(delayMs)ms · \(failure.code)"
        case .llmRetryStarted(_, _, _, let retry):
            params = nil; result = nil; isError = false
            summary = "重试 \(retry) 重发请求"
        case .requestHeader(let header, let reason):
            params = nil; result = nil; isError = false
            summary = "\(header.config.model) · \(reason)"
        case .sessionTitle(let title, _):
            params = nil; result = nil; isError = false
            summary = excerpt(title, 60)
        case .system(let note):
            params = nil; result = nil; isError = false
            summary = excerpt(note, 80)
        case .compactionStart(let compactionId, let turn):
            params = nil; result = nil; isError = false
            summary = "\(compactionId) · turn \(turn.map(String.init) ?? "回合外")"
        case .compactionSummary(let compactionId, let sum, let rs, let re, _, _):
            params = nil; result = sum.isEmpty ? nil : sum; isError = false
            summary = "\(compactionId) 替换 [\(rs)…\(re)]"
        case .compactionEnd(let compactionId, _, let error):
            params = nil; result = nil; isError = error != nil
            summary = "\(compactionId) · \(error ?? "完成")"
        case .compactionPrune(let seqs, let tokens):
            params = nil; result = nil; isError = false
            summary = "prune \(seqs.count) 事件 \(tokens) tok"
        case .commandRun(_, let name, let args):
            params = nil; result = nil; isError = false
            summary = "/\(name) \(args ?? "")"
        case .commandDone(_, let kind, let text):
            params = nil; result = text ?? nil; isError = kind != "success"
            summary = "[\(kind)] \(excerpt(text ?? "-", 40))"
        case .approvalAsked(_, let tool, let reason):
            params = nil; result = nil; isError = false
            summary = "\(tool) · \(reason ?? "-")"
        case .approvalDecided(_, let verdict):
            params = nil; result = nil; isError = false
            summary = verdict
        case .extensionEvent(let kind, let payload):
            params = nil; result = nil; isError = false
            summary = "\(kind) · \(excerpt(compactJSON(payload), 80))"
        case .ignored(let kind):
            params = nil; result = nil; isError = false
            summary = "外来事件透传 · \(kind)"
        }

        return Record(id: event.seq, seq: event.seq, timeMs: event.timeMs,
                      wireType: event.wireType, summary: summary,
                      paramsText: params, resultText: result,
                      isError: isError, durationMs: nil)
    }

    // MARK: 文本助手（纯函数）

    /// 首 30 + 尾 30 摘录（换行折叠空格；不超阈值原样）。
    static func excerpt(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    private static func compactJSON(_ payload: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
    }

    private static func firstText(_ message: AssistantMessage) -> String? {
        for block in message.content {
            switch block {
            case .text(let text), .reasoning(let text):
                return text.isEmpty ? nil : text
            case .toolCall:
                continue
            }
        }
        return nil
    }

    private static func turnReasonText(_ reason: TurnEndReason) -> String {
        switch reason {
        case .completed: return "completed"
        case .aborted(let cause): return "aborted(\(cause))"
        case .blocked: return "blocked"
        case .error(let failure): return "error \(failure.code)"
        case .maxTokens: return "max-tokens"
        case .interrupted: return "interrupted"
        }
    }

    private static func chunkSummaryText(_ chunk: StreamChunk) -> String {
        switch chunk {
        case .blockStart(let index, let blockType):
            return "block-start #\(index) \(blockType)"
        case .textDelta(_, let text):
            return "text: \(excerpt(text, 40))"
        case .reasoningDelta(_, let text):
            return "thinking: \(excerpt(text, 40))"
        case .toolCallDelta(_, let id, let name, let delta):
            return "toolΔ \(name ?? id): \(excerpt(delta, 40))"
        case .blockEnd(let index, let block):
            let kind: String
            switch block {
            case .text: kind = "text"
            case .reasoning: kind = "reasoning"
            case .toolCall(_, let name, _): kind = "tool-call(\(name))"
            }
            return "block-end #\(index) \(kind)"
        case .usage(let usage):
            return "usage in \(usage.inputTokens) out \(usage.outputTokens)"
        case .finish(let reason):
            switch reason {
            case .stop: return "finish stop"
            case .toolCalls: return "finish tool-calls"
            case .maxTokens: return "finish max-tokens"
            case .error(let failure): return "finish error \(failure.code)"
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class TrajectoryTabViewModel: ObservableObject {
    @Published private(set) var groups: [TrajectoryLedger.TurnGroup] = []
    @Published private(set) var rawEventCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 本地过滤查询（视图侧双向绑定）。
    @Published var query: String = "" { didSet { applyFilter() } }
    /// 检查器选中记录（sheet 载体）。
    @Published var selectedRecord: TrajectoryLedger.Record?

    @Published private(set) var visibleGroups: [TrajectoryLedger.TurnGroup] = []

    private let environment: AppEnvironment
    /// 会话锚（nil = 无选中会话——空态）。
    private var sessionID: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 会话切换 / 首次出现：重载（onChange 驱动；同会话不重复加载）。
    func update(sessionID: String?) async {
        guard sessionID != self.sessionID else { return }
        self.sessionID = sessionID
        await reload()
    }

    func reload() async {
        guard let id = sessionID, !id.isEmpty else {
            groups = []; visibleGroups = []; rawEventCount = 0
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        // 只读 replay（EventStreamView 同款纪律：纯 Data 读取、零写柄）。
        let result = await Task.detached(priority: .userInitiated) {
            TrajectoryLoader.load(sessionID: id)
        }.value
        switch result {
        case .success(let events):
            rawEventCount = events.count
            errorMessage = nil
            groups = TrajectoryLedger.buildDirect(events: events)
            applyFilter()
        case .failure(let error):
            groups = []; visibleGroups = []; rawEventCount = 0
            errorMessage = "读取失败：\(error)"
        }
    }

    private func applyFilter() {
        visibleGroups = TrajectoryLedger.filter(groups: groups, query: query)
    }
}

/// 只读加载器（复用 SessionLogScanner 直读路径；与 EventStreamLoader 同纪律）。
private enum TrajectoryLoader {
    enum LoadError: Error, Equatable {
        case invalidSessionID(String)
        case logNotFound(String)
        case unreadable(String)
    }

    static func load(sessionID: String) -> Result<[SessionEvent], LoadError> {
        guard !sessionID.isEmpty,
              sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return .failure(.invalidSessionID(sessionID)) }
        let url = GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase,
            groupID: GroupStore.defaultGroupID)
            .appendingPathComponent("\(sessionID).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.logNotFound(sessionID))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable(sessionID))
        }
        do {
            let scan = try SessionLogScanner.scan(data: data)
            return .success(scan.events)
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }
}

// MARK: - 视图

/// 轨迹页签（台账版）。
struct TrajectoryTabView: View {
    @StateObject private var model: TrajectoryTabViewModel
    /// 会话锚（nil = 无选中会话——空态引导）。
    private let sessionID: String?

    init(environment: AppEnvironment, sessionID: String?) {
        _model = StateObject(wrappedValue: TrajectoryTabViewModel(environment: environment))
        self.sessionID = sessionID
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            ledgerList
        }
        .sheet(item: $model.selectedRecord) { record in
            RecordInspectorView(record: record)
        }
        .task(id: sessionID) {
            await model.update(sessionID: sessionID)
        }
        .refreshable { await model.reload() }
    }

    // MARK: 过滤条

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("过滤事件词汇或内容", text: $model.query)
                    .font(.footnote)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await model.reload() }
                } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading || sessionID == nil)
                .accessibilityLabel("刷新轨迹")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Text("共 \(model.rawEventCount) 事件 · \(groupSummaryText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }

    private var groupSummaryText: String {
        let turns = model.visibleGroups.count
        return "轨迹 \(turns) 轮"
    }

    // MARK: 台账列表

    private var ledgerList: some View {
        List {
            if sessionID == nil {
                emptyState("选中一个会话后查看其事件轨迹")
            } else if model.visibleGroups.isEmpty && !model.isLoading {
                emptyState(model.errorMessage ?? (model.query.isEmpty
                                                 ? "该会话暂无事件" : "无匹配记录"))
            }
            ForEach(model.visibleGroups) { group in
                TurnGroupSection(group: group) { record in
                    model.selectedRecord = record
                }
            }
        }
        .listStyle(.plain)
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
    }
}

// MARK: - turn 组段（第一级折叠）

private struct TurnGroupSection: View {
    let group: TrajectoryLedger.TurnGroup
    let onSelect: (TrajectoryLedger.Record) -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // 无 step 归属记录（用户消息/命令/轮次边界等）。
            ForEach(group.records) { record in
                LedgerRowView(record: record, onSelect: onSelect)
            }
            // step（assistant）级摘要组（第二级折叠）。
            ForEach(group.stepGroups) { stepGroup in
                StepGroupSection(stepGroup: stepGroup, onSelect: onSelect)
            }
        } label: {
            turnLabel
        }
    }

    private var turnLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text(group.id == 0 ? "回合外" : "第 \(group.id) 轮")
                    .font(.footnote.weight(.medium))
                Spacer()
                Text("\(group.eventCount) 事件")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let runMs = group.runMs {
                    Text(SessionStatsFold.formatDuration(runMs))
                }
                if let tokens = group.tokenSummary {
                    Text("in \(SessionStatsFold.formatTokens(tokens.billed)) · "
                        + "out \(SessionStatsFold.formatTokens(tokens.output))")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - step 组段（第二级折叠）

private struct StepGroupSection: View {
    let stepGroup: TrajectoryLedger.StepGroup
    let onSelect: (TrajectoryLedger.Record) -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(stepGroup.records) { record in
                LedgerRowView(record: record, onSelect: onSelect)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                Text("step \(stepGroup.step)")
                    .font(.caption.weight(.medium))
                if let usage = stepGroup.usage {
                    Text("in \(SessionStatsFold.formatTokens(usage.billedInputTokens)) · "
                        + "out \(SessionStatsFold.formatTokens(usage.outputTokens))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let duration = stepGroup.durationMs {
                    Text(SessionStatsFold.formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(stepGroup.records.count) 事件")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - 台账行（两列：事件词汇 / 内容）

private struct LedgerRowView: View {
    let record: TrajectoryLedger.Record
    let onSelect: (TrajectoryLedger.Record) -> Void

    var body: some View {
        Button {
            onSelect(record)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.wireType)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(record.isError ? Color.red : Color.blue)
                        .lineLimit(1)
                    Text(record.summary)
                        .font(.caption)
                        .foregroundStyle(record.isError ? Color.red : .primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("#\(record.seq)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let duration = record.durationMs {
                        Text(SessionStatsFold.formatDuration(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.wireType) \(record.summary)")
    }
}

// MARK: - 记录检查器（概述/参数/结果/计时 四 tab）

private struct RecordInspectorView: View {
    let record: TrajectoryLedger.Record

    enum Tab: String, CaseIterable {
        case overview = "概述"
        case params = "参数"
        case result = "结果"
        case timing = "计时"
    }

    @State private var tab: Tab = .overview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("检查面", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                // 空态缺席面直呈占位（dsh 检查器空段语义——省略整段改为
                // 单行说明，iOS 形态登记）。
                tabBody
            }
            .navigationTitle("#\(record.seq) · \(record.wireType)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var tabBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .overview:
                    keyValue("事件词汇", record.wireType)
                    keyValue("概述", record.summary)
                    keyValue("seq", "#\(record.seq)")
                case .params:
                    if let params = record.paramsText {
                        codeBlock(params)
                    } else {
                        emptyFace("本记录无参数面")
                    }
                case .result:
                    if let result = record.resultText {
                        codeBlock(result)
                    } else {
                        emptyFace("本记录无结果面")
                    }
                case .timing:
                    keyValue("事件时间",
                             Self.timeText(record.timeMs))
                    if let duration = record.durationMs {
                        keyValue("配对时长",
                                 SessionStatsFold.formatDuration(duration))
                    } else {
                        emptyFace("本记录无配对时长（tool call→result、stepStart→message 才计时）")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(6)
    }

    private func emptyFace(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static func timeText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }
}
