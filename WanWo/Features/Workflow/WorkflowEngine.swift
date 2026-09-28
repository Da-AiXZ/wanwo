//
//  WorkflowEngine.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】Workflow 引擎 seam（packages/workflow/
//  workflow/src/index.ts 引擎契约 + workflow-worker-thread/src/index.ts 引擎
//  实现 + meta.ts 校验 + protocol.ts 事件词汇的进程内承载）：
//    - index.ts(seam):157-187 —— WorkflowEngine 契约：非法请求在发布前 throw；
//      活 run 为 holder-owned；result 永不 reject；取消/处置有界；生命周期
//      listener 故障被包含；workflow/end 恰好在 result 结算时发射一次。
//    - index.ts(seam):175-201 —— emitWorkflowEvent（逐 listener 包含失败 +
//      warn 日志；listener 面永不影响 run）。
//    - worker index.ts:53-74  —— assertBodyParses（META_STATEMENT 指名文案 +
//      同 wrapper 预解析——语法失败保留同步 SCRIPT_ERROR 面（万我 async throws
//      登记）；一次冗余解析买契约）。
//    - worker index.ts:76-104 —— resolveSubagentProvider / resolveMaxTotalAgents
//      （文案逐字）。
//    - worker index.ts:143-202 —— start()（meta 校验 → body 预解析 → provider
//      路由解析 → 总帽解析 → id → limits → run 装配 → workflow/start 发射 →
//      result 结算时 workflow/end 发射（无 value））。
//
//  万我适配裁定（登记）：
//    - 每栈一枚引擎（dsh 为 cordis 单例服务；万我事件 listener 随会话栈装配，
//      per-stack 实例使 recorder 的会话归档自然闭合——语义等价，登记）。
//    - Cordis ctx.events → 进程内 listener 注册表（addWorkflowListener 返回
//      disposer；批1"进程内回调/通知"同款适配）。
//    - start() `async throws`（getProvider 为 actor 调用 + JSC 语法预检持有
//      context——校验顺序/文案逐字不变，登记）。
//    - 语法预解析 = JSCheckScriptSyntax（JSBase.h 公开 C API——仅解析不执行，
//      vm.Script 预解析等价；throwaway context 每 run 一枚，登记）。
//    - Watchdog 缺失（dlsym 失败）为退化面（WorkflowExecution 头注⑦同登记）。
//

import Foundation
import JavaScriptCore

/// Workflow 引擎（校验 + run 装配 + 生命周期事件；执行核心在
/// WorkflowExecution，宿主控制面在 WorkflowRunHandle）。
final class WorkflowEngine: @unchecked Sendable {

    private let config: WorkflowEngineConfig
    /// 子 agent 缝（provider 注册表查询 + one-shot 启动）。
    private let runtime: SubagentRuntime

    // MARK: listener 注册表（cordis ctx.events 进程内承载）

    private let listenersLock = NSLock()
    private var listeners: [UUID: @Sendable (WorkflowEventName, WorkflowEventDetail) -> Void] = [:]

    init(config: WorkflowEngineConfig = WorkflowEngineConfig(),
         runtime: SubagentRuntime) {
        self.config = config
        self.runtime = runtime
    }

