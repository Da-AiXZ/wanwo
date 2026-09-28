//
//  SubagentRun.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 C · F045】出处（packages/subagent/ 逐文件对拍）：
//    - subagent/src/types.ts:308-334 —— SubagentRun{id, result, dispose 幂等}。
//    - subagent/src/assistant-output.ts —— finalAssistantOutput：最终 assistant
//      消息的 text 块拼接（canonical selection rule；partial answer 在 cancel/
//      truncation 下存活）。
//    - subagent/src/run-settlement.ts:1-75 —— runOutcome/settleRun 1:1：
//      completed 携带终文本；本地取消（aborted 无 diagnostic）= killed；
//      provider 诊断的远端 abort 与其余全部 reason = failed（不带 partial）。
//    - tool-subagent/src/index.ts:156-195 —— stopReasonError（merge-extensible
//      未知按失败）+ withDiagnosticAndPartialText（diagnostic 与 partial
//      answer 拼进错误行，保持文本分离语义）。
//
//  万我适配裁定（登记）：
//    - result: Promise → Task<SubagentResult, Error>（Sendable 值语义承载）。
//    - output: dsh ContentBlock[] → WanWo 文本（最终 assistant 消息 text 拼接
//      ——同一选择规则的文本面，SubagentTypes 头注同登记）。
//

import Foundation

// MARK: - SubagentRun（types.ts:308-334）

/// ONE-SHOT 运行柄：id + 终局 result + 幂等 dispose。
/// dsh "Dispose must be idempotent"（types.ts:329-334 注释语义）。
final class SubagentRun: @unchecked Sendable {
    /// Child session id（dsh localAgent 形态的 WanWo 等价——运行柄不暴露活
    /// loop，取消经 dispose 通道）。
    let id: String
    /// 终局结果（Promise 等价：Task 值语义；失败即 start/驱动故障）。
    let result: Task<SubagentResult, Error>

    private let lock = NSLock()
    private var disposed = false
    private let disposeBody: @Sendable () async -> Void

    init(id: String, result: Task<SubagentResult, Error>,
         disposeBody: @escaping @Sendable () async -> Void) {
        self.id = id
        self.result = result
        self.disposeBody = disposeBody
    }

    /// Release the child's resources。幂等（首次调用生效，后续 no-op）。
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

// MARK: - 终局输出选择（assistant-output.ts WanWo 文本面）

/// 最终 assistant 消息的 text 拼接（assistant-output.ts canonical selection
/// rule 的文本面：最后一条 assistant/message；无 → nil；partial answer 在
/// cancel/truncation 下存活）。
enum SubagentOutput {
    static func finalAssistantOutput(_ events: [SessionEvent]) -> String? {
        for event in events.reversed() {
            if case .assistantMessage(_, _, let message, _, _) = event.payload {
                let text = message.content.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }.joined()
                // 空 assistant 消息不构成输出（E1 持久纪律同构——空消息不落盘，
                // 此处防御 replay 边界）。
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }
}

// MARK: - run-settlement.ts 1:1

/// ONE-SHOT 运行结算（run-settlement.ts WanWo 形态；仅 one-shot 后台路径用
/// jobs，continuable 子无 Task 无 per-message result——:1-11 头注语义）。
enum SubagentSettlement {
    /// Failed stop reason 渲染（可选 provider-authored detail）。
    private static func failureDetail(_ result: SubagentResult) -> String {
        let stopReason = result.stopReason.wireName
        guard let diagnostic = result.diagnostic else { return stopReason }
        return "\(stopReason); diagnostic: \(diagnostic)"
    }

    /// Map a child result to the task outcome（run-settlement.ts:37-53 1:1）：
    /// completed 携带终文本；本地取消（aborted 无 diagnostic）= killed；
    /// 其余全部 = failed 不带 partial output。
    static func runOutcome(_ result: SubagentResult) -> JobOutcome {
        switch result.stopReason {
        case .completed:
            return JobOutcome(status: .completed, output: result.output)
        case .aborted:
            return result.diagnostic == nil
                ? JobOutcome(status: .killed)
                : JobOutcome(status: .failed, detail: failureDetail(result))
        case .error, .maxTokens, .refusal, .unknown:
            return JobOutcome(status: .failed, detail: failureDetail(result))
        }
    }

    /// Await the child result, dispose the run, then return its task outcome
    ///（run-settlement.ts:61-75 1:1：result 与 dispose 故障都变 failed；
    /// 双故障时两段 detail 都保留）。
    static func settleRun(_ run: SubagentRun) async -> JobOutcome {
        let outcome: JobOutcome
        do {
            outcome = runOutcome(try await run.result.value)
        } catch {
            outcome = JobOutcome(status: .failed, detail: String(describing: error))
        }
        // dispose 幂等且无失败路径（WanWo 形态：log close 容错在
        // SessionWriter.close 内部，登记——dsh dispose 抛错拼接语义退化为
        // 恒成功路径）。
        await run.dispose()
        return outcome
    }

    // MARK: tool-subagent 前台结算助手（index.ts:156-195 1:1）

    /// A non-`completed` stop reason means the child did not finish cleanly
    ///（merge-extensible：未知按失败）。
    static func stopReasonError(_ result: SubagentResult) -> String? {
        switch result.stopReason {
        case .completed:
            return nil
        case .aborted:
            return "subagent run was cancelled"
        case .error:
            return "subagent run failed"
        case .maxTokens:
            return "subagent run hit its token limit before finishing"
        case .refusal:
            return "subagent declined the task"
        case .unknown(let raw):
            return "subagent run ended abnormally (\(raw))"
        }
    }

    /// Append provider-authored failure detail and the child's preserved
    /// partial answer to a stop-reason error（index.ts:183-195 1:1）。
    static func withDiagnosticAndPartialText(_ error: String, _ result: SubagentResult) -> String {
        let diagnostic = result.diagnostic == nil
            ? ""
            : "\nDiagnostic: \(result.diagnostic!)"
        let partial = result.output.isEmpty
            ? ""
            : "\nPartial output before the run ended:\n\(result.output)"
        return "\(error)\(diagnostic)\(partial)"
    }
}
