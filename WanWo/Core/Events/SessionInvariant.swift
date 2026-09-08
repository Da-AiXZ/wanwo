//
//  SessionInvariant.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/session/src/invariant.ts（SessionTrace /
//  validateEvent / requireOpenStep 的 M1 关系不变量子集）。
//  校验：seq 严格递增；turn/start 唯一开放且序号连续；turn/end 前不得有开放 step；
//  step/start 序号连续；step 内事件（assistant/chunk、assistant/message、step/end、
//  request/header）必须命名当前开放的 turn/step。校验失败即抛（fail closed），
//  调用方拒绝追加/重建。
//

import Foundation

/// 会话事件流关系不变量校验器（逐事件 validate；每会话一个实例）。
/// M2：tool/call ↔ tool/result 按 callId 配对（dsh tool-pairing 语义）；prune 的
/// tool/result 替换引用的是历史 callId（已见过）同样成立；tool 事件不要求 step
/// 开放（prune 替换发生在回合外，带历史 turn/step 坐标）。
struct SessionInvariant {
    private(set) var lastSeq: Int = -1
    private(set) var openTurn: Int?
    private(set) var openStep: Int?
    private(set) var nextTurn: Int = 1
    private(set) var nextStep: Int = 1
    private var seenCallIds: Set<String> = []
    /// E1：extension 应答配对的开键集（dsh approval requestId 配对语义的
    /// 通用化；键生命周期 = 会话级，对齐 seenCallIds）。键 = (开 kind, 关 kind)。
    private struct ExtensionPair: Hashable {
        let openKind: String
        let closeKind: String
    }
    private var openExtensionKeys: [ExtensionPair: Set<String>] = [:]

    enum InvariantViolation: Error, Equatable {
        case seqNotIncreasing(event: Int, last: Int)
        case turnStartWhileOpen(event: Int, open: Int)
        case unexpectedTurn(event: Int, expected: Int)
        case turnEndMismatch(event: Int, open: Int?)
        case turnEndWithOpenStep(turn: Int, step: Int)
        case stepStartWithOpenStep(event: Int, open: Int)
        case stepOutsideTurn(event: Int, openTurn: Int?)
        case stepScopedEventOutsideStep(kind: String, turn: Int?, step: Int?)
        case requestHeaderOutsideTurn
        case toolResultWithoutCall(event: Int, callId: String)
        /// E1：extension 应答配对违例（close 无 open / 键缺失或非字符串）。
        case extensionPairViolation(event: Int, kind: String, reason: String)
    }

