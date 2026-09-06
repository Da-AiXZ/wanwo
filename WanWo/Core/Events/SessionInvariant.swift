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
struct SessionInvariant {
    private(set) var lastSeq: Int = -1
    private(set) var openTurn: Int?
    private(set) var openStep: Int?
    private(set) var nextTurn: Int = 1
    private(set) var nextStep: Int = 1

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
        case .userMessage, .llmRetry, .llmRetryStarted, .sessionTitle, .system, .ignored:
            // dsh invariant：user/message 无约束；log-only/插件类事件归其属主约束。
            break
        }
        // commit（dsh applyTransition）
        lastSeq = event.seq
    }

    private func requireOpenStep(_ kind: String, turn: Int, step: Int) throws {
        guard openTurn == turn, openStep == step else {
            throw InvariantViolation.stepScopedEventOutsideStep(
                kind: kind, turn: openTurn, step: openStep)
        }
    }
}
