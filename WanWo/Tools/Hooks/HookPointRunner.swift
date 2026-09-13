//
//  HookPointRunner.swift
//  WanWo
//
//  【M4-E 批 E5 · runPoint 编排（桥无关层）+ 五挂点入口】出处（逐行亲读，
//  file:line 对拍）：
//    - hooks-claude-code/src/index.ts:137-187（runPoint 串行序/事件对/warn 面）
//      + :83 handlerId 格式 `claude-code:${point}:${++n}`
//    - hooks-codex/src/index.ts:113-170（同构 + plainStdoutAsContext :152-156）
//      + :69 handlerId `codex:${point}:${++n}`
//    - CC index.ts:321-346 / Codex index.ts:290-328（方言 payload 构造逐字段）
//  跨桥扩展（WanWo 双桥并存裁定，dsh 单桥无此面）：双桥顺序=固定
//  claude→codex（loader 产出序），两桥 groups[point] 的 hooks 串成一条
//  serial 序列（每 hook 仍按桥的 trailingNewline/matcherMode/stderrSummaryMaxChars
//  执行），全部 outputs 合并进**一次 mergeHookOutputs**——否则 A 桥 deny 会被
//  B 桥无决策稀释（merge 全局 deny>ask>allow，ask 胜出即 ask=CC 桥语义主导，
//  codex 桥无 ask 表达）。事件对 dialect 字段各随其桥（E3 端口消费）。
//  R5 全链 fail open：HookRunner 从不抛（E2）；E3 append async throws 的
//  失败在此 catch+log 继续（dsh append 不抛故无此面——WanWo 语义等价物=
//  吞错+log，hook 审计失败不阻塞主流程）。
//  SessionStart 零事件对锚（E3 文件头注明）：turn=nil → invoked/result 均不落
//  （dsh detached lifecycle points omit the pair，CC index.ts:157/:181 同条件）。
//

import Foundation

// MARK: - 载荷字段集（方言轴构造的输入）

/// 一次挂点触发的上下文字段（全部可选——按 point 取用；方言 payload 在
/// runner 内按桥构造，调用方不感知方言差异）。
struct HookPointPayload: Sendable {
    /// SessionStart 来源（"startup" | "resume"）。
    var source: String?
    /// UserPromptSubmit 的 prompt 文本（blocksToText 等价=消息文本）。
    var prompt: String?
    /// Pre/PostToolUse 的工具名（= matcher subject；payload tool_name 同值）。
    var toolName: String?
    /// CC tool_input：完整 arguments object。
    var toolInput: JSONValue?
    /// Codex tool_input：{command} 折叠（commandOf——args.command 字符串否则 ''）。
    var toolCommand: String?
    /// tool_use_id = tool/call 事件的 callId。
    var toolUseId: String?
    /// PostToolUse 的 tool_response（blocksToText=ToolOutput.text）。
    var toolResponse: String?
}

// MARK: - 编排层

/// 五挂点编排器（每会话一份，装配期构造；桥无关——双桥 runtime 数组驱动）。
/// 持有 writer（E3 事件对落盘）；executor 经注入（生产 IshHookCommandExecutor /
/// 测试桩）。全部入口 total：不抛、不阻塞主流程（R5）。
final class HookPointRunner: @unchecked Sendable {
    private static let logger = AppLogger(category: "hook-points")

    let sessionId: String
    private let writer: SessionWriter
    /// 双桥 runtime（固定 claude→codex 序——构造时显式排序）。
    private let runtimes: [HookBridgeRuntime]
    private let executor: HookCommandExecuting
    /// 会话工作区（guest 视角；hooks 执行 cwd + payload cwd 字段）。
    private let cwd: String

    /// handlerId 计数器（dsh 每桥一枚举全局计数——跨 point 共享递增；
    /// CC index.ts:81 / codex index.ts:67）。
    private var handlerCounters: [HookDialect: Int] = [:]
    private let counterLock = NSLock()

    /// warn 缝（测试注入捕获断言；nil = 走 AppLogger——dsh ctx.logger.warn
    /// 的 WanWo 等价物）。
    var warnSink: (@Sendable (String) -> Void)?

    init(sessionId: String,
         writer: SessionWriter,
         runtimes: [HookBridgeRuntime],
         executor: HookCommandExecuting,
         cwd: String = WanWoPaths.workspaceLinuxDir) {
        self.sessionId = sessionId
        self.writer = writer
        // 跨桥顺序裁定：固定 claude→codex（稳定序不受装配细节漂移影响）。
        let order: [HookDialect] = [.claudeCode, .codex]
        self.runtimes = order.compactMap { dialect in
            runtimes.first { $0.dialect == dialect }
        }
        self.executor = executor
        self.cwd = cwd
    }

    // MARK: 五挂点入口（语义命名；内部统一 runPoint）

    /// SessionStart（CC index.ts:206-215 detached）——turn=nil 零事件对；
    /// additionalContext 由调用方走 agent.inject 通道（AgentLoop.inject）。
    func sessionStart(source: String) async -> MergedHookOutcome {
        await runPoint("SessionStart", matchQuery: source, turn: nil,
                       payload: HookPointPayload(source: source),
                       plainStdoutAsContext: true)
    }

