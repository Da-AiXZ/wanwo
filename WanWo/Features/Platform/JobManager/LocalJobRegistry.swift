//
//  LocalJobRegistry.swift
//  WanWo
//
//  【M5-A 批 J2 · 后台作业本地实现】出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/jobs/jobs-local/src/index.ts（534 行全文）：
//    - :131-190 start preflight 序（servesOwner→label→outputLimit→并发上限
//      →run()→注册→notifyChanged；run 抛错=什么都不注册）
//    - :192-228 list/get/read/kill（owner 围栏 :356-360、终态读取标
//      reported :211、kill 先 cancel 后 stopping+reported :222-227）
//    - :230-279 wait（waiters 计数 + waitResolvers；超时返回快照不抛；
//      caller 取消仅 live 时抛 'wait aborted'；结算胜出）
//    - :416-440 settle first-wins 铁律：先写终态记录 → 释放全部 waiter →
//      markSettled → notifyChanged → 最后 listeners（reporter 可能同步开
//      模型回合——必须最后）
//    - :481-500 disposeAll（listenersClosed 先置、cancel 'jobs service
//      disposed'、await settled、清 store、逐 owner notifyChanged）
//    - :507-531 cancelForTeardown（teardown cancel 标 reported——无读者）
//  WanWo 形态裁定（派单批准）：final class + NSLock（J1 裁定延续）；单层
//  controller 集合（ScopedLayers 不做）；owner cleanup 缩为 service
//  disposeAll（WanWo 无 agent 生命周期服务——差异登记；会话级清理由会话
//  关闭时显式调）；JobHooks.cancel 非抛（Swift 闭包形态）→ teardown
//  强置 failed 分支不可达（结构保留）。
//

import Foundation

/// 注册表业务错误（dsh 逐字文案经 message 承载；localizedDescription 直出）。
struct JobRegistryError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 进程本地作业注册表（dsh `@deepseek-ai/dsh-jobs-local` 对应）。全部记录
/// 在内存，发放全新快照、绝不外借活状态（index.ts:1-4 头注语义）。
///
/// 并发模型：dsh 靠 JS 事件循环单线程原子；WanWo 以一把 NSLock 复刻同序
/// ——所有读改写临界区内完成，listener/notifyChanged 一律在锁外调用
/// （被包含语义：观察者不能破坏已发生的生命周期提交，index.ts:394-397）。
public final class LocalJobRegistry: JobRegistryProtocol, @unchecked Sendable {

    /// 单 owner（或 unowned 共享桶）默认活跃作业上限（index.ts:28）。
    public static let defaultMaxConcurrentJobsPerOwner = 10

    private static let logger = AppLogger(category: "job-registry")

    /// index.ts:31-37 Config.maxConcurrentJobsPerOwner（schemastery 缺省 10
    /// → 构造参数缺省；z.number().min(1) → init 断言）。
    private let maxConcurrentJobsPerOwner: Int

    private let lock = NSLock()
    /// 活跃记录（插入序 = 注册序，list 语义 index.ts:192-197）。
    private var jobs: [String: TrackedTask] = [:]
    /// 每 kind 正序数（index.ts:103/:151-153）。
    private var counters: [String: Int] = [:]
    /// 单层 controller 挂接计数（dsh ScopedLayers 全局层等价——存在即服务
    /// 全部 owner，index.ts:315-319 的单层退化）。
    private var controllerCount = 0
    /// listener 持 UUID token（匿名条目语义——disposer 摘除靠 token 而非
    /// 闭包身份，dsh AnonymousEntries :76-79 对应）。
    private var doneListeners: [(token: UUID, listener: JobDoneListener)] = []
    private var changedListeners: [(token: UUID, listener: JobsChangedListener)] = []
    /// disposeAll 后 listener 关闭（index.ts:117/:429/:484）。
    private var listenersClosed = false
    /// 完成出队竞态吸收面（WanWo detached 通道专用；见 IshExecutorBridge）。
    var completedDetachedPids: Set<Int32> = []

