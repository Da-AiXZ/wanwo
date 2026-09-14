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
    /// M4-E E5：hooks Pre/PostToolUse 编排器（nil = 不启用——既有调用面/
    /// 测试不受扰；init 参数默认值保既有调用面）。
    let hookPoints: HookPointRunner?
    /// spill 阈值（F037：>50KB 落盘）。
    static let spillThresholdBytes = 50_000

    private static let logger = AppLogger(category: "ToolPipeline")

    init(registry: ToolRegistry, repeatAdviser: RepeatCallAdviser,
         hookPoints: HookPointRunner? = nil) {
        self.registry = registry
        self.repeatAdviser = repeatAdviser
        self.hookPoints = hookPoints
    }

    /// 执行一笔工具调用（不含事件落盘——tool/call 与 tool/result 由调度器按
    /// model order 落盘；本方法只负责管线本身）。
    /// - Parameter isSubDispatch: run_code SDK 子派发标记（dsh exec.parent !==
    ///   undefined 的 WanWo 调用点形态——index.ts:1208 nested 语义：true 时
    ///   ptc collapse 不生效，子派发可调用任意可见工具）。
    /// - Returns: canonical 结果（成功或合成错误，永不抛）。
    func run(toolName: String, args: JSONValue, ctx: ToolExecutionContext,
             isSubDispatch: Bool = false) async -> ToolOutput {
        // 0. 工具可见性：未注册/hidden → 未知工具失败（dsh UNKNOWN_TOOL）。
        guard let tool = registry.get(toolName), tool.exposure != .hidden else {
            return .failure("unknown tool \"\(toolName)\"", code: "UNKNOWN_TOOL",
                            name: "ToolNotFoundError")
        }

        // 0.1 PTC collapse 拒绝面（dsh index.ts:1363-1369——collapsed 调用
        //     在可扩展政策管线之前确定性终止：pre-execute listeners、审批 ask、
        //     guards 绝不观察——或更糟，放行——一个只可能失败的调用；谓词
        //     !nested && mode === 'ptc' && name !== RUN_CODE_NAME，:1314-1316
        //     同一谓词与提示词宣告段共享，两永不漂移）。文案 = ToolNotFoundError
        //     reachableFrom 形态逐字（index.ts:1429-1432 + :494-501：名字可见、
        //     仅呈现面拒绝 → 拒绝携带模型应走的路线）。
        if !isSubDispatch && registry.presentationMode == .ptc
            && toolName != ToolRegistry.runCodeName {
            return .failure(
                "unknown tool \"\(toolName)\": only `run_code` is callable directly "
                    + "— call `\(toolName)` from inside a `run_code` program instead",
                code: "UNKNOWN_TOOL", name: "ToolNotFoundError")
        }

        // 0.5 M4-E E5：PreToolUse hook（CC index.ts:238-244 / codex :225-231
        //     ——dsh tools/pre-execute 位；UNKNOWN_TOOL 检查后、guard 前）。
        //     matcher subject=toolName。deny→合成错误结果；ask→审批缝挂起等
        //     真人（SandboxGate 提权同通道——escalationApprover 闭包，'never'
        //     与 nil 服务在闭包/守卫内 fail closed）；其余 next（=guard 流程）。
        if let hookPoints {
            let merged = await hookPoints.preToolUse(turn: ctx.turn,
                                                     toolName: toolName,
                                                     args: args,
                                                     callId: ctx.callId)
            switch merged.decision {
            case .deny:
                return .failure(merged.reason ?? "blocked by PreToolUse hook",
                                code: "DENIED_BY_HOOK", name: "HookDeniedError")
            case .ask:
                // CC ask 语义=PreToolDecision.ask → 真人审批（跨桥 merge 后
                // ask 胜出即 ask——裁定②）。allowedOnce → 准入继续 guard；
                // 其余（rejected/cancelled/unavailable）→ 合成错误（hook 请求
                // 的准入被拒=deny 等价，fail closed）。
                guard let approver = ctx.escalationApprover else {
                    return .failure(
                        "hook asks for approval, but no approval service is composed",
                        code: "HOOK_ASK_UNAVAILABLE", name: "HookDeniedError")
                }
                let outcome = await approver(
                    toolName, ctx.callId,
                    merged.reason ?? "PreToolUse hook requested approval")
                guard case .allowedOnce = outcome else {
                    return .failure(
                        "tool use not approved (hook ask): \(outcome.rawValue)",
                        code: "HOOK_ASK_REJECTED", name: "HookDeniedError")
                }
            default:
                break
            }
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

        // 3.5 M4-E E5：PostToolUse hook（CC index.ts:247-265 / codex
        //     :234-253——spill 后 adviser 前：deny 短路 adviser，坏结果不必
        //     再附重复调用提醒）。matcher subject=toolName。deny→结果替换为
        //     isError feedback（CC :252 kind:'block'+feedback）；additional-
        //     Context→并入结果文本（adviser 同款拼接——dsh 以 additional-
        //     Contexts 附在 downstream 决策，WanWo tool/result 是模型可见
        //     最近位，登记差异）。
        var postHooked = postProcessed
        if let hookPoints {
            let merged = await hookPoints.postToolUse(turn: ctx.turn,
                                                      toolName: toolName,
                                                      args: args,
                                                      callId: ctx.callId,
                                                      response: postProcessed.text)
            if merged.decision == .deny {
                return .failure(merged.reason ?? "blocked by PostToolUse hook",
                                code: "DENIED_BY_HOOK", name: "HookDeniedError")
            }
            if !merged.additionalContext.isEmpty {
                postHooked.text += "\n\n"
                    + merged.additionalContext.joined(separator: "\n\n")
            }
        }

        // 4. result 观察：重复调用 advisory（只提醒，不改变执行结果本身）。
        var final = postHooked
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
