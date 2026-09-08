//
//  SessionStore.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - dsh packages/core/session/src/preparation.ts / index.ts（SessionStore：create/
//      resume 排他写所有权、setup 事务、回滚发布——M1 最小面）
//    - dsh packages/session/session-persistence-jsonl/src/storage.ts（JsonlBackendTracker：
//      每 session id 单一活跃写者）
//    - 10-design §5.2（SessionLifecycle：create / resume = open 排他 → replay →
//      interruptedTurnClosers 修复）
//  M1.2 v2（启动空窗根治，对齐 OpenMinis ChatStore 持久索引设计）：
//    - 启动不再全量对账：索引是写路径同步维护的持久表，listSessions 直查即秒出；
//    - verifyIncremental：后台增量校验（mtime/size 基线比对，只重扫变化文件）；
//    - reconcileIndex：保留 API，改用途为兜底快速重建（索引空而 JSONL 存在时，
//      每文件只读 header + 尾部事件，禁止全文件读入 + 全事件解析）；
//    - sessionListCache + sessionListCacheDirty：无列表相关变更时 listSessions
//      原样返回缓存数组（零分配——OpenMinis [T-ios-listsessions-cache] 模式，
//      该模式实证修复过「重复 listSessions 数百 MB 内存增长」，防回归）。
//

import Foundation

