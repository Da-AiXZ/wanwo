//
//  EventStreamView.swift
//  WanWo
//
//  【最小移植自 dsh ui-trajectory（09 #19）+ F060 M8.2 前置】出处：
//    - dsh packages/client/ui-trajectory（TrajectoryTable/TrajectoryCell/Timeline：
//      按时间线逐事件呈现、类型可辨（分类着色 + 图标）、载荷单行摘要截断；
//      M2.8 只移植「事件流表」最小面，不做 span 树/成本核算/过滤检索/实时订阅）
//  M2.8 范围（只读诊断页）：
//    - 数据源 = SessionLogScanner.scan（SessionStore/JsonlEventLog 的同一 replay
//      扫描器；reconcileIndex 的只读同款路径）。纯 Data 读取，不开任何可写句柄、
//      不写任何事件/文件（JsonlEventLog.open 读模式也会开写柄做 inode 校验，
//      此处刻意不走它，做到字面意义的只读）。
//    - 手动刷新全量 replay；List 惰性渲染 + 摘要预投影（长会话几千条不卡）。
//    - M8.2 再升级：span 树 / 成本 / 过滤检索 / 实时订阅（本文件刻意不含）。
//

import SwiftUI

// MARK: - 只读加载器

/// 事件流只读加载器：SessionLogScanner 同款 replay，纯 Data 读取、零写句柄。
/// （出处：SessionStore.reconcileIndex 的只读扫描路径——M1 交付物零改动复用。
///  无状态 enum、静态方法默认 nonisolated，可安全放后台任务执行。）
enum EventStreamLoader {
    /// 一次全量 replay 投影的输出（Sendable，跨并发域回传）。
    struct Output: Sendable {
        var sessionID: String
        var createdAtMs: Int64
        var rows: [EventStreamRow]
        /// 非致命扫描残记（torn tail 等；中部损坏走 failure）。
        var issue: String?
    }

    enum LoadError: Error, Equatable {
        case invalidSessionID(String)
        case logNotFound(String)
        case unreadable(String)
    }

    /// 全量 replay + 行投影（CPU 密集，调用方放后台任务）。
    static func loadAndProject(sessionID: String) -> Result<Output, LoadError> {
        do {
            // id 路径安全校验（与 SessionStore.fileURL 同口径，fail closed）。
            guard !sessionID.isEmpty,
                  sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else {
                return .failure(.invalidSessionID(sessionID))
            }
            let url = WanWoPaths.persistentBase
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.logNotFound(sessionID))
            }
            guard let data = try? Data(contentsOf: url) else {
                return .failure(.unreadable(sessionID))
            }
            let scan = try SessionLogScanner.scan(data: data)
            // 摘要字符串在本任务内一次建成，行渲染只拼现成字段（长会话惰性不卡的关键）。
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss.SSS"
            let rows = scan.events.map { EventStreamRowBuilder.build(event: $0, timeFormatter: timeFormatter) }
            let output = Output(sessionID: scan.header.id,
                                createdAtMs: scan.header.createdAtMs,
                                rows: rows,
                                issue: scan.issue)
            return .success(output)
        } catch let error as SessionLogError {
            return .failure(.unreadable("\(error)"))
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }
}

// MARK: - 行模型

/// 事件流一行（dsh TrajectoryCell 最小面：seq · 类型标 · 摘要 · 时间）。
/// 字段在 replay 投影期一次算好，行视图零计算（几千条 List 惰性渲染不卡）。
struct EventStreamRow: Identifiable, Sendable {
    let id: Int          // = seq
    let seq: Int
    let timeText: String
    let wireType: String
    let iconName: String
    let tint: Color
    let summary: String
    /// 错误态行（tool/result isError、turn/end error、compaction/end error）红色醒目。
    let isAlert: Bool
}

/// 分类着色（照 dsh 轨迹视图 tagSystem/tagUser/tagMessage/tagTool 的分类着色思路，
/// 素净色板）：user 绿 / assistant 紫 / tool 橙 / 结构蓝 / 压缩青 / 控制灰 / 重试与错误红。
private enum EventStreamCategory {
    case user, assistant, tool, structure, compaction, control, retry

    var tint: Color {
        switch self {
        case .user: return .green
        case .assistant: return .purple
        case .tool: return .orange
        case .structure: return .blue
        case .compaction: return .teal
        case .control: return .gray
        case .retry: return .red
        }
    }

    var iconName: String {
        switch self {
        case .user: return "person"
        case .assistant: return "text.bubble"
        case .tool: return "wrench"
        case .structure: return "arrow.right.circle"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .control: return "info.circle"
        case .retry: return "arrow.triangle.2.circlepath"
        }
    }

    static func classify(wireType: String) -> EventStreamCategory {
        if wireType.hasPrefix("user/") { return .user }
        if wireType.hasPrefix("assistant/") { return .assistant }
        if wireType.hasPrefix("tool/") { return .tool }
        if wireType.hasPrefix("turn/") || wireType.hasPrefix("step/") { return .structure }
        if wireType.hasPrefix("compaction/") { return .compaction }
        if wireType.hasPrefix("llm/retry") { return .retry }
        return .control   // request/header、command/*、approval/*、system、session/title、ignored
    }
}