    /// 注册表可变单作业记录（绝不外借——快照经 snapshotLocked 投影，
    /// index.ts:39-63 TrackedTask 对应）。
    private final class TrackedTask {
        let id: String
        let kind: JobKind
        let label: String
        let outputLimitBytes: Int?
        /// 精确生命周期 owner；session-id 授权由它派生（index.ts:45-46）。
        let ownerSessionId: String?
        let cancel: (String?) -> Void
        let readOutput: (() -> String)?
        var status: JobStatus = .running
        var detail: String?
        var output: String?
        let startedAt: Int64
        var finishedAt: Int64?
        var reported = false
        /// 活跃 wait 计数（settle 据此判 reported，index.ts:59）。
        var waiters = 0
        /// 活跃 wait 的可摘除续体；超时/取消在结算前摘除（index.ts:62）。
        var waitResolvers: [UUID: CheckedContinuation<Void, Error>] = [:]
        /// disposeAll 的 settled 等待者（index.ts:56-58 settled Promise 的
        /// 多等待者展开——Swift 无 broadcast Promise）。
        var settledWaiters: [CheckedContinuation<Void, Never>] = []

        init(id: String, kind: JobKind, label: String, outputLimitBytes: Int?,
             ownerSessionId: String?, cancel: @escaping (String?) -> Void,
             readOutput: (@Sendable () -> String)?, startedAt: Int64) {
            self.id = id
            self.kind = kind
            self.label = label
            self.outputLimitBytes = outputLimitBytes
            self.ownerSessionId = ownerSessionId
            self.cancel = cancel
            self.readOutput = readOutput
            self.startedAt = startedAt
        }
    }

    /// - Parameter maxConcurrentJobsPerOwner: 活跃作业上限（≥1）。
    public init(maxConcurrentJobsPerOwner: Int = LocalJobRegistry.defaultMaxConcurrentJobsPerOwner) {
        precondition(maxConcurrentJobsPerOwner >= 1,
                     "maxConcurrentJobsPerOwner must be >= 1 (dsh z.number().min(1))")
        self.maxConcurrentJobsPerOwner = maxConcurrentJobsPerOwner
    }

    // MARK: - start（index.ts:131-190 preflight 序逐条）

    public func start(_ spec: JobStart) throws -> String {
        lock.lock()

        // 1. servesOwner 门控（index.ts:132-134 文案逐字；单层：controller
        //    存在即服务全部 owner——global 层语义 index.ts:315-317）。
        if controllerCount == 0 {
            lock.unlock()
            throw JobRegistryError(message: "background jobs unavailable: no job controller serves this agent (load @deepseek-ai/dsh-tool-jobs in its composition)")
        }
        // 2. kind 非空校验（index.ts:135）——JobKind 是非空 rawValue 的封闭
        //    enum，空串分支在类型系统下不可能（J1 已登记差异）。
        // 3. label 非空（index.ts:136 文案逐字）。
        if spec.label.isEmpty {
            lock.unlock()
            throw JobRegistryError(message: "invalid job label: expected a non-empty string")
        }
        // 4. outputLimitBytes 正整数（index.ts:137-140 文案逐字）。
        if let limit = spec.outputLimitBytes, limit <= 0 {
            lock.unlock()
            throw JobRegistryError(message: "invalid outputLimitBytes: expected a positive safe integer, got \(limit)")
        }
        // 5. owner cleanup 挂接（index.ts:141 ensureOwnerCleanup）——WanWo
        //    无 agent 生命周期服务，缩为 service disposeAll（差异登记）。
        // 6. 并发上限（index.ts:143-148 文案逐字；按精确 owner 桶计数，
        //    unowned 共享一桶 index.ts:322-328）。
        let active = jobs.values.filter {
            $0.ownerSessionId == spec.ownerSessionId
                && ($0.status == .running || $0.status == .stopping)
        }.count
        if active >= maxConcurrentJobsPerOwner {
            lock.unlock()
            throw JobRegistryError(message: "background job limit reached for this owner (limit: \(maxConcurrentJobsPerOwner)); use job_kill to stop an unneeded job, wait for it to finish, then retry")
        }

        // 7. run()——抛错则什么都不注册（锁内调用：run 是同步非阻塞契约，
        //    dsh ctx.shell.start 同款；序数在 run 之后才消费 index.ts:150-153，
        //    抛错的 start 不耗号）。
        let hooks: JobHooks
        do {
            hooks = try spec.run()
        } catch {
            lock.unlock()
            throw error
        }
        let count = (counters[spec.kind.rawValue] ?? 0) + 1
        counters[spec.kind.rawValue] = count
        let id = "\(spec.kind.rawValue)-\(count)"
        let job = TrackedTask(
            id: id, kind: spec.kind, label: spec.label,
            outputLimitBytes: spec.outputLimitBytes,
            ownerSessionId: spec.ownerSessionId,
            cancel: hooks.cancel, readOutput: hooks.readOutput,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000))
        jobs[id] = job
        lock.unlock()

