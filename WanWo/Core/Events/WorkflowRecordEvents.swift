//
//  WorkflowRecordEvents.swift
//  WanWo
//
//  【语义移植 · dsh · M7-Fix E1b 任务8】Workflow recorder 四事件落日志
//  （packages/workflow/tool-workflow/src/index.ts:72-130 createWorkflowRecorder
//  + packages/core/session/src/known-event-types.ts:67-70 事件词汇）：
//    - index.ts:56-63   —— ToolWorkflowRecordEventMap 四事件：run-start /
//      agent-start / agent-end / run-end；index.ts:86-88 注释裁定
//      "These four package-owned events are all log-only"。
//    - payload-validation.ts:233-250 —— requiredFields 对照：
//      run-start {runId, name}；agent-start {runId, seq, label, childId}
//      （phase 可选，不入 required）；agent-end {runId, seq,
//      outcome ∈ completed|failed|cancelled}；run-end {runId,
//      stopReason ∈ completed|cancelled|error}。
//    - index.ts:90-101  —— append 失败 → warn + active.delete（本 run
//      记录停用，后续事件跳过；下一 run start 重新武装）。
//    - index.ts:103-125 —— start/finish/abandon 三面（万我以 .start/.end
//      内部事件映射；abandon 面无独立内部事件，run-end 恒落）。
//
//  万我适配裁定（登记）：
//    - 引擎内部事件 .start/.end 的 detail 不携带 runId/meta.name
//      （WorkflowEngine.swift:145 emitWorkflowEvent(.start, .none) /
//      :151 .result(WorkflowResultInfo)——Features/Workflow 本批禁改面）。
//      recorder 以每 run 自铸 correlation id 承载四事件互关联；
//      runId 与 WorkflowTool 返回 handle.id 的跨面对齐缺口已登记报告
//      （建议 WorkflowEventDetail 增 run(WorkflowRunInfo) case 后收敛，
//      本类仅须改为读取该 case）。
//    - name 暂以工具名 "workflow" 占位（dsh = run.meta.name，同缺口面）。
//    - per-stack 引擎 + workflow 工具前台串行（每 loop 一 run）→ 每 run
//      单一 currentRunId 状态机无重叠歧义。
//

import Foundation

/// dsh tool-workflow 四事件词汇（known-event-types.ts:67-70 原词）。
enum WorkflowRecordEvents {
    static let runStartKind = "tool-workflow/run-start"
    static let agentStartKind = "tool-workflow/agent-start"
    static let agentEndKind = "tool-workflow/agent-end"
    static let runEndKind = "tool-workflow/run-end"

    /// 装配期注册（重名 fatal——ExtensionEventRegistry 既有纪律；幂等
    /// guard 同 PermissionCoordinator/DiagTraceEvents 注册先例）。
    static func registerEventSchemas() {
        let registry = ExtensionEventRegistry.shared
        // run-start {runId, name}（payload-validation.ts:247-250）。
        if !registry.isRegistered(runStartKind) {
            registry.register(ExtensionEventSchema(
                kind: runStartKind,
                requiredFields: [
                    ExtensionFieldSchema("runId", .string),
                    ExtensionFieldSchema("name", .string),
                ],
                projection: .logOnly,
                pairing: .none))
        }
        // agent-start {runId, seq, label, childId}（:237-242；phase 可选
        // ——requiredFields 不含，写侧按在场透传，registry 额外字段放行）。
        if !registry.isRegistered(agentStartKind) {
            registry.register(ExtensionEventSchema(
                kind: agentStartKind,
                requiredFields: [
                    ExtensionFieldSchema("runId", .string),
                    ExtensionFieldSchema("seq", .int),
                    ExtensionFieldSchema("label", .string),
                    ExtensionFieldSchema("childId", .string),
                ],
                projection: .logOnly,
                pairing: .none))
        }
        // agent-end {runId, seq, outcome}（:233-236；outcome 封闭值域）。
        if !registry.isRegistered(agentEndKind) {
            registry.register(ExtensionEventSchema(
                kind: agentEndKind,
                requiredFields: [
                    ExtensionFieldSchema("runId", .string),
                    ExtensionFieldSchema("seq", .int),
                    ExtensionFieldSchema("outcome", .string,
                                         allowedValues: [
                                            .string("completed"),
                                            .string("failed"),
                                            .string("cancelled"),
                                         ]),
                ],
                projection: .logOnly,
                pairing: .none))
        }
        // run-end {runId, stopReason}（:243-246；stopReason 封闭值域）。
        if !registry.isRegistered(runEndKind) {
            registry.register(ExtensionEventSchema(
                kind: runEndKind,
                requiredFields: [
                    ExtensionFieldSchema("runId", .string),
                    ExtensionFieldSchema("stopReason", .string,
                                         allowedValues: [
                                            .string("completed"),
                                            .string("cancelled"),
                                            .string("error"),
                                         ]),
                ],
                projection: .logOnly,
                pairing: .none))
    }
}

/// Workflow recorder（dsh createWorkflowRecorder 的 WanWo listener 承载）：
/// 引擎内部事件 → 父会话 tool-workflow/* extensionEvent 追加。
/// 故障包含：追加失败 warn + 本 run 停用（currentRunId 清空——后续事件
/// nil guard 跳过，下一 .start 重新武装；index.ts:90-101 语义）。
/// 追加顺序：串行 Task 链（listener 同步面 → writer.append 异步面，
/// 链尾挂接保序；dsh session.append 同步序的万我等价承载）。
final class WorkflowEventRecorder: @unchecked Sendable {

