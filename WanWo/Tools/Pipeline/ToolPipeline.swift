//
//  ToolPipeline.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/tools/src/index.ts（pre-execute waterfall
//  → execute around → post-execute → result 观察 四事件管线；guard 单调否定；
//  ask → serviceAsk 缺 answerer 即 deny）+ 10-design §5.3（ToolPipeline F010）
//  + F037（>50KB 大结果 spill 落盘 + locator）。
//  管线顺序（一次调用）：
//    1. guard 单调否定（deny 理由即合成错误结果）
//    2. pre-execute 判定 .allow / .deny / .ask（ask → ApprovalSeam，fail closed）
//    3. around：ToolTimeout 协作式 deadline
//    4. post：>50KB 结果 spill 落盘 + locator 替换（F037）
//    5. result 观察：RepeatCallAdviser advisory 附加（F020，只提醒不改变执行）
//  工具体抛错一律合成错误结果（不抛穿 loop，§十三.2）。
//

import Foundation

final class ToolPipeline: @unchecked Sendable {
    let registry: ToolRegistry
    /// M2 = AutoApprovalSeam 占位；M3 换审批卡 answerer（fail closed：nil 即 deny）。
    let approvalSeam: ApprovalSeam?
    let repeatAdviser: RepeatCallAdviser
    /// spill 阈值（F037：>50KB 落盘）。
    static let spillThresholdBytes = 50_000

    private static let logger = AppLogger(category: "ToolPipeline")

    init(registry: ToolRegistry, approvalSeam: ApprovalSeam?, repeatAdviser: RepeatCallAdviser) {
        self.registry = registry
        self.approvalSeam = approvalSeam
        self.repeatAdviser = repeatAdviser
    }

    /// 执行一笔工具调用（不含事件落盘——tool/call 与 tool/result 由调度器按
    /// model order 落盘；本方法只负责管线本身）。
    /// - Returns: canonical 结果（成功或合成错误，永不抛）。
    func run(toolName: String, args: JSONValue, ctx: ToolExecutionContext) async -> ToolOutput {
        // 0. 工具可见性：未注册/hidden → 未知工具失败（dsh UNKNOWN_TOOL）。
        guard let tool = registry.get(toolName), tool.exposure != .hidden else {
            return .failure("unknown tool \"\(toolName)\"", code: "UNKNOWN_TOOL",
                            name: "ToolNotFoundError")
        }

        // 1. guard 单调否定（dsh：guard 在 pre-execute 之后、工具体之前；
        //    只有 deny 结果，后注册 guard 不能翻转先前否定）。
        if let reason = registry.guardReason(name: toolName, args: args) {
            return .failure(reason, code: "DENIED_BY_GUARD", name: "ToolGuardError")
        }

        // 2. pre-execute 判定（M2：无扩展 listener；审批判定按 dsh ask 语义）。
        //    fail closed：seam 缺失 → deny（answerer 缺失即拒，F018）。
        //    【M2 占位】管线恒走 AutoApprovalSeam → allow；真判定 M3 落地。
        if let seam = approvalSeam {
            let verdict = await seam.request(tool: toolName, args: args, reason: nil,
                                             sessionId: ctx.sessionId,
                                             turn: ctx.turn, step: ctx.step)
            if verdict != .allow {
                return .failure("tool call \"\(toolName)\" was not approved",
                                code: "NOT_APPROVED", name: "ApprovalDeniedError")
            }
        } else {
            return .failure("no approval answerer configured; denying by default",
                            code: "NOT_APPROVED", name: "ApprovalDeniedError")
        }

        // 3. around：协作式 timeout 包住工具体；抛错合成失败结果。
        let output = await ToolTimeout.run(timeoutMs: tool.timeoutMs) { [weak self] in
            guard let self else {
                throw LLMError(message: "pipeline released", code: "UNKNOWN")
            }
            do {
                return try await tool.execute(args, ctx)
            } catch {
                return ToolTimeout.failure(from: error)
            }
        }

        // 4. post：大结果 spill（F037 >50KB → 落盘 + locator，按引用取回）。
        let postProcessed = await self.applySpill(output, ctx: ctx)

        // 5. result 观察：重复调用 advisory（只提醒，不改变执行结果本身）。
        var final = postProcessed
        let canonical = Self.canonicalArgsText(args)
        if let advisory = await repeatAdviser.advise(tool: toolName, canonicalArgs: canonical) {
            final.text += "\n\n\(advisory)"
        }
        return final
    }

    /// F037：超过 50KB 的文本结果落盘并替换为 head + locator。
    private func applySpill(_ output: ToolOutput, ctx: ToolExecutionContext) async -> ToolOutput {
        guard !output.isError,
              output.text.utf8.count > Self.spillThresholdBytes else { return output }
        let headBytes = 4_000
        let head = String(output.text.prefix(headBytes))
        let locator = await ctx.spill.spill(output.text, sessionId: ctx.sessionId,
                                            callId: ctx.callId)
        Self.logger.info("tool result spilled (\(output.text.utf8.count) bytes) → \(locator)")
        var replaced = output
        replaced.text = head
            + "\n\n[... output truncated: full result (\(output.text.utf8.count) bytes) spilled to file ...]\n"
            + "[result file: \(locator)] Use shell `cat` on the workspace-mounted path or ask the user to open it."
        return replaced
    }

    /// 参数规范化文本（adviser key；排序键稳定化）。
    static func canonicalArgsText(_ args: JSONValue) -> String {
        switch args {
        case .object(let fields):
            let sorted = fields.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(canonicalArgsText($0.value))" }
            return "{" + sorted.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map { canonicalArgsText($0) }.joined(separator: ",") + "]"
        case .string(let value): return "\"\(value)\""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }
}
