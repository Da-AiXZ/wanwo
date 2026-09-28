//
//  GoalTypes.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 B · F006】出处（repos/deepseek-harness-master/packages/goal/
//  goal/src/ 逐文件对拍）：
//    - types.ts:19-24  —— GoalRef{id, revision}（每次持久变更 revision+1）。
//    - types.ts:44-48  —— GoalPhase = active|paused|blocked|complete。
//    - types.ts:51-56  —— GoalBlockReason{code(kebab), message}。
//    - types.ts:59-68  —— GoalSnapshot{objective, phase, blockedReason?, maxGoalRounds}。
//    - types.ts:70-71  —— GoalActivation = armed|disarmed（进程本地永不持久化）。
//    - types.ts:74-100 —— GoalView / GoalProjection。
//    - domain.ts:14-21 —— GoalOperation 七值。
//    - domain.ts:24-44 —— goal/change 两形态（快照变更 | clear 墓碑）。
//    - domain.ts:93-102 —— 9 错误码 1:1。
//    - runtime.ts:8    —— GOAL_CHANGE_VERSION = 1。
//    - index.ts:172-181 —— defaultMaxGoalRounds 缺省 256。
//
//  适配裁定（登记）：
//    - dsh MessageSource{goalId,revision,round} 挂 user/message（user/message
//      事件载荷冻结不可改）→ 万我定案：goal 轮次 admitted 记录经独立
//      extensionEvent kind="goal/round"（requiredFields=[goalId,revision,round]）
//      落盘，fold 从该事件推进 roundsStarted（语义等价，AgentLoop claim 处
//      同步写）。
//    - GoalId branded type → Swift String（typealias；brand 语义由域边界
//      校验承接）。
//

import Foundation

/// Identifies one goal across its durable revisions（types.ts:16 branded id）。
typealias GoalId = String

/// Compare-and-set identity for one exact goal revision（types.ts:19-24）。
struct GoalRef: Equatable, Hashable, Sendable, Codable {
    /// Stable goal identity.
    var id: GoalId
    /// Positive revision; every durable mutation increments it.
    var revision: Int
}

/// Durable continuation phase. Activation is process-local and separate（types.ts:44）。
enum GoalPhase: String, Equatable, Sendable, CaseIterable {
    case active
    case paused
    case blocked
    case complete
}

/// Machine-routable and human-readable explanation for a blocked goal（types.ts:51-56）。
struct GoalBlockReason: Equatable, Sendable {
    /// Stable lower-kebab-case classification chosen by the blocking policy.
    var code: String
    /// Non-empty explanation shown to humans and models.
    var message: String
}

/// Full durable state written by every non-clear goal mutation（types.ts:59-68）。
struct GoalSnapshot: Equatable, Sendable {
    var id: GoalId
    var revision: Int
    /// Human-requested completion objective.
    var objective: String
    /// Durable lifecycle phase.
    var phase: GoalPhase
    /// Present exactly while `phase` is `blocked`.
    var blockedReason: GoalBlockReason?
    /// Total admitted goal-round cap.
    var maxGoalRounds: Int

    var ref: GoalRef { GoalRef(id: id, revision: revision) }
}

/// Whether this live process may automatically continue an active goal（types.ts:70-71）。
enum GoalActivation: String, Equatable, Sendable {
    case armed
    case disarmed
}

/// Live view（types.ts:74-83）：durable 快照 + replay 计数 + 进程本地 activation。
struct GoalView: Equatable, Sendable {
    var id: GoalId
    var revision: Int
    var objective: String
    var phase: GoalPhase
    var blockedReason: GoalBlockReason?
    var maxGoalRounds: Int
    /// Highest admitted round number for this goal.
    var roundsStarted: Int
    /// Epoch milliseconds of the create mutation.
    var createdAt: Int64
    /// Epoch milliseconds of the latest mutation.
    var updatedAt: Int64
    /// Process-local continuation eligibility; never persisted.
    var activation: GoalActivation

    var ref: GoalRef { GoalRef(id: id, revision: revision) }
    var snapshot: GoalSnapshot {
        GoalSnapshot(id: id, revision: revision, objective: objective, phase: phase,
                     blockedReason: blockedReason, maxGoalRounds: maxGoalRounds)
    }
}

/// Strict fold 产物（domain.ts:71-82 FoldedGoal 1:1）。
struct FoldedGoal: Equatable, Sendable {
    var goal: GoalSnapshot?
    var roundsStarted: Int
    var createdAt: Int64?
    var updatedAt: Int64?
    var lastRef: GoalRef?
}

