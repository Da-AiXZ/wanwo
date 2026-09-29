//
//  MemoryPhase2.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6
//  memories/write/src/phase2.rs run() 十步 1:1 + agent::get_config 锁死清单 +
//  agent::handle 收口）：
//    1. 抢占全局 Phase2 任务（try_claim_global_phase2_job——Skipped* 三臂静默退出）
//    2. 准备 memory 工作区（ensure_layout + 清陈旧 diff 工件——prepare_memory_
//       workspace；git baseline 随适配③换为快照清单）
//    3. 整合 agent 配置锁死（get_config :312-370——见下方 runner 装配注记）
//    4. 读取 Phase2 输入选取（get_phase2_input_selection top-256）
//    5. 同步输入进工作区（sync_rollout_summaries + rebuild_raw_memories +
//       prune_old_extension_resources 万我不适用=extensions 恒空）
//    6. 变更判定：diff 无变化且工件校验通过 → succeed(succeeded_no_workspace_changes)
//    7. 落 diff 文件（write_workspace_diff）
//    8. 生成整合 agent（consolidation prompt）
//    9. 等待收口 → 工件校验 → 基线重置 → succeed / failed
//   10. watermark 推进（get_watermark :567-577 逐字：选取集 max(source_updated_at)
//       与抢占水位取大）
//  万我适配（登记）：
//    - 整合 agent = 受限子会话（派单拍板复用 ChildMaterializer 模式）：注入
//      runner 闭包由 AppEnvironment 装配——临时子会话（cwd=memory guest 根
//      /var/wanwo/memory → 文件工具/shell/技能 project 根全部限定在 memory 树）
//      + 提交渲染后的 consolidation prompt + 尾回合判定收口 + 会话删除（ephemeral
//      1:1——get_config :322 agent_config.ephemeral = true）。锁死清单余项对照：
//        · generate/use_memories=false → 子会话非根会话不触发记忆管线（触发器
//          子会话跳过门结构性保证）+ 独立 cwd 不在候选枚举面；
//        · notify=None → 子会话不挂用户回调（callbacks.onTurnEnd 仅收口信号）；
//        · mcp_servers=空/approval=Never/Collab/MemoryTool/Apps/Plugins 禁/
//          WorkspaceWrite 仅 memory root 无网 → QA-5 P1-1 三闸已装（最小
//          修法）：MemoryTools/web 双族 toolFilter 注册闸禁 + 沙箱锁定
//          （subagentSandboxOverride=.workspaceWrite × cwd=memoryGuestPath
//          → approval Never 随缝折叠）+ effort medium（会话级选择缝）；完整
//          per-stack 策略参数化（mcp_servers 空/Collab/Apps 面等）仍留 P2。
//    - 基线：git → 快照清单（适配③）；"## Diff" 节恒空块（Status 为权威变更
//      队列，MemoryStorage 头注登记）。
//    - diff 工件生命周期：生成（步骤 7）→ 会话收口后删除（remove_workspace_diff
//      同语义——基线重置前清，prompt 工件不入基线）。
//

import Foundation

