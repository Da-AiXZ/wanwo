//
//  WorkflowRunHandle.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】宿主侧一次 run 的控制面（workflow-
//  worker-thread/src/host.ts WorkerRun 的无 RPC 形态）：
//    - host.ts:105-172   —— 构造/输入 signal（万我：取消由 holder 的 cancel()
//      直调承载，无 AbortSignal——ToolExecutionContext 无 signal 缝，登记）。
//    - host.ts:183-207   —— cancel（幂等；首个 reason 胜；settled 后 no-op 防
//      "每个已完成 run 一次有界泄漏"；abort 共享子 signal + 宽限定时器：
//      disposeGraceMs 后仍 unsettled → force-settle cancelled + 弃 context）。
//    - host.ts:224-255   —— dispose（cancel + 立即驱动全部已登记子 disposal +
//      有界等待 result/子 quiescence ≤ grace + 弃 context；幂等）。
//    - host.ts:563-585   —— endAgent 单一配对闸（start 仍在账本才转发 end——
//      每个 agent-start 恰好一个 agent-end）+ endStrandedAgents（已启动未配对
//      的全部合成 outcome 'cancelled'——worker 不能说话的路径：宽限强结算/
//      死亡/退出；万我的死亡面 = 强结算路径，登记）。
//    - host.ts:477-487   —— reapChildren/abortChildren（cancel reason 复用）。
//
//  万我适配裁定（登记）：
//    - agentsStarted 全路径取 execution 的脚本侧计数（进程内直连——dsh 终止
//      路径"host-observed 计数"的退化场景不存在：队列中的 agent() 调用对
//      宿主同样可见，登记）。
//    - 强杀面 = 弃 context（JSContextGroupSetExecutionTimeLimit 已由 Watchdog
//      承载同步片；parked-on-foreign-promise 的脚本由宽限定时器 force-settle
//      ——JCore 无 worker.terminate 等价，挂死队列线程不可回收，登记）。
//    - narration 抑制（host.ts:281-291）：cancel 后 phase/log 不再前进观察者
//      ——取消后无事可叙述。
//

import Foundation

/// Holder-owned live workflow。`result` 永不 reject；消费方可 cancel 并必须
/// 调用幂等 dispose() 以等待脚本与子的有界收敛（runtime-types.ts:40-49）。
final class WorkflowRunHandle: @unchecked Sendable {

    /// The run's id.
    let id: String
    /// The validated meta block（脚本 body 运行前即可用）。
    let meta: WorkflowMeta

    /// Settles exactly once with the run's outcome；never rejects。
    lazy var result: Task<WorkflowResult, Never> = Task { [execution] in
        await execution.awaitTerminal()
    }

    /// 执行核心（强持有；handle 生命周期 = run 生命周期）。
    private let execution: WorkflowExecution
    /// 引擎事件发射缝（containment 在引擎侧）。
    private let emit: @Sendable (WorkflowEventName, WorkflowEventDetail) -> Void
    /// 宽限毫秒（disposeGraceMs）。
    private let disposeGraceMs: Double

    // MARK: 状态（cancel/settle/账本一把锁——dsh 同族字段合并面）

    private let lock = NSLock()
    private var cancelReason: String?
    private var settled = false
    /// Result/宽限强结算原子胜出标志（teardown 回调再入 cancel 前认领）。
    private var terminalClaimed = false
    private var graceTimer: DispatchSourceTimer?
    /// Started-but-not-ended agents by seq——宿主保证的配对账本。
    private var liveAgents: [Int: WorkflowAgentInfo] = [:]
    /// 已登记子（callId/seq → handle）；entry 只在 disposal 结算后离开。
    private var children: [Int: WorkflowChildHandle] = []
    /// 子 quiescence 等待者（children 清空时释放）。
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var disposed = false

    init(id: String, meta: WorkflowMeta, execution: WorkflowExecution,
         emit: @escaping @Sendable (WorkflowEventName, WorkflowEventDetail) -> Void,
         disposeGraceMs: Double) {
        self.id = id
        self.meta = meta
        self.execution = execution
        self.emit = emit
        self.disposeGraceMs = disposeGraceMs
    }

    // MARK: 观察者面（execution → handle → 引擎事件）

    /// 结算登记（result 结算后调用——此后 cancel/宽限臂 no-op 化，
    /// host.ts:184-190 "settled 后 cancel no-op" 契约面）。
    func markSettled() {
        lock.lock()
        settled = true
        lock.unlock()
    }

    /// agent-start 登记闸（host.ts:292-295）：入账本 + 发射事件。
    func observerAgentStart(_ info: WorkflowAgentInfo) {
        lock.lock()
        liveAgents[info.seq] = info
        lock.unlock()
        emit(.agentStart, .agent(info))
    }

    /// agent-end 配对闸（host.ts:563-567）：start 仍无配对才转发——每个
    /// agent-start 恰好一个 agent-end（全部停止路径）。
    func observerAgentEnd(_ end: WorkflowAgentEndInfo) {
        lock.lock()
        let paired = liveAgents.removeValue(forKey: end.seq) != nil
        lock.unlock()
        guard paired else { return }
        emit(.agentEnd, .agentEnd(end))
    }

