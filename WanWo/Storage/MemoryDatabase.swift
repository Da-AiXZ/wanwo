//
//  MemoryDatabase.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6 逐文件对拍）：
//    - state/memory_migrations/0001_memories.sql —— 两表 DDL 1:1（stage1_outputs
//      全列照搬；jobs 按「已定适配②」去 worker_id/ownership_token/lease_until
//      三列——单 App 单进程无多实例抢锁，actor 串行化等价承载；started_at/
//      finished_at/retry_at/retry_remaining/input_watermark/last_success_watermark
//      保留——幂等水位与重试语义不变）。
//    - state/src/runtime/memories.rs —— 全部账本操作 1:1：
//        · stage1_source_needs_update（两查询语义：无行=true；有行且
//          source_updated_at 更新=true——水位幂等）
//        · mark_stage1_job_succeeded / succeeded_no_output / failed
//          （retry_at = now+3600s；retry_remaining 递减，DEFAULT_RETRY_REMAINING=3）
//        · try_claim_global_phase2_job（状态机 pending/running/error/done；
//          成功 6h 冷却 SkippedCooldown；失败重试窗 SkippedRetryUnavailable）
//        · mark_global_phase2_job_succeeded（selected_for_phase2 重写语义：
//          选中集=1 其余=0，selected_for_phase2_source_updated_at 随行）
//        · prune_stage1_outputs_for_retention（selected_for_phase2=0 且
//          COALESCE(last_usage, source_updated_at) < cutoff，批 200 最旧优先）
//        · get_phase2_input_selection（usage_count DESC → COALESCE(last_usage,
//          source_updated_at) DESC → source_updated_at DESC → thread_id DESC
//          选取；返回前按 thread_id ASC 稳定排序——raw_memories.md 机械重建序）
//        · usage 记账（memory_usage.rs：citation rollout_ids 命中 →
//          usage_count+1 / last_usage=now）
//    - ext/memories/src/lib.rs —— 常量（DEFAULT/MAX 各工具上限）。
//  万我适配裁定（登记）：
//    - 独立 DatabaseQueue（memory-index.sqlite3）而非并入 SessionDatabase：
//      ①E1 并行持有 SessionDatabase.swift 文件（派单禁碰）；②memory 账本
//      生命周期独立——设置页「一键清空」= 两表清 + memory/ 目录删，独立库
//      文件使账本重置与索引库零耦合；③codex 侧 memories 账本同样是独立于
//      threads 索引的 state 库表族，拓扑同构。
//    - 候选会话枚举不入本库（codex 有 threads 表；万我会话事实源 =
//      SessionStore 事件流，枚举由 MemoryPhase1 经注入缝完成，本库只承接
//      水位/结果账本——语义等价：codex claim_stage1_jobs_for_startup 的
//      threads 扫描 + jobs 抢占两步，万我拆为宿主枚举 + 本库水位判定）。
//    - GRDB 迁移形态照 SessionDatabase 先例（DatabaseQueue + DatabaseMigrator）。
//

import Foundation
import GRDB

// MARK: - 记录类型（state/src/model/memories.rs Stage1Output 万我行形态）

/// stage1_outputs 一行（codex Stage1Output 模型 + 账本列）。
struct MemoryStage1Record: Equatable, Sendable {
    var threadId: String
    /// 会话源更新水位（codex source_updated_at；万我 = 事件流最新事件 timeMs 秒值）。
    var sourceUpdatedAt: Int
    var rawMemory: String
    var rolloutSummary: String
    var rolloutSlug: String?
    /// 产物生成时刻（epoch 秒）。
    var generatedAt: Int
    var usageCount: Int?
    var lastUsage: Int?
    var selectedForPhase2: Bool
    var selectedForPhase2SourceUpdatedAt: Int?
}

/// Phase1 启动抢占结果（codex Stage1JobClaim 万我形态；无 ownership_token——
/// 已定适配②去租约，单进程 actor 串行化即权威）。
struct MemoryStage1Claim: Equatable, Sendable {
    var threadId: String
    var sourceUpdatedAt: Int
}

/// Phase2 全局任务抢占结果（codex Phase2JobClaimOutcome 四臂 1:1；
/// Skipped* 三臂在单进程下仍保留——重试窗/冷却/running 状态机语义不变）。
enum MemoryPhase2ClaimOutcome: Equatable, Sendable {
    case claimed(inputWatermark: Int)
    case skippedRetryUnavailable
    case skippedCooldown
    case skippedRunning
}

