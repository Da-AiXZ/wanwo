//
//  GoalFold.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 B · F006】出处（packages/goal/goal/src/fold.ts 全文对拍）：
//    - :27-49   —— GoalFoldState 累加器 + emptyGoalFoldState。
//    - :186-253 —— 转移校验（requireNextRevision / requireSameDefinition /
//      validateSnapshotTransition：edit 保 phase+blockedReason、pause
//      active→paused、resume {active,paused,blocked}→active 且 roundsStarted
//      < maxGoalRounds、complete 非 complete→complete、block active→blocked）。
//    - :271-306 —— applyGoalChange（create：revision 1/active/rounds 0/仅可
//      替换 complete 旧 goal/seenGoalIds 拒绝 id 复用；clear：需 current、
//      revision+1、clearedAt ≥ updatedAt、全量清空）。
//    - :313-332 —— applyGoalEvent（goal/change → 严格解码+应用；goal 轮次
//      admitted → 校验 active goal 的下一轮 → roundsStarted 推进）。
//    - :339-349 —— foldGoal 纯折叠。
//  万我事件承载：goal/change = extensionEvent("goal/change")；goal 轮次
//  admitted = extensionEvent("goal/round")（dsh user/message source 的伴随
//  事件等价——简报定案，见 GoalTypes 头注）。fold 异常由消费方软捕获进
//  state.failure 语义（GoalService.current 捕获后抛给宿主，replay 不断流）。
//

import Foundation

/// Mutable accumulator kept private to the pure fold（fold.ts:27-34）。
struct GoalFoldState: Equatable, Sendable {
    var goal: GoalSnapshot?
    var roundsStarted: Int = 0
    var createdAt: Int?
    var updatedAt: Int?
    var lastRef: GoalRef?
    /// Goal identities already created in this Session, retained to reject reuse。
    var seenGoalIds: Set<GoalId> = []

    static func empty() -> GoalFoldState { GoalFoldState() }
}

/// Pure replay fold of durable goal facts（fold.ts 全量 1:1）。
enum GoalFold {

    // MARK: - 转移校验（fold.ts:186-253）

    /// Require one exact next revision of the current goal（fold.ts:193-197）。
    private static func requireNextRevision(_ current: GoalSnapshot,
                                            _ next: GoalRef,
                                            _ operation: GoalOperation) throws {
        if next.id != current.id || next.revision != current.revision + 1 {
            throw GoalError(
                message: "goal \(operation.rawValue) must advance the current goal by one revision",
                code: .goalInvalidTransition)
        }
    }

    /// Require two snapshots to retain fields that only `edit` may replace（fold.ts:186-190）。
    private static func requireSameDefinition(_ current: GoalSnapshot,
                                              _ next: GoalSnapshot,
                                              _ operation: GoalOperation) throws {
        if next.objective != current.objective || next.maxGoalRounds != current.maxGoalRounds {
            throw GoalError(
                message: "goal \(operation.rawValue) cannot change objective or maxGoalRounds",
                code: .goalInvalidTransition)
        }
    }

    /// Validate one non-create snapshot operation against the preceding
    /// projection（fold.ts:200-253 1:1）。
    private static func validateSnapshotTransition(_ state: GoalFoldState,
                                                   _ change: GoalSnapshotChange,
                                                   _ current: GoalSnapshot) throws {
        let next = change.goal
        try requireNextRevision(current, next.ref, change.operation)
        guard state.updatedAt != nil else {
            throw GoalError(message: "current goal fold lacks updatedAt", code: .goalInvalidTransition)
        }
        if change.createdAt != state.createdAt
            || change.updatedAt < state.updatedAt!
            || change.roundsStarted != state.roundsStarted {
            throw GoalError(
                message: "goal \(change.operation.rawValue) does not preserve the current counters and timestamps",
                code: .goalInvalidTransition)
        }
        switch change.operation {
        case .edit:
            if next.phase != current.phase || next.blockedReason != current.blockedReason {
                throw GoalError(message: "goal edit cannot change phase or blocked reason",
                                code: .goalInvalidTransition)
            }
        case .pause:
            try requireSameDefinition(current, next, change.operation)
            if current.phase != .active || next.phase != .paused {
                throw GoalError(message: "goal pause has an invalid phase transition",
                                code: .goalInvalidTransition)
            }
        case .resume:
            try requireSameDefinition(current, next, change.operation)
            let resumable: Set<GoalPhase> = [.active, .paused, .blocked]
            if !resumable.contains(current.phase) || next.phase != .active
                || state.roundsStarted >= next.maxGoalRounds {
                throw GoalError(
                    message: "goal resume has an invalid phase transition or exhausted round budget",
                    code: .goalInvalidTransition)
            }
        case .complete:
            try requireSameDefinition(current, next, change.operation)
            if current.phase == .complete || next.phase != .complete {
                throw GoalError(message: "goal complete has an invalid phase transition",
                                code: .goalInvalidTransition)
            }
        case .block:
            try requireSameDefinition(current, next, change.operation)
            if current.phase != .active || next.phase != .blocked {
                throw GoalError(message: "goal block has an invalid phase transition",
                                code: .goalInvalidTransition)
            }
        case .create:
            throw GoalError(message: "goal create cannot be validated as a current-goal transition",
                            code: .goalInvalidTransition)
        case .clear:
            throw GoalError(message: "unknown goal snapshot operation", code: .goalInvalidTransition)
        }
    }

