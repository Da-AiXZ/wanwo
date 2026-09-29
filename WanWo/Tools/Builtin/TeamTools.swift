//
//  TeamTools.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 L · F046】出处（experimental/tool-agent-team/src/
//  index.ts :31-411，逐文件实读本体）：
//    - POLICY :31-37 逐字内嵌 + 角色行 :169（"Your Team role is …"）。
//    - 九作用域工具 schema/description 逐字：spawn_teammate(:174)/send_message
//      (:201)/list_agents(:218)/wait_agent(:228)/interrupt_agent(:263)/
//      team_task_create(:278)/team_task_list(:302)/team_task_get(:334)/
//      team_task_update(:349)。
//    - team_task_list 过滤+分页 :317-331 逐语义（cursor/limit 校验文案逐字、
//      nextCursor 条件字段）。
//    - 输出 schema：MEMBER_VIEW_SCHEMA/TASK_VIEW_SCHEMA/SEND_VALUE_SCHEMA/
//      INTERRUPT_VALUE_SCHEMA/TASK_LIST_VALUE_SCHEMA 逐字段（jsonOutput
//      紧凑 JSON 渲染 :141-149 等价——模型面 JSON 文本 + meta 同载）。
//  万我适配（登记，报告已述）：
//    - wait_agent 复用批1 WaitAgentTool（主理人判定：勿重造）——TeamTools 不
//      注册该名，批1 版在 teammate 栈由 SubagentTools.registerAll 照常注册；
//      dsh noProgress 捷径不移植（批1 等待-唤醒底座语义差异登记）。
//    - 作用域安装：dsh per-Agent scope install → 万我注册序承载——teammate
//      栈与 Lead 栈（QA-6 P1-4 裁决批准）均装八件，同名四件先注册占名，
//      批1 SubagentTools.registerAll 的 tryRegister 冲突路径跳过——team 栈
//      只见 team 版（普通非 team 子代理栈 scope=nil 不注册 → 批1 版照常）；
//      wait_agent 复用批1（不在此注册）。
//    - experimental 语义不引入（已定适配④）。
//

import Foundation

// MARK: - 政策文案（tool-agent-team :31-37 逐字）

/// 模型面协作指引（Lead 与 teammate 共享；:31-37 逐字）。
private let TEAM_POLICY = """
Agent Teams is available in this session, but create teammates only when the user explicitly asks to use Agent Teams or teammates.

The Team Lead and all teammates share the same working directory and filesystem. Edits are immediately visible to every member. Split write work into disjoint scopes, record expected write scopes on shared tasks, and use task dependencies when work must be ordered. Write-scope overlap is advisory, not a lock.

Prefer read/edit/write for file changes. If a file operation returns FS_STALE_VERSION, read the current file, rebase your intended change onto the new content, and retry. Bash, formatters, code generators, and scripts are not fully protected by the filesystem version guard; coordinate them explicitly and have the Lead review the final diff and run tests.

send_message steers a running target at its nearest step boundary, starts an idle target, and cold-resumes an inactive teammate. A delivered peer item starts with its stable message id and sender name. A successful send is already durable even when its result says queued; do not resend it. Shared-task workflow is list, get, claim with the current revision, perform the work, then complete. Task readiness never starts an owner. Before wait_agent, use list_agents and make sure another required member is running or provisioning; use send_message first when the required member is inactive. wait_agent observes only changes after that call starts, never wakes a member, and returns noProgress immediately when no other member can produce a change. Re-list after wakeup or timeout. The Lead must wait for required teammates before giving the final answer.
"""

// MARK: - 注册面

/// 九作用域工具装配（AppEnvironment.makeAgentStack 调用；注册序承载作用域）。
enum TeamTools {

    /// 作用域上下文（dsh membership(agent) 角色行的装配期快照——policy 段
    /// 文案供值；scope 判定在 makeAgentStack：label 前缀→teammate，顶层→lead）。
    struct ScopeContext: Sendable {
        enum Role: String, Sendable {
            case lead, teammate
        }

        var role: Role
        var name: String
        var teamId: String
    }

