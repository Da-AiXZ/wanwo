//
//  ToolPipeline.swift
//  WanWo
//
//  【语义移植 · dsh · P1-3 审批缝重做】出处：dsh packages/core/tools/src/index.ts
//  （pre-execute waterfall → execute around → post-execute → result 观察 四事件
//  管线；guard 单调否定）+ 10-design §5.3（ToolPipeline F010）+ F037（>50KB
//  大结果 spill 落盘 + locator）。
//  P1-3 重做（对齐 dsh「审批只由提权请求触发」原件语义——dsh 自身无效果分类
//  表、无主动审批判定；approval 只在 sandbox escalation 的 approveEscalation
//  里发生，escalation.ts:173）：
//    1. guard 单调否定（deny 理由即合成错误结果）
//    2. around：ToolTimeout 协作式 deadline（沙箱拒绝/提权审批由工具体内的
//       SandboxGate 承担——read-only/workspace-write 围栏、sandbox_permissions
//       提权、never 短路全部 fail closed）
//    3. post：>50KB 结果 spill 落盘 + locator 替换（F037）
//    4. result 观察：RepeatCallAdviser advisory 附加（F020，只提醒不改变执行）
//  工具体抛错一律合成错误结果（不抛穿 loop，§十三.2）。
//

import Foundation

final class ToolPipeline: @unchecked Sendable {
    let registry: ToolRegistry
    let repeatAdviser: RepeatCallAdviser
    /// spill 阈值（F037：>50KB 落盘）。
    static let spillThresholdBytes = 50_000

    private static let logger = AppLogger(category: "ToolPipeline")

    init(registry: ToolRegistry, repeatAdviser: RepeatCallAdviser) {
        self.registry = registry
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

        // 2. around：协作式 timeout 包住工具体；抛错合成失败结果。
        //    沙箱强制与提权审批在工具体内（SandboxGate）：read-only/workspace-
        //    write 围栏拒绝 → denial marker + hint（isError）；sandbox_permissions
        //    提权 → ApprovalCoordinator 挂起等真人；'never' 政策 → 确定性拒绝。
        //    全部 fail closed：任何异常路径不产生放行。
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

        // 3. post：大结果 spill（F037 >50KB → 落盘 + locator，按引用取回）。
        let postProcessed = await self.applySpill(output, ctx: ctx)

        // 4. result 观察：重复调用 advisory（只提醒，不改变执行结果本身）。
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