    /// 注册生命周期 listener（包含纪律：listener 内异常/失败不影响 run——
    /// Swift 非抛闭包 + 调用方自包含；disposer 幂等移除）。
    func addWorkflowListener(
        _ listener: @escaping @Sendable (WorkflowEventName, WorkflowEventDetail) -> Void
    ) -> () -> Void {
        let token = UUID()
        listenersLock.lock()
        listeners[token] = listener
        listenersLock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.listenersLock.lock()
            self.listeners[token] = nil
            self.listenersLock.unlock()
        }
    }

    /// Emit a lifecycle event（逐 listener 派发；listener 故障包含 + warn——
    /// index.ts(seam):175-187 语义；Swift 非抛闭包，故障面为调用方自吞）。
    private func emitWorkflowEvent(_ name: WorkflowEventName, _ detail: WorkflowEventDetail) {
        listenersLock.lock()
        let current = Array(listeners.values)
        listenersLock.unlock()
        for listener in current {
            listener(name, detail)
        }
    }

    // MARK: start（worker index.ts:143-202 1:1 面）

    /// Validate and execute a workflow script。请求无法开始时 throw
    /// WorkflowError（META_INVALID / SCRIPT_PARSE / INVALID_ARGUMENT /
    /// AGENT_START）；run 返回后一切失败经 result.stopReason 结算。
    func start(_ request: WorkflowStartRequest) async throws -> WorkflowRunHandle {
        // 1. meta 校验（NORMALIZED 拷贝；META_INVALID 逐名违反）。
        let meta = try validateWorkflowMeta(.object(metaPayload(request.meta)))
        // 2. body 预解析（同 wrapper；META_STATEMENT 指名文案优先）。
        try Self.assertBodyParses(request.script, name: meta.name)
        // 3. provider 路由解析（worker index.ts:76-89 文案逐字）。
        let providerName = request.subagentProvider ?? config.provider
        if providerName.isEmpty || providerName != providerName.trimmingCharacters(in: .whitespaces) {
            throw WorkflowError(
                message: "workflow subagentProvider must be a non-empty normalized string",
                code: .invalidArgument)
        }
        if await runtime.getProvider(providerName) == nil {
            throw WorkflowError(
                message: "no subagent provider registered for \"\(providerName)\"",
                code: .agentStart)
        }
        // 4. 总帽解析（worker index.ts:92-104 文案逐字）。
        let maxTotalAgents = try Self.resolveMaxTotalAgents(
            request.maxTotalAgents, ceiling: config.maxTotalAgents)
        // 5. id + limits。
        let id = UUID().uuidString
        let maxConcurrent = config.maxConcurrentAgents == 0
            ? min(16, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            : config.maxConcurrentAgents
        let limits = WorkflowLimits(
            maxConcurrentAgents: maxConcurrent,
            maxTotalAgents: maxTotalAgents,
            maxItemsPerCall: config.maxItemsPerCall,
            syncTimeoutMs: config.syncTimeoutMs)
        // 6. run 装配（execution + handle + 观察者桥）。
        let childPort = SubagentRuntimeChildPort(
            runtime: runtime, provider: providerName, parent: request.parent)
        let execution = WorkflowExecution(
            limits: limits, childPort: childPort,
            observer: WorkflowExecutionObserver(phase: { _ in }, log: { _ in },
                                                agentStart: { _ in }, agentEnd: { _ in }),
            script: request.script, args: request.args)
        var emitClosure: (@Sendable (WorkflowEventName, WorkflowEventDetail) -> Void)?
        let handle = WorkflowRunHandle(
            id: id, meta: meta, execution: execution,
            emit: { name, detail in emitClosure?(name, detail) },
            disposeGraceMs: config.disposeGraceMs)
        execution.runHandle = handle
        emitClosure = { [weak self] name, detail in
            self?.emitWorkflowEvent(name, detail)
        }
        // 观察者桥（agent 配对闸/取消抑制在 handle）。
        let observerBridge = WorkflowExecutionObserver(
            phase: { [weak handle] title in handle?.observerPhase(title) },
            log: { [weak handle] message in handle?.observerLog(message) },
            agentStart: { [weak handle] agent in handle?.observerAgentStart(agent) },
            agentEnd: { [weak handle] end in handle?.observerAgentEnd(end) })
        execution.replaceObserver(observerBridge)

        // 7. workflow/start 发射 + workflow/end（result 结算时；无 value）。
        emitWorkflowEvent(.start, .none)
        Task { [weak self, weak handle] in
            guard let self, let handle else { return }
            let settled = await handle.result.value
            // markSettled 已由 execution.settleTerminal 同步承载（QA-7 P2②
            // ——此处不重复）。
            self.emitWorkflowEvent(.end, .result(WorkflowResultInfo(
                stopReason: settled.stopReason,
                error: settled.error,
                agentsStarted: settled.agentsStarted)))
        }
        return handle
    }

    // MARK: 预解析（worker index.ts:53-74）

    /// A body that still carries the Claude Code-style meta header（meta 以
    /// request 数据承载——此处指名纠正最可能的模型笔误）。
    private static let metaStatementPattern = "^[ \\t]*export[ \\t]+const[ \\t]+meta\\b"

    /// Parse-check the body with the SAME wrapper the execution compiles
    ///（JSCheckScriptSyntax 仅解析不执行——vm.Script 预解析等价；throwaway
    /// context，一次冗余解析买契约，worker index.ts:56-63 注释语义）。
    static func assertBodyParses(_ body: String, name: String) throws {
        if body.range(of: metaStatementPattern, options: [.regularExpression, .anchored]) != nil {
            throw WorkflowError(
                message: "workflow meta rides the `meta` request field, not the script:"
                    + " remove the `export const meta = {...}` statement from the body",
                code: .scriptParse)
        }
        let wrapped = "(async () => {\n" + body + "\n})()"
        let parseContext = JSContext()!
        let source = JSStringCreateWithCFString(wrapped as CFString)
        let sourceURL = JSStringCreateWithCFString("workflow:\(name)" as CFString)
        var exception: JSValueRef?
        let parses = JSCheckScriptSyntax(parseContext.jsGlobalContextRef, source,
                                         sourceURL, 0, &exception)
        JSStringRelease(source)
        JSStringRelease(sourceURL)
        guard parses else {
            // 异常文案经公开 C API JSValueToStringCopy 取（QA-7 P1①——
            // JSValue(context:jsvRef:) 非公开初始化器形态有编译风险，零依赖
            // C 面最稳；JSStringCopyCFString 桥 CFString）。
            var detail = "unknown"
            if let exception {
                if let textRef = JSValueToStringCopy(parseContext.jsGlobalContextRef,
                                                     exception, nil) {
                    detail = (JSStringCopyCFString(kCFAllocatorDefault, textRef) as String?) ?? "unknown"
                    JSStringRelease(textRef)
                }
            }
            throw WorkflowError(message: "workflow script does not parse: \(detail)",
                                code: .scriptParse)
        }
    }

    /// meta 记录 → JSONValue（validateWorkflowMeta 输入面）。
    private func metaPayload(_ meta: WorkflowMeta) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "name": .string(meta.name),
            "description": .string(meta.description),
        ]
        if let whenToUse = meta.whenToUse {
            fields["whenToUse"] = .string(whenToUse)
        }
        if let phases = meta.phases {
            fields["phases"] = .array(phases.map { phase in
                var entry: [String: JSONValue] = ["title": .string(phase.title)]
                if let detail = phase.detail { entry["detail"] = .string(detail) }
                if let provider = phase.provider { entry["provider"] = .string(provider) }
                if let model = phase.model { entry["model"] = .string(model) }
                return .object(entry)
            })
        }
        return fields
    }

    // MARK: 总帽解析（worker index.ts:92-104 文案逐字）

    static func resolveMaxTotalAgents(_ requested: Int?, ceiling: Int) throws -> Int {
        guard let requested else { return ceiling }
        // Swift Int 即 safe integer（64 位平台；dsh Number.isSafeInteger 面等价）。
        if requested < 1 {
            throw WorkflowError(
                message: "workflow maxTotalAgents must be a positive safe integer",
                code: .invalidArgument)
        }
        if requested > ceiling {
            throw WorkflowError(
                message: "workflow maxTotalAgents \(requested) exceeds the engine ceiling \(ceiling)",
                code: .invalidArgument)
        }
        return requested
    }
}