    /// UserPromptSubmit（CC index.ts:219-235）——matchQuery 恒 ""（该事件
    /// 无 matcher 主语）。
    func userPromptSubmit(turn: Int, prompt: String) async -> MergedHookOutcome {
        await runPoint("UserPromptSubmit", matchQuery: "", turn: turn,
                       payload: HookPointPayload(prompt: prompt),
                       plainStdoutAsContext: true)
    }

    /// PreToolUse（CC index.ts:238-244）——matchQuery=toolName。
    func preToolUse(turn: Int, toolName: String, args: JSONValue,
                    callId: String) async -> MergedHookOutcome {
        await runPoint("PreToolUse", matchQuery: toolName, turn: turn,
                       payload: HookPointPayload(toolName: toolName,
                                                 toolInput: args,
                                                 toolCommand: Self.commandOf(args),
                                                 toolUseId: callId))
    }

    /// PostToolUse（CC index.ts:247-265）——matchQuery=toolName。
    func postToolUse(turn: Int, toolName: String, args: JSONValue,
                     callId: String, response: String) async -> MergedHookOutcome {
        await runPoint("PostToolUse", matchQuery: toolName, turn: turn,
                       payload: HookPointPayload(toolName: toolName,
                                                 toolInput: args,
                                                 toolCommand: Self.commandOf(args),
                                                 toolUseId: callId,
                                                 toolResponse: response))
    }

    /// Stop（CC index.ts:270-277）——matchQuery 忽略。
    func stop(turn: Int) async -> MergedHookOutcome {
        await runPoint("Stop", matchQuery: "", turn: turn,
                       payload: HookPointPayload())
    }

    // MARK: runPoint 核心（CC index.ts:137-187 语义，跨桥扩展）

    /// 跑一个挂点上的全部匹配 hooks（跨桥 serial 序）并折叠。
    /// - Returns: 合并 outcome（空 hooks/零 runtime = 中性 outcome）。
    func runPoint(_ point: String,
                  matchQuery: String,
                  turn: Int?,
                  payload: HookPointPayload,
                  plainStdoutAsContext: Bool = false) async -> MergedHookOutcome {
        var outputs: [HookOutput] = []
        for runtime in runtimes {
            let groups = runtime.groups[point] ?? []
            // 方言 payload 构造（CC index.ts:321-346 / codex :290-328 逐字段）。
            let payloadJSON = encodePayload(buildFields(point: point, turn: turn,
                                                        payload: payload,
                                                        runtime: runtime))
            for group in groups {
                if !HookMatcher.matchesMatcher(group.matcher, query: matchQuery,
                                               mode: runtime.matcherMode) {
                    continue
                }
                for hook in group.hooks {
                    let handlerId = nextHandlerId(dialect: runtime.dialect,
                                                  point: point)
                    // turn 非 nil 才落事件对（detached lifecycle points omit
                    // the pair——CC index.ts:157/:181 同条件）。
                    if let turn {
                        do {
                            _ = try await HookSessionEvents.appendHookInvoked(
                                to: writer,
                                invocation: HookInvocation(
                                    turn: turn, point: point,
                                    dialect: runtime.dialect,
                                    handlerId: handlerId,
                                    matcher: group.matcher))
                        } catch {
                            // R5：hook 审计失败不阻塞主流程（吞错+log——裁定④）。
                            Self.logger.error("hook/invoked append failed for "
                                + "\(handlerId): \(String(describing: error))")
                        }
                    }
                    // env：CC 恒注 CLAUDE_PROJECT_DIR（index.ts:148-151——
                    // 显式 config 值即装配常量）；codex 无 hook env。
                    let env: [String: String] = runtime.dialect == .claudeCode
                        ? ["CLAUDE_PROJECT_DIR": HookConfigLoader.projectDir]
                        : [:]
                    let (output, durationMs) = await HookRunner.run(
                        executor: executor,
                        hook: hook,
                        payload: payloadJSON,
                        trailingNewline: runtime.trailingNewline,
                        defaultTimeoutMs: runtime.defaultTimeoutMs,
                        env: env,
                        cwd: cwd,
                        expectedEventName: point)
                    var finalOutput = output
                    // codex plainStdoutAsContext（codex index.ts:152-156）：
                    // 干净 plain stdout 且无结构化上下文时折叠为上下文。
                    if plainStdoutAsContext, runtime.dialect == .codex,
                       output.exitCode == 0,
                       output.additionalContext == nil,
                       !output.stdout.isEmpty,
                       !output.stdout.hasPrefix("{") {
                        finalOutput.additionalContext = output.stdout
                    }
                    // warn 面（CC index.ts:175-180 文案逐字 / codex :161-163
                    // 同族——CC 有 updatedInput warn、codex 无）。
                    if runtime.dialect == .claudeCode,
                       finalOutput.updatedInput != nil {
                        emitWarn("hooks-claude-code: \(point) hook "
                            + "requested updatedInput, which is not yet honored (ignored)")
                    }
                    if finalOutput.systemMessage != nil {
                        emitWarn(
                            "hooks-\(runtime.dialect.rawValue): \(point) hook "
                                + "emitted a systemMessage, which is not yet surfaced (ignored)")
                    }
                    if let turn {
                        do {
                            _ = try await HookSessionEvents.appendHookResult(
                                to: writer,
                                record: HookResultRecord(
                                    turn: turn, point: point,
                                    handlerId: handlerId,
                                    output: finalOutput,
                                    stderrSummaryMaxChars: runtime.stderrSummaryMaxChars,
                                    durationMs: durationMs))
                        } catch {
                            Self.logger.error("hook/result append failed for "
                                + "\(handlerId): \(String(describing: error))")
                        }
                    }
                    outputs.append(finalOutput)
                }
            }
        }
        // 跨桥一次 merge（deny>ask>allow 全局折——裁定①）。
        return HookMerge.mergeHookOutputs(outputs)
    }