// MARK: - 数据库

/// memory 账本（GRDB 两表；独立 DatabaseQueue——理由见头注适配①）。
final class MemoryDatabase: @unchecked Sendable {
    /// codex DEFAULT_RETRY_REMAINING（state 运行时缺省重试余量）。
    static let defaultRetryRemaining = 3

    private let dbQueue: DatabaseQueue
    private let lock = NSLock()

    /// - Parameter path: sqlite 文件路径（AppEnvironment 装配：
    ///   persistentBase/memory-index.sqlite3；测试注入临时路径）。
    /// - Parameter interruptedRetryDelaySeconds: 崩溃回收（QA-5 P1-2）重试
    ///   窗；缺省 = MemoryConstants.jobRetryDelaySeconds（3600s），测试注入 0
    ///   断言立即可再抢。
    init(path: String,
         interruptedRetryDelaySeconds: Int = MemoryConstants.jobRetryDelaySeconds) throws {
        dbQueue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("wanwo.memory.v1") { db in
            // 0001_memories.sql 1:1（jobs 去 worker_id/ownership_token/
            // lease_until 三列——已定适配②；索引同形退役租约维度）。
            try db.create(table: "stage1_outputs") { t in
                t.column("thread_id", .text).primaryKey()
                t.column("source_updated_at", .integer).notNull()
                t.column("raw_memory", .text).notNull()
                t.column("rollout_summary", .text).notNull()
                t.column("rollout_slug", .text)
                t.column("generated_at", .integer).notNull()
                t.column("usage_count", .integer)
                t.column("last_usage", .integer)
                t.column("selected_for_phase2", .integer).notNull().defaults(to: 0)
                t.column("selected_for_phase2_source_updated_at", .integer)
            }
            try db.create(
                index: "idx_stage1_outputs_source_updated_at",
                on: "stage1_outputs",
                columns: ["source_updated_at", "thread_id"])
            try db.create(table: "jobs") { t in
                t.column("kind", .text).notNull()
                t.column("job_key", .text).notNull()
                t.column("status", .text).notNull()
                t.column("started_at", .integer)
                t.column("finished_at", .integer)
                t.column("retry_at", .integer)
                t.column("retry_remaining", .integer).notNull()
                    .defaults(to: Self.defaultRetryRemaining)
                t.column("last_error", .text)
                t.column("input_watermark", .integer)
                t.column("last_success_watermark", .integer)
                t.primaryKey(["kind", "job_key"])
            }
            try db.create(
                index: "idx_jobs_kind_status_retry",
                on: "jobs",
                columns: ["kind", "status", "retry_at"])
        }
        // 批3 C1（记忆项目化）：候选/整合/设置面带 project 维度——最小扩展
        // （新列 nullable，NULL = legacy 全局池；既有行零改动，登记）。
        migrator.registerMigration("wanwo.memory.v2") { db in
            try db.alter(table: "stage1_outputs") { t in
                t.add(column: "project_key", .text)
            }
        }
        try migrator.migrate(dbQueue)
        // QA-5 P1-2：崩溃回收——打开账本时残留 status=="running" 的
        // phase2/global 行必然是上进程残骸（单进程 + 内存单飞闸），复位
        // error 进重试窗；不复位则 tryClaim 恒 SkippedRunning——整合中途
        // 被杀后 Phase2 永久静默停摆。
        try recoverInterruptedPhase2Job(
            retryDelaySeconds: interruptedRetryDelaySeconds)
    }

    private func nowSeconds() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    // MARK: - Phase1 水位（state/runtime/memories.rs stage1_source_needs_update）