/// Phase2 整合器（actor——全局串行锚；tryClaim 的 NSLock 双保险在账本侧）。
actor MemoryPhase2 {

    /// 整合子会话运行缝（AppEnvironment 装配）：
    /// 输入渲染后的 consolidation prompt；返回 = agent 正常完成（codex
    /// AgentStatus::Completed 等价）；抛错 = spawn/运行失败。
    typealias ConsolidationRunner = @Sendable (_ prompt: String, _ cwd: String) async throws -> Void

    struct Configuration: Sendable {
        var storage: MemoryStorage
        var runner: ConsolidationRunner
        /// 候选 cwd 供值缝（raw_memories.md 元数据行 cwd 列）。
        var cwdFor: @Sendable (String) -> String
    }

    private let database: MemoryDatabase
    private var configuration: Configuration?

    init(database: MemoryDatabase) {
        self.database = database
    }

    /// 装配期注入（AppEnvironment init；actor 隔离赋值）。
    func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// run() 十步（phase2.rs :49-212 逐语义）。供值 inputs 为空时按
    /// get_phase2_input_selection 语义自取（limit=256/maxUnusedDays=30 拍板档）。
    /// - Parameters:
    ///   - storage: 本轮存储面覆盖（批3 C1 项目化——触发器按当前项目桶传入；
    ///     nil = Configuration.storage legacy 全局桶。既有 runOnce() 调用点
    ///     编译兼容）。
    ///   - memoryRootGuestPath: 本轮整合 prompt memory_root 覆盖（项目桶
    ///     guest 路径 <cwd>/wanwo-memory——整合子会话 cwd 须同值，C2 装配缝；
    ///     nil = legacy /var/wanwo/memory）。
    ///   - projectKey: 本轮项目身份键（批3 C1——Phase2 输入选取与 selected
    ///     重写按项目过滤；nil = legacy 全局池）。
    /// - Returns: 结果标签（诊断面；Skipped* 三臂照 codex metrics status 词汇）。
    @discardableResult
    func runOnce(storage overrideStorage: MemoryStorage? = nil,
                 memoryRootGuestPath: String? = nil,
                 projectKey: String? = nil) async -> String {
        guard let configuration else { return "failed_not_configured" }
        let storage = overrideStorage ?? configuration.storage

        // 1. 抢占全局锁（job::claim——Skipped* 静默退出；批3 C1 任务键随
        //    项目身份键，'global' = legacy 行）。
        let claimOutcome: MemoryPhase2ClaimOutcome
        do {
            claimOutcome = try database.tryClaimGlobalPhase2Job(
                cooldownSeconds: MemoryConstants.phase2SuccessCooldownSeconds,
                jobKey: MemoryDatabase.phase2JobKey(forProjectKey: projectKey))
        } catch {
            return "failed_claim"
        }
        let inputWatermark: Int
        switch claimOutcome {
        case .claimed(let watermark): inputWatermark = watermark
        case .skippedRetryUnavailable: return "skipped_retry_unavailable"
        case .skippedCooldown: return "skipped_cooldown"
        case .skippedRunning: return "skipped_running"
        }

        // 2. 准备工作区（prepare_memory_workspace——布局 + 清陈旧 diff 工件）。
        do {
            try storage.ensureLayout()
            storage.removeWorkspaceDiff()
        } catch {
            await fail(configuration, reason: "failed_prepare_workspace", projectKey: projectKey)
            return "failed_prepare_workspace"
        }

        // 4. 输入选取（get_phase2_input_selection——拍板档 256/30；批3 C1
        //    按 projectKey 过滤，nil = legacy 全局池）。
        let rawMemories: [MemoryStage1Record]
        do {
            rawMemories = try database.getPhase2InputSelection(
                limit: MemoryConstants.maxRawMemoriesForConsolidation,
                maxUnusedDays: MemoryConstants.maxUnusedDays,
                projectKey: projectKey)
        } catch {
            await fail(configuration, reason: "failed_load_stage1_outputs", projectKey: projectKey)
            return "failed_load_stage1_outputs"
        }
        // 10a. 新水位（get_watermark 逐字：max(source_updated_at) ∨ 抢占水位）。
        let newWatermark = rawMemories.map(\.sourceUpdatedAt).max()
            .flatMap { max($0, inputWatermark) }
            ?? inputWatermark

        // 5. 同步输入进工作区。
        do {
            try storage.syncRolloutSummaries(
                rawMemories,
                maxRawMemoriesForConsolidation: rawMemories.count,
                cwdFor: { configuration.cwdFor($0.threadId) })
            try storage.rebuildRawMemoriesFile(
                rawMemories,
                maxRawMemoriesForConsolidation: rawMemories.count,
                cwdFor: { configuration.cwdFor($0.threadId) })
        } catch {
            await fail(configuration, reason: "failed_sync_workspace_inputs", projectKey: projectKey)
            return "failed_sync_workspace_inputs"
        }

        // 6. 变更判定（无变化且工件合法 → 直接成功）。
        let baseline = storage.loadManifest()
        let workspaceDiff = storage.diffAgainstManifest(baseline)
        if !workspaceDiff.hasChanges,
           (try? storage.validateConsolidationArtifacts()) != nil {
            storage.removeWorkspaceDiff()
            do {
                try database.markGlobalPhase2JobSucceeded(
                    completionWatermark: newWatermark,
                    selectedThreadIds: rawMemories.map(\.threadId),
                    projectKey: projectKey)
                try storage.saveManifest(storage.snapshotManifest())
            } catch {
                await fail(configuration, reason: "failed_mark_succeeded", projectKey: projectKey)
                return "failed_mark_succeeded"
            }
            return "succeeded_no_workspace_changes"
        }

        // 7. 落 diff 文件（整合 agent 先读件）。
        do {
            try storage.writeWorkspaceDiff(workspaceDiff)
        } catch {
            await fail(configuration, reason: "failed_workspace_diff_file", projectKey: projectKey)
            return "failed_workspace_diff_file"
        }

        // 8. 生成整合 agent（build_consolidation_prompt——extensions 两占位符
        //    万我恒空串，prompts.rs :49-64 is_dir 分支语义；memory_root 随本轮
        //    桶 guest 路径——批3 C1 项目化）。
        let prompt = MemoryTemplates.render(MemoryTemplates.consolidation, [
            ("memory_root", memoryRootGuestPath ?? MemoryConstants.memoryGuestPath),
            ("memory_extensions_folder_structure", ""),
            ("memory_extensions_primary_inputs", ""),
            ("phase2_workspace_diff_file", MemoryConstants.phase2WorkspaceDiffFilename),
        ])

        // 9. agent 收口（loop_agent/heartbeat 随适配②退役——actor 串行 +
        //    单进程无所有权竞争，runner 返回即收口）。
        let agentCompleted: Bool
        do {
            // M8 批3 C1 缝②（batch3-review 方案 B2）：透传本轮桶 guest 路径
            // （与 prompt memory_root 渲染值 :180 严格同值）——整合子会话 cwd
            // 随桶，项目桶 Phase2 整合读写一致。
            try await configuration.runner(prompt,
                memoryRootGuestPath ?? MemoryConstants.memoryGuestPath)
            agentCompleted = true
        } catch {
            agentCompleted = false
        }
        // 收口先清 diff 工件（prompt 工件不入基线——remove_workspace_diff 语义）。
        storage.removeWorkspaceDiff()

        guard agentCompleted else {
            _ = try? storage.removeMemorySymlinks()
            await fail(configuration, reason: "failed_agent", projectKey: projectKey)
            return "failed_agent"
        }

        // 工件校验（validate_consolidation_artifacts）。
        do {
            try storage.validateConsolidationArtifacts()
        } catch {
            await fail(configuration, reason: "failed_invalid_artifacts", projectKey: projectKey)
            return "failed_invalid_artifacts"
        }

        // 基线重置 + 成功落账（reset_memory_workspace_baseline + job::succeed）。
        do {
            try storage.saveManifest(storage.snapshotManifest())
            try database.markGlobalPhase2JobSucceeded(
                completionWatermark: newWatermark,
                selectedThreadIds: rawMemories.map(\.threadId),
                projectKey: projectKey)
        } catch {
            await fail(configuration, reason: "failed_workspace_commit", projectKey: projectKey)
            return "failed_workspace_commit"
        }
        return "succeeded"
    }

    /// job::failed 1:1（单进程无 ownership 复核面——mark_..._if_unowned 随
    /// 适配②退役，账本头注登记；任务键随项目身份键）。
    private func fail(_ configuration: Configuration, reason: String,
                      projectKey: String?) async {
        try? database.markGlobalPhase2JobFailed(
            reason: reason,
            retryDelaySeconds: MemoryConstants.jobRetryDelaySeconds,
            jobKey: MemoryDatabase.phase2JobKey(forProjectKey: projectKey))
    }
}