/// Goal state-changing verbs（domain.ts:14-21）。
enum GoalOperation: String, Equatable, Sendable, CaseIterable {
    case create, edit, pause, resume, complete, block, clear
}

/// 快照变更形态（domain.ts:24-32）。
struct GoalSnapshotChange: Equatable, Sendable {
    static let kind = "goal/change"
    var operation: GoalOperation            // 非 clear
    var goal: GoalSnapshot
    var roundsStarted: Int
    var createdAt: Int64
    var updatedAt: Int64
}

/// clear 墓碑形态（domain.ts:35-41）。
struct GoalClearChange: Equatable, Sendable {
    var cleared: GoalRef
    var clearedAt: Int64
}

/// Durable change union（domain.ts:44）。
enum GoalChangeMeta: Equatable, Sendable {
    case snapshot(GoalSnapshotChange)
    case clear(GoalClearChange)

    var operation: GoalOperation {
        switch self {
        case .snapshot(let change): return change.operation
        case .clear: return .clear
        }
    }
}

/// Live notification after one durable goal mutation commits（domain.ts:85-90）
/// + 万我扩展 origin（dsh currentInitiator() 检查的进程内等价——host 侧 pause
/// 在运行中回合触发 cancel，模型侧 pause 自然收尾；AgentLoop.onGoalChanged 消费）。
enum GoalMutationOrigin: Equatable, Sendable {
    /// 宿主面（/goal 命令、round driver）。
    case host
    /// 模型面（update_goal 工具，运行于其自身回合内）。
    case model
}

struct GoalChanged: Equatable, Sendable {
    var operation: GoalOperation
    var ref: GoalRef
    /// Absent for a clear tombstone.
    var goal: GoalView?
    var origin: GoalMutationOrigin
}

/// Stable error codes（domain.ts:93-102 九码 1:1）。
enum GoalErrorCode: String, Equatable, Sendable, CaseIterable {
    case goalAgentNotLive = "GOAL_AGENT_NOT_LIVE"
    case goalNotFound = "GOAL_NOT_FOUND"
    case goalAlreadyExists = "GOAL_ALREADY_EXISTS"
    case goalStaleRevision = "GOAL_STALE_REVISION"
    case goalInvalidObjective = "GOAL_INVALID_OBJECTIVE"
    case goalInvalidMaxRounds = "GOAL_INVALID_MAX_ROUNDS"
    case goalInvalidBlockReason = "GOAL_INVALID_BLOCK_REASON"
    case goalInvalidEdit = "GOAL_INVALID_EDIT"
    case goalInvalidTransition = "GOAL_INVALID_TRANSITION"
}

/// Error returned by the goal domain boundary（runtime.ts:20-30）。
struct GoalError: Error, Equatable {
    var message: String
    var code: GoalErrorCode
}

/// 工具面策略错误（tool-goal authority.ts:24-26 HarnessError 的 WanWo 形态）。
struct GoalToolError: Error, Equatable {
    var message: String
    var code: String
}

/// 域常量（runtime.ts:8 + index.ts:244 default 256）。
enum GoalDomain {
    static let changeVersion = 1
    static let defaultMaxGoalRounds = 256
}

// MARK: - extensionEvent 注册（简报件 B 拍板：goal/change + goal/round）

/// goal 域 extensionEvent 注册面（装配期幂等；AgentLoop claim 处同步写
/// goal/round——dsh MessageSource 的伴随事件等价，见头注适配裁定）。
enum GoalEvents {
    /// wire type = "extension/goal/change"（快照变更 | clear 墓碑；深度校验在
    /// GoalCodec 严格解码 1:1——ExtensionFieldSchema 表达力边界，登记）。
    static let changeKind = "goal/change"
    /// wire type = "extension/goal/round"（admitted 轮次记录；fold 据此推进
    /// roundsStarted——dsh user/message source 的 WanWo 等价承载）。
    static let roundKind = "goal/round"

    static func register() {
        if !ExtensionEventRegistry.shared.isRegistered(changeKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: changeKind,
                requiredFields: [ExtensionFieldSchema("version", .int)],
                projection: .logOnly))
        }
        if !ExtensionEventRegistry.shared.isRegistered(roundKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: roundKind,
                requiredFields: [
                    ExtensionFieldSchema("goalId", .string),
                    ExtensionFieldSchema("revision", .int),
                    ExtensionFieldSchema("round", .int),
                ],
                projection: .logOnly))
        }
    }
}