    /// 注册 Team 工具族 + policy 段（幂等注册冲突可捕获路径同批1 纪律）。
    /// - Parameters:
    ///   - scope: nil = 非 Team 会话（不注册任何件）；.lead / .teammate =
    ///     八件 + policy（QA-6 P1-4 主理人裁决批准：dsh 作用域安装语义 =
    ///     Lead 栈同样装 team 版 send_message/interrupt_agent/list_agents——
    ///     Lead 的团队通信必须走邮箱持久语义，批1 四件同名对 Lead 被遮蔽是
    ///     正确的；普通（非 team）子代理栈 scope = nil 不注册任何件 → 批1
    ///     四件照常生效。注册序仍先于 SubagentTools.registerAll 占名）。
    static func registerAll(into registry: ToolRegistry,
                            assembler: PromptAssembler,
                            service: TeamService,
                            scope: ScopeContext?) {
        guard let scope else { return }
        // policy 段（:164-171 1:1——POLICY + 角色行；order = SECTION_ORDERS
        // .teamPolicy，dsh getSectionOrder('TEAM_POLICY') 的万我槽位承载）。
        assembler.section(PromptSection(
            name: "team:policy",
            order: SECTION_ORDERS.teamPolicy,
            text: "\(TEAM_POLICY)\n\nYour Team role is \(scope.role.rawValue); "
                + "your Team name is \(scope.name); Team id is \(scope.teamId)."))

        let candidates: [any AgentTool] = [
            TeamSpawnTeammateTool(service: service),
            TeamSendMessageTool(service: service),
            TeamListAgentsTool(service: service),
            TeamInterruptAgentTool(service: service),
            TeamTaskCreateTool(service: service),
            TeamTaskListTool(service: service),
            TeamTaskGetTool(service: service),
            TeamTaskUpdateTool(service: service),
        ]
        for tool in candidates {
            do {
                _ = try registry.tryRegister(tool)
            } catch {
                // 同名已在场（重装配）= 幂等 no-op；其余冲突可捕获吞并（装配
                // 侧呈现面归 AppEnvironment，批1 同纪律）。
                continue
            }
        }
    }
}

// MARK: - 输出编码（jsonOutput 紧凑 JSON :141-149 等价）

/// TeamMemberView → JSONValue（MEMBER_VIEW_SCHEMA 字段面 1:1；nil 字段省略
/// ——additionalProperties:false + 可选字段语义）。
func teamMemberViewJSON(_ view: TeamMemberView) -> JSONValue {
    var fields: [String: JSONValue] = [
        "id": .string(view.id),
        "name": .string(view.name),
        "role": .string(view.role),
        "status": .string(view.status),
        "diagnostics": .array(view.diagnostics.map { .string($0) }),
    ]
    if let description = view.description { fields["description"] = .string(description) }
    if let provider = view.provider { fields["provider"] = .string(provider) }
    if let context = view.context { fields["context"] = .string(context) }
    if let model = view.model { fields["model"] = .string(model) }
    return .object(fields)
}

/// TeamTaskView → JSONValue（TASK_VIEW_SCHEMA 字段面 1:1）。
func teamTaskViewJSON(_ view: TeamTaskView) -> JSONValue {
    var fields: [String: JSONValue] = [
        "id": .string(view.id),
        "revision": .int(view.revision),
        "subject": .string(view.subject),
        "description": .string(view.description),
        "status": .string(view.status.rawValue),
        "blockedBy": .array(view.blockedBy.map { .string($0) }),
        "writeScopes": .array(view.writeScopes.map { .string($0) }),
        "ready": .bool(view.ready),
        "writeScopeWarnings": .array(view.writeScopeWarnings.map { .string($0) }),
    ]
    if let ownerName = view.ownerName { fields["ownerName"] = .string(ownerName) }
    return .object(fields)
}

/// TeamError → 工具失败输出（TeamError RespondToModel 面；code 稳定词汇直载）。
private func teamFailure(_ error: Error) -> ToolOutput {
    if let teamError = error as? TeamError {
        return .failure(teamError.message, code: teamError.code, name: "TeamError")
    }
    return .failure(String(describing: error), code: "TEAM_INTERNAL", name: "TeamError")
}

// MARK: - spawn_teammate（:174-199 1:1）

