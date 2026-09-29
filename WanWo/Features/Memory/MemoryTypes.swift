//
//  MemoryTypes.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6）：
//    - memories/write/src/lib.rs —— stage_one/stage_two 常量段 1:1（REASONING_
//      EFFORT Low/Medium、CONCURRENCY_LIMIT=8、JOB_RETRY_DELAY=3600、
//      THREAD_SCAN_LIMIT=5000、PRUNE_BATCH_SIZE=200、DEFAULT_ROLLOUT_TOKEN_
//      LIMIT=150000、CONTEXT_WINDOW_PERCENT=70；JOB_LEASE/JOB_HEARTBEAT 随
//      已定适配②退役——单进程无租约/心跳）。
//    - memories/write/src/start.rs —— 三重门（ephemeral || !MemoryTool ||
//      non-root agent → return）的常量映射源。
//    - memories/write/src/workspace.rs —— workspace_diff FILENAME/
//      MAX_BYTES（diff 文件由 git baseline 换为 hash 快照清单渲染，已定适配③，
//      文件名与渲染头保持同款）。
//    - ext/memories/src/lib.rs —— 四工具上限常量 1:1（list 2000 / search 200 /
//      read max_tokens 20000 / summary_token_limit 2500）。
//    - state/src/model/memories.rs —— Stage1Output 严格三字段（deny_unknown_
//      fields；rollout_slug 可空——模型面 schema required 但 type 可 null）。
//    - 用户拍板（批2 派单「已定适配」）：触发三条件（前台+空闲+总开关默认开）
//      + 每次启动最多 2 条 + 失败重试≤3（3600s）+ 成功 6h 冷却 + Phase2 选取
//      top-256。
//

import Foundation

/// 全链常量（lib.rs 常量段 + 用户拍板档；出处逐项见头注）。
enum MemoryConstants {
    // MARK: stage_one（lib.rs stage_one 段 1:1）

    /// Phase1 抽取推理档（ReasoningEffort::Low）。
    static let stageOneReasoningEffort = "low"
    /// 并行抽取上限（buffer_unordered(CONCURRENCY_LIMIT)）。
    static let concurrencyLimit = 8
    /// 失败重试间隔（JOB_RETRY_DELAY_SECONDS = 3_600）。
    static let jobRetryDelaySeconds = 3_600
    /// 候选扫描上限（THREAD_SCAN_LIMIT = 5_000）。
    static let threadScanLimit = 5_000
    /// 淘汰批大小（PRUNE_BATCH_SIZE = 200）。
    static let pruneBatchSize = 200
    /// 模型无上下文窗元数据时的兜底截断（DEFAULT_ROLLOUT_TOKEN_LIMIT）。
    static let defaultRolloutTokenLimit = 150_000
    /// 生效输入窗中划给 rollout 输入的份额（CONTEXT_WINDOW_PERCENT = 70）。
    static let contextWindowPercent = 70

    // MARK: stage_two（lib.rs stage_two 段；JOB_HEARTBEAT 随适配②退役）

    /// Phase2 整合推理档（ReasoningEffort::Medium）。
    static let stageTwoReasoningEffort = "medium"
    /// Phase2 成功冷却（批2 拍板 PHASE2_SUCCESS_COOLDOWN = 6h）。
    static let phase2SuccessCooldownSeconds = 6 * 3_600
    /// 整合收口等待超时（QA-5 P2-② 兜底——codex status_poll 等价：AgentLoop
    /// 异常路径不发 onTurnEnd 时防触发器单飞永挂；超时 = failed_agent 重试窗）。
    static let consolidationWaitTimeoutSeconds: TimeInterval = 900

    // MARK: 拍板档（批2 派单「已定适配」）

    /// 每次启动最多抽取的会话数（codex max_rollouts_per_startup 万我档 = 2）。
    static let maxRolloutsPerStartup = 2
    /// 候选会话最大年龄（codex max_rollout_age_days 缺省 10）。
    static let maxRolloutAgeDays = 10
    /// 候选会话最短空闲（codex min_rollout_idle_hours 缺省 6）。
    static let minRolloutIdleHours = 6
    /// 账本保留期（codex max_unused_days——prune 与 Phase2 选取共用）。
    static let maxUnusedDays = 30
    /// Phase2 输入上限（codex max_raw_memories_for_consolidation = 256）。
    static let maxRawMemoriesForConsolidation = 256

    // MARK: ext/memories 常量（ext/memories/src/lib.rs 1:1）

    /// list 工具缺省/上限结果数。
    static let listDefaultMaxResults = 2_000
    static let listMaxResults = 2_000
    /// search 工具缺省/上限结果数。
    static let searchDefaultMaxResults = 200
    static let searchMaxResults = 200
    /// read 工具缺省 token 上限。
    static let readMaxTokens = 20_000
    /// memory_summary.md 注入截断（developer instructions summary token limit）。
    static let memorySummaryTokenLimit = 2_500

