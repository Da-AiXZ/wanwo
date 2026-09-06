//
//  SessionWriter.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - dsh packages/core/session/src/preparation.ts + index.ts（Session.append 校验管线；
//      per-session 串行追加——dsh 由 Session 对象内建，WanWo 以内部 gate actor 等价实现，
//      使「对话回合」与「标题生成」两个并发任务的事件追加严格串行）
//    - dsh packages/core/agent-loop（deriveMessages 消费语义）
//    - dsh packages/core/session/src/repair.ts（resume 时 closers 追加）
//    - 10-design §5.2（SessionLifecycle resume：open 排他写 → replay → 修复）
//  会话写柄：排他写所有权 + 事件追加（含不变量校验）+ 派生历史 + 请求头簿记。
//

import Foundation

/// 追加串行化门（dsh per-session append 串行语义的最小实现）。
private actor SessionWriterGate {
    func run<T>(_ work: () async throws -> T) async throws -> T {
        try await work()
    }
}

/// 一个会话的写柄。同一会话同一时刻仅存在一个实例（SessionStore 保证）。
final class SessionWriter {
    let id: String
    let header: SessionHeader
    private let log: JsonlEventLog
    private let database: SessionDatabase
    private let gate = SessionWriterGate()
    private let stateLock = NSLock()
    private var eventsStorage: [SessionEvent]
    private var invariant = SessionInvariant()
    private var lastRunLoggedHeader: EpochHeader?
    private static let logger = AppLogger(category: "session")

    init(id: String, header: SessionHeader, log: JsonlEventLog, database: SessionDatabase) async throws {
        self.id = id
        self.header = header
        self.log = log
        self.database = database
        self.eventsStorage = await log.snapshotEvents()
        // replay 全量过一遍不变量（fail closed：非法历史拒绝写）。
        for event in eventsStorage {
            try invariant.validate(event)
        }
    }

    // MARK: - 读（锁保护的快照语义）

    /// 事件快照（dsh read()：读取不返回短于先前观察值的日志）。
    var events: [SessionEvent] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventsStorage
    }

    var eventCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventsStorage.count
    }

    /// 当前开放的 turn/step（取消收尾用，dsh openTurn/openStep 游标）。
    var openTurn: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invariant.openTurn
    }

    var openStep: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invariant.openStep
    }

    /// 下一个回合序号（dsh turnBoundary 投影 lastTurn + 1）。
    var nextTurn: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invariant.nextTurn
    }

    /// 打开时是否发生过断电截断恢复（供 UI 呈现）。
    var didTruncateTornTail: Bool {
        get async { await log.didTruncateTornTail }
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: - 追加（gate 串行；dsh Session.append 校验管线）

    /// 校验并 durable 追加一条事件。返回即已 fsync（model-visible=logged 的实现根基）。
    @discardableResult
    func append(_ payload: SessionEvent.Payload, ignorable: Bool = false) async throws -> SessionEvent {
        try await gate.run { [self] in
            let event = try withState {
                let event = SessionEvent(seq: eventsStorage.count,
                                         timeMs: Int64(Date().timeIntervalSince1970 * 1000),
                                         payload: payload,
                                         ignorable: ignorable)
                try invariant.validate(event)
                return event
            }
            try await log.append(event)
            withState { eventsStorage.append(event) }
            // GRDB 投影同步（一致性：索引与事实源同步推进；失败仅记日志，不中断对话）。
            database.touch(id: id, updatedAt: Date(), eventCount: event.seq + 1)
            return event
        }
    }

    /// resume 修复：追加合成收尾事件（seq/时间已在事件内确定）。
    func appendSynthetic(_ event: SessionEvent) async throws {
        try await gate.run { [self] in
            try withState {
                try invariant.validate(event)
            }
            try await log.append(event)
            withState { eventsStorage.append(event) }
            database.touch(id: id, updatedAt: Date(), eventCount: event.seq + 1)
        }
    }

    // MARK: - 请求头簿记（dsh buildRequest 的 header 日志语义）

    /// 最新已记录请求头（dsh session.requestHeader()）。
    var recordedRequestHeader: EpochHeader? {
        for event in events.reversed() {
            if case .requestHeader(let header, _) = event.payload {
                return header
            }
        }
        return nil
    }

    /// 计算本次请求头的追加理由（dsh RequestHeaderReason：initial/resume/change/series），
    /// 若需要则落盘 request/header 事件并返回 reason；不需要则返回 nil。
    func logRequestHeaderIfNeeded(_ header: EpochHeader) async throws -> String? {
        try await gate.run { [self] in
            let baseline = withState {
                eventsStorage.reversed().compactMap { event -> EpochHeader? in
                    if case .requestHeader(let header, _) = event.payload { return header }
                    return nil
                }.first
            }
            if baseline == nil {
                // 本日志此前从未有过 header → initial；已有 header（resume 场景）→ resume。
                let hadHeader = withState {
                    eventsStorage.contains { $0.wireType == "request/header" }
                }
                let reason = hadHeader ? "resume" : "initial"
                _ = try await append(.requestHeader(header: header, reason: reason))
                withState { lastRunLoggedHeader = header }
                return reason
            }
            if baseline != header {
                _ = try await append(.requestHeader(header: header, reason: "change"))
                withState { lastRunLoggedHeader = header }
                return "change"
            }
            if withState({ lastRunLoggedHeader }) != header {
                withState { lastRunLoggedHeader = header }
                return "resume"
            }
            return nil
        }
    }

    // MARK: - 派生历史（dsh deriveMessages 语义子集）

    /// 从事件流派生模型可见消息：最新 request/header 提供 system + config；
    /// user/message → user；assistant/message → assistant（仅文本块上 wire）。
    /// 不变量：返回内容全部来自已落盘事件（model-visible = logged）。
    func deriveMessages() -> (config: LlmCallConfig?, system: String?, messages: [ChatMessage]) {
        let snapshot = events
        var config: LlmCallConfig?
        var system: String?
        for event in snapshot.reversed() {
            if case .requestHeader(let header, _) = event.payload {
                config = header.config
                system = header.system
                break
            }
        }
        var messages: [ChatMessage] = []
        for event in snapshot {
            switch event.payload {
            case .userMessage(let text):
                messages.append(ChatMessage(role: .user, content: text))
            case .assistantMessage(_, _, let message, _, _):
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined()
                messages.append(ChatMessage(role: .assistant, content: text))
            default:
                break
            }
        }
        return (config, system, messages)
    }

    /// 第一条 user/message 文本（标题 fallback 与标题生成输入）。
    var firstUserMessage: String? {
        for event in events {
            if case .userMessage(let text) = event.payload {
                return text
            }
        }
        return nil
    }

    // MARK: - 关闭

    func close() {
        Task { await log.close() }
    }
}
