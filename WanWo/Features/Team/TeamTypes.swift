//
//  TeamTypes.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 L · F046】出处（analysis/dsh-upstream-m5/packages/
//  experimental/agent-team/src/ + tool-agent-team/src/index.ts，逐文件实读本体）：
//    - types.ts —— TeamId/TeamTaskId/TeamMessageId 品牌型（万我 String typealias
//      承载）、TeamMemberPhase/TeamMemberSnapshot/TeamMemberView、TeamTaskStatus/
//      TeamTaskSnapshot/TeamTaskView、TeamMessageSnapshot、TeamTaskAction 七+
//      UpdateTeamTaskRequest、SendTeamMessageResult、TeamWaitResult 1:1。
//    - index.ts :44-48 —— 五常量 1:1（maxMembers 8 / maxTasks 256 /
//      maxPendingMessagesPerMember 64 / maxMessageBytes 65536 /
//      disposalTimeoutMs 5000）。
//    - validation.ts —— requiredText / writeScope 逐语义。
//    - task-graph.ts —— assertTaskGraphCandidate 全图校验 1:1（missing/
//      duplicate/cycle 三 violation）。
//    - types.ts:218-234 —— 四事件 wire version 2 形态（extensionEvent 通道，
//      已定适配①；InboxSource 增 case 由主理人合并统一加——见 TeamService 头注）。
//  万我适配（登记）：
//    - experimental 语义：dsh 五 Teams 包显式公开；万我不引入 experimental
//      标记机制（已定适配④）。
//    - dsh durable ContentBlock[] 消息体 → 万我纯文本 message（userMessage
//      词汇冻结——dsh ContentBlock 序列面万我无对应，登记）。
//

import Foundation

// MARK: - 常量（index.ts :44-48 1:1 + tool 词汇）

/// Agent Teams 全链常量（出处逐项见头注）。
enum TeamConstants {
    /// 每个花名册最大不可复用成员名数（DEFAULT_MAX_MEMBERS）。
    static let maxMembers = 8
    /// 每 Team 最大未删除任务数（DEFAULT_MAX_TASKS）。
    static let maxTasks = 256
    /// 单目标 queued-minus-delivered 消息上限（DEFAULT_MAX_PENDING_MESSAGES）。
    static let maxPendingMessagesPerMember = 64
    /// 单条完整 sender-framed 投递 UTF-8 字节上限（DEFAULT_MAX_MESSAGE_BYTES）。
    static let maxMessageBytes = 65_536
    /// Team 运行时处置宽限毫秒（DEFAULT_DISPOSAL_TIMEOUT_MS）。
    static let disposalTimeoutMs = 5_000
    /// wait_agent/waitForChange 等待界（tool-agent-team :243 1:1：10s–1h）。
    static let minWaitTimeoutMs = 10_000
    static let maxWaitTimeoutMs = 3_600_000
    /// wait_agent 缺省等待毫秒（tool-agent-team :240 缺省 30_000）。
    static let defaultWaitTimeoutMs = 30_000
    /// teammate 名规则（roster.ts :26 MEMBER_NAME 正则语义）：
    /// lower-kebab-case、≤64 字符、不得叫 "lead"。
    static let memberNameMaxLength = 64
    /// 任务 subject / description 文本上限（task-board create 1:1：
    /// subject 200 / description 16_384）。
    static let taskSubjectMaxLength = 200
    static let taskDescriptionMaxLength = 16_384
    /// teammate 启动请求 label 前缀（万我适配：teammate 栈装配期 team 作用域
    /// 判定承载——dsh durable descriptor 语义的万我 label 承载，登记）。
    static let memberLabelPrefix = "team-member:"
    /// 投递框架行（mailbox deliveryContent :309-314 逐字——"Team message
    /// {id} from {senderName}:"；万我以内容指纹承载 durable 去重身份，登记）。
    static func deliveryFrame(messageId: String, senderName: String) -> String {
        "Team message \(messageId) from \(senderName):"
    }
    /// 邮箱消息 id 形态（mailbox :131 `team-message-${randomUUID}` 1:1）。
    static func newMessageId() -> String { "team-message-\(UUID().uuidString)" }
    /// 任务 id 形态（task-board :56 `task-${nextTaskNumber}` 1:1）。
    static func taskId(_ number: Int) -> String { "task-\(number)" }
}