    /// 校验一个候选事件（不通过即抛）。通过后由调用方 commit()。
    mutating func validate(_ event: SessionEvent) throws {
        guard event.seq > lastSeq else {
            throw InvariantViolation.seqNotIncreasing(event: event.seq, last: lastSeq)
        }
        switch event.payload {
        case .turnStart(let turn):
            if let open = openTurn {
                throw InvariantViolation.turnStartWhileOpen(event: turn, open: open)
            }
            if turn != nextTurn {
                throw InvariantViolation.unexpectedTurn(event: turn, expected: nextTurn)
            }
            openTurn = turn
            nextStep = 1
        case .turnEnd(let turn, _):
            guard openTurn == turn else {
                throw InvariantViolation.turnEndMismatch(event: turn, open: openTurn)
            }
            if let openStep = openStep {
                throw InvariantViolation.turnEndWithOpenStep(turn: turn, step: openStep)
            }
            openTurn = nil
            nextTurn += 1
        case .stepStart(let turn, let step):
            guard openTurn == turn else {
                throw InvariantViolation.stepOutsideTurn(event: turn, openTurn: openTurn)
            }
            if let open = openStep {
                throw InvariantViolation.stepStartWithOpenStep(event: step, open: open)
            }
            if step != nextStep {
                throw InvariantViolation.unexpectedTurn(event: step, expected: nextStep)
            }
            openStep = step
        case .stepEnd(let turn, let step):
            try requireOpenStep("step/end", turn: turn, step: step)
            openStep = nil
            nextStep += 1
        case .assistantChunk(let turn, let step, _):
            try requireOpenStep("assistant/chunk", turn: turn, step: step)
        case .assistantMessage(let turn, let step, _, _, _):
            try requireOpenStep("assistant/message", turn: turn, step: step)
        case .requestHeader:
            guard openTurn != nil else {
                throw InvariantViolation.requestHeaderOutsideTurn
            }
        case .toolCall(_, _, let callId, _, _):
            // callId 必须唯一（重放替换不会重写 tool/call；dsh 配对语义）。
            if seenCallIds.contains(callId) {
                throw InvariantViolation.toolResultWithoutCall(event: event.seq, callId: callId)
            }
            seenCallIds.insert(callId)
        case .toolResult(_, _, let callId, _, _, _, _, _):
            guard seenCallIds.contains(callId) else {
                throw InvariantViolation.toolResultWithoutCall(event: event.seq, callId: callId)
            }
        case .extensionEvent(let kind, let payload):
            // E1：extension 事件对 turn/step 结构无约束；配对规则按注册表
            // 分流（默认 .none 无约束；answeredBy 见 validateExtensionPairing）。
            // 未注册 kind：透传事件（消费侧跳过口径），无约束。
            try validateExtensionPairing(kind: kind, payload: payload, event: event)
        case .userMessage, .llmRetry, .llmRetryStarted, .sessionTitle, .system, .ignored,
             .compactionStart, .compactionSummary, .compactionEnd, .compactionPrune,
             .commandRun, .commandDone, .approvalAsked, .approvalDecided:
            // dsh invariant：user/message 无约束；log-only/插件类事件归其属主约束。
            break
        }
        // commit（dsh applyTransition）
        lastSeq = event.seq
    }

    /// E1 通道配对校验（注册规则驱动）：
    ///   · 本 kind 是某 answeredBy 规则的 closeKind → 键必须命中对应开集（消费）；
    ///   · 本 kind 自身带 answeredBy 规则（开事件）→ 键必须存在且为字符串（登记）。
    /// 先关后开：同一事件既是某对的关又是另一对的开时，先消费键再登记。
    private mutating func validateExtensionPairing(kind: String, payload: JSONValue,
                                                   event: SessionEvent) throws {
        let registry = ExtensionEventRegistry.shared
        for openSchema in registry.allSchemas() {
            guard case .answeredBy(let closeKind, let keyField) = openSchema.pairing,
                  closeKind == kind else { continue }
            guard case .object(let fields) = payload,
                  let keyValue = fields[keyField],
                  case .string(let key) = keyValue else {
                throw InvariantViolation.extensionPairViolation(
                    event: event.seq, kind: kind,
                    reason: "pairing close for \"\(openSchema.kind)\" lacks string key \"\(keyField)\"")
            }
            let pair = ExtensionPair(openKind: openSchema.kind, closeKind: closeKind)
            guard openExtensionKeys[pair]?.contains(key) == true else {
                throw InvariantViolation.extensionPairViolation(
                    event: event.seq, kind: kind,
                    reason: "pairing close key \"\(key)\" has no open \"\(openSchema.kind)\"")
            }
            openExtensionKeys[pair]?.remove(key)
        }
        if let schema = registry.schema(for: kind),
           case .answeredBy(let closeKind, let keyField) = schema.pairing {
            guard case .object(let fields) = payload,
                  let keyValue = fields[keyField],
                  case .string(let key) = keyValue else {
                throw InvariantViolation.extensionPairViolation(
                    event: event.seq, kind: kind,
                    reason: "pairing open lacks string key \"\(keyField)\"")
            }
            openExtensionKeys[ExtensionPair(openKind: kind, closeKind: closeKind),
                              default: []].insert(key)
        }
    }

    private func requireOpenStep(_ kind: String, turn: Int, step: Int) throws {
        guard openTurn == turn, openStep == step else {
            throw InvariantViolation.stepScopedEventOutsideStep(
                kind: kind, turn: openTurn, step: openStep)
        }
    }
}
