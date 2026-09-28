//
//  TeamProjection.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 L · F046】出处（experimental/agent-team/src/
//  projection.ts，逐文件实读本体）：
//    - TeamState :127-134（id/members/tasks/messages/delivered/nextTaskNumber）
//      + emptyTeamState :141-150 1:1。
//    - applyCurrentTeamEvent :237-304 四事件转移规则逐语义：
//      member（新行必须 provisioning 起/不可变字段/name 跨行复用拒/状态机
//      provisioning→active|failed 单向）、task（revision 连续/任务图校验/
//      数值 id 推进 nextTaskNumber）、queued（id 去重）、delivered（先 queued
//      后 delivered/target 不变/幂等去重）。
//    - applyProjectionEvent :221-235 —— failure 中毒面（后续事件不再应用）。
//  万我适配（登记）：
//    - dsh sessionProjections 增量注册 → 万我 TeamService 内存缓存 + 日志重放
//      重建（rebuildFromEvents——journal 重放语义等价）。
//    - zod strict 解码 → JSONValue 手工解码 + 缺字段拒绝（fail closed 等价）。
//

import Foundation

/// 当前 Team 状态（projection.ts :127-134 + :152-155 failure 面合并）。
struct TeamState: Sendable {
    var id: String
    var members: [TeamMemberSnapshot]
    var tasks: [TeamTaskSnapshot]
    var messages: [TeamMessageSnapshot]
    var delivered: [String]
    var nextTaskNumber: Int
    /// 投影失败中毒面（applyProjectionEvent :233——置位后不再应用任何事件；
    /// 权威操作抛 failure 文案——journal.state :30-34）。
    var failure: String?

    /// emptyTeamState 1:1（projection.ts :141-150）。
    static func empty(rootId: String) -> TeamState {
        TeamState(id: rootId, members: [], tasks: [], messages: [],
                  delivered: [], nextTaskNumber: 1, failure: nil)
    }
}

/// Team 投影（applyCurrentTeamEvent 四事件规则 1:1）。
enum TeamProjection {

    /// 是否 Team 域事件（isTeamEvent :188-193 1:1）。
    static func isTeamEvent(_ payload: SessionEvent.Payload) -> Bool {
        if case .extensionEvent(let kind, _) = payload {
            return TeamEvents.allKinds.contains(kind)
        }
        return false
    }

    /// 从 Lead 会话日志重放重建（dsh projection init+apply 等价——journal
    /// 重放语义；顺序敏感，append-only 日志保证）。
    static func rebuildFromEvents(rootId: String, events: [SessionEvent]) -> TeamState {
        var state = TeamState.empty(rootId: rootId)
        for event in events {
            apply(&state, payload: event.payload)
        }
        return state
    }

    /// 单事件应用（applyProjectionEvent :221-235 + applyCurrentTeamEvent
    /// :237-304 逐语义；他 Team 事件跳过；failure 中毒后不再应用）。
    static func apply(_ state: inout TeamState, payload: SessionEvent.Payload) {
        guard state.failure == nil else { return }
        guard isTeamEvent(payload) else { return }
        guard case .extensionEvent(let kind, let data) = payload else { return }
        do {
            try TeamEvents.selector(of: data, teamId: state.id)
            switch kind {
            case TeamEvents.memberKind:
                try applyMember(&state, data: data)
            case TeamEvents.taskKind:
                try applyTask(&state, data: data)
            case TeamEvents.messageQueuedKind:
                try applyQueued(&state, data: data)
            case TeamEvents.messageDeliveredKind:
                try applyDelivered(&state, data: data)
            default:
                return
            }
        } catch {
            state.failure = (error as? TeamError)?.message ?? String(describing: error)
        }
    }

    // MARK: team/member（:239-259）

