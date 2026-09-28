//
//  MemoryTrigger.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6
//  memories/write/src/start.rs :24-38 三重门 + phase1.rs claim_startup_jobs
//  候选参数 + 用户拍板档）：
//    - 三重门（start.rs 1:1 映射）：config.ephemeral → 万我「子代理会话跳过」
//      （子/侧会话拓扑等价 ephemeral——lineage 事件判定，登记）；
//      !features.enabled(MemoryTool) → 万我「总开关」（UserDefaults
//      wanwo.memory.enabled，默认开——拍板）；source.is_non_root_agent() → 同
//      子代理跳过门。前台 + 空闲为万我拍板追加门（用户拍板①：触发=前台+空闲+
//      总开关）。
//    - 候选参数（phase1.rs :160-177 1:1）：scan_limit=THREAD_SCAN_LIMIT=5000、
//      max_claimed=max_rollouts_per_startup（拍板 2）、max_age_days=10、
//      min_rollout_idle_hours=6、allowed_sources=INTERACTIVE_SESSION_SOURCES →
//      万我会话事实源（SessionStore 列表）——子代理会话按 lineage 事件剔除
//      （is_non_root_agent 等价）；水位判定/重试窗在 MemoryDatabase。
//    - 编排（start.rs :54-81）：ensureLayout → prune → Phase1 → Phase2。
//      rate_limits_ok 守卫（guard.rs）万我无配额面→不移植（登记）。
//  万我形态（登记）：
//    - 不碰 AgentLoop：前台/空闲观察经 NotificationCenter + 轮询面（scenePhase
//      与 activeRunSessionIDs 既有 AppEnvironment 镜像经装配缝回调注入）；
//      会话枚举/事件读取经 SessionStore/JsonlEventLog 只读缝。
//    - 总开关持久化：UserDefaults（App 级单键；MemorySettings 承载设置页绑定）。
//

import Foundation

/// memory 总开关（设置页 ↔ 触发器绑定；UserDefaults 单键，默认开——拍板）。
enum MemorySettings {
    static let enabledKey = "wanwo.memory.enabled"

