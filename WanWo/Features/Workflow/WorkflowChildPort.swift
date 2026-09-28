//
//  WorkflowChildPort.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】子 agent 缝（workflow-worker-thread/
//  src/types.ts:39-94 的 WanWo 无 RPC 形态）：
//    - types.ts:40-49  —— ChildStartRequest{prompt, schema?, provider?, model?}
//      （options 已由运行时侧校验）。
//    - types.ts:56-63  —— ChildResult{output, structured?, stopReason: string}
//      （stopReason 闭集可扩展降级 string；运行时只分支 'completed'）。
//    - types.ts:69-80  —— ChildHandle{id, result（只在宿主上报基础设施故障时
//      reject——子自身失败 resolve 非 completed）, dispose()}。
//    - types.ts:86-94  —— ChildPort.startAgent（同步启动/provider 异步启动
//      失败即 reject）。
//
//  万我适配裁定（登记）：
//    - 无 worker RPC（已定适配②）：ChildPort/ChildHandle 即进程内直连——
//      协议层省略，钩子宿主回调。ChildHandle = SubagentRun 的投影包装
//      （dispose 幂等语义 1:1 保留）。
//    - dsh startChild 经 subagents.start 传 outputSchema + agentOptions
//      （host.ts:355-368）——QA-7 缝①起 outputSchema 正式落地透传
//      （SubagentStartRequest.outputSchema → SubagentInProcessDriver.readResult
//      解析+校验）；provider/model 仍接受但丢弃（M7.2 登记）。
//    - child label：dsh start 不传 label（label 只是 agent info 显示字段，
//      host.ts:355-368 无 label 实证）——WanWo 传 nil 同语义。
//

import Foundation

// MARK: - 缝词汇（types.ts:39-94）

/// What the runtime asks the host to start for one `agent()` call
///（options already validated runtime-side）。
struct WorkflowChildStart: Sendable {
    /// The child's prompt text.
    var prompt: String
    /// The structured-output schema, if the call passed one（subset-checked）。
    var schema: JSONValue?
    /// The per-child provider override, if the call passed one.
    var provider: String?
    /// The per-child model override, if the call passed one.
    var model: String?
}

/// The JSON projection of a child's `SubagentResult`（stopReason 闭集可扩展
/// 降级 string——运行时只分支 'completed'）。
struct WorkflowChildResult: Equatable, Sendable {
    /// The child's final assistant output（WanWo 文本面）。
    var output: String
    /// The structured value, present iff the request carried a schema AND the
    /// provider honored it.
    var structured: JSONValue?
    /// Why the child run ended.
    var stopReason: String
}

/// The worker-side handle for one started child——the seam's run handle
/// reduced to what the runtime consumes（result 只在基础设施故障时 throw）。
final class WorkflowChildHandle: @unchecked Sendable {
    /// The child agent's id（subagent seam 铸造）。
    let id: String
    /// The child's terminal result；throw = 基础设施故障（宿主上报面）。
    let result: Task<WorkflowChildResult, Error>

    private let lock = NSLock()
    private var disposed = false
    private let disposeBody: @Sendable () async -> Void

    init(id: String, result: Task<WorkflowChildResult, Error>,
         dispose: @escaping @Sendable () async -> Void) {
        self.id = id
        self.result = result
        self.disposeBody = dispose
    }

    /// Ask the host to dispose the child。幂等（SubagentRun.dispose 同契约）。
    func dispose() async {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        lock.unlock()
        await disposeBody()
    }
}

/// The port the runtime starts child agents through——the seam that keeps the
/// execution core ignorant of the transport（无 RPC 形态：进程内直连）。
protocol WorkflowChildPort: Sendable {
    /// Start one child agent（the `agent()` hook's start half）。
    /// - Returns: the published child handle.
    /// - Throws: when synchronous start or the provider's asynchronous start fails.
    func startAgent(_ request: WorkflowChildStart) async throws -> WorkflowChildHandle
}

// MARK: - 生产适配器（host.ts:352-415 startChild 的 SubagentRuntime 直连形态）

/// SubagentRuntime 公开缝适配器（start/dispense；批2 缝：start + SubagentRun.
/// dispose——禁改 runtime 本体，本适配器为唯一生产实现）。每次 run 构造一枚
/// （携带父会话快照）。
final class SubagentRuntimeChildPort: WorkflowChildPort {
    private let runtime: SubagentRuntime
    /// The provider children run on（engine config / run override 解析产物）。
    private let provider: String
    /// 父会话快照（归属/深度/cwd）。
    private let parent: WorkflowParent

    init(runtime: SubagentRuntime, provider: String, parent: WorkflowParent) {
        self.runtime = runtime
        self.provider = provider
        self.parent = parent
    }

    func startAgent(_ request: WorkflowChildStart) async throws -> WorkflowChildHandle {
        // host.ts:355-368 1:1 面：prompt + schema + provider/model——schema
        // 经 QA-7 缝①透传（SubagentStartRequest.outputSchema → driver 侧
        // 解析+校验）；provider/model 仍接受但丢弃（per-child 路由缝缺，
        // M7.2 登记）。
        let run = try await runtime.start(provider: provider, request: SubagentStartRequest(
            label: nil,
            prompt: request.prompt,
            parentSessionId: parent.sessionId,
            parentCwd: parent.cwd,
            parentDepth: parent.depth,
            outputSchema: request.schema))
        return WorkflowChildHandle(
            id: run.id,
            result: Task<WorkflowChildResult, Error> {
                let settled = try await run.result.value
                return WorkflowChildResult(
                    output: settled.output,
                    structured: settled.structured,
                    stopReason: settled.stopReason.wireName)
            },
            dispose: { [run] in
                await run.dispose()
            })
    }
}