    // MARK: - 变更应用（fold.ts:271-306 applyGoalChange 1:1）

    /// Validate and apply one decoded change to a mutable accumulator。
    static func applyGoalChange(_ state: inout GoalFoldState, _ change: GoalChangeMeta) throws {
        let ref = GoalCodec.ref(of: change)
        if case .clear(let clear) = change {
            guard let current = state.goal else {
                throw GoalError(message: "goal clear requires a current goal", code: .goalNotFound)
            }
            try requireNextRevision(current, clear.cleared, .clear)
            guard state.updatedAt != nil else {
                throw GoalError(message: "current goal fold lacks updatedAt", code: .goalInvalidTransition)
            }
            if clear.clearedAt < state.updatedAt ?? 0 {
                throw GoalError(message: "goal clear timestamp cannot precede the current goal update",
                                code: .goalInvalidTransition)
            }
            state.goal = nil
            state.roundsStarted = 0
            state.createdAt = nil
            state.updatedAt = nil
            state.lastRef = ref
            return
        }
        guard case .snapshot(let change) = change else { return }
        if change.operation == .create {
            if change.goal.revision != 1 || change.goal.phase != .active
                || change.roundsStarted != 0
                || (state.goal != nil && state.goal?.phase != .complete)
                || state.seenGoalIds.contains(change.goal.id) {
                throw GoalError(
                    message: "goal create requires a fresh active revision-one goal with zero rounds",
                    code: .goalInvalidTransition)
            }
            state.seenGoalIds.insert(change.goal.id)
        } else {
            guard let current = state.goal else {
                throw GoalError(message: "goal \(change.operation.rawValue) requires a current goal",
                                code: .goalNotFound)
            }
            try validateSnapshotTransition(state, change, current)
        }
        state.goal = change.goal
        state.roundsStarted = change.roundsStarted
        state.createdAt = change.createdAt
        state.updatedAt = change.updatedAt
        state.lastRef = ref
    }

    // MARK: - 事件应用（fold.ts:313-332 applyGoalEvent · 万我事件承载）

    /// Apply one session event to the strict durable goal fold。
    /// - goal/change（extensionEvent）→ 严格解码 + 应用（畸形 fail loud）。
    /// - goal/round（extensionEvent，dsh user/message goal source 等价）→
    ///   必须是 active goal 的下一 admitted 轮（fold.ts:321-331 1:1：
    ///   round === roundsStarted+1 且 ≤ maxGoalRounds）→ 推进 roundsStarted。
    static func applyGoalEvent(_ state: inout GoalFoldState, _ event: SessionEvent) throws {
        switch event.payload {
        case .extensionEvent(GoalEvents.changeKind, let payload):
            guard let change = try GoalCodec.decode(payload) else {
                throw GoalError(
                    message: "goal change at session event \(event.seq) has an invalid kind",
                    code: .goalInvalidTransition)
            }
            try applyGoalChange(&state, change)
        case .extensionEvent(GoalEvents.roundKind, let payload):
            guard let source = GoalCodec.decodeRound(payload) else {
                throw GoalError(message: "goal message source is invalid", code: .goalInvalidTransition)
            }
            guard let current = state.goal, current.phase == .active,
                  source.goalId == current.id, source.revision == current.revision,
                  source.round == state.roundsStarted + 1,
                  source.round <= current.maxGoalRounds else {
                throw GoalError(
                    message: "goal round at session event \(event.seq) is not the next admitted round of the active goal",
                    code: .goalInvalidTransition)
            }
            state.roundsStarted = source.round
        default:
            break
        }
    }

    // MARK: - 折叠（fold.ts:339-349 foldGoal 1:1）

    /// Fold current goal state from a contiguous session event log。
    /// - Throws: 首个违规（消费方软捕获进 failure 语义——replay 不断流）。
    static func foldGoal(_ events: [SessionEvent]) throws -> FoldedGoal {
        var state = GoalFoldState.empty()
        for event in events {
            try applyGoalEvent(&state, event)
        }
        return FoldedGoal(goal: state.goal, roundsStarted: state.roundsStarted,
                          createdAt: state.createdAt, updatedAt: state.updatedAt,
                          lastRef: state.lastRef)
    }
}