// MARK: - 域错误（error.ts TeamError 1:1）

/// Team 域稳定失败码（error.ts HarnessError code 词汇 1:1）。
struct TeamError: Error, CustomStringConvertible {
    let message: String
    let code: String

    init(_ message: String, code: String) {
        self.message = message
        self.code = code
    }

    var description: String { message }

    // 稳定码词汇（dsh 调用面逐处对拍）。
    static let notMember = "TEAM_NOT_MEMBER"
    static let leadRequired = "TEAM_LEAD_REQUIRED"
    static let memberNotFound = "TEAM_MEMBER_NOT_FOUND"
    static let invalidTarget = "TEAM_INVALID_TARGET"
    static let invalidMemberName = "TEAM_INVALID_MEMBER_NAME"
    static let memberNameTaken = "TEAM_MEMBER_NAME_TAKEN"
    static let memberLimit = "TEAM_MEMBER_LIMIT"
    static let selfMessage = "TEAM_SELF_MESSAGE"
    static let mailboxFull = "TEAM_MAILBOX_FULL"
    static let messageTooLarge = "TEAM_MESSAGE_TOO_LARGE"
    static let invalidArgument = "TEAM_INVALID_ARGUMENT"
    static let invalidWriteScope = "TEAM_INVALID_WRITE_SCOPE"
    static let invalidTimeout = "TEAM_INVALID_TIMEOUT"
    static let taskNotFound = "TEAM_TASK_NOT_FOUND"
    static let taskLimit = "TEAM_TASK_LIMIT"
    static let taskStaleRevision = "TEAM_TASK_STALE_REVISION"
    static let taskDeleted = "TEAM_TASK_DELETED"
    static let taskUnauthorized = "TEAM_TASK_UNAUTHORIZED"
    static let taskAlreadyClaimed = "TEAM_TASK_ALREADY_CLAIMED"
    static let taskBlocked = "TEAM_TASK_BLOCKED"
    static let taskInvalidTransition = "TEAM_TASK_INVALID_TRANSITION"
    static let taskHasDependents = "TEAM_TASK_HAS_DEPENDENTS"
    static let taskDependencyCycle = "TEAM_TASK_DEPENDENCY_CYCLE"
    static let provisioningConflict = "TEAM_PROVISIONING_CONFLICT"
    static let leadSessionUnavailable = "TEAM_LEAD_SESSION_UNAVAILABLE"
}

// MARK: - 花名册（types.ts :44-68 1:1）

/// Durable teammate 生命周期（types.ts :44）。
enum TeamMemberPhase: String, Equatable, Sendable {
    case provisioning
    case active
    case failed
}

/// 每次生命周期变更写入的整值快照（types.ts :47-55 strict 1:1）。
struct TeamMemberSnapshot: Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var provider: String
    var context: String   // 'fresh' | 'fork'
    var phase: TeamMemberPhase
    var error: String?
    /// 万我扩展（QA-6 P0-1 登记）：初始 prompt 持久参照——reconcile 与
    /// waitForPromptAccepted 同口径（hasPrefix）的参照面。dsh strict snapshot
    /// 无此字段；encode 随行、decode 容缺（旧日志 nil → reconcile 宽松回退
    /// ——升级窗口兼容）。project applyMember 按不可变字段校验。
    var prompt: String? = nil

    func encoded() -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "description": .string(description),
            "provider": .string(provider),
            "context": .string(context),
            "phase": .string(phase.rawValue),
        ]
        if let error { fields["error"] = .string(error) }
        if let prompt { fields["prompt"] = .string(prompt) }
        return .object(fields)
    }

    static func decode(_ payload: JSONValue) -> TeamMemberSnapshot? {
        guard let id = payload.field("id")?.stringValue,
              let name = payload.field("name")?.stringValue,
              let description = payload.field("description")?.stringValue,
              let provider = payload.field("provider")?.stringValue,
              let context = payload.field("context")?.stringValue,
              let phaseRaw = payload.field("phase")?.stringValue,
              let phase = TeamMemberPhase(rawValue: phaseRaw) else { return nil }
        return TeamMemberSnapshot(id: id, name: name, description: description,
                                  provider: provider, context: context,
                                  phase: phase,
                                  error: payload.field("error")?.stringValue,
                                  prompt: payload.field("prompt")?.stringValue)
    }
}