// MARK: - 摘要投影（dsh trajectory-event-projection 的最小面）

/// SessionEvent 载荷 → 单行摘要字符串（载荷前缀截断口径照规格：
/// user 60 字、tool/call 工具名+参数 80 字、assistant/message 正文 60 字+usage）。
private enum EventStreamRowBuilder {

    static func build(event: SessionEvent, timeFormatter: DateFormatter) -> EventStreamRow {
        let wireType = event.wireType
        let category = EventStreamCategory.classify(wireType: wireType)
        let (summary, isAlert) = summarize(event)
        return EventStreamRow(id: event.seq,
                              seq: event.seq,
                              timeText: timeFormatter.string(from: Date(timeIntervalSince1970:
                                  TimeInterval(event.timeMs) / 1000.0)),
                              wireType: wireType,
                              iconName: category.iconName,
                              tint: category.tint,
                              summary: summary,
                              isAlert: isAlert)
    }

    /// - Returns: (单行摘要, 是否错误态行)
    private static func summarize(_ event: SessionEvent) -> (String, Bool) {
        switch event.payload {
        case .turnStart(let turn):
            return ("turn \(turn)", false)
        case .turnEnd(let turn, let reason):
            return ("turn \(turn) · \(turnReasonText(reason))",
                    isTurnEndError(reason))
        case .stepStart(let turn, let step):
            return ("turn \(turn) · step \(step)", false)
        case .stepEnd(let turn, let step):
            return ("turn \(turn) · step \(step)", false)
        case .userMessage(let text):
            return (prefix(text, 60), false)
        case .assistantChunk(_, _, let chunk):
            return (chunkSummary(chunk), false)
        case .assistantMessage(_, _, let message, let usage, let interrupted):
            var parts: [String] = []
            if let body = firstText(message) {
                parts.append(prefix(body, 60))
            }
            if let usage {
                parts.append("in \(usage.inputTokens) out \(usage.outputTokens)")
            }
            if interrupted {
                parts.append("interrupted")
            }
            return (parts.joined(separator: " · "), false)
        case .requestHeader(let header, let reason):
            return ("\(header.config.model) · \(reason)", false)
        case .llmRetry(_, _, _, let provider, let mode, _, let retry, let maxRetries,
                       let delayMs, let failure):
            let maxText = maxRetries.map(String.init) ?? "-"
            return ("\(provider)/\(mode) retry \(retry)/\(maxText) "
                    + "wait \(delayMs)ms · \(failure.code)", true)
        case .llmRetryStarted(_, _, _, let retry):
            return ("retry \(retry) 重发请求", false)
        case .sessionTitle(let title, _):
            return (prefix(title, 60), false)
        case .system(let note):
            return (prefix(note, 80), false)
        case .toolCall(_, _, let callId, let name, let arguments):
            return ("\(name) args: \(prefix(arguments, 80)) · call \(callId)", false)
        case .toolResult(_, _, let callId, let content, let isError,
                         let errorName, let errorCode, _):
            var parts: [String] = [prefix(content, 60)]
            if let errorName, let errorCode {
                parts.append("\(errorName)/\(errorCode)")
            }
            parts.append("call \(callId)")
            return (parts.joined(separator: " · "), isError)
        case .compactionStart(let compactionId, let turn):
            return ("\(compactionId) · turn \(turn.map(String.init) ?? "回合外")", false)
        case .compactionSummary(let compactionId, let summary, let rangeStart,
                                let rangeEnd, let seqs, let tokens):
            // 替换范围 = 影子区间 + 被替换事件数 + 影子定价（规格：替换范围必显）。
            return ("\(compactionId) 替换 [\(rangeStart)…\(rangeEnd)] "
                    + "\(seqs.count) 事件 \(tokens) tok · \(prefix(summary, 40))", false)
        case .compactionEnd(let compactionId, _, let error):
            return ("\(compactionId) · \(error ?? "完成")", error != nil)
        case .compactionPrune(let seqs, let tokens):
            return ("prune \(seqs.count) 事件 \(tokens) tok", false)
        case .commandRun(_, let name, let args):
            return ("/\(name) \(args ?? "")", false)
        case .commandDone(_, let kind, let text):
            return ("[\(kind)] \(prefix(text ?? "-", 40))", kind != "success")
        case .approvalAsked(_, let tool, let reason):
            return ("\(tool) · \(reason ?? "-")", false)
        case .approvalDecided(_, let verdict):
            return (verdict, false)
        case .ignored(let kind):
            return ("外来事件透传 · \(kind)", false)
        }
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

    private static func isTurnEndError(_ reason: TurnEndReason) -> Bool {
        if case .error = reason { return true }
        return false
    }

    private static func chunkSummary(_ chunk: StreamChunk) -> String {
        switch chunk {
        case .blockStart(let index, let blockType):
            return "block-start #\(index) \(blockType)"
        case .textDelta(_, let text):
            return "text: \(prefix(text, 60))"
        case .reasoningDelta(_, let text):
            return "thinking: \(prefix(text, 60))"
        case .toolCallDelta(_, let id, let name, let argumentsDelta):
            return "toolΔ \(name ?? id): \(prefix(argumentsDelta, 60))"
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

    /// 第一个 text/reasoning 块正文（assistant/message 摘要用）。
    private static func firstText(_ message: AssistantMessage) -> String? {
        for block in message.content {
            switch block {
            case .text(let text), .reasoning(let text):
                return text
            case .toolCall:
                continue
            }
        }
        return nil
    }

    /// 单行截断：前 `limit` 个字符 + 省略号（新行折叠为空格保证单行）。
    private static func prefix(_ text: String, _ limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= limit {
            return flattened
        }
        let head = String(flattened.prefix(limit))
        return head + "…"
    }
}

// MARK: - ViewModel

/// 事件流诊断页模型：会话选择 + 手动全量 replay（只读；无实时订阅，M8.2 升级）。
@MainActor
final class EventStreamViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var selectedSessionID: String?
    @Published private(set) var rows: [EventStreamRow] = []
    @Published private(set) var eventCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var scanIssue: String?
    @Published private(set) var lastLoadedAt: Date?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 进入页面：拉会话列表（默认选最近一个）+ 首次 replay。
    func onAppear() async {
        await reloadSessions()
        await loadEvents()
    }

    /// 重拉会话列表；当前选择已失效（被删）则落回最近一个。
    func reloadSessions() async {
        sessions = await environment.loadSessions()
        if let selected = selectedSessionID,
           sessions.contains(where: { $0.id == selected }) {
            return
        }
        selectedSessionID = sessions.first?.id
    }

    /// 手动刷新：全量 replay + 行投影（扫描/投影放后台，主线程只收结果）。
    func loadEvents() async {
        guard let id = selectedSessionID else {
            rows = []
            eventCount = 0
            errorMessage = sessions.isEmpty ? "暂无会话" : nil
            scanIssue = nil
            lastLoadedAt = Date()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) {
            EventStreamLoader.loadAndProject(sessionID: id)
        }.value
        switch result {
        case .success(let output):
            rows = output.rows
            eventCount = output.rows.count
            scanIssue = output.issue
            errorMessage = nil
        case .failure(let error):
            rows = []
            eventCount = 0
            scanIssue = nil
            errorMessage = "读取失败：\(error)"
        }
        lastLoadedAt = Date()
    }
}

// MARK: - 视图

/// 「当前会话事件流」只读诊断视图（dsh ui-trajectory 时间线最小移植）。
struct EventStreamView: View {
    @StateObject private var model: EventStreamViewModel

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: EventStreamViewModel(environment: environment))
    }

