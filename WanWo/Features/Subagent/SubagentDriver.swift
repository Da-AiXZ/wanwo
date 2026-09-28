//
//  SubagentDriver.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 C · F045】出处（packages/subagent/
//  subagent-in-process-driver/src/index.ts 全文 239 行逐段对拍）：
//    - startInProcessRun :104-152 —— 创建事务（makeChild）→ drivePublishedRun
//      （prompt 投递 → whenIdle → readResult）。
//    - toStopReason :50-67 —— 回合终因 → stopReason 词汇（blocked=refusal；
//      error/interrupted/无=error；未知按 error 不夸大成功）。
//    - prePublicationAbort :76-78 —— 发布前取消 = 定型错误。
//    - drivePublishedRun :158-209 —— signal abort → child.cancel(parent)；
//      dispose 幂等；取消旗标在 readResult 把非 completed 记录改写为 aborted。
//    - readResult :212-238 —— activation boundary（seed 长度）后事件流读终局：
//      foldConsumedWork.end 的 turn/end reason + finalAssistantOutput。
//
//  万我适配裁定（登记）：
//    - dsh agents.create（发布事务 + seed 落盘 + composition）→ WanWo
//      ChildStackFactory 缝（AppEnvironment 装配：SessionStore 建子会话 +
//      lineage/descriptor 事件 + 种子批量写 + makeAgentStack 全栈复用）。
//    - signal：dsh AbortSignal → WanWo Task 取消 + dispose 通道（ SubagentRun
//      持 cancelled 旗标；dispose 即取消语义，tool-subagent 前台路径 dispose
//      在结算后调用不触发取消，与 dsh「dispose 在 result 之后」时序一致）。
//    - 子纪律声明（child-agent.ts:171-175）由 ChildStackFactory 侧以 prompt
//      段落注入（子会话 system 面），不在 driver 内——dsh applyChildComposition
//      同为 composition 职责。
//

import Foundation

// MARK: - 子栈工厂缝（dsh agents.create 的 WanWo 承载）

/// 创建并发布一个子 agent 栈（ChildStackFactory：dsh agents.create 事务的
/// WanWo 等价——未发布段的 setup 与 rollback 归装配侧；返回的 loop 即
/// quiescent lifecycle owner）。
typealias SubagentChildStackFactory = @Sendable (
    _ resolved: SubagentResolvedRequest,
    _ seed: [SessionEvent]?
) async throws -> (loop: AgentLoop, writer: SessionWriter)

// MARK: - in-process driver（index.ts 1:1）

/// Shared driver for in-process ONE-SHOT subagent providers。Continuable
/// children never come through here: the continuation manager (SubagentRuntime
/// startContinuable) composes and drives them directly——本 driver 恰好拥有
/// 一个 turn 与一个 result（index.ts:7-12 头注语义）。
enum SubagentInProcessDriver {
    /// 回合终因 → stop reason 词汇（index.ts:50-67 toStopReason 1:1）。
    static func toStopReason(_ reason: TurnEndReason?) -> SubagentStopReason {
        switch reason {
        case .completed:
            return .completed
        case .maxTokens:
            return .maxTokens
        case .aborted:
            return .aborted
        // A pre-step rejection discarded the claimed prompt: the task was
        // declined, and the caller must not read the run as done.
        case .blocked:
            return .refusal
        case .error, .interrupted, .none:
            return .error
        }
    }

    /// Establish and drive one in-process one-shot child（index.ts:104-152 +
    /// :158-209 + :212-238 合并 WanWo 形态）。Rejection = 创建事务未发布。
    static func startInProcessRun(
        request: SubagentResolvedRequest,
        seed: [SessionEvent]?,
        makeChild: SubagentChildStackFactory
    ) async throws -> SubagentRun {
        let flags = RunFlags()
        if flags.cancelled {
            // 取消胜过发布边界（prePublicationAbort :76-78）。
            throw SubagentError(
                message: "subagent request was aborted before child publication")
        }
        let child = try await makeChild(request, seed)
        // QA-3 P0-2 修正：boundary 不由 seed.count 推导——子栈创建窗口
        // （lineage/descriptor/种子批量写）之后、driver followup 之前的实际
        // eventCount 即自有事件起点。seed.count 推导会把子栈创建期追加的
        // lineage/descriptor 事件算进"父日志"，使 readResult 漏进父日志尾部
        // （被 kill 的 fork 假 completed / 父文本冒充子输出）。
        // （dsh activationBoundary = SessionLogOffset(seed?.length ?? 0) 成立
        // 的前提是 seed 由 agents.create 原子落盘——万我创建窗口多追加两事件，
        // 等价偏移须取实际值，登记。）
        let boundary = child.writer.eventCount
        return drivePublishedRun(loop: child.loop, writer: child.writer,
                                 request: request, boundary: boundary, flags: flags)
    }

    /// 取消旗标（index.ts:167 flags cancelled 的 WanWo 形态）。
    final class RunFlags: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledStorage = false
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return cancelledStorage }
            set { lock.lock(); cancelledStorage = newValue; lock.unlock() }
        }
    }

    /// Wrap a published child in the single run lifecycle（index.ts:158-209 1:1）。
    private static func drivePublishedRun(
        loop: AgentLoop,
        writer: SessionWriter,
        request: SubagentResolvedRequest,
        boundary: Int,
        flags: RunFlags
    ) -> SubagentRun {
        let childId = request.childId
        let prompt = request.request.prompt
        let resultTask = Task<SubagentResult, Error> {
            if !flags.cancelled {
                // Prompt 投递（createUserMessage source user 的 followup 通道；
                // 独立回合——dsh child.followup 同 API 形态）。
                await loop.followup(prompt)
                // dsh child.whenIdle()：驱动循环消费完队列即返回。
                await loop.whenIdle()
            }
            return readResult(Array(writer.events.dropFirst(boundary)),
                              cancelled: flags.cancelled)
        }

        return SubagentRun(id: childId, result: resultTask) {
            flags.cancelled = true
            // dispose = signal abort 语义（onAbort :168-172：child.cancel
            // parent；幂等由 SubagentRun.dispose 承载）。
            await loop.cancel(cause: .parent)
            _ = try? await resultTask.value
        }
    }

    /// Read one settled child's result from its OWN events（index.ts:212-238
    /// 1:1；QA-3 P0-2 拆分为纯函数吃自有事件数组——boundary 语义 =
    /// "child.writer.events 自 boundary 起为自有事件"，单测可对拍栈序组合）。
    static func readResult(_ own: [SessionEvent], cancelled: Bool) -> SubagentResult {
        // 最后一条 turn/end 的 reason（foldConsumedWork().end 等价——折叠
        // 消费面的最后一个回合终因）。`droppedUnrun` 刻意不读：取消无会计
        // 回合经 toStopReason(nil) 归 error，绝不夸大成功（:221-224 注释）。
        let lastEnd: TurnEndReason? = own.reversed().lazy.compactMap { event in
            if case .turnEnd(_, let reason) = event.payload { return reason }
            return nil
        }.first
        let output = SubagentOutput.finalAssistantOutput(own) ?? ""
        let recorded = toStopReason(lastEnd)
        // Disposal 可以先于常规 aborted 收尾拆掉 owner（:229-230）——取消旗标
        // 把非 completed 记录改写为 aborted。
        let stopReason: SubagentStopReason =
            (cancelled && recorded != .completed) ? .aborted : recorded
        return SubagentResult(output: output, structured: nil,
                              diagnostic: nil, stopReason: stopReason)
    }
}