/// 运行时增强的花名册行（types.ts :58-68 1:1）。
struct TeamMemberView: Equatable, Sendable {
    var id: String
    var name: String
    var role: String        // 'lead' | 'teammate'
    var status: String      // running | idle | inactive | provisioning | failed
    var description: String?
    var provider: String?
    var context: String?
    var model: String?
    var diagnostics: [String]
}

// MARK: - 任务板（types.ts :71-97 1:1）

/// Durable task 生命周期（types.ts :71）。
enum TeamTaskStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case deleted
}

/// 整值任务快照；每次变更 revision +1（types.ts :74-83 strict 1:1）。
struct TeamTaskSnapshot: Equatable, Sendable {
    var id: String
    var revision: Int
    var subject: String
    var description: String
    var status: TeamTaskStatus
    var ownerId: String?
    var blockedBy: [String]
    var writeScopes: [String]

    func encoded() -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "revision": .int(revision),
            "subject": .string(subject),
            "description": .string(description),
            "status": .string(status.rawValue),
            "blockedBy": .array(blockedBy.map { .string($0) }),
            "writeScopes": .array(writeScopes.map { .string($0) }),
        ]
        if let ownerId { fields["ownerId"] = .string(ownerId) }
        return .object(fields)
    }

    static func decode(_ payload: JSONValue) -> TeamTaskSnapshot? {
        guard let id = payload.field("id")?.stringValue,
              let revision = payload.field("revision")?.intValue,
              let subject = payload.field("subject")?.stringValue,
              let description = payload.field("description")?.stringValue,
              let statusRaw = payload.field("status")?.stringValue,
              let status = TeamTaskStatus(rawValue: statusRaw),
              let blockedByRaw = payload.field("blockedBy")?.arrayItems,
              let writeScopesRaw = payload.field("writeScopes")?.arrayItems else {
            return nil
        }
        return TeamTaskSnapshot(
            id: id, revision: revision, subject: subject, description: description,
            status: status,
            ownerId: payload.field("ownerId")?.stringValue,
            blockedBy: blockedByRaw.compactMap(\.stringValue),
            writeScopes: writeScopesRaw.compactMap(\.stringValue))
    }
}

/// 运行时增强任务视图（types.ts :86-97 1:1）。
struct TeamTaskView: Equatable, Sendable {
    var id: String
    var revision: Int
    var subject: String
    var description: String
    var status: TeamTaskStatus
    var blockedBy: [String]
    var writeScopes: [String]
    var ownerName: String?
    var ready: Bool
    var writeScopeWarnings: [String]
}

// MARK: - 邮箱（types.ts :106-121 1:1）

/// durable 邻message（types.ts :106-112；万我 content = 纯文本，登记）。
struct TeamMessageSnapshot: Equatable, Sendable {
    var id: String
    var senderId: String
    var senderName: String
    var targetId: String
    var content: String

    func encoded() -> JSONValue {
        .object([
            "id": .string(id),
            "senderId": .string(senderId),
            "senderName": .string(senderName),
            "targetId": .string(targetId),
            "content": .string(content),
        ])
    }

    static func decode(_ payload: JSONValue) -> TeamMessageSnapshot? {
        guard let id = payload.field("id")?.stringValue,
              let senderId = payload.field("senderId")?.stringValue,
              let senderName = payload.field("senderName")?.stringValue,
              let targetId = payload.field("targetId")?.stringValue,
              let content = payload.field("content")?.stringValue else { return nil }
        return TeamMessageSnapshot(id: id, senderId: senderId, senderName: senderName,
                                   targetId: targetId, content: content)
    }
}

/// 发送结果（types.ts :166-169 1:1：queued 也已持久——勿重发）。
struct SendTeamMessageResult: Equatable, Sendable {
    var messageId: String
    var status: String   // 'accepted' | 'queued'
}