    var body: some View {
        List {
            Section("会话") {
                Picker("查看会话", selection: sessionBinding) {
                    if model.sessions.isEmpty {
                        Text("暂无会话").tag("")
                    }
                    ForEach(model.sessions) { summary in
                        Text("\(summary.title ?? "新会话") · \(summary.eventCount) 事件")
                            .tag(summary.id)
                    }
                }
                HStack {
                    Text("共 \(model.eventCount) 条事件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let loadedAt = model.lastLoadedAt {
                        Text("刷新于 \(loadedAt.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let issue = model.scanIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("事件流（时间线）") {
                if model.rows.isEmpty && !model.isLoading && model.errorMessage == nil {
                    Text("该会话暂无事件")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    EventStreamRowView(row: row)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("事件流")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await model.loadEvents() }
                } label: {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading || model.selectedSessionID == nil)
                .accessibilityLabel("刷新事件流")
            }
        }
        .refreshable {
            await model.loadEvents()
        }
        .task { await model.onAppear() }
        .onChange(of: model.selectedSessionID) { _ in
            Task { await model.loadEvents() }
        }
        // 只读诊断页不持写柄：本视图不触碰 SessionStore.openWriter，也不写任何事件/文件。
    }

    /// 空会话列表时以 "" 兜底（Picker 需要 stable tag）。
    private var sessionBinding: Binding<String> {
        Binding(get: { model.selectedSessionID ?? "" },
                set: { newValue in
                    model.selectedSessionID = newValue.isEmpty ? nil : newValue
                })
    }
}

/// 单行：seq · 分类图标 · wire 名（着色）· 单行摘要截断 · 时间。
private struct EventStreamRowView: View {
    let row: EventStreamRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(row.seq))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Image(systemName: row.iconName)
                .foregroundStyle(row.isAlert ? Color.red : row.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.wireType)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(row.isAlert ? Color.red : row.tint)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.footnote)
                    .foregroundStyle(row.isAlert ? Color.red : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(row.timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
