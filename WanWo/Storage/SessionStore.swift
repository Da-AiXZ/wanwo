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
//

import Foundation

/// 会话仓库：JSONL 事实源 + GRDB 索引投影的统一门面。
actor SessionStore {
    private let root: URL
    private let database: SessionDatabase
    /// 每 session id 单一活跃写者（dsh JsonlBackendTracker.writers 语义）。
    private var writers: [String: SessionWriter] = [:]

    private static let logger = AppLogger(category: "session-store")

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

    func listSessions() -> [SessionSummary] {
        database.list()
    }

    /// 创建新会话：立即物化头-only 日志（dsh flush 空会话语义）并登记索引。
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
        database.upsert(summary)
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
    }

    // MARK: - 打开 / 关闭写柄（dsh resume 语义）

    /// resume：open 排他写所有权 → replay → interruptedTurnClosers 修复。
    /// 返回写柄与本次修复的收尾事件数（UI 呈现「已恢复：N 个中断回合」）。
    func openWriter(id: String) async throws -> (writer: SessionWriter, repairedClosers: Int) {
        if writers[id] != nil {
            throw StoreError.sessionAlreadyOwned(id)
        }
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

    func closeWriter(id: String) {
        if let writer = writers.removeValue(forKey: id) {
            writer.close()
        }
    }

    // MARK: - 索引对账（10-design §十一 M1.2：投影与 JSONL 一致性）

    /// 启动时以 JSONL 事实源全量重建 GRDB 投影（M1 体量可全扫；FTS/增量优化后置 M9）。
    func reconcileIndex() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        var summaries: [SessionSummary] = []
        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file) else { continue }
            guard let scan = try? SessionLogScanner.scan(data: data) else {
                Self.logger.warning("reconcile: skip unreadable log \(file.lastPathComponent)")
                continue
            }
            let created = Date(timeIntervalSince1970:
                TimeInterval(scan.header.createdAtMs) / 1000.0)
            var updated = created
            if let last = scan.events.last {
                updated = Date(timeIntervalSince1970: TimeInterval(last.timeMs) / 1000.0)
            }
            var title: String?
            for event in scan.events.reversed() {
                if case .sessionTitle(let t, _) = event.payload {
                    title = t
                    break
                }
            }
            summaries.append(SessionSummary(id: scan.header.id, title: title,
                                            createdAt: created, updatedAt: updated,
                                            eventCount: scan.events.count))
        }
        database.replaceAll(with: summaries)
    }
}