    private let writer: SessionWriter
    private static let logger = AppLogger(category: "workflow-recorder")

    private let lock = NSLock()
    /// 当前 run 的 correlation id（nil = 无活跃 run 或本 run 已停用）。
    private var currentRunId: String?
    /// 保序追加链尾。
    private var chain: Task<Void, Never>?

    init(writer: SessionWriter) {
        self.writer = writer
    }

    /// listener 面（engine.addWorkflowListener 缝；非抛——故障自包含）。
    func handle(_ name: WorkflowEventName, _ detail: WorkflowEventDetail) {
        lock.lock()
        defer { lock.unlock() }
        switch name {
        case .start:
            let runId = UUID().uuidString
            currentRunId = runId
            enqueue(kind: WorkflowRecordEvents.runStartKind, runId: runId, fields: [
                // name 占位裁定见头注（dsh = run.meta.name，缺口面）。
                "name": .string("workflow"),
            ])
        case .agentStart:
            guard let runId = currentRunId, case .agent(let info) = detail else { return }
            var fields: [String: JSONValue] = [
                "seq": .int(info.seq),
                "label": .string(info.label),
                "childId": .string(info.childId),
            ]
            if let phase = info.phase { fields["phase"] = .string(phase) }
            enqueue(kind: WorkflowRecordEvents.agentStartKind, runId: runId, fields: fields)
        case .agentEnd:
            guard let runId = currentRunId, case .agentEnd(let end) = detail else { return }
            enqueue(kind: WorkflowRecordEvents.agentEndKind, runId: runId, fields: [
                "seq": .int(end.seq),
                "outcome": .string(end.outcome.rawValue),
            ])
        case .end:
            guard let runId = currentRunId else { return }
            var stopReason = WorkflowStopReason.error.rawValue
            if case .result(let info) = detail {
                stopReason = info.stopReason.rawValue
            }
            enqueue(kind: WorkflowRecordEvents.runEndKind, runId: runId, fields: [
                "stopReason": .string(stopReason),
            ])
            currentRunId = nil
        case .phase, .log:
            // 非四事件词汇——recorder 不落（dsh 仅订阅 agent-start/agent-end
            // + 显式 start/finish 三面）。
            break
        }
    }

    /// 链尾挂接追加（锁内调用——保序 + 停用判定原子）。
    private func enqueue(kind: String, runId: String, fields: [String: JSONValue]) {
        guard !currentRunDisabled else { return }
        var payloadFields = fields
        payloadFields["runId"] = .string(runId)
        let writer = writer
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            do {
                _ = try await writer.append(
                    .extensionEvent(kind: kind, payload: .object(payloadFields)))
            } catch {
                // dsh index.ts:91-97：warn + 本 run 停用（active.delete 等价）。
                Self.logger.warning("workflow-recorder: disabled durable record after "
                                    + "\(kind) append failed: \(String(describing: error))")
                guard let self else { return }
                self.lock.lock()
                if self.currentRunId == runId { self.currentRunId = nil }
                self.lock.unlock()
            }
        }
    }

    /// 停用态（锁内读；currentRunId == nil 即停用/空闲——再入保护）。
    private var currentRunDisabled: Bool { currentRunId == nil }
}