    // MARK: 目录与文件（write/src/lib.rs artifacts + workspace_diff 段）

    /// rollout_summaries 子目录（ROLLOUT_SUMMARIES_SUBDIR）。
    static let rolloutSummariesSubdir = "rollout_summaries"
    /// extensions 子目录（EXTENSIONS_SUBDIR；万我无 extensions 面——ad_hoc
    /// note 落点按 codex extensions/ad_hoc/notes/ 形态保留子目录名）。
    static let extensionsSubdir = "extensions"
    /// ad-hoc note 落点（read_path.md :120 "extensions/ad_hoc/notes/" 逐字）。
    static let adHocNotesSubdir = "extensions/ad_hoc/notes"
    /// raw_memories.md（RAW_MEMORIES_FILENAME）。
    static let rawMemoriesFilename = "raw_memories.md"
    /// Phase2 diff 文件名（workspace_diff::FILENAME 逐字保留）。
    static let phase2WorkspaceDiffFilename = "phase2_workspace_diff.md"
    /// diff 文件字节上限（workspace_diff::MAX_BYTES = 4MiB）。
    static let workspaceDiffMaxBytes = 4 * 1024 * 1024
    /// 记忆根 guest 路径（全局桶静态 bind mount：memoryPersistentDir ↔ 本路径，
    /// IshExecutorBridge.swift:845——只读化按落点⑪缝交付，见 analysis/m7-fix/
    /// e2-report.md 缝需求②；切换前 guest shell 侧为读写 mount）。
    static let memoryGuestPath = "/var/wanwo/memory"
}

// MARK: - Stage1Output（state/src/model/memories.rs）

/// Phase1 模型输出（serde deny_unknown_fields 三字段 1:1；rollout_slug 可空）。
struct MemoryStage1Output: Equatable, Codable, Sendable {
    /// Detailed markdown raw memory for a single rollout。
    var rawMemory: String
    /// Compact summary line used for routing and indexing。
    var rolloutSummary: String
    /// Optional slug used to derive rollout summary artifact filenames。
    var rolloutSlug: String?

    enum CodingKeys: String, CodingKey {
        case rawMemory = "raw_memory"
        case rolloutSummary = "rollout_summary"
        case rolloutSlug = "rollout_slug"
    }

    /// 严格解码（deny_unknown_fields 1:1）：未知键即拒——模型输出面 fail closed。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawMemory = try container.decode(String.self, forKey: .rawMemory)
        rolloutSummary = try container.decode(String.self, forKey: .rolloutSummary)
        rolloutSlug = try container.decodeIfPresent(String.self, forKey: .rolloutSlug)
        // 未知键拒绝（serde deny_unknown_fields 等价）：动态键容器 allKeys 含
        // 全部键，剔除已知三键后仍有剩余即拒。
        let known: Set<String> = ["raw_memory", "rollout_summary", "rollout_slug"]
        if let extra = try? decoder.container(keyedBy: ExtraKeys.self),
           extra.allKeys.contains(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: extra.allKeys.first { !known.contains($0.stringValue) }!,
                in: extra,
                debugDescription: "unknown field in stage-1 output (deny_unknown_fields)")
        }
    }

    private struct ExtraKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(rawMemory: String, rolloutSummary: String, rolloutSlug: String?) {
        self.rawMemory = rawMemory
        self.rolloutSummary = rolloutSummary
        self.rolloutSlug = rolloutSlug
    }
}

// MARK: - 域错误

/// memory 域错误（codex MemoriesBackendError 文案族的 Swift 承载；
/// 工具面 RespondToModel 语义 = 可回模型的字符串错误）。
struct MemoryError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - 快照清单（已定适配③：git baseline → 自维护文件 hash 快照）

/// 上次成功 Phase2 基线的文件 hash 快照清单（JSON 持久于 memory 根外——
/// config/memory-snapshot.json；diff = 清单比对 added/modified/deleted，
/// 渲染同款 markdown 给整合 agent——整合语义「以 diff 为权威变更队列」不变）。
struct MemorySnapshotManifest: Equatable, Codable, Sendable {
    /// 相对 memory 根的文件路径 → 内容 hash（ContextInjector.digest 同款
    /// 非密码学稳定摘要——FNV 变体，语义=变化检测足够）。
    var entries: [String: String]

    init(entries: [String: String] = [:]) {
        self.entries = entries
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> MemorySnapshotManifest {
        try JSONDecoder().decode(MemorySnapshotManifest.self, from: data)
    }
}

/// 快照 diff 结果（GitBaselineDiff 变更队列的等价承载）。
struct MemorySnapshotDiff: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        /// git status label 词汇（A/M/D——渲染同款 "- A path" 行）。
        var label: String
        var path: String
    }

    var changes: [Change]
    var renderedDiff: String

    var hasChanges: Bool { !changes.isEmpty }
}