    /// 水位幂等判定（两查询语义 1:1）：stage1_outputs 无行 → true（首次抽取）；
    /// 有行且源更新水位 > 已抽取水位 → true（会话又前进了 → 重抽）。
    func stage1SourceNeedsUpdate(threadId: String, sourceUpdatedAt: Int) throws -> Bool {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT source_updated_at FROM stage1_outputs WHERE thread_id = ?",
                arguments: [threadId])
            guard let row else { return true }
            return sourceUpdatedAt > (row["source_updated_at"] as Int? ?? 0)
        }
    }

    /// codex claim_stage1_jobs_for_startup 的万我承接段：对宿主枚举出的候选
    /// （threadId, sourceUpdatedAt）做水位判定过滤——已抽取且源未变化者剔除，
    /// 限量 maxClaimed（max_rollouts_per_startup 语义）。
    func filterEligibleStage1Candidates(_ candidates: [(threadId: String, sourceUpdatedAt: Int)],
                                        maxClaimed: Int) throws -> [MemoryStage1Claim] {
        var claims: [MemoryStage1Claim] = []
        for candidate in candidates {
            if try stage1SourceNeedsUpdate(threadId: candidate.threadId,
                                           sourceUpdatedAt: candidate.sourceUpdatedAt) {
                claims.append(MemoryStage1Claim(
                    threadId: candidate.threadId,
                    sourceUpdatedAt: candidate.sourceUpdatedAt))
                if claims.count >= maxClaimed { break }
            }
        }
        return claims
    }

    // MARK: - Phase1 结果落账（mark_stage1_job_* 三态）

    /// mark_stage1_job_succeeded 1:1：upsert stage1_outputs + jobs 置 done +
    /// last_success_watermark 推进 + retry 余量重置。批3 C1：projectKey 落账
    /// （nil = legacy 全局池）。
    func markStage1JobSucceeded(threadId: String, sourceUpdatedAt: Int,
                                rawMemory: String, rolloutSummary: String,
                                rolloutSlug: String?,
                                projectKey: String? = nil) throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO stage1_outputs
                    (thread_id, source_updated_at, raw_memory, rollout_summary, rollout_slug,
                     generated_at, usage_count, last_usage, selected_for_phase2,
                     selected_for_phase2_source_updated_at, project_key)
                VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, 0, NULL, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                    source_updated_at = excluded.source_updated_at,
                    raw_memory = excluded.raw_memory,
                    rollout_summary = excluded.rollout_summary,
                    rollout_slug = excluded.rollout_slug,
                    generated_at = excluded.generated_at,
                    project_key = excluded.project_key
                """,
                arguments: [threadId, sourceUpdatedAt, rawMemory, rolloutSummary,
                            rolloutSlug, now, projectKey])
            try Self.upsertJob(db, kind: "stage1", jobKey: threadId, status: "done",
                               startedAt: nil, finishedAt: now, retryAt: nil,
                               retryRemaining: Self.defaultRetryRemaining,
                               lastError: nil,
                               inputWatermark: sourceUpdatedAt,
                               lastSuccessWatermark: sourceUpdatedAt)
        }
    }

    /// mark_stage1_job_succeeded_no_output 1:1：模型三字段全空 = 无可保存信号；
    /// jobs 置 done + 水位推进，不产 stage1_outputs 行。
    func markStage1JobSucceededNoOutput(threadId: String, sourceUpdatedAt: Int) throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            try Self.upsertJob(db, kind: "stage1", jobKey: threadId, status: "done",
                               startedAt: nil, finishedAt: now, retryAt: nil,
                               retryRemaining: Self.defaultRetryRemaining,
                               lastError: nil,
                               inputWatermark: sourceUpdatedAt,
                               lastSuccessWatermark: sourceUpdatedAt)
        }
    }

    /// mark_stage1_job_failed 1:1：retry_at = now + 3600s；余量递减（不为负）。
    func markStage1JobFailed(threadId: String, sourceUpdatedAt: Int,
                             reason: String, retryDelaySeconds: Int) throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            let remaining = try Self.retryRemaining(db, kind: "stage1", jobKey: threadId)
            let nextRemaining = max(0, remaining - 1)
            try Self.upsertJob(db, kind: "stage1", jobKey: threadId, status: "error",
                               startedAt: nil, finishedAt: nil,
                               retryAt: now + retryDelaySeconds,
                               retryRemaining: nextRemaining,
                               lastError: reason,
                               inputWatermark: sourceUpdatedAt,
                               lastSuccessWatermark: nil)
        }
    }

    /// 该会话是否还有重试余量（codex retry_remaining > 0 才可再抢）。
    func stage1RetryRemaining(threadId: String) throws -> Int {
        try dbQueue.read { db in
            try Self.retryRemaining(db, kind: "stage1", jobKey: threadId)
        }
    }

    // MARK: - Phase2 全局任务（try_claim_global_phase2_job 状态机）

    /// QA-5 P1-2：崩溃回收（init 尾单次调用）。残留 running 行复位 error：
    /// retry_at = now + 重试窗、retry_remaining -1（mark_global_phase2_job_
    /// failed 同语义——中断计一次失败）、last_error 记中断；无残行 no-op
    /// （不落首行）。批3 C1：回收面扩到全部项目任务键（每项目一行 phase2
    /// 任务——崩溃残留可能跨多项目，逐行复位）。
    func recoverInterruptedPhase2Job(retryDelaySeconds: Int) throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db, sql: """
                SELECT job_key, retry_remaining FROM jobs
                WHERE kind = 'phase2' AND status = 'running'
                """)
            for row in rows {
                guard let jobKey: String = row["job_key"] else { continue }
                let remaining = row["retry_remaining"] as Int?
                    ?? Self.defaultRetryRemaining
                try Self.upsertJob(db, kind: "phase2", jobKey: jobKey, status: "error",
                                   startedAt: nil, finishedAt: nil,
                                   retryAt: now + retryDelaySeconds,
                                   retryRemaining: max(0, remaining - 1),
                                   lastError: "recovered: interrupted by process exit",
                                   inputWatermark: nil, lastSuccessWatermark: nil)
            }
        }
    }

    /// Phase2 任务键（批3 C1 项目化：projectKey → 项目自身；nil → 'global'
    /// legacy 行。jobs 表主键 (kind, job_key) 天然按项目分行，零 schema 改动）。
    static func phase2JobKey(forProjectKey projectKey: String?) -> String {
        projectKey ?? "global"
    }

    /// try_claim_global_phase2_job 万我单进程形态（actor 串行 + NSLock 双保险）：
    /// running → SkippedRunning；done 且在成功冷却窗（6h）→ SkippedCooldown；
    /// error 且重试未到点 → SkippedRetryUnavailable；否则置 running 并交出
    /// input_watermark（= last_success_watermark，幂等基线）。批3 C1：任务键
    /// 随项目（缺省 'global' = legacy，既有调用点编译兼容）。
    func tryClaimGlobalPhase2Job(cooldownSeconds: Int,
                                 jobKey: String = "global") throws -> MemoryPhase2ClaimOutcome {
        lock.lock()
        defer { lock.unlock() }
        let now = nowSeconds()
        return try dbQueue.write { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM jobs WHERE kind = 'phase2' AND job_key = ?",
                arguments: [jobKey])
            let status = row?["status"] as String?
            let finishedAt = row?["finished_at"] as Int?
            let retryAt = row?["retry_at"] as Int?
            let lastSuccessWatermark = row?["last_success_watermark"] as Int? ?? 0
            switch status {
            case "running":
                // 租约回收（codex lib.rs:82 JOB_LEASE_SECONDS=3600 1:1——拍板
                // 2026-10-04）：领取后进程死亡（杀 App/崩溃/挂起越窗）会让
                // running 行永久卡死（无心跳/租约的移植假设"进程不死"不成立）
                // ——超租约视为陈旧落回可领取（原行由下方 upsert 覆盖）；
                // started_at 缺席按陈旧处理（防御旧格式行）。
                if let startedAt = row?["started_at"] as Int?,
                   now - startedAt < MemoryConstants.phase2JobLeaseSeconds {
                    return .skippedRunning
                }
            case "done":
                if let finishedAt, now < finishedAt + cooldownSeconds {
                    return .skippedCooldown
                }
            case "error":
                if let retryAt, now < retryAt {
                    return .skippedRetryUnavailable
                }
            default:
                break
            }
            try Self.upsertJob(db, kind: "phase2", jobKey: jobKey, status: "running",
                               startedAt: now, finishedAt: nil, retryAt: nil,
                               retryRemaining: Self.defaultRetryRemaining,
                               lastError: nil,
                               inputWatermark: lastSuccessWatermark,
                               lastSuccessWatermark: lastSuccessWatermark)
            return .claimed(inputWatermark: lastSuccessWatermark)
        }
    }

    /// mark_global_phase2_job_failed 1:1（单进程无 ownership 校验面——
    /// mark_global_phase2_job_failed_if_unowned 的双保险随租约一并退役，登记；
    /// 批3 C1：任务键随项目，缺省 'global'）。
    func markGlobalPhase2JobFailed(reason: String, retryDelaySeconds: Int,
                                   jobKey: String = "global") throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            let remaining = try Self.retryRemaining(db, kind: "phase2", jobKey: jobKey)
            try Self.upsertJob(db, kind: "phase2", jobKey: jobKey, status: "error",
                               startedAt: nil, finishedAt: nil,
                               retryAt: now + retryDelaySeconds,
                               retryRemaining: max(0, remaining - 1),
                               lastError: reason,
                               inputWatermark: nil,
                               lastSuccessWatermark: nil)
        }
    }

    /// mark_global_phase2_job_succeeded 1:1：置 done + finished_at（冷却起点）+
    /// last_success_watermark = 完成水位；selected_for_phase2 重写（选中集=1
    /// 并随行 selected_for_phase2_source_updated_at，其余=0）。批3 C1：任务键
    /// 与 selected 重写面均按项目收窄（projectKey 维度过滤——其余项目/legacy
    /// 行零扰动），缺省 'global'/NULL = legacy。
    func markGlobalPhase2JobSucceeded(completionWatermark: Int,
                                      selectedThreadIds: [String],
                                      projectKey: String? = nil) throws {
        let jobKey = Self.phase2JobKey(forProjectKey: projectKey)
        let now = nowSeconds()
        try dbQueue.write { db in
            try Self.upsertJob(db, kind: "phase2", jobKey: jobKey, status: "done",
                               startedAt: nil, finishedAt: now, retryAt: nil,
                               retryRemaining: Self.defaultRetryRemaining,
                               lastError: nil,
                               inputWatermark: completionWatermark,
                               lastSuccessWatermark: completionWatermark)
            let selected = Set(selectedThreadIds)
            let rows = try Row.fetchAll(
                db, sql: "SELECT thread_id FROM stage1_outputs WHERE project_key IS ?",
                arguments: [projectKey])
            for row in rows {
                guard let threadId: String = row["thread_id"] else { continue }
                if selected.contains(threadId) {
                    try db.execute(
                        sql: """
                        UPDATE stage1_outputs
                        SET selected_for_phase2 = 1,
                            selected_for_phase2_source_updated_at = source_updated_at
                        WHERE thread_id = ?
                        """,
                        arguments: [threadId])
                } else {
                    try db.execute(
                        sql: """
                        UPDATE stage1_outputs
                        SET selected_for_phase2 = 0,
                            selected_for_phase2_source_updated_at = NULL
                        WHERE thread_id = ?
                        """,
                        arguments: [threadId])
                }
            }
        }
    }

    // MARK: - Phase2 输入选取（get_phase2_input_selection）

    /// get_phase2_input_selection 1:1：排除已过保留期条目（codex 同一
    /// COALESCE(last_usage, source_updated_at) >= cutoff 谓词）；
    /// 排序 usage_count DESC → COALESCE(last_usage, source_updated_at) DESC →
    /// source_updated_at DESC → thread_id DESC 取 top-N；返回前按 thread_id ASC
    /// 稳定排序（raw_memories.md 机械重建序——thread_id 稳定升序）。
    /// 批3 C1：projectKey 维度过滤（`IS ?` 兼容 NULL——nil = legacy 全局池）。
    func getPhase2InputSelection(limit: Int, maxUnusedDays: Int,
                                 projectKey: String? = nil) throws -> [MemoryStage1Record] {
        let cutoff = nowSeconds() - maxUnusedDays * 86_400
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM stage1_outputs
                WHERE COALESCE(last_usage, source_updated_at) >= ?
                  AND project_key IS ?
                ORDER BY COALESCE(usage_count, 0) DESC,
                         COALESCE(last_usage, source_updated_at) DESC,
                         source_updated_at DESC,
                         thread_id DESC
                LIMIT ?
                """,
                arguments: [cutoff, projectKey, limit])
        }
        return rows.map(Self.record(from:)).sorted { $0.threadId < $1.threadId }
    }

    /// 全量账本（thread_id ASC——raw_memories.md 机械重建读面）。批3 C1：
    /// projectKey 过滤（nil = legacy 池；`IS ?` 语义）。
    func allStage1Outputs(projectKey: String? = nil) throws -> [MemoryStage1Record] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM stage1_outputs WHERE project_key IS ? ORDER BY thread_id ASC",
                arguments: [projectKey])
        }
        return rows.map(Self.record(from:))
    }

    // MARK: - 淘汰（prune_stage1_outputs_for_retention）

    /// prune 1:1：selected_for_phase2=0 且 COALESCE(last_usage, source_updated_at)
    /// < cutoff 的行删除，批 200 最旧优先（codex ORDER ASC LIMIT batch）。
    @discardableResult
    func pruneStage1OutputsForRetention(maxUnusedDays: Int, batchSize: Int) throws -> Int {
        let cutoff = nowSeconds() - maxUnusedDays * 86_400
        return try dbQueue.write { db in
            let stale = try String.fetchAll(
                db,
                sql: """
                SELECT thread_id FROM stage1_outputs
                WHERE selected_for_phase2 = 0
                  AND COALESCE(last_usage, source_updated_at) < ?
                ORDER BY COALESCE(last_usage, source_updated_at) ASC
                LIMIT ?
                """,
                arguments: [cutoff, batchSize])
            for threadId in stale {
                try db.execute(sql: "DELETE FROM stage1_outputs WHERE thread_id = ?",
                               arguments: [threadId])
            }
            return stale.count
        }
    }

    // MARK: - 引用记账（core/src/memory_usage.rs 语义）

    /// citation rollout_ids 命中 → usage_count+1 / last_usage=now（反馈环回写）。
    func recordMemoryUsage(threadIds: [String]) throws {
        let now = nowSeconds()
        try dbQueue.write { db in
            for threadId in Set(threadIds) {
                try db.execute(
                    sql: """
                    UPDATE stage1_outputs
                    SET usage_count = COALESCE(usage_count, 0) + 1,
                        last_usage = ?
                    WHERE thread_id = ?
                    """,
                    arguments: [now, threadId])
            }
        }
    }

    // MARK: - 设置页（一键清空 + 条目可溯）

    /// 条目列表（来源会话 + turn 可溯——raw_memory 正文内含 turn 级任务块）。
    /// 批3 C1：projectKey 过滤（设置页按当前项目桶列举——C2 消费点；nil =
    /// legacy 池）。
    func listEntries(projectKey: String? = nil) throws -> [MemoryStage1Record] {
        try allStage1Outputs(projectKey: projectKey)
    }

    /// 一键清空：两表清（memory/ 目录删除由 MemoryStorage.clearAll 承担）。
    func clearAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM stage1_outputs")
            try db.execute(sql: "DELETE FROM jobs")
        }
    }

    /// 上次成功整合时刻（jobs 表 phase2 行 finished_at；设置页状态行）。
    /// 批3 C1：任务键随项目（缺省 'global' = legacy）。
    func lastPhase2SuccessDate(jobKey: String = "global") throws -> Date? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: """
                SELECT finished_at FROM jobs
                WHERE kind = 'phase2' AND job_key = ? AND status = 'done'
                """,
                arguments: [jobKey])
            guard let seconds: Int = row?["finished_at"] else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    // MARK: - 私有

    /// jobs 行 upsert（保留未提及列现值——retry 语义跨次失败累计）。
    private static func upsertJob(_ db: Database, kind: String, jobKey: String,
                                  status: String, startedAt: Int?, finishedAt: Int?,
                                  retryAt: Int?, retryRemaining: Int, lastError: String?,
                                  inputWatermark: Int?, lastSuccessWatermark: Int?) throws {
        try db.execute(
            sql: """
            INSERT INTO jobs
                (kind, job_key, status, started_at, finished_at, retry_at,
                 retry_remaining, last_error, input_watermark, last_success_watermark)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, job_key) DO UPDATE SET
                status = excluded.status,
                started_at = excluded.started_at,
                finished_at = excluded.finished_at,
                retry_at = excluded.retry_at,
                retry_remaining = excluded.retry_remaining,
                last_error = excluded.last_error,
                input_watermark = COALESCE(excluded.input_watermark, jobs.input_watermark),
                last_success_watermark = COALESCE(excluded.last_success_watermark,
                                                  jobs.last_success_watermark)
            """,
            arguments: [kind, jobKey, status, startedAt, finishedAt, retryAt,
                        retryRemaining, lastError, inputWatermark, lastSuccessWatermark])
    }

    private static func retryRemaining(_ db: Database, kind: String, jobKey: String) throws -> Int {
        let row = try Row.fetchOne(
            db, sql: "SELECT retry_remaining FROM jobs WHERE kind = ? AND job_key = ?",
            arguments: [kind, jobKey])
        return row?["retry_remaining"] as Int? ?? defaultRetryRemaining
    }

    private static func record(from row: Row) -> MemoryStage1Record {
        MemoryStage1Record(
            threadId: row["thread_id"] ?? "",
            sourceUpdatedAt: row["source_updated_at"] ?? 0,
            rawMemory: row["raw_memory"] ?? "",
            rolloutSummary: row["rollout_summary"] ?? "",
            rolloutSlug: row["rollout_slug"],
            generatedAt: row["generated_at"] ?? 0,
            usageCount: row["usage_count"],
            lastUsage: row["last_usage"],
            selectedForPhase2: (row["selected_for_phase2"] as Int? ?? 0) != 0,
            selectedForPhase2SourceUpdatedAt: row["selected_for_phase2_source_updated_at"])
    }
}
