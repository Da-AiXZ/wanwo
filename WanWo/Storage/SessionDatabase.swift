//
//  SessionDatabase.swift
//  WanWo
//
//  【按设计新写 · GRDB 投影】出处：10-design §2.3 / §5.1 / §十一 M1.2（会话索引表 +
//  迁移框架；投影与 JSONL 一致性）、§十二（GRDB.swift ^7.0，MIT）。
//  GRDB 仅在本文件 import（UI 不触达，§十三.1）；提供值类型 API。
//
//  M1.2 v2（启动空窗根治）：sessionIndex 为**持续维护的持久表**——写路径同步
//  upsert（含文件基线 fileMtime/fileSize），启动直查零对账（对齐 OpenMinis
//  ChatStore 持久索引设计）；文件基线供后台增量校验（SessionStore.verifyIncremental）
//  识别「已同步 / 需重扫」。
//

import Foundation
import GRDB

/// 索引行（摘要 + 文件基线）：增量校验与兜底快速重建共用。
struct SessionIndexRow: Equatable, Sendable {
    var summary: SessionSummary
    /// JSONL 文件 mtime（timeIntervalSince1970 Double 原样存 REAL，保证逐位
    /// 可比）；nil = 基线未知（视为需校验）。
    var fileMtimeSeconds: Double?
    /// JSONL 文件字节数基线；nil = 基线未知。
    var fileSize: Int?
}

/// SQLite 会话索引投影（事实源 = JSONL；写路径同步维护，兜底可由
/// SessionStore.reconcileIndex 快速重建）。
final class SessionDatabase {
    private let dbQueue: DatabaseQueue
    private static let logger = AppLogger(category: "database")

    /// 列表失效钩子：任何成功的索引写变（upsert/touch/setTitle/remove/replaceAll）
    /// 在**写入线程上同步**触发（SessionStore 借此置脏列表缓存——跨线程同步信号，
    /// 见 SessionStore.pendingListInvalidation）。仅在装配期赋值一次，运行期只读。
    var onIndexChanged: (@Sendable () -> Void)?

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("wanwo.sessionIndex.v1") { db in
            try db.create(table: "sessionIndex") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("eventCount", .integer).notNull().defaults(to: 0)
            }
        }
        // v2（启动空窗根治）：文件属性基线两列——增量校验以 mtime/size 判定
        // 「该文件自上次索引以来是否变化」，变化文件才重扫。
        migrator.registerMigration("wanwo.sessionIndex.v2") { db in
            try db.alter(table: "sessionIndex") { t in
                t.add(column: "fileMtime", .double)
                t.add(column: "fileSize", .integer)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - 写

    /// upsert 一行摘要（可附文件基线；nil 时保留既有基线）。成功后触发列表失效钩子。
    func upsert(_ summary: SessionSummary,
                fileMtimeSeconds: Double? = nil,
                fileSize: Int? = nil) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessionIndex (id, title, createdAt, updatedAt, eventCount, fileMtime, fileSize)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        createdAt = excluded.createdAt,
                        updatedAt = excluded.updatedAt,
                        eventCount = excluded.eventCount,
                        fileMtime = COALESCE(excluded.fileMtime, sessionIndex.fileMtime),
                        fileSize = COALESCE(excluded.fileSize, sessionIndex.fileSize)
                    """,
                    arguments: [summary.id, summary.title, summary.createdAt,
                                summary.updatedAt, summary.eventCount,
                                fileMtimeSeconds, fileSize])
            }
            onIndexChanged?()
        } catch {
            Self.logger.error("sessionIndex upsert failed: \(String(describing: error))")
        }
    }

    /// 推进 updatedAt/eventCount（可附文件基线；nil 时保留既有基线）。
    /// 成功后触发列表失效钩子。
    func touch(id: String, updatedAt: Date, eventCount: Int,
               fileMtimeSeconds: Double? = nil, fileSize: Int? = nil) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE sessionIndex SET updatedAt = ?, eventCount = ?,
                        fileMtime = COALESCE(?, fileMtime), fileSize = COALESCE(?, fileSize)
                    WHERE id = ?
                    """,
                    arguments: [updatedAt, eventCount, fileMtimeSeconds, fileSize, id])
            }
            onIndexChanged?()
        } catch {
            Self.logger.error("sessionIndex touch failed: \(String(describing: error))")
        }
    }

    /// 标题落盘（不改文件，不动基线）。成功后触发列表失效钩子。
    func setTitle(id: String, title: String) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE sessionIndex SET title = ? WHERE id = ?",
                               arguments: [title, id])
            }
            onIndexChanged?()
        } catch {
            Self.logger.error("sessionIndex setTitle failed: \(String(describing: error))")
        }
    }

    func remove(id: String) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sessionIndex WHERE id = ?", arguments: [id])
            }
            onIndexChanged?()
        } catch {
            Self.logger.error("sessionIndex remove failed: \(String(describing: error))")
        }
    }

    /// 兜底快速重建（只应由 SessionStore.reconcileIndex 的探针路径调用）：
    /// 事务内整表替换并写入文件基线。成功后触发列表失效钩子。
    func replaceAll(with rows: [SessionIndexRow]) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sessionIndex")
                for row in rows {
                    try db.execute(
                        sql: """
                        INSERT INTO sessionIndex (id, title, createdAt, updatedAt, eventCount, fileMtime, fileSize)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [row.summary.id, row.summary.title,
                                    row.summary.createdAt, row.summary.updatedAt,
                                    row.summary.eventCount,
                                    row.fileMtimeSeconds, row.fileSize])
                }
            }
            onIndexChanged?()
        } catch {
            Self.logger.error("sessionIndex replaceAll failed: \(String(describing: error))")
        }
    }

    // MARK: - 读

    /// 全表读出（含文件基线）——增量校验的基线来源。
    func listWithBaselines() -> [SessionIndexRow] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM sessionIndex ORDER BY updatedAt DESC")
                return rows.map { row -> SessionIndexRow in
                    SessionIndexRow(
                        summary: SessionSummary(
                            id: row["id"] ?? "",
                            title: row["title"],
                            createdAt: row["createdAt"] ?? Date(timeIntervalSince1970: 0),
                            updatedAt: row["updatedAt"] ?? Date(timeIntervalSince1970: 0),
                            eventCount: row["eventCount"] ?? 0),
                        fileMtimeSeconds: row["fileMtime"],
                        fileSize: row["fileSize"])
                }
            }
        } catch {
            Self.logger.error("sessionIndex list failed: \(String(describing: error))")
            return []
        }
    }

    /// 列表 UI 数据源（仅摘要列，按 updatedAt 倒序）。
    func list() -> [SessionSummary] {
        listWithBaselines().map(\.summary)
    }
}