// MARK: - 载荷编解码（fold.ts 严格解码的写侧对称面）

/// goal/change 载荷 ↔ GoalChangeMeta（字段集精确——fold.ts:134-172 的
/// 解码规则在写侧同样强制，读写两侧闭环）。
enum GoalCodec {
    // MARK: 编码（写侧）

    static func encode(_ change: GoalChangeMeta) -> JSONValue {
        switch change {
        case .snapshot(let change):
            var goal: [String: JSONValue] = [
                "id": .string(change.goal.id),
                "revision": .int(change.goal.revision),
                "objective": .string(change.goal.objective),
                "phase": .string(change.goal.phase.rawValue),
                "maxGoalRounds": .int(change.goal.maxGoalRounds),
            ]
            if let reason = change.goal.blockedReason {
                goal["blockedReason"] = .object([
                    "code": .string(reason.code),
                    "message": .string(reason.message),
                ])
            }
            return .object([
                "kind": .string("goal/change"),
                "version": .int(GoalDomain.changeVersion),
                "operation": .string(change.operation.rawValue),
                "goal": .object(goal),
                "roundsStarted": .int(change.roundsStarted),
                "createdAt": .int(change.createdAt),
                "updatedAt": .int(change.updatedAt),
            ])
        case .clear(let change):
            return .object([
                "kind": .string("goal/change"),
                "version": .int(GoalDomain.changeVersion),
                "operation": .string("clear"),
                "cleared": .object([
                    "id": .string(change.cleared.id),
                    "revision": .int(change.cleared.revision),
                ]),
                "clearedAt": .int(change.clearedAt),
            ])
        }
    }

    static func ref(of change: GoalChangeMeta) -> GoalRef {
        switch change {
        case .snapshot(let change):
            return change.goal.ref
        case .clear(let change):
            return change.cleared
        }
    }

    // MARK: 解码（fold.ts:134-172 decodeGoalChange 1:1：字段集精确/时间戳/
    // kebab code/值域；不相关值返回 nil，畸形 goal change 抛错）

    /// 解码声明自己为 goal change 的值；kind 不符返回 nil（fold.ts:135）。
    static func decode(_ value: JSONValue) throws -> GoalChangeMeta? {
        guard value.field("kind")?.stringValue == "goal/change" else { return nil }
        guard value.field("version")?.intValue == GoalDomain.changeVersion else {
            throw GoalError(
                message: "unsupported goal change version \(value.field("version")?.intValue ?? -1)",
                code: .goalInvalidTransition)
        }
        let operation = value.field("operation")?.stringValue
        if operation == "clear" {
            let allowed: Set<String> = ["cleared", "clearedAt", "kind", "operation", "version"]
            guard let fields = value.objectValue, Set(fields.keys) == allowed else {
                throw GoalError(
                    message: "goal clear change must have exactly cleared,clearedAt,kind,operation,version fields",
                    code: .goalInvalidTransition)
            }
            guard let cleared = decodeRef(value.field("cleared")) else {
                throw GoalError(message: "goal clear tombstone must have exactly id and revision fields",
                                code: .goalInvalidTransition)
            }
            let clearedAt = try nonNegative(value.field("clearedAt")?.intValue, "clearedAt")
            return .clear(GoalClearChange(cleared: cleared, clearedAt: clearedAt))
        }
        guard let operation, GoalOperation(rawValue: operation) != nil, operation != "clear" else {
            throw GoalError(message: "goal change operation is invalid", code: .goalInvalidTransition)
        }
        let allowed: Set<String> = ["createdAt", "goal", "kind", "operation", "roundsStarted",
                                    "updatedAt", "version"]
        guard let fields = value.objectValue, Set(fields.keys) == allowed else {
            throw GoalError(
                message: "goal snapshot change must have exactly createdAt,goal,kind,operation,roundsStarted,updatedAt,version fields",
                code: .goalInvalidTransition)
        }
        let createdAt = try nonNegative(value.field("createdAt")?.intValue, "createdAt")
        let updatedAt = try nonNegative(value.field("updatedAt")?.intValue, "updatedAt")
        if updatedAt < createdAt {
            throw GoalError(message: "goal change updatedAt cannot precede createdAt",
                            code: .goalInvalidTransition)
        }
        guard let goal = decodeSnapshot(value.field("goal")) else {
            throw GoalError(message: "goal change goal must be a record", code: .goalInvalidTransition)
        }
        let roundsStarted = try nonNegative(value.field("roundsStarted")?.intValue, "roundsStarted")
        return .snapshot(GoalSnapshotChange(
            operation: GoalOperation(rawValue: operation) ?? .create,
            goal: goal, roundsStarted: roundsStarted, createdAt: createdAt, updatedAt: updatedAt))
    }