    private static func applyMember(_ state: inout TeamState, data: JSONValue) throws {
        guard let raw = data.field("member"), let member = TeamMemberSnapshot.decode(raw) else {
            throw TeamError("persisted Agent Teams team/member payload is invalid",
                            code: TeamError.invalidArgument)
        }
        let index = state.members.firstIndex { $0.id == member.id }
        let prior = index.map { state.members[$0] }
        if let named = state.members.first(where: { $0.name == member.name }),
           named.id != member.id {
            throw TeamError("teammate name \"\(member.name)\" is reused by another member",
                            code: TeamError.invalidArgument)
        }
        if prior == nil {
            if member.phase != .provisioning {
                throw TeamError("teammate \"\(member.name)\" must begin provisioning",
                                code: TeamError.invalidArgument)
            }
        } else {
            if prior!.name != member.name || prior!.provider != member.provider
                || prior!.context != member.context
                || prior!.prompt != member.prompt {
                throw TeamError(
                    "teammate \"\(member.id)\" changed immutable identity fields",
                    code: TeamError.invalidArgument)
            }
            if prior!.phase != .provisioning || member.phase == .provisioning {
                throw TeamError(
                    "teammate \"\(member.name)\" has an invalid "
                        + "\(prior!.phase.rawValue) -> \(member.phase.rawValue) transition",
                    code: TeamError.invalidArgument)
            }
        }
        if let index {
            state.members[index] = member
        } else {
            state.members.append(member)
        }
    }

    // MARK: team/task（:261-282）

    private static func applyTask(_ state: inout TeamState, data: JSONValue) throws {
        guard let raw = data.field("task"), let task = TeamTaskSnapshot.decode(raw) else {
            throw TeamError("persisted Agent Teams team/task payload is invalid",
                            code: TeamError.invalidArgument)
        }
        let index = state.tasks.firstIndex { $0.id == task.id }
        let prior = index.map { state.tasks[$0] }
        if prior == nil && task.revision != 1 {
            throw TeamError("team task \"\(task.id)\" must begin at revision 1",
                            code: TeamError.invalidArgument)
        }
        if let prior, task.revision != prior.revision + 1 {
            throw TeamError("team task \"\(task.id)\" revision is not contiguous",
                            code: TeamError.invalidArgument)
        }
        do {
            try TeamTaskGraph.assertCandidate(current: state.tasks, candidate: task)
        } catch let error as TeamTaskGraph.GraphError {
            // TASK_GRAPH_ERROR_CODES（task-board.ts :25-29）。
            let code: String
            switch error.violation {
            case .missing: code = TeamError.taskNotFound
            case .duplicate: code = TeamError.invalidArgument
            case .cycle: code = TeamError.taskDependencyCycle
            }
            throw TeamError(error.message, code: code)
        }
        // 数值任务 id 推进 nextTaskNumber（:272-279 1:1——task-N 后缀最大值+1）。
        if let number = numericTaskNumber(task.id) {
            state.nextTaskNumber = max(state.nextTaskNumber,
                                       number == Int.max ? number : number + 1)
        }
        if let index {
            state.tasks[index] = task
        } else {
            state.tasks.append(task)
        }
    }

    /// numericTaskIdPattern = /^task-(\d+)$/u（projection.ts :26）。
    static func numericTaskNumber(_ id: String) -> Int? {
        guard id.hasPrefix("task-") else { return nil }
        let suffix = String(id.dropFirst("task-".count))
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
              let number = Int(suffix) else { return nil }
        return number
    }

    // MARK: team/message/queued（:284-290）

    private static func applyQueued(_ state: inout TeamState, data: JSONValue) throws {
        guard let raw = data.field("message"), let message = TeamMessageSnapshot.decode(raw) else {
            throw TeamError("persisted Agent Teams team/message/queued payload is invalid",
                            code: TeamError.invalidArgument)
        }
        if state.messages.contains(where: { $0.id == message.id }) {
            throw TeamError("team message \"\(message.id)\" was queued twice",
                            code: TeamError.invalidArgument)
        }
        state.messages.append(message)
    }

    // MARK: team/message/delivered（:292-298）

    private static func applyDelivered(_ state: inout TeamState, data: JSONValue) throws {
        guard let messageId = data.field("messageId")?.stringValue,
              let targetId = data.field("targetId")?.stringValue else {
            throw TeamError("persisted Agent Teams team/message/delivered payload is invalid",
                            code: TeamError.invalidArgument)
        }
        guard let queued = state.messages.first(where: { $0.id == messageId }) else {
            throw TeamError("team message \"\(messageId)\" was delivered before queueing",
                            code: TeamError.invalidArgument)
        }
        if queued.targetId != targetId {
            throw TeamError("team message \"\(messageId)\" target changed",
                            code: TeamError.invalidArgument)
        }
        if state.delivered.contains(messageId) {
            throw TeamError("team message \"\(messageId)\" was delivered twice",
                            code: TeamError.invalidArgument)
        }
        state.delivered.append(messageId)
    }
}