/// 会话仓库：JSONL 事实源 + GRDB 索引投影的统一门面。
actor SessionStore {
    private let root: URL
    private let database: SessionDatabase
    /// 每 session id 单一活跃写者（dsh JsonlBackendTracker.writers 语义）。
    private var writers: [String: SessionWriter] = [:]

    /// 列表缓存（OpenMinis [T-ios-listsessions-cache] 模式）。
    private var sessionListCache: [SessionSummary]?
    /// 缓存脏标志：任何列表相关变更（create/delete/索引写/reconcile）置 true。
    private var sessionListCacheDirty = true
    /// 跨线程失效旗标：SessionDatabase 写路径（writer 追加 / 标题落盘等）在
    /// **任意线程**同步触发 onIndexChanged，而本 actor 的脏标志无法被外部线程
    /// 同步置位——钩子先原子记录到此旗标，listSessions 入口先排空再判定缓存。
    private let pendingListInvalidation = PendingListInvalidation()

    private static let logger = AppLogger(category: "session-store")

    /// 原子失效旗标（锁保护；@unchecked Sendable——仅承载一个 Bool）。
    private final class PendingListInvalidation: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        func mark() {
            lock.lock()
            pending = true
            lock.unlock()
        }

        /// 取走并清零；返回取走前是否有未排空的失效。
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let value = pending
            pending = false
            return value
        }
    }

    enum StoreError: Error, Equatable {
        case sessionAlreadyOwned(String)
        case sessionNotFound(String)
        case sessionOpenCannotDelete(String)
        case invalidSessionID(String)
    }

    init(root: URL, database: SessionDatabase) {
        self.root = root
        self.database = database
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 列表失效钩子：数据库写路径在写入线程上同步置旗标（见
        // pendingListInvalidation 注释；装配期赋值一次，运行期只读）。
        let invalidation = self.pendingListInvalidation
        database.onIndexChanged = { invalidation.mark() }
    }

    private func fileURL(for id: String) throws -> URL {
        // dsh encodeSegment 语义：id 先做路径安全编码再用（fail closed 拒绝越界）。
        guard !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw StoreError.invalidSessionID(id)
        }
        return root.appendingPathComponent("\(id).jsonl")
    }

    // MARK: - 列表 / 创建 / 删除

    /// 会话列表（持久索引直查 + 缓存）：无列表相关变更时原样返回缓存数组
    /// （零分配——OpenMinis [T-ios-listsessions-cache] 防回归口径）。
    func listSessions() -> [SessionSummary] {
        // 先排空跨线程失效旗标（writer 追加/标题落盘等路径的同步信号）。
        if pendingListInvalidation.take() {
            sessionListCache = nil
            sessionListCacheDirty = true
        }
        if !sessionListCacheDirty, let cached = sessionListCache {
            return cached
        }
        let sessions = database.list()
        sessionListCache = sessions
        sessionListCacheDirty = false
        return sessions
    }

    /// 创建新会话：立即物化头-only 日志（dsh flush 空会话语义）并登记索引
    /// （含文件基线，保证下次启动增量校验识别「已同步」）。
    func createSession(cwd: String?) throws -> SessionSummary {
        let id = UUID().uuidString
        let header = SessionHeader(id: id,
                                   createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                   cwd: cwd)
        let url = try fileURL(for: id)
        _ = try JsonlEventLog.create(header: header, at: url)
        let now = Date()
        let summary = SessionSummary(id: id, title: nil,
                                     createdAt: now, updatedAt: now, eventCount: 0)
        let baseline = Self.fileBaseline(atPath: url.path)
        database.upsert(summary, fileMtimeSeconds: baseline?.mtimeSeconds,
                        fileSize: baseline?.size)
        sessionListCache = nil
        sessionListCacheDirty = true
        return summary
    }

    /// 删除会话（拒绝在写柄开放时删除；事件溯源永不部分删除）。
    func deleteSession(id: String) throws {
        if writers[id] != nil {
            throw StoreError.sessionOpenCannotDelete(id)
        }
        let url = try fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        database.remove(id: id)
        sessionListCache = nil
        sessionListCacheDirty = true
    }

    // MARK: - 打开 / 关闭写柄（dsh resume 语义）

    /// resume：open 排他写所有权 → replay → interruptedTurnClosers 修复。
    /// 返回写柄与本次修复的收尾事件数（UI 呈现「已恢复：N 个中断回合」）。
    /// 单写者语义（dsh SessionLifecycle open/dispose）：若同 id 写柄仍开放（上次会话
    /// 切走未显式释放），先走 closeWriter 修复收尾并释放，再正常打开——绝不以
    /// alreadyOwned 拒绝重开（重开会话 = 释放上一个写柄 + 全量 replay）。
    func openWriter(id: String) async throws -> (writer: SessionWriter, repairedClosers: Int) {
        await closeWriter(id: id)
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.sessionNotFound(id)
        }
        let log = try JsonlEventLog.open(fileURL: url, writeMode: true, expectedID: id)
        let writer = try await SessionWriter(id: id, header: log.header,
                                             log: log, database: database)
        // interruptedTurnClosers 修复（dsh agent-loop resume 语义）。
        let closers = InterruptedTurnClosers.closers(for: writer.events)
        for closer in closers {
            try await writer.appendSynthetic(closer)
        }
        writers[id] = writer
        return (writer, closers.count)
    }

    /// 关闭写柄（dsh dispose 语义）：释放前对该 writer 走 interruptedTurnClosers 修复
    /// ——被中断的开放 turn/step 以合成收尾事件落盘（平衡日志返回空序列，无副作用），
    /// 保证「切走会话」不留悬空回合；随后释放 JSONL 写柄。
    func closeWriter(id: String) async {
        guard let writer = writers.removeValue(forKey: id) else { return }
        await release(writer)
    }

    /// 按 writer 实例身份关闭（会话视图释放自身写柄用）：仅当该 writer 仍是当前
    /// 登记的活跃写柄时才释放——过期视图（会话已被快速切走又切回、写柄已被
    /// openWriter 换新）的迟到 close 是 no-op，绝不误关新写柄。
    func closeWriter(_ writer: SessionWriter) async {
        guard let current = writers[writer.id], current === writer else { return }
        writers.removeValue(forKey: writer.id)
        await release(writer)
    }

    /// 释放前置收尾（openWriter 自动 close 与显式 closeWriter 共用）：
    /// interruptedTurnClosers 修复 → 关闭底层日志。
    private func release(_ writer: SessionWriter) async {
        let closers = InterruptedTurnClosers.closers(for: writer.events)
        for closer in closers {
            try? await writer.appendSynthetic(closer)
        }
        writer.close()
    }

    // MARK: - 后台增量校验（启动空窗根治第 2 层：替换原启动全量对账的保险职能）

    /// 文件属性快照（基线读/写共用）。
    private struct FileBaseline {
        var mtimeSeconds: Double
        var size: Int
    }

    /// 读单文件属性基线（失败返回 nil——按基线未知处理）。
    private static func fileBaseline(atPath path: String) -> FileBaseline? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        guard let mtime = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return FileBaseline(mtimeSeconds: mtime.timeIntervalSince1970, size: size)
    }

    /// 启动后台增量校验（App 启动 Task 调用；不阻塞首帧，完成后由调用方 bump
    /// sessionsRevision）：
    ///   1. 枚举 sessions 目录，逐文件取 mtime/size 与索引基线比对；
    ///   2. 零变化 → 静默完成（不做任何 I/O 扫描、不动索引）；
    ///   3. 变化 / 新增文件 → 只对该文件走轻量探针（header + 尾部事件，
    ///      SessionLogScanner.probeLightweight）更新索引行 + 刷新基线；
    ///   4. 索引空而 JSONL 存在（新装 / 删重装）→ 全部文件按 3 处理 = 兜底快速重建；
    ///   5. 磁盘已删但索引仍在 → 移除索引行。
    /// 损坏的 JSONL（torn tail）不在此处置——沿用既有 interruptedTurnClosers
    /// 修复链（openWriter 全量扫描 + 截断残尾）衔接。
    func verifyIncremental() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: []) else { return }

        let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }
        var rowsByFileStem: [String: SessionIndexRow] = [:]
        for row in database.listWithBaselines() {
            rowsByFileStem[row.summary.id] = row
        }

        var didChange = false
        for file in jsonlFiles {
            let stem = file.deletingPathExtension().lastPathComponent
            let mtimeSeconds = (try? file.resourceValues(forKeys: keySet))?
                .contentModificationDate?.timeIntervalSince1970
            let size = (try? file.resourceValues(forKeys: keySet))?.fileSize

            // 基线一致 → 已同步，跳过（增量校验的核心快路径）。
            if let row = rowsByFileStem[stem],
               let baselineMtime = row.fileMtimeSeconds, let mtimeSeconds,
               baselineMtime == mtimeSeconds,
               let baselineSize = row.fileSize, let size,
               baselineSize == size {
                continue
            }

            // 变化 / 新增 / 基线未知 → 轻量探针（header + 尾部事件；禁全量解析）。
            guard let probe = try? SessionLogScanner.probeLightweight(fileURL: file) else {
                Self.logger.warning("verifyIncremental: skip unreadable log "
                    + "\(file.lastPathComponent)")
                continue
            }
            // 头行 id 与文件名不一致 → 外来文件，拒绝登记（fail closed）。
            guard probe.header.id == stem else {
                Self.logger.warning("verifyIncremental: header id \(probe.header.id) "
                    + "mismatch file stem \(stem), skipped")
                continue
            }
            let created = Date(timeIntervalSince1970:
                TimeInterval(probe.header.createdAtMs) / 1000.0)
            // 尾部窗口没有 title（长会话标题在日志前部）→ 保留索引既有标题。
            let existingTitle = rowsByFileStem[stem]?.summary.title
            let updated = probe.lastTimeMs.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
            } ?? created
            let summary = SessionSummary(id: probe.header.id, title: probe.title ?? existingTitle,
                                         createdAt: created, updatedAt: updated,
                                         eventCount: probe.eventCount)
            database.upsert(summary, fileMtimeSeconds: mtimeSeconds, fileSize: size)
            didChange = true
        }

        // 磁盘已删但索引仍在 → 移除索引行（外部删除兜底）。
        let fileStems = Set(jsonlFiles.map { $0.deletingPathExtension().lastPathComponent })
        for stem in rowsByFileStem.keys where !fileStems.contains(stem) {
            database.remove(id: stem)
            didChange = true
        }

        if didChange {
            sessionListCache = nil
            sessionListCacheDirty = true
        }
    }

    // MARK: - 索引兜底快速重建（API 保留；原「启动全量对账」改用途）

    /// 兜底快速重建：以 JSONL 事实源整表替换 GRDB 投影。**禁止全文件读入内存 +
    /// 全事件解析**——每文件只走 SessionLogScanner.probeLightweight（首行 header +
    /// 256KB 分块行计数 + 64KB 尾部窗口解码）。调用时机：索引空而 JSONL 存在
    /// （verifyIncremental 的新增路径已覆盖）、或显式诊断触发。
    func reconcileIndex() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        var rows: [SessionIndexRow] = []
        for file in files where file.pathExtension == "jsonl" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let probe = try? SessionLogScanner.probeLightweight(fileURL: file) else {
                Self.logger.warning("reconcile: skip unreadable log \(file.lastPathComponent)")
                continue
            }
            guard probe.header.id == stem else {
                Self.logger.warning("reconcile: header id \(probe.header.id) mismatch "
                    + "file stem \(stem), skipped")
                continue
            }
            let created = Date(timeIntervalSince1970:
                TimeInterval(probe.header.createdAtMs) / 1000.0)
            let updated = probe.lastTimeMs.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
            } ?? created
            let baseline = Self.fileBaseline(atPath: file.path)
            rows.append(SessionIndexRow(
                summary: SessionSummary(id: probe.header.id, title: probe.title,
                                        createdAt: created, updatedAt: updated,
                                        eventCount: probe.eventCount),
                fileMtimeSeconds: baseline?.mtimeSeconds,
                fileSize: baseline?.size))
        }
        database.replaceAll(with: rows)
        sessionListCache = nil
        sessionListCacheDirty = true
    }
}