    // MARK: - 私有助手

    /// warn 输出（warnSink 注入时捕获，否则 AppLogger）。
    private func emitWarn(_ message: String) {
        if let warnSink {
            warnSink(message)
        } else {
            Self.logger.warning(message)
        }
    }

    /// handlerId：`{dialect}:{point}:{n}`（CC index.ts:83 / codex :69 逐字
    /// 格式；每桥一枚举跨 point 共享递增）。
    private func nextHandlerId(dialect: HookDialect, point: String) -> String {
        counterLock.lock()
        defer { counterLock.unlock() }
        handlerCounters[dialect, default: 0] += 1
        return "\(dialect.rawValue):\(point):\(handlerCounters[dialect]!)"
    }

    /// Codex commandOf（codex index.ts:310-316）：args.command 字符串否则 ''。
    private static func commandOf(_ args: JSONValue) -> String {
        guard case .object(let fields) = args,
              case .string(let command)? = fields["command"] else { return "" }
        return command
    }

    // MARK: 方言 payload 构造（CC index.ts:321-346 / codex :290-328 逐字段）

    /// CC base（index.ts:321-330）+ Codex base（:291-302）双支。
    private func buildFields(point: String, turn: Int?,
                             payload: HookPointPayload,
                             runtime: HookBridgeRuntime) -> [String: JSONValue] {
        var fields: [String: JSONValue]
        switch runtime.dialect {
        case .claudeCode:
            fields = [
                "session_id": .string(sessionId),
                // 持久缝无 artifact 路径——字段恒空串（index.ts:324-326 原注）。
                "transcript_path": .string(""),
                "cwd": .string(cwd),
                "hook_event_name": .string(point),
            ]
        case .codex:
            fields = [
                "session_id": .string(sessionId),
                // 持久缝无 artifact 路径——字段恒 null（codex index.ts:294-296 原注）。
                "transcript_path": .null,
                "cwd": .string(cwd),
                "hook_event_name": .string(point),
                "model": .string(runtime.model),
                "permission_mode": .string("default"),
            ]
            // turnBase（codex index.ts:305-307）——turn 域事件附 turn_id
            //（SessionStart detached 无 turn_id）。
            if let turn {
                fields["turn_id"] = .string(String(turn))
            }
        }
        // per-event 字段（CC :332-346 / codex :318-328 + :189/:261）。
        switch point {
        case "SessionStart":
            if let source = payload.source { fields["source"] = .string(source) }
        case "UserPromptSubmit":
            if let prompt = payload.prompt { fields["prompt"] = .string(prompt) }
        case "PreToolUse":
            if let toolName = payload.toolName {
                fields["tool_name"] = .string(toolName)
            }
            fields["tool_input"] = runtime.dialect == .claudeCode
                ? (payload.toolInput ?? .null)
                : .object(["command": .string(payload.toolCommand ?? "")])
            if let toolUseId = payload.toolUseId {
                fields["tool_use_id"] = .string(toolUseId)
            }
        case "PostToolUse":
            if let toolName = payload.toolName {
                fields["tool_name"] = .string(toolName)
            }
            fields["tool_input"] = runtime.dialect == .claudeCode
                ? (payload.toolInput ?? .null)
                : .object(["command": .string(payload.toolCommand ?? "")])
            if let toolUseId = payload.toolUseId {
                fields["tool_use_id"] = .string(toolUseId)
            }
            if let response = payload.toolResponse {
                fields["tool_response"] = .string(response)
            }
        case "Stop":
            // CC :345 / codex :261——stop_hook_active 恒 false（loop-guard
            // 旗标；WanWo 无 stop 循环治理——codex 另带 last_assistant_message:null）。
            fields["stop_hook_active"] = .bool(false)
            if runtime.dialect == .codex {
                fields["last_assistant_message"] = .null
            }
        default:
            break
        }
        return fields
    }

    /// JSONValue → JSON 串（编码失败不可能——JSONValue 全值可编码；防御性
    /// 回退空 object）。
    private func encodePayload(_ fields: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