    static var isEnabled: Bool {
        get {
            // 缺省 true（未写入时 enabled true——拍板「默认开」）。
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// 长期记忆触发器（start_memories_startup_task 万我承载；App 级单例装配）。
final class MemoryTrigger: @unchecked Sendable {

    /// 宿主缝（AppEnvironment 装配期注入；全部只读消费）。
    struct HostSeams {
        /// 会话列表（SessionStore.listSessions——actor 缝）。
        var listSessions: @Sendable () async -> [SessionSummary]
        /// 会话事件流只读读取（JsonlEventLog.open(writeMode:false)）。
        var readSessionEvents: @Sendable (String) async -> [SessionEvent]?
        /// 当前活跃运行会话集（AppEnvironment.activeRunSessionIDs 镜像快照；
        /// async——MainActor 镜像跳线程读取）。
        var activeRunSessionIDs: @Sendable () async -> Set<String>
        /// 前台判定（scenePhase == .active 等价快照；async——同上跳线程）。
        var isForeground: @Sendable () async -> Bool
        /// Phase1 连接事实与调用缝。
        var phase1: MemoryPhase1
        /// Phase2（configure 已注入 runner/storage）。
        var phase2: MemoryPhase2
        /// 供值缝：模型上下文窗 token 数（Phase1 截断；nil = 回落缺省）。
        var contextWindowTokens: @Sendable () -> Int?
        /// 供值缝：会话 cwd（header cwd 探针——整合会话防回流判定用）。
        var sessionCWD: @Sendable (String) async -> String?
    }

    private let database: MemoryDatabase
    private let storage: MemoryStorage
    private var seams: HostSeams?
    private let lock = NSLock()
    /// 单飞闸：一次只跑一条启动管线（start.rs tokio::spawn 单任务语义）。
    private var isRunning = false

    private static let logger = AppLogger(category: "memory-trigger")

    init(database: MemoryDatabase, storage: MemoryStorage) {
        self.database = database
        self.storage = storage
    }

    /// 装配期注入宿主缝（赋值一次，运行期只读）。
    func attach(_ seams: HostSeams) {
        lock.lock()
        self.seams = seams
        lock.unlock()
    }

    /// 前台转入门（WanWoApp scenePhase .active onChange 调用点——报行号）。
    func onDidEnterForeground() {
        guard MemorySettings.isEnabled else { return }
        startPipelineIfNeeded()
    }

    // MARK: - 管线（start.rs 编排 1:1）

    /// 单飞启动：前台 + 空闲 + 总开关三重门全过才跑（tokio::spawn 等价）。
    private func startPipelineIfNeeded() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()
        Task { [weak self] in
            await self?.runPipeline()
            self?.lock.lock()
            self?.isRunning = false
            self?.lock.unlock()
        }
    }

    private func runPipeline() async {
        guard let seams else { return }
        // 三重门（start.rs :33-38 映射 + 拍板追加门）：
        // ①总开关（MemoryTool feature 等价）②前台 ③空闲（无运行中会话）。
        guard MemorySettings.isEnabled else { return }
        guard await seams.isForeground() else { return }
        guard await seams.activeRunSessionIDs().isEmpty else { return }

        do {
            try storage.ensureLayout()
        } catch {
            Self.logger.warning("memory ensureLayout failed: \(String(describing: error))")
            return
        }

        // prune（phase1::prune——账本保留期淘汰，零 token 消耗先做）。
        _ = try? database.pruneStage1OutputsForRetention(
            maxUnusedDays: MemoryConstants.maxUnusedDays,
            batchSize: MemoryConstants.pruneBatchSize)
        // codex rate_limits_ok 守卫万我无配额面，不移植（登记）。

        // Phase1（claim → 抽取）。
        await runPhase1(seams: seams)
        // Phase2（整合）。
        _ = await seams.phase2.runOnce()
    }

    /// Phase1：候选枚举（age/idle/子代理过滤 + 水位判定 + 拍板限量）→ 抽取。
    private func runPhase1(seams: HostSeams) async {
        let sessions = await seams.listSessions()
        let now = Date()
        var candidates: [(threadId: String, sourceUpdatedAt: Int, cwd: String)] = []
        // scan_limit=THREAD_SCAN_LIMIT 1:1（列表截断）。
        for summary in sessions.prefix(MemoryConstants.threadScanLimit) {
            // 整合子会话防回流（phase2 cwd=memory guest 根的临时会话不入候选
            // ——get_config generate_memories=false 的结构性等价承载）。
            guard let cwd = await seams.sessionCWD(summary.id) else { continue }
            if cwd == MemoryConstants.memoryGuestPath { continue }
            // max_rollout_age_days（更新时刻距 now ≤ 10 天）。
            guard now.timeIntervalSince(summary.updatedAt)
                <= TimeInterval(MemoryConstants.maxRolloutAgeDays * 86_400) else { continue }
            // min_rollout_idle_hours（空闲 ≥ 6 小时——updated_at 距 now）。
            guard now.timeIntervalSince(summary.updatedAt)
                >= TimeInterval(MemoryConstants.minRolloutIdleHours * 3_600) else { continue }
            candidates.append((summary.id,
                               Int(summary.updatedAt.timeIntervalSince1970),
                               cwd))
        }

        // 水位判定 + 拍板限量（claim_stage1_jobs_for_startup 的两步拆分承接）。
        let claims: [MemoryStage1Claim]
        do {
            claims = try database.filterEligibleStage1Candidates(
                candidates.map { ($0.threadId, $0.sourceUpdatedAt) },
                maxClaimed: MemoryConstants.maxRolloutsPerStartup)
        } catch {
            Self.logger.warning("stage1 claim failed: \(String(describing: error))")
            return
        }
        guard !claims.isEmpty else { return }

        var inputs: [MemoryPhase1.JobInput] = []
        for claim in claims {
            guard let events = await seams.readSessionEvents(claim.threadId) else {
                continue
            }
            // 子代理会话跳过（source.is_non_root_agent 等价——lineage 事件在场
            // 即子会话；此处兜底二次过滤：枚举面无法免读流先行判定）。
            if events.contains(where: {
                if case .extensionEvent(SubagentLineage.eventKind, _) = $0.payload {
                    return true
                }
                return false
            }) { continue }
            let contents = MemoryRollout.serializeFilteredEvents(events)
            // 全空 rollout = 无可抽取面 → 直接按 no_output 落账推进水位
            // （等价 codex 空 rollout 抽取后 no_output；避免重扫）。
            if contents == "[]" {
                try? database.markStage1JobSucceededNoOutput(
                    threadId: claim.threadId,
                    sourceUpdatedAt: claim.sourceUpdatedAt)
                continue
            }
            inputs.append(MemoryPhase1.JobInput(
                claim: claim,
                rolloutContents: contents,
                rolloutPath: "sessions/\(claim.threadId).jsonl",
                rolloutCwd: candidates.first(where: { $0.threadId == claim.threadId })?.cwd
                    ?? WanWoPaths.workspaceLinuxDir,
                contextWindowTokens: seams.contextWindowTokens()))
        }
        guard !inputs.isEmpty else { return }
        _ = await seams.phase1.run(inputs: inputs)
    }

    // MARK: - 私有
}