        // 8. 观察生产者结算（index.ts:178-185：拒绝=生产者契约违约 →
        //    failed，包住使 cleanup 与 waiter 不会悬挂）。
        let observeDone = hooks.done
        Task { [weak self] in
            do {
                let outcome = try await observeDone()
                self?.settle(job, outcome)
            } catch {
                Self.logger.warning("jobs: job \(id) producer done promise rejected (producer contract violation): \(String(describing: error))")
                self?.settle(job, JobOutcome(status: .failed,
                                             detail: String(describing: error)))
            }
        }
        // 9. 注册已完成、此后不可能失败——可见集确实变了（index.ts:186-188）。
        notifyChanged(spec.ownerSessionId)
        return id
    }

    // MARK: - list / get / read / kill（index.ts:192-228）

    public func list(callerSessionId: String?) -> [JobSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values
            .filter { $0.ownerSessionId == nil || $0.ownerSessionId == callerSessionId }
            .map { snapshotLocked($0) }
    }

    public func get(id: String, callerSessionId: String?) throws -> JobSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let job = try expectLocked(id)
        try assertAccessLocked(job, callerSessionId)
        return snapshotLocked(job)
    }

    public func read(id: String, callerSessionId: String?) throws -> JobRead {
        lock.lock()
        defer { lock.unlock() }
        let job = try expectLocked(id)
        try assertAccessLocked(job, callerSessionId)
        // index.ts:208-210：流式=readOutput 增量；仅终态输出=结算前空/
        // 结算后 output（幂等、永不消费）。
        let text: String
        if let readOutput = job.readOutput {
            text = readOutput()
        } else if job.status.isTerminal {
            text = job.output ?? ""
        } else {
            text = ""
        }
        // index.ts:211：终态读取标 reported。
        if job.status.isTerminal { job.reported = true }
        return JobRead(text: text, snapshot: snapshotLocked(job))
    }

    @discardableResult
    public func kill(id: String, callerSessionId: String?, reason: String?) throws -> JobKillResult {
        lock.lock()
        let job: TrackedTask
        do {
            job = try expectLocked(id)
            try assertAccessLocked(job, callerSessionId)
        } catch {
            lock.unlock()
            throw error
        }
        if job.status.isTerminal {
            // index.ts:218-221：已终态→标 reported 返回 already-finished。
            job.reported = true
            lock.unlock()
            return .alreadyFinished
        }
        // index.ts:222-223：先 cancel（抛错原样传播不改状态）——Swift cancel
        // 非抛（差异登记），传播面不存在。
        job.cancel(reason)
        job.status = .stopping
        job.reported = true
        let owner = job.ownerSessionId
        lock.unlock()
        notifyChanged(owner)
        return .requested
    }

    // MARK: - wait（index.ts:230-279 语义逐字）

    public func wait(id: String, timeoutMs: Int64, callerSessionId: String?) async throws -> JobSnapshot {
        // expect + access 先于 timeout 校验（index.ts:231-232 序）。
        lock.lock()
        let job: TrackedTask
        do {
            job = try expectLocked(id)
            try assertAccessLocked(job, callerSessionId)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        // index.ts:233-235 文案逐字。
        guard timeoutMs > 0 else {
            throw JobRegistryError(message: "invalid wait timeout: expected a positive number of milliseconds, got \(timeoutMs)")
        }
        // TASK_WAIT_TIMEOUT 常量在 Swift 无承载面（超时走返回值不抛，
        // caller 取消抛 WaitAborted——两路天然可区分，index.ts:24-25 的
        // 区分目的由类型达成）。
        let waitId = UUID()

        if !job.status.isTerminal {
            // index.ts:236-237：caller 已取消→立刻 'wait aborted'。
            if Task.isCancelled {
                throw JobRegistryError(message: "wait aborted")
            }
            do {
                try await withTaskCancellationHandler(operation: {
                    try await withCheckedThrowingContinuation {
                        (cont: CheckedContinuation<Void, Error>) in
                        // 登记与 waiters 计数必须同临界区：settle 释放
                        // waitResolvers 与本登记若错序，waiter 会悬挂到
                        // 超时（dsh 由事件循环原子性保证，此处显式锁序）。
                        lock.lock()
                        if job.status.isTerminal {
                            // 登记前已结算：终态快照胜出（index.ts:236 短路）。
                            lock.unlock()
                            cont.resume()
                            return
                        }
                        if Task.isCancelled {
                            lock.unlock()
                            cont.resume(throwing: JobRegistryError(message: "wait aborted"))
                            return
                        }
                        job.waiters += 1
                        job.waitResolvers[waitId] = cont
                        lock.unlock()
                        // 有界等待计时器：结算摘除（claim）后本计时器
                        // removeValue 落空，零双 resume。
                        DispatchQueue.global(qos: .utility).asyncAfter(
                            deadline: .now() + .milliseconds(Int(timeoutMs)),
                            execute: DispatchWorkItem { [weak self] in
                                guard let self else { return }
                                self.lock.lock()
                                let claimed = job.waitResolvers.removeValue(forKey: waitId)
                                self.lock.unlock()
                                claimed?.resume()
                            })
                    }
                }, onCancel: { [weak self] in
                    // caller 取消仅在 live 时抛（结算胜出——settle 先清空
                    // waitResolvers 再通知，结算后的取消必然 claim 落空）。
                    guard let self else { return }
                    self.lock.lock()
                    let claimed = job.waitResolvers.removeValue(forKey: waitId)
                    self.lock.unlock()
                    claimed?.resume(throwing: JobRegistryError(message: "wait aborted"))
                })
            } catch {
                // finally uncount（index.ts:273-275）：每次 waiter 退出
                // 自减自己的计数。
                lock.lock()
                job.waiters -= 1
                lock.unlock()
                throw error
            }
            lock.lock()
            job.waiters -= 1
            lock.unlock()
        }

        // index.ts:277-278：结算/超时后返回快照；终态（含本次等待促成的
        // reported 置位）先落账。
        lock.lock()
        if job.status.isTerminal { job.reported = true }
        let snapshot = snapshotLocked(job)
        lock.unlock()
        return snapshot
    }

    // MARK: - listener / controller（index.ts:281-305 单层展开）

    @discardableResult
    public func onJobDone(_ listener: @escaping JobDoneListener) -> () -> Void {
        let token = UUID()
        lock.lock()
        doneListeners.append((token, listener))
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.doneListeners.removeAll { $0.token == token }
            self.lock.unlock()
        }
    }

    @discardableResult
    public func onJobsChanged(_ listener: @escaping JobsChangedListener) -> () -> Void {
        let token = UUID()
        lock.lock()
        changedListeners.append((token, listener))
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.changedListeners.removeAll { $0.token == token }
            self.lock.unlock()
        }
    }

    @discardableResult
    public func attachController(name: String) -> () -> Void {
        // name 仅诊断标签；重名互相独立（index.ts:298）——单层形态连符号
        // 表都不需要，计数即语义。
        lock.lock()
        controllerCount += 1
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.controllerCount -= 1
            self.lock.unlock()
        }
    }

    // MARK: - settle（index.ts:416-440 first-wins 铁律逐序）

    /// 记录首个终态 outcome、释放 waiter、然后宣布完成。first-wins 保住
    /// teardown 强置失败对迟到生产者结算的优先权。有 waiter 的结算在
    /// listeners 之前标 reported。完成通知最后发：reporter 可能同步打开
    /// 模型回合——结算的每个其他观察者必须已看到已提交的记录。
    private func settle(_ job: TrackedTask, _ outcome: JobOutcome) {
        lock.lock()
        // first-wins：迟到结算零效果（index.ts:417）。
        guard !job.status.isTerminal else {
            lock.unlock()
            return
        }
        switch outcome.status {
        case .completed: job.status = .completed
        case .killed: job.status = .killed
        case .failed: job.status = .failed
        }
        job.detail = outcome.detail
        job.output = outcome.output
        job.finishedAt = Int64(Date().timeIntervalSince1970 * 1000)
        // index.ts:422：有 waiter 的结算标 reported。
        if job.waiters > 0 { job.reported = true }
        let snapshot = snapshotLocked(job)
        // ── 释放全部 waiter（index.ts:424-426：先摘除再锁外 resume）──
        let resolvers = Array(job.waitResolvers.values)
        job.waitResolvers.removeAll()
        // ── markSettled（index.ts:427：disposeAll 的等待者放行）──
        let settled = job.settledWaiters
        job.settledWaiters = []
        let owner = job.ownerSessionId
        lock.unlock()
        for resolver in resolvers { resolver.resume() }
        for waiter in settled { waiter.resume() }
        // ── notifyChanged（index.ts:428）──
        notifyChanged(owner)
        // ── listeners 最后（index.ts:429-439）──
        lock.lock()
        let closed = listenersClosed
        let listeners = doneListeners.map(\.listener)
        lock.unlock()
        if closed { return }
        for listener in listeners {
            listener(snapshot, owner)
        }
    }

    // MARK: - 内部面

    /// 查找或响亮失败（index.ts:344-349 文案逐字）。
    private func expectLocked(_ id: String) throws -> TrackedTask {
        guard let job = jobs[id] else {
            throw JobRegistryError(message: "unknown job \(id)")
        }
        return job
    }

    /// 隔离围栏：有 owner 的作业仅 owner session id 相同的 caller 可达
    /// （index.ts:351-360——unowned 开放；无 caller 永不匹配 owned）。
    private func assertAccessLocked(_ job: TrackedTask, _ callerSessionId: String?) throws {
        if let owner = job.ownerSessionId, owner != callerSessionId {
            throw JobRegistryError(message: "job \(job.id) belongs to another session")
        }
    }

    /// 全新只读快照投影（index.ts:362-377——绝不外借活状态）。
    private func snapshotLocked(_ job: TrackedTask) -> JobSnapshot {
        JobSnapshot(
            id: job.id, kind: job.kind, label: job.label,
            outputLimitBytes: job.outputLimitBytes,
            ownerSessionId: job.ownerSessionId,
            status: job.status, detail: job.detail,
            startedAt: job.startedAt, finishedAt: job.finishedAt,
            reported: job.reported)
    }

    /// 可见集变更宣布（index.ts:394-406）。每个 listener 被包含——Swift
    /// 闭包非抛，包含面由「锁外调用」承载（观察者不能破坏已提交的生命周期）。
    private func notifyChanged(_ ownerSessionId: String?) {
        lock.lock()
        let listeners = changedListeners.map(\.listener)
        lock.unlock()
        for listener in listeners {
            listener(ownerSessionId)
        }
    }

    // MARK: - teardown（index.ts:466-531；owner disposal 缩并差异登记）

    /// 等单个作业结算（index.ts:470 `await job.settled` 对应；已终态即刻
    /// 返回）。disposeAll 专用。
    private func awaitSettled(_ job: TrackedTask) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if job.status.isTerminal {
                lock.unlock()
                cont.resume()
                return
            }
            job.settledWaiters.append(cont)
            lock.unlock()
        }
    }

    /// 关闭 listener、取消在飞作业、等结算、清 store、逐 owner 宣布清空
    /// （index.ts:481-500 逐序）。owner disposal 缩并：WanWo 无 agent 生命
    /// 周期服务，teardown 只有 service disposeAll 一面（差异登记）。
    func disposeAll() async {
        lock.lock()
        if listenersClosed { lock.unlock(); return }
        listenersClosed = true
        let all = Array(jobs.values)
        // cancelForTeardown（index.ts:507-531）：teardown 取消=无 caller 的
        // kill，同款标 reported。Swift cancel 非抛——「cancel 抛错强置
        // failed」分支不可达（结构保留于注释，差异登记）。
        var teardownNotified: [String?] = []
        for job in all where !job.status.isTerminal {
            // 该决定先于生产者运行：本路径没有会宣布未上报完成的后路。
            job.reported = true
            job.cancel("jobs service disposed")
            job.status = .stopping
            // 慢停生产者的整段窗口内，这里先宣布 stopping 迁移——观察者
            // 不至于整窗显示 running（index.ts:521-524）。
            teardownNotified.append(job.ownerSessionId)
        }
        lock.unlock()
        for owner in teardownNotified { notifyChanged(owner) }

        // 等全部生产者释放（index.ts:487；不结算的慢停与 dsh 同为可 stall 面）。
        for job in all { await awaitSettled(job) }

        lock.lock()
        // 消失的记录按 owner 去重宣布（index.ts:488-495——移除是唯一无法
        // 由单作业记录承载的可见集变更）。
        let emptied = Set(all.map(\.ownerSessionId))
        jobs.removeAll()
        lock.unlock()
        for owner in emptied { notifyChanged(owner) }
    }

    // MARK: - 诊断/测试面（不属 protocol）

    /// 活跃 waiter 计数镜像（wait 语义测试用：取消后归零→结算不标 reported）。
    public func waiterCount(id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]?.waiters ?? 0
    }
}