/// 等待结果（types.ts :214-216 1:1）。
struct TeamWaitResult: Equatable, Sendable {
    var timedOut: Bool
}

// MARK: - 任务变更请求（types.ts :180-200 1:1）

/// 支持的任务变更动作（types.ts :180-188）。
enum TeamTaskAction: String, Equatable, Sendable {
    case claim, release, edit
    case setDependencies = "set_dependencies"
    case complete, reopen, reassign, delete
}

/// CAS 任务变更请求（types.ts :191-200 1:1）。
struct UpdateTeamTaskRequest: Sendable {
    var taskId: String
    var expectedRevision: Int
    var action: TeamTaskAction
    var subject: String?
    var description: String?
    var blockedBy: [String]?
    var writeScopes: [String]?
    var owner: String?
}

// MARK: - 校验（validation.ts 1:1）

/// Team 输入归一化（validation.ts 逐语义）。
enum TeamValidation {
    /// requiredText 1:1（validation.ts :12-19）。
    static func requiredText(_ value: String, field: String, maxLength: Int) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw TeamError("\(field) must be non-empty", code: TeamError.invalidArgument)
        }
        if text.count > maxLength {
            throw TeamError("\(field) exceeds \(maxLength) characters",
                            code: TeamError.invalidArgument)
        }
        return text
    }

    /// writeScope 1:1（validation.ts :26-34——工作区相对路径前缀归一化，
    /// 咨询性告警非锁）。
    static func writeScope(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        var work = normalized
        if work.hasPrefix("./") { work = String(work.dropFirst(2)) }
        while work.hasSuffix("/") { work = String(work.dropLast()) }
        let segments = work.split(separator: "/", omittingEmptySubsequences: false)
        let drivePattern = work.range(of: "^[a-zA-Z]:", options: .regularExpression) != nil
        if work.isEmpty || work.hasPrefix("/") || drivePattern
            || segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw TeamError(
                "invalid workspace-relative write scope \(String(describing: value))",
                code: TeamError.invalidWriteScope)
        }
        return work
    }

    /// memberName 1:1（roster.ts :26 正则 + :453-461 校验——lower-kebab-case、
    /// ≤64、不得叫 "lead"）。
    static func isValidMemberName(_ value: String) -> Bool {
        guard value.count <= TeamConstants.memberNameMaxLength, value != "lead" else {
            return false
        }
        // MEMBER_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u
        return value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// scopesOverlap 1:1（task-board.ts :21-23——路径组件前缀重叠）。
    static func scopesOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix("\(right)/") || right.hasPrefix("\(left)/")
    }
}

// MARK: - 任务图校验（task-graph.ts 1:1）

/// 共享任务图完整校验（task-graph.ts :26-69 1:1）。
enum TeamTaskGraph {
    enum Violation: String, Sendable {
        case missing, duplicate, cycle
    }

    struct GraphError: Error {
        var message: String
        var violation: Violation
    }

    /// 替换单个候选快照后的全图校验（assertTaskGraphCandidate 1:1）。
    static func assertCandidate(current: [TeamTaskSnapshot],
                                candidate: TeamTaskSnapshot) throws {
        var tasks = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        tasks[candidate.id] = candidate

        for task in tasks.values where task.status != .deleted {
            var seen = Set<String>()
            for blockerId in task.blockedBy {
                if blockerId == task.id {
                    throw GraphError(
                        message: "team task \"\(task.id)\" cannot block itself",
                        violation: .cycle)
                }
                if seen.contains(blockerId) {
                    throw GraphError(
                        message: "team task \"\(task.id)\" repeats blocker \"\(blockerId)\"",
                        violation: .duplicate)
                }
                guard let blocker = tasks[blockerId], blocker.status != .deleted else {
                    throw GraphError(
                        message: "blocker task \"\(blockerId)\" for \"\(task.id)\" is missing or deleted",
                        violation: .missing)
                }
                seen.insert(blockerId)
            }
        }

        // 环检测（DFS 三色——task-graph.ts :54-68 1:1）。
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ id: String) throws {
            if visiting.contains(id) {
                throw GraphError(
                    message: "task dependency cycle includes \"\(id)\"",
                    violation: .cycle)
            }
            if visited.contains(id) { return }
            guard let task = tasks[id], task.status != .deleted else { return }
            visiting.insert(id)
            for blockerId in task.blockedBy { try visit(blockerId) }
            visiting.remove(id)
            visited.insert(id)
        }
        for task in tasks.values { try visit(task.id) }
    }
}