    /// goal/round 载荷解码（fold.ts:175-183 goalSource 的伴随事件等价）。
    static func decodeRound(_ payload: JSONValue) -> GoalRef.Round? {
        guard let goalId = payload.field("goalId")?.stringValue, !goalId.isEmpty,
              let revision = payload.field("revision")?.intValue, revision >= 1,
              let round = payload.field("round")?.intValue, round >= 1 else { return nil }
        return GoalRef.Round(goalId: goalId, revision: revision, round: round)
    }

    // MARK: 私有解码器（fold.ts:73-126）

    private static func positive(_ value: Int?, _ field: String) throws -> Int {
        guard let value, value >= 1 else {
            throw GoalError(message: "goal change \(field) must be a positive safe integer",
                            code: .goalInvalidTransition)
        }
        return value
    }

    private static func nonNegative(_ value: Int?, _ field: String) throws -> Int {
        guard let value, value >= 0 else {
            throw GoalError(message: "goal change \(field) must be a non-negative safe integer",
                            code: .goalInvalidTransition)
        }
        return value
    }

    /// decodeBlockReason（fold.ts:73-85 1:1：字段集精确 + kebab 正则 + message 归一）。
    static func decodeBlockReason(_ value: JSONValue?) -> GoalBlockReason? {
        guard let fields = value?.objectValue, Set(fields.keys) == ["code", "message"] else {
            return nil
        }
        guard let code = fields["code"]?.stringValue,
              code.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            return nil
        }
        guard let message = fields["message"]?.stringValue,
              !message.trimmingCharacters(in: .whitespaces).isEmpty,
              message == message.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return GoalBlockReason(code: code, message: message)
    }

    /// decodeSnapshot（fold.ts:88-115 1:1：objective 归一/phase 值域/字段集
    /// 随 phase 精确/revision 与 maxGoalRounds 正整数）。
    static func decodeSnapshot(_ value: JSONValue?) -> GoalSnapshot? {
        guard let fields = value?.objectValue else { return nil }
        guard let id = fields["id"]?.stringValue, !id.isEmpty else { return nil }
        guard let objective = fields["objective"]?.stringValue,
              !objective.trimmingCharacters(in: .whitespaces).isEmpty,
              objective == objective.trimmingCharacters(in: .whitespaces) else { return nil }
        guard let phaseRaw = fields["phase"]?.stringValue,
              let phase = GoalPhase(rawValue: phaseRaw) else { return nil }
        var expected: Set<String> = ["id", "maxGoalRounds", "objective", "phase", "revision"]
        if phase == .blocked { expected.insert("blockedReason") }
        guard Set(fields.keys) == expected else { return nil }
        guard let revision = try? positive(fields["revision"]?.intValue, "goal.revision"),
              let maxGoalRounds = try? positive(fields["maxGoalRounds"]?.intValue, "goal.maxGoalRounds") else {
            return nil
        }
        var blockedReason: GoalBlockReason?
        if phase == .blocked {
            guard let reason = decodeBlockReason(fields["blockedReason"]) else { return nil }
            blockedReason = reason
        }
        return GoalSnapshot(id: id, revision: revision, objective: objective, phase: phase,
                            blockedReason: blockedReason, maxGoalRounds: maxGoalRounds)
    }

    /// decodeRef（fold.ts:118-126 1:1）。
    static func decodeRef(_ value: JSONValue?) -> GoalRef? {
        guard let fields = value?.objectValue, Set(fields.keys) == ["id", "revision"],
              let id = fields["id"]?.stringValue, !id.isEmpty,
              let revision = try? positive(fields["revision"]?.intValue, "cleared.revision") else {
            return nil
        }
        return GoalRef(id: id, revision: revision)
    }
}

extension GoalRef {
    /// 消息归属身份（domain.ts:47-53 GoalMessageSource 的伴随事件承载形态）。
    struct Round: Equatable, Hashable, Sendable {
        var goalId: GoalId
        var revision: Int
        var round: Int
    }
}
