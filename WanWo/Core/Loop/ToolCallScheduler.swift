//
//  ToolCallScheduler.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/agent-loop/src/tool-calls.ts
//  （executeToolCalls：model order 扫描 → 连续 parallel-safe 调用为有界滚动池
//  （maxParallelToolCalls 缺省 10）、exclusive 调用为屏障；abort 时未启动调用
//  记合成错误结果 ABORTED_BEFORE_DISPATCH 保 replay）+ 10-design §5.3 F011。
//  落盘纪律：
//    · tool/call 按 model order 先行落盘（每笔调用的 callId 配对锚点）
//    · tool/result 随完成落盘（SessionWriter gate actor 保证串行追加）
//    · 取消/放弃的调用：tool/call 已在 → 只补合成 tool/result，配对不变量成立
//

import Foundation

// MARK: - 取消旗标（actor 内 cancel() 同步置位；调度器任务轻量读取）

/// 跨并发域的取消旗标（cancel() 在 actor 上同步调用、工具子任务只读——
/// 用 NSLock 而非 actor，避免调度路径上为读一个布尔做 actor hop）。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }
}

// MARK: - 有界池信号量

/// 计数信号量（AsyncSemaphore：parallel 有界滚动池的并发闸）。
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits: Int

    init(_ permits: Int) {
        self.permits = max(1, permits)
    }

    func wait() async {
        lock.lock()
        if permits > 0 {
            permits -= 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            permits += 1
            lock.unlock()
        }
    }
}

// MARK: - 调度器

enum ToolCallScheduler {

    private static let logger = AppLogger(category: "ToolCallScheduler")

    // MARK: 在飞收敛面（真机转圈批 A 修复）

    /// 在飞调用登记（notifyStarted 后、result 落盘前的调用）。锁保护
    /// static 状态；callId 全局唯一（provider 前缀），回合结束整体清空。
    private static let inflightLock = NSLock()
    private static var inflightCallIds: Set<String> = []
    /// 已结算调用（含中断合成）——appendResult 幂等守卫，防中断合成与
    /// 真结果双落（tool/result 配对唯一性）。
    private static var settledCallIds: Set<String> = []

    /// 回合中断时对全部在飞调用收敛：立即落合成 error result + 工具卡
    /// 回调（卡片停转）。真结果晚到的由 settledCallIds 守卫丢弃（M2 注记
    /// 「将以错误结果回注」的实现载体——原缺口=卡片无限转圈）。
    static func convergeInflightOnInterrupt(deps: AgentLoop.Dependencies,
                                            turn: Int, step: Int) {
        inflightLock.lock()
        let ids = Array(inflightCallIds)
        inflightCallIds.removeAll()
        settledCallIds.formUnion(ids)
        inflightLock.unlock()
        guard !ids.isEmpty else { return }
        logger.warning("turn interrupted: converging \(ids.count) inflight tool call(s)")
        let output = ToolOutput.failure(
            "回合被中断：本工具调用未完成，结果未知。",
            code: "TURN_INTERRUPTED", name: "ToolInterruptError")
        // 异步落盘+卡片回调（SessionWriter gate 串行化保证 append 有序；
        // cancel 调用方在 actor 同步段——不阻塞等待）。
        Task {
            for id in ids {
                await appendResult(deps, turn: turn, step: step, callId: id,
                                   output: output)
                deps.callbacks.onToolCallFinished(id, output.text, output.isError)
            }
        }
    }

    /// 回合收尾清理（防 static 集合跨回合无限增长）。
    static func endTurnSweep() {
        inflightLock.lock()
        inflightCallIds.removeAll()
        settledCallIds.removeAll()
        inflightLock.unlock()
    }

