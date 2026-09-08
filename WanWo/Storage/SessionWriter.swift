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

/// 追加串行化门（dsh per-session append 串行语义）。
///
/// ERR-021 并发缺陷本体：原实现为 actor 直接转发（`run` 内 `try await work()`），
/// actor 在 work 挂起点（`log.append` 跨 actor await）会重入——两笔并发 append
/// 都能进入 pipeline，且内存快照推进（eventsStorage.append）发生在 log.append
/// 返回之后，于是两笔读到同一 eventsStorage.count、分配到同一 seq，后到的一笔
/// 被 JsonlEventLog 连续性守卫拒绝 → 调用方 `try?` 静默吞掉 → tool/result 丢失。
/// 改用 NSLock + CheckedContinuation 的异步互斥锁：挂起期间持续持锁，把整段
/// pipeline（seq 分配 → log 落盘 → 内存快照推进）原子化，等价 dsh 的
/// per-handle promise chain（链上严格串行，无重入缝）。
private final class SessionWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ work: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        lock.lock()
        if !locked {
            locked = true
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    private func release() {
        lock.lock()
        // 所有权转移给队首等待者（不清 locked）；无人等待才真正释放。
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            locked = false
            lock.unlock()
        }
    }
}

/// 一个会话的写柄。同一会话同一时刻仅存在一个实例（SessionStore 保证）。
/// @unchecked Sendable：内部状态经 stateLock + gate actor 双层串行化（M2 Dependencies 约束）。
final class SessionWriter: @unchecked Sendable {
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

    /// 当前日志文件的属性基线（mtime 秒 / 字节数）——投影 touch 时同步刷新，
    /// 保证下次启动的增量校验（SessionStore.verifyIncremental）能按基线判定
    /// 「该文件已同步」，避免每个启动周期重复重扫活跃会话。
    private var fileBaseline: (mtimeSeconds: Double?, size: Int?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.fileURL.path) else {
            return (nil, nil)
        }
        let mtimeSeconds = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.intValue
        return (mtimeSeconds, size)
    }

    // MARK: - 追加（gate 串行；dsh Session.append 校验管线）

    /// 校验并 durable 追加一条事件。返回即已 fsync（model-visible=logged 的实现根基）。
    ///
    /// ERR-021 防御①：pre-write 失败（`.appendRetryable`——seq 连续性 / 只读拒绝，
    /// 行必然未写入）自动重试一次；重试前回滚已提交的不变量状态（validate 与
    /// 落盘非原子，失败时校验器可能已推进游标）。I/O 失败（`.corrupt`）不重试
    /// ——行可能已部分/完整落盘，盲目重写会产生重复行损坏 JSONL。
    @discardableResult
    func append(_ payload: SessionEvent.Payload, ignorable: Bool = false) async throws -> SessionEvent {
        try await gate.run { [self] in
            try await appendWithRetry(payload, ignorable: ignorable)
        }
    }

    /// 带重试的追加管线（仅在 gate 内调用；`append` 与
    /// `logRequestHeaderIfNeeded` 共用——后者已在 gate 内，不得再入 gate）。
    private func appendWithRetry(_ payload: SessionEvent.Payload,
                                 ignorable: Bool) async throws -> SessionEvent {
        var attempt = 0
        while true {
            do {
                return try await appendOnce(payload, ignorable: ignorable)
            } catch let error as SessionLogError {
                guard case .appendRetryable(let reason) = error else { throw error }
                attempt += 1
                guard attempt <= 1 else { throw error }
                Self.logger.warning("session \(self.id): append pre-write failure, "
                    + "retrying once: \(reason)")
            }
        }
    }

    /// 单次追加尝试（seq 分配 → 不变量校验 → log 落盘 → 内存快照推进）。
    /// 仅在 gate 内调用（串行语义的组成段）。
    private func appendOnce(_ payload: SessionEvent.Payload, ignorable: Bool) async throws -> SessionEvent {
        // 值语义快照：validate 通过即推进校验器状态，log 落盘失败时据此回滚。
        var preValidateState: SessionInvariant?
        let event = try withState { () -> SessionEvent in
            // E1 写侧门（编码端 fail closed）：本进程永不落 schema 违例的
            // extension 事件——解码端同规则拒绝，读写两侧闭环（v2.4 修订①）。
            if case .extensionEvent(let kind, let extPayload) = payload,
               let reason = ExtensionEventRegistry.shared.validationReason(
                   kind: kind, payload: extPayload) {
                throw ExtensionEventRegistry.SchemaViolation(kind: kind, reason: reason)
            }
            var event = SessionEvent(seq: eventsStorage.count,
                                     timeMs: Int64(Date().timeIntervalSince1970 * 1000),
                                     payload: payload,
                                     ignorable: ignorable)
            // E1：extension 事件 wire 恒带 ignorable（v2.4 修订①「旧版本读新
            // 日志不崩」的编码端承载——旧构建遇到未知类型按 ignorable 透传）。
            if case .extensionEvent = payload { event.ignorable = true }
            preValidateState = invariant
            try invariant.validate(event)
            return event
        }
        do {
            try await log.append(event)
        } catch {
            if let logError = error as? SessionLogError,
               case .appendRetryable = logError,
               let snapshot = preValidateState {
                withState { invariant = snapshot }
            }
            throw error
        }
        withState { eventsStorage.append(event) }
        // GRDB 投影同步（一致性：索引与事实源同步推进；失败仅记日志，不中断对话）。
        // 同步刷新文件基线（mtime/size）——持久索引「写路径维护」的组成段。
        let baseline = fileBaseline
        database.touch(id: id, updatedAt: Date(), eventCount: event.seq + 1,
                       fileMtimeSeconds: baseline.mtimeSeconds, fileSize: baseline.size)
        return event
    }

    /// resume 修复：追加合成收尾事件（seq/时间已在事件内确定）。
    func appendSynthetic(_ event: SessionEvent) async throws {
        try await gate.run { [self] in
            try withState {
                try invariant.validate(event)
            }
            try await log.append(event)
            withState { eventsStorage.append(event) }
            let baseline = fileBaseline
            database.touch(id: id, updatedAt: Date(), eventCount: event.seq + 1,
                           fileMtimeSeconds: baseline.mtimeSeconds, fileSize: baseline.size)
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
                _ = try await appendWithRetry(.requestHeader(header: header, reason: reason),
                                              ignorable: false)
                withState { lastRunLoggedHeader = header }
                return reason
            }
            if baseline != header {
                _ = try await appendWithRetry(.requestHeader(header: header, reason: "change"),
                                              ignorable: false)
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

    // MARK: - 派生历史（dsh deriveMessages 语义；M2 折叠升级）

    /// 从事件流派生模型可见消息：最新 request/header 提供 system + config；
    /// 折叠规则（DeriveFold）：user/message → user；assistant/message → assistant
    /// （含 tool_calls）；tool/result → tool（last-wins，prune 替换生效）；
    /// 压缩影子范围跳过、summary 以 `<compaction-summary>` user 消息呈现。
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
        let messages = DeriveFold(snapshot).messages
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
