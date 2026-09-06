//
//  SessionDatabase.swift
//  WanWo
//
//  【按设计新写 · GRDB 投影】出处：10-design §2.3 / §5.1 / §十一 M1.2（会话索引表 +
//  迁移框架；投影与 JSONL 一致性）、§十二（GRDB.swift ^7.0，MIT）。
//  GRDB 仅在本文件 import（UI 不触达，§十三.1）；提供值类型 API。
//

import Foundation
import GRDB

/// SQLite 会话索引投影（事实源 = JSONL；本库可随时由 reconcileIndex 全量重建）。
final class SessionDatabase {
    private let dbQueue: DatabaseQueue
    private static let logger = AppLogger(category: "database")

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
        try migrator.migrate(dbQueue)
    }

    // MARK: - 写

    func upsert(_ summary: SessionSummary) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO sessionIndex (id, title, createdAt, updatedAt, eventCount)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        createdAt = excluded.createdAt,
                        updatedAt = excluded.updatedAt,
                        eventCount = excluded.eventCount
                    """,
                    arguments: [summary.id, summary.title, summary.createdAt,
                                summary.updatedAt, summary.eventCount])
            }
        } catch {
            Self.logger.error("sessionIndex upsert failed: \(String(describing: error))")
        }
    }

    func touch(id: String, updatedAt: Date, eventCount: Int) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sessionIndex SET updatedAt = ?, eventCount = ? WHERE id = ?",
                    arguments: [updatedAt, eventCount, id])
            }
        } catch {
            Self.logger.error("sessionIndex touch failed: \(String(describing: error))")
        }
    }

    func setTitle(id: String, title: String) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE sessionIndex SET title = ? WHERE id = ?",
                               arguments: [title, id])
            }
        } catch {
            Self.logger.error("sessionIndex setTitle failed: \(String(describing: error))")
        }
    }

    func remove(id: String) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sessionIndex WHERE id = ?", arguments: [id])
            }
        } catch {
            Self.logger.error("sessionIndex remove failed: \(String(describing: error))")
        }
    }

    /// 全量对账（启动时以 JSONL 事实源重建投影；删多余行 + 覆盖写）。
    func replaceAll(with summaries: [SessionSummary]) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sessionIndex")
                for summary in summaries {
                    try db.execute(
                        sql: """
                        INSERT INTO sessionIndex (id, title, createdAt, updatedAt, eventCount)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [summary.id, summary.title, summary.createdAt,
                                    summary.updatedAt, summary.eventCount])
                }
            }
        } catch {
            Self.logger.error("sessionIndex replaceAll failed: \(String(describing: error))")
        }
    }

    // MARK: - 读

    func list() -> [SessionSummary] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM sessionIndex ORDER BY updatedAt DESC")
                return rows.map { row -> SessionSummary in
                    SessionSummary(
                        id: row["id"] ?? "",
                        title: row["title"],
                        createdAt: row["createdAt"] ?? Date(timeIntervalSince1970: 0),
                        updatedAt: row["updatedAt"] ?? Date(timeIntervalSince1970: 0),
                        eventCount: row["eventCount"] ?? 0)
                }
            }
        } catch {
            Self.logger.error("sessionIndex list failed: \(String(describing: error))")
            return []
        }
    }
}