    /// 结算登记：返回 true = 首次结算（允许落盘）；false = 已被中断合成
    /// （真结果丢弃——tool/result 配对唯一性）。
    private static func markSettled(_ callId: String) -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        inflightCallIds.remove(callId)
        if settledCallIds.contains(callId) { return false }
        settledCallIds.insert(callId)
        return true
    }

    /// dsh abort 合成结果（未派发即放弃的调用；文本与 dsh 对齐）。
    static func abortedBeforeDispatch() -> ToolOutput {
        .failure("tool call aborted before dispatch", code: "ABORTED_BEFORE_DISPATCH",
                 name: "ToolAbortError")
    }

    /// 执行一批工具调用（model order；结果按完成序落盘，tool/call 恒按 model order）。
    static func executeToolCalls(deps: AgentLoop.Dependencies,
                                 cancelFlag: CancelFlag,
                                 turn: Int,
                                 step: Int,
                                 toolCalls: [ToolCallSpec],
                                 maxParallel: Int) async {
        var index = 0
        while index < toolCalls.count {
            if Task.isCancelled || cancelFlag.isCancelled {
                await synthesize(deps, cancelFlag: cancelFlag, turn: turn, step: step,
                                 calls: Array(toolCalls[index...]))
                return
            }
            let call = toolCalls[index]
            let args = parseArgs(call.arguments)
            if deps.registry.executionMode(name: call.name, args: args) == .exclusive {
                // 屏障：exclusive 调用单独成批，等它完成才继续（dsh exclusive barrier）。
                await runSingle(deps, cancelFlag: cancelFlag, turn: turn, step: step,
                                call: call, args: args)
                index += 1
            } else {
                // 收集连续 parallel-safe 调用为一组（dsh rolling window 分组）。
                var batch: [ToolCallSpec] = []
                while index < toolCalls.count {
                    let candidate = toolCalls[index]
                    let candidateArgs = parseArgs(candidate.arguments)
                    guard deps.registry.executionMode(name: candidate.name,
                                                      args: candidateArgs) == .parallel
                    else { break }
                    batch.append(candidate)
                    index += 1
                }
                await runParallelBatch(deps, cancelFlag: cancelFlag, turn: turn, step: step,
                                       batch: batch, maxParallel: maxParallel)
            }
        }
    }

    // MARK: 结果落盘（ERR-021：失败显式记日志，不再无声吞掉）

    /// tool/result 落盘。SessionWriter 侧已有 pre-write 重试 + gate 串行化；
    /// 此处剩余失败（如 I/O 级）记 error 日志——step 收尾配对校验
    /// （AgentLoop.ensureStepToolResultsPaired）会兜底合成 TOOL_RESULT_LOST，
    /// 配对不变量仍成立。
    private static func appendResult(_ deps: AgentLoop.Dependencies,
                                     turn: Int, step: Int, callId: String,
                                     output: ToolOutput) async {
        do {
            try await deps.writer.append(.toolResult(
                turn: turn, step: step, callId: callId,
                content: output.text, isError: output.isError,
                errorName: output.errorName, errorCode: output.errorCode,
                meta: output.meta))
        } catch {
            logger.error("tool/result append failed for \(callId) "
                + "(will be synthesized at step end): \(String(describing: error))")
        }
    }

    // MARK: 单笔（exclusive 屏障路径）

    private static func runSingle(_ deps: AgentLoop.Dependencies,
                                  cancelFlag: CancelFlag,
                                  turn: Int, step: Int,
                                  call: ToolCallSpec,
                                  args: JSONValue) async {
        let writer = deps.writer
        if Task.isCancelled || cancelFlag.isCancelled {
            await synthesize(deps, cancelFlag: cancelFlag, turn: turn, step: step, calls: [call])
            return
        }
        // tool/call 先行落盘（配对锚点；append 即 durable）。
        _ = try? await writer.append(.toolCall(turn: turn, step: step,
                                               callId: call.id, name: call.name,
                                               arguments: call.arguments))
        notifyStarted(deps, call: call, args: args)
        inflightLock.lock()
        inflightCallIds.insert(call.id)
        inflightLock.unlock()
        let ctx = makeContext(deps, turn: turn, step: step, callId: call.id)
        // 【真机批 B3 删除】调度层硬超时（900s→1200s 两轮形态）经用户裁决移除：
        // 设计文档（10-design）无此机制，属根因未明时期（drain 挂死）的自愈
        // 面——根因已修（drain 泵干），用户裁定回归设计文档纯净度。工具级
        // 超时语义保留：ToolTimeout（dsh tool-call-timeout-policy，per-tool
        // timeoutMs）+ run_code 引擎墙钟（600s）不受影响。
        deps.diagTrace("scheduler: runSingle pipeline.run begin " + call.name)
        let output = await deps.pipeline.run(toolName: call.name, args: args, ctx: ctx)
        deps.diagTrace("scheduler: runSingle pipeline.run returned " + call.name
            + " isError=" + (output.isError ? "1" : "0"))
        guard markSettled(call.id) else { return }   // 中断合成已落，真结果丢弃
        await appendResult(deps, turn: turn, step: step, callId: call.id, output: output)
        deps.diagTrace("scheduler: runSingle result appended " + call.id)
        notifyFinished(deps, callId: call.id, output: output)
        deps.diagTrace("scheduler: runSingle card notified " + call.id)
    }

    // MARK: 有界并行池（dsh rolling window）

    private static func runParallelBatch(_ deps: AgentLoop.Dependencies,
                                         cancelFlag: CancelFlag,
                                         turn: Int, step: Int,
                                         batch: [ToolCallSpec],
                                         maxParallel: Int) async {
        let writer = deps.writer
        // 全批 tool/call 按 model order 先行落盘（replay 完整性：未启动调用也有配对锚点）。
        for call in batch {
            _ = try? await writer.append(.toolCall(turn: turn, step: step,
                                                   callId: call.id, name: call.name,
                                                   arguments: call.arguments))
            notifyStarted(deps, call: call, args: parseArgs(call.arguments))
            inflightLock.lock()
            inflightCallIds.insert(call.id)
            inflightLock.unlock()
        }
        let semaphore = AsyncSemaphore(maxParallel)
        await withTaskGroup(of: Void.self) { group in
            for call in batch {
                group.addTask { [args = parseArgs(call.arguments)] in
                    // 有界池闸：许可即"派发"边界；闸前取消 = 未派发。
                    await semaphore.wait()
                    defer { semaphore.signal() }
                    if Task.isCancelled || cancelFlag.isCancelled {
                        let output = abortedBeforeDispatch()
                        _ = markSettled(call.id)
                        await appendResult(deps, turn: turn, step: step,
                                           callId: call.id, output: output)
                        notifyFinished(deps, callId: call.id, output: output)
                        return
                    }
                    let ctx = makeContext(deps, turn: turn, step: step, callId: call.id)
                    deps.diagTrace("scheduler: batch pipeline.run begin " + call.name)
                    let output = await deps.pipeline.run(toolName: call.name, args: args, ctx: ctx)
                    deps.diagTrace("scheduler: batch pipeline.run returned " + call.name
                        + " isError=" + (output.isError ? "1" : "0"))
                    guard markSettled(call.id) else { return }   // 中断合成已落
                    await appendResult(deps, turn: turn, step: step,
                                       callId: call.id, output: output)
                    notifyFinished(deps, callId: call.id, output: output)
                }
            }
        }
    }

    // MARK: abort 收尾（未启动调用合成错误结果）

    private static func synthesize(_ deps: AgentLoop.Dependencies,
                                   cancelFlag: CancelFlag,
                                   turn: Int, step: Int,
                                   calls: [ToolCallSpec]) async {
        guard !calls.isEmpty else { return }
        let output = abortedBeforeDispatch()
        for call in calls {
            logger.info("synthesizing aborted result for call \(call.id) (\(call.name))")
            await appendResult(deps, turn: turn, step: step, callId: call.id, output: output)
        }
        _ = cancelFlag // 旗标只读；保留参数使调用点语义显式
    }

    // MARK: 工具卡回调（Callbacks 缝：started 在 tool/call 落盘后、finished 在 tool/result 落盘后）

    /// 工具卡活投影（callId, name, arguments 原文, presentCall detail）。
    private static func notifyStarted(_ deps: AgentLoop.Dependencies,
                                      call: ToolCallSpec,
                                      args: JSONValue) {
        let detail = deps.registry.get(call.name)?.presentCall(args)?.detail
        deps.callbacks.onToolCallStarted(call.id, call.name, call.arguments, detail)
    }

    /// 工具卡收敛（callId, 结果文本, isError）。
    private static func notifyFinished(_ deps: AgentLoop.Dependencies,
                                       callId: String,
                                       output: ToolOutput) {
        deps.callbacks.onToolCallFinished(callId, output.text, output.isError)
    }

    // MARK: 上下文构造

    /// 参数解析（畸形 JSON → .null；管线按 unknown 参数处理，不抛穿）。
    static func parseArgs(_ arguments: String) -> JSONValue {
        guard let value = JSONValue(data: Data(arguments.utf8)) else { return .null }
        return value
    }

    /// 工具执行上下文（每笔调用一份：callId 唯一；completeLLM 惰性建 adapter；
    /// P1-3：沙箱模式与提权通道随行——围栏与审批的 per-call 真相）。
    private static func makeContext(_ deps: AgentLoop.Dependencies,
                                    turn: Int, step: Int,
                                    callId: String) -> ToolExecutionContext {
        let workspace = AgentLoop.workspaceAccess(sessionId: deps.sessionId)
        // M4-D D2：write/edit 失效通道②观测缝——变更工具全部落盘经
        // WorkspaceFileAccess.writeAt 成功点回调，前缀判定在 SkillRegistry
        // .noteHostMutation（dsh skills.md:81）。
        if let skillRegistry = deps.skillRegistry {
            workspace.onMutation = { [weak skillRegistry] url in
                skillRegistry?.noteHostMutation(url)
            }
        }
        return ToolExecutionContext(
            sessionId: deps.sessionId,
            turn: turn,
            step: step,
            callId: callId,
            workspace: workspace,
            spill: deps.spill,
            onShellLine: deps.callbacks.onShellLine,
            completeLLM: { prompt, system in
                let adapter = try await deps.makeAdapter()
                return try await Self.complete(adapter: adapter,
                                               prompt: prompt, system: system)
            },
            sandboxMode: deps.sandboxModeProvider(),
            escalationApprover: deps.escalationApprover)
    }

    /// 一次性 LLM 直调（web_search / 摘要类工具缝；M1 只有流式——
    /// 消费流并聚合 text 块即 complete 语义）。
    static func complete(adapter: OpenAICompatAdapter,
                         prompt: String, system: String?) async throws -> String {
        let request = LLMRequest(
            baseURL: adapter.endpoint.baseURL,
            apiKey: adapter.apiKey,
            model: adapter.endpoint.model,
            system: system,
            messages: [ChatMessage(role: .user, content: prompt)])
        var text = ""
        for try await chunk in adapter.stream(request) {
            if case .blockEnd(_, let block) = chunk,
               case .text(let delta) = block {
                text += delta
            }
        }
        return text
    }
}