    /// phase 叙述（cancel 后抑制——host.ts:287）。
    func observerPhase(_ title: String) {
        lock.lock()
        let suppressed = cancelReason != nil
        lock.unlock()
        guard !suppressed else { return }
        emit(.phase, .title(title))
    }

    /// log 叙述（cancel 后抑制——host.ts:290）。
    func observerLog(_ message: String) {
        lock.lock()
        let suppressed = cancelReason != nil
        lock.unlock()
        guard !suppressed else { return }
        emit(.log, .message(message))
    }

    // MARK: 子登记（execution 的 agent() 路径回写——cancel 善后的账面）

    func registerChild(seq: Int, child: WorkflowChildHandle) {
        lock.lock()
        children[seq] = child
        lock.unlock()
    }

    func removeChild(seq: Int) {
        lock.lock()
        children.removeValue(forKey: seq)
        let empty = children.isEmpty
        let waiters = quiescenceWaiters
        if empty { quiescenceWaiters = [] }
        lock.unlock()
        if empty {
            for waiter in waiters { waiter.resume() }
        }
    }

    // MARK: cancel（host.ts:183-207 1:1）

    /// Cancel the run and its children：钩子面开始抛 CANCELLED（脚本死在
    /// 下一个 await）+ 已登记子统一 disposal + 宽限定时器武装：仍 unsettled
    /// 的 run 在 disposeGraceMs 后 force-settle `cancelled` 并弃 context。
    /// 幂等；首个 reason 胜；settled 后 no-op（防"已完成 run 一次有界泄漏"
    /// ——host.ts:184-190 注释语义）。
    func cancel(_ reason: String? = nil) {
        lock.lock()
        if settled || terminalClaimed || cancelReason != nil {
            lock.unlock()
            return
        }
        let reason = reason ?? "workflow cancelled"
        cancelReason = reason
        lock.unlock()

        execution.cancel(reason: reason)
        reapChildren(reason)
        armGraceTimer(reason)
    }

    private func armGraceTimer(_ reason: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + disposeGraceMs / 1000.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.forceSettleCancelled(reason: reason)
        }
        timer.resume()
        lock.lock()
        graceTimer = timer
        lock.unlock()
    }

    /// 宽限到期：认领终局边界 → 合成全部未配对 agent-end（'cancelled'，先于
    /// workflow/end——host.ts:194-204 时序）→ force-settle cancelled → 弃
    /// context（JCore 无 terminate 的兜底）。
    private func forceSettleCancelled(reason: String) {
        lock.lock()
        if settled || cancelReason == nil {
            // Result 先到（grace 未参与竞争）或 cancel 已被 forget——no-op。
            lock.unlock()
            return
        }
        terminalClaimed = true
        lock.unlock()
        endStrandedAgents()
        execution.settleTerminal(WorkflowResult(
            value: .null, stopReason: .cancelled,
            error: "workflow run cancelled: \(reason)",
            agentsStarted: execution.startedCountForHost()))
        execution.abandonContext()
    }

    // MARK: 子善后（host.ts:441-487）

    /// Abort + dispose 每个已登记子（cancel/teardown 面；disposal 包含不等待
    /// ——登记项在结算后离开 registry）。
    private func reapChildren(_ reason: String) {
        lock.lock()
        let entries = children
        lock.unlock()
        for (seq, child) in entries {
            Task { [weak self] in
                await child.dispose()
                self?.removeChild(seq: seq)
            }
        }
    }

    /// Resolves once every registered child has reached quiescence。
    func childQuiescence() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if children.isEmpty {
                lock.unlock()
                continuation.resume()
                return
            }
            quiescenceWaiters.append(continuation)
            lock.unlock()
        }
    }

    // MARK: dispose（host.ts:224-255 1:1）

    /// Cancel + bounded settle + 弃 context。宿主驱动每个已登记子的 disposal
    /// **立即**（幂等 join runtime 自身的 finally-disposal），等待（至多 grace）
    /// result 与子 quiescence，然后弃 context。幂等；全路径安全。
    func dispose() async {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        lock.unlock()

        cancel("workflow disposed")
        // 已 settled 的 run 也要收割存留子（cancel 已 no-op——disposal 仍归
        // dispose 所有；host.ts:236-239 同语义）。
        reapChildren("workflow disposed")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(continuation)
            Task { [weak self] in
                guard let self else { once.finish(); return }
                await self.result.value
                await self.childQuiescence()
                once.finish()
            }
            Task { [weak self] in
                let graceMs = self?.disposeGraceMs ?? 5000
                try? await Task.sleep(nanoseconds: UInt64(graceMs * 1_000_000))
                once.finish()
            }
        }
        execution.abandonContext()
    }

    /// 合成全部已启动未配对 agent 的 agent-end（outcome 'cancelled'）——
    /// worker 不能说话的路径（宽限强结算；host.ts:581-585）。
    private func endStrandedAgents() {
        lock.lock()
        let stranded = Array(liveAgents.values)
        lock.unlock()
        for info in stranded {
            observerAgentEnd(WorkflowAgentEndInfo(info: info, outcome: .cancelled))
        }
    }
}

/// 一次性续体包装（dispose 的 result/quiescence 与 grace 双臂竞速）。
final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume()
    }
}