// MARK: - 事件词汇（types.ts :218-234 wire version 2 · extensionEvent 通道）

/// 四 Team 事件（已定适配①：dsh SessionEventMap team/* → 万我 extensionEvent；
/// wire version 2 形态照 types.ts:218-234 逐字）。
enum TeamEvents {
    /// wire type = "extension/team/member"。
    static let memberKind = "team/member"
    /// wire type = "extension/team/task"。
    static let taskKind = "team/task"
    /// wire type = "extension/team/message/queued"。
    static let messageQueuedKind = "team/message/queued"
    /// wire type = "extension/team/message/delivered"。
    static let messageDeliveredKind = "team/message/delivered"

    /// 全部 Team 事件 kind（投影过滤面）。
    static var allKinds: Set<String> {
        [memberKind, taskKind, messageQueuedKind, messageDeliveredKind]
    }

    /// 装配期注册（幂等；AppEnvironment init 调用——TodoEvents.register 同款）。
    static func register() {
        let schemas: [(String, [ExtensionFieldSchema])] = [
            (memberKind, [ExtensionFieldSchema("version", .int),
                          ExtensionFieldSchema("teamId", .string),
                          ExtensionFieldSchema("member", .object)]),
            (taskKind, [ExtensionFieldSchema("version", .int),
                        ExtensionFieldSchema("teamId", .string),
                        ExtensionFieldSchema("task", .object)]),
            (messageQueuedKind, [ExtensionFieldSchema("version", .int),
                                 ExtensionFieldSchema("teamId", .string),
                                 ExtensionFieldSchema("message", .object)]),
            (messageDeliveredKind, [ExtensionFieldSchema("version", .int),
                                    ExtensionFieldSchema("teamId", .string),
                                    ExtensionFieldSchema("messageId", .string),
                                    ExtensionFieldSchema("targetId", .string)]),
        ]
        for (kind, required) in schemas {
            guard !ExtensionEventRegistry.shared.isRegistered(kind) else { continue }
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: kind, requiredFields: required, projection: .logOnly))
        }
    }

    /// member 事件载荷（{version:2, teamId, member} 1:1）。
    static func memberPayload(teamId: String, member: TeamMemberSnapshot) -> JSONValue {
        .object(["version": .int(2), "teamId": .string(teamId),
                 "member": member.encoded()])
    }

    /// task 事件载荷（{version:2, teamId, task} 1:1）。
    static func taskPayload(teamId: String, task: TeamTaskSnapshot) -> JSONValue {
        .object(["version": .int(2), "teamId": .string(teamId),
                 "task": task.encoded()])
    }

    /// queued 事件载荷（{version:2, teamId, message} 1:1）。
    static func queuedPayload(teamId: String, message: TeamMessageSnapshot) -> JSONValue {
        .object(["version": .int(2), "teamId": .string(teamId),
                 "message": message.encoded()])
    }

    /// delivered 事件载荷（{version:2, teamId, messageId, targetId} 1:1）。
    static func deliveredPayload(teamId: String, messageId: String,
                                 targetId: String) -> JSONValue {
        .object(["version": .int(2), "teamId": .string(teamId),
                 "messageId": .string(messageId), "targetId": .string(targetId)])
    }

    /// 事件版本选择器校验（projection.ts :96-99 teamEventSelectorSchema 1:1：
    /// teamId 匹配 + version==2，否则投影 failure）。
    static func selector(of payload: JSONValue, teamId: String) throws {
        guard payload.field("teamId")?.stringValue == teamId else {
            return   // 他 Team 事件不投影（applyProjectionEvent :226 return）。
        }
        guard payload.field("version")?.intValue == 2 else {
            throw TeamError(
                "unsupported Agent Teams event version "
                    + "\(payload.field("version")?.intValue ?? -1)",
                code: TeamError.invalidArgument)
        }
    }
}