// MARK: - 尾回合收口闸（AppEnvironment runner 装配消费）

/// 整合子会话收口闸（agent::handle 的 loop_agent 终态判定万我承载）：
/// onTurnEnd 信号到达时复核事件流——刚收束的回合内无 tool/call 即「agent
/// 自然终止」（AgentStatus::Completed 等价），放行 wait()。
final class MemoryTurnCompletionGate: @unchecked Sendable {
    private let writer: SessionWriter
    private let condition = NSCondition()
    private var finished = false

    init(writer: SessionWriter) {
        self.writer = writer
    }

    /// 尾回合判定（回合边界取本回合 turn/start…turn/end 窗口内 tool/call）。
    func evaluateAndSignalIfFinal() {
        let events = writer.events
        guard let lastEnd = events.last(where: { event in
            if case .turnEnd = event.payload { return true }
            return false
        }) else { return }
        guard case .turnEnd(let turn, _) = lastEnd.payload else { return }
        guard let lastStart = events.last(where: { event in
            if case .turnStart(let startTurn) = event.payload { return startTurn == turn }
            return false
        }) else { return }
        let hadToolCall = events[(lastStart.seq + 1)..<max(lastEnd.seq, lastStart.seq + 1)]
            .contains { event in
                if case .toolCall = event.payload { return true }
                return false
            }
        if !hadToolCall { signalFinish() }
    }

    /// 等待终态（finish 先于 wait 的竞态由 finished 旗标承接；QA-5 P2-②：
    /// 超时兜底 = codex status_poll 等价——AgentLoop 异常路径不发 onTurnEnd
    /// 时防调用方永挂 → 触发器整进程单飞死锁；调用方超时分支 = failed_agent
    /// 语义进重试窗）。
    /// - Parameter timeout: 收口等待上限（MemoryConstants.consolidationWaitTimeout
    /// Seconds 拍板档 900s）。
    /// - Returns: true = 收口信号已达；false = 超时兜底放行。
    @discardableResult
    func wait(timeout: TimeInterval = MemoryConstants.consolidationWaitTimeoutSeconds)
        async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // NSCondition.wait(until:) 为阻塞原语——脱协作线程池到 utility 队列
        // 等待（上限 = timeout 兜底，不占死 Swift 并发执行器）。
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                condition.lock()
                while !finished {
                    // 虚假唤醒重等；到点未放行 → 超时返回 false。
                    if !condition.wait(until: deadline) { break }
                }
                let result = finished
                condition.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    private func signalFinish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