struct TeamSpawnTeammateTool: AgentTool {
    let name = "spawn_teammate"
    let description = "Create one named, durable teammate. Only the Team Lead may call this tool."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "name": .object([
                "type": .string("string"),
                "description": .string("Unique lower-kebab-case teammate name."),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Short description of the delegated responsibility."),
            ]),
            "prompt": .object([
                "type": .string("string"),
                "description": .string("Complete initial task for the teammate."),
            ]),
            "context": .object([
                "type": .string("string"),
                "enum": .array([.string("fresh"), .string("fork")]),
                "description": .string("fresh starts without Lead history; fork inherits "
                    + "completed Lead turns. Defaults to fresh."),
            ]),
        ],
        required: ["name", "description", "prompt"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Spawn teammate",
                       detail: args.field("name")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.field("name")?.stringValue,
              let memberDescription = args.field("description")?.stringValue,
              let prompt = args.field("prompt")?.stringValue else {
            return .failure("name, description, and prompt are required",
                            code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
        }
        let context = args.field("context")?.stringValue ?? "fresh"
        do {
            let member = try await service.spawnTeammate(
                callerSessionId: ctx.sessionId, name: name,
                description: memberDescription, prompt: prompt, context: context)
            let value = teamMemberViewJSON(member)
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - send_message（:201-216 1:1）

struct TeamSendMessageTool: AgentTool {
    let name = "send_message"
    let description = "Send one durable message to another Team member. A running target "
        + "receives it at the nearest step boundary; an idle target starts a turn; an "
        + "inactive teammate cold-resumes."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "target": .object([
                "type": .string("string"),
                "description": .string("Team member name, or lead."),
            ]),
            "message": .object([
                "type": .string("string"),
                "description": .string("Self-contained message for the target."),
            ]),
        ],
        required: ["target", "message"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Send team message",
                       detail: args.field("target")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let target = args.field("target")?.stringValue,
              let message = args.field("message")?.stringValue else {
            return .failure("target and message are required",
                            code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
        }
        do {
            let result = try await service.sendMessage(
                callerSessionId: ctx.sessionId, target: target, message: message)
            let value: JSONValue = .object([
                "messageId": .string(result.messageId),
                "status": .string(result.status),
            ])
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - list_agents（:218-226 1:1）

struct TeamListAgentsTool: AgentTool {
    let name = "list_agents"
    let description = "List the Lead and every durable teammate with current runtime status."
    let parameters: JSONValue = .schemaObject(properties: [:], required: [])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "List team agents")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        do {
            let members = try await service.listMembers(ctx.sessionId)
            let value: JSONValue = .array(members.map(teamMemberViewJSON))
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - interrupt_agent（:263-276 1:1）

struct TeamInterruptAgentTool: AgentTool {
    let name = "interrupt_agent"
    let description = "Interrupt one teammate's current turn while preserving its pending "
        + "inbox. Team Lead only."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "target": .object([
                "type": .string("string"),
                "description": .string("Teammate name."),
            ]),
        ],
        required: ["target"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Interrupt teammate",
                       detail: args.field("target")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let target = args.field("target")?.stringValue else {
            return .failure("target is required", code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
        }
        do {
            let previousStatus = try await service.interrupt(
                callerSessionId: ctx.sessionId, targetName: target)
            let value: JSONValue = .object(["previousStatus": .string(previousStatus)])
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - team_task_create（:278-300 1:1）

struct TeamTaskCreateTool: AgentTool {
    let name = "team_task_create"
    let description = "Create one unowned pending task on the shared Team task board."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "subject": .object([
                "type": .string("string"),
                "description": .string("Concise task title."),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Complete task details and acceptance criteria."),
            ]),
            "blocked_by": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Task ids that must complete first."),
            ]),
            "write_scopes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Advisory workspace-relative file or directory "
                    + "prefixes this task expects to modify."),
            ]),
        ],
        required: ["subject", "description"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Create team task",
                       detail: args.field("subject")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let subject = args.field("subject")?.stringValue,
              let description = args.field("description")?.stringValue else {
            return .failure("subject and description are required",
                            code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
        }
        let blockedBy = args.field("blocked_by")?.arrayItems?.compactMap(\.stringValue) ?? []
        let writeScopes = args.field("write_scopes")?.arrayItems?.compactMap(\.stringValue) ?? []
        do {
            let view = try await service.createTask(
                callerSessionId: ctx.sessionId, subject: subject,
                description: description, blockedBy: blockedBy, writeScopes: writeScopes)
            let value = teamTaskViewJSON(view)
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - team_task_list（:302-332 1:1）

struct TeamTaskListTool: AgentTool {
    let name = "team_task_list"
    let description = "List shared tasks, including readiness, owner, revision, blockers, "
        + "and write-scope warnings."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("pending"), .string("in_progress"),
                                .string("completed")]),
                "description": .string("Optional exact status filter."),
            ]),
            "owner": .object([
                "type": .string("string"),
                "description": .string("Optional member-name filter; use unowned for "
                    + "tasks without an owner."),
            ]),
            "ready": .object([
                "type": .string("boolean"),
                "description": .string("Optional readiness filter."),
            ]),
            "cursor": .object([
                "type": .string("integer"),
                "description": .string("Zero-based result offset. Defaults to 0."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Number of rows, 1 through 100. Defaults to 50."),
            ]),
        ],
        required: [])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "List team tasks")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        do {
            let all = try await service.listTasks(ctx.sessionId)
            let status = args.field("status")?.stringValue
            let owner = args.field("owner")?.stringValue
            let ready = args.field("ready")?.boolValue
            let filtered = all.filter { task in
                (status == nil || task.status.rawValue == status)
                    && (owner == nil
                        || (owner == "unowned" ? task.ownerName == nil
                            : task.ownerName == owner))
                    && (ready == nil || task.ready == ready)
            }
            // cursor/limit 校验文案逐字（:325-326）。
            let cursor = args.field("cursor")?.intValue ?? 0
            let limit = args.field("limit")?.intValue ?? 50
            if cursor < 0 {
                return .failure("cursor must be a non-negative safe integer",
                                code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
            }
            if limit < 1 || limit > 100 {
                return .failure("limit must be an integer from 1 through 100",
                                code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
            }
            let upperBound = min(cursor + limit, filtered.count)
            let rows = (cursor < filtered.count && cursor <= upperBound)
                ? Array(filtered[cursor..<upperBound]) : []
            var fields: [String: JSONValue] = [
                "tasks": .array(rows.map(teamTaskViewJSON)),
            ]
            if cursor + limit < filtered.count {
                fields["nextCursor"] = .int(cursor + limit)
            }
            let value: JSONValue = .object(fields)
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - team_task_get（:334-347 1:1）

struct TeamTaskGetTool: AgentTool {
    let name = "team_task_get"
    let description = "Read the complete latest value of one shared task before changing or "
        + "executing it."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "task_id": .object([
                "type": .string("string"),
                "description": .string("Shared task id."),
            ]),
        ],
        required: ["task_id"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .file, title: "Get team task",
                       detail: args.field("task_id")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let taskId = args.field("task_id")?.stringValue else {
            return .failure("task_id is required", code: "TEAM_INVALID_ARGUMENT",
                            name: "TeamError")
        }
        do {
            let view = try await service.getTask(callerSessionId: ctx.sessionId, taskId: taskId)
            let value = teamTaskViewJSON(view)
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}

// MARK: - team_task_update（:349-380 1:1）

struct TeamTaskUpdateTool: AgentTool {
    let name = "team_task_update"
    let description = "Compare-and-set a shared task action using the latest revision from "
        + "team_task_get or team_task_list."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "task_id": .object([
                "type": .string("string"),
                "description": .string("Shared task id."),
            ]),
            "expected_revision": .object([
                "type": .string("integer"),
                "description": .string("Current task revision used as the CAS precondition."),
            ]),
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("claim"), .string("release"), .string("edit"),
                    .string("set_dependencies"), .string("complete"),
                    .string("reopen"), .string("reassign"), .string("delete"),
                ]),
                "description": .string("Task transition to apply."),
            ]),
            "subject": .object([
                "type": .string("string"),
                "description": .string("Replacement title for edit."),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Replacement details for edit."),
            ]),
            "blocked_by": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Complete blocker list for set_dependencies."),
            ]),
            "write_scopes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Replacement advisory write scopes for edit."),
            ]),
            "owner": .object([
                "type": .string("string"),
                "description": .string("Member name for Lead-only reassign; omit to unassign."),
            ]),
        ],
        required: ["task_id", "expected_revision", "action"])

    private let service: TeamService

    init(service: TeamService) { self.service = service }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Update team task",
                       detail: args.field("task_id")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let taskId = args.field("task_id")?.stringValue,
              let expectedRevision = args.field("expected_revision")?.intValue,
              let actionRaw = args.field("action")?.stringValue,
              let action = TeamTaskAction(rawValue: actionRaw) else {
            return .failure("task_id, expected_revision, and action are required",
                            code: "TEAM_INVALID_ARGUMENT", name: "TeamError")
        }
        let request = UpdateTeamTaskRequest(
            taskId: taskId, expectedRevision: expectedRevision, action: action,
            subject: args.field("subject")?.stringValue,
            description: args.field("description")?.stringValue,
            blockedBy: args.field("blocked_by")?.arrayItems?.compactMap(\.stringValue),
            writeScopes: args.field("write_scopes")?.arrayItems?.compactMap(\.stringValue),
            owner: args.field("owner")?.stringValue)
        do {
            let view = try await service.updateTask(
                callerSessionId: ctx.sessionId, request: request)
            let value = teamTaskViewJSON(view)
            return .success(MemoryRollout.serializeJSON(value), meta: value)
        } catch {
            return teamFailure(error)
        }
    }
}
