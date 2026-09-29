//
//  GoalTools.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 B · F006】出处（packages/goal/tool-goal/src/ 逐文件对拍）：
//    - index.ts:44-53   —— CREATE_DESCRIPTION / GET_DESCRIPTION 逐字。
//    - index.ts:112-122 —— guidance() 策略段文案逐字（blockedAfter=3 缺省，
//      :31-33 Config 缺省）。
//    - index.ts:144-153 —— goalRef 参数校验（GOAL_TOOL_INVALID_UPDATE）。
//    - index.ts:156-172 —— goalValue 紧凑 JSON 输出（activation 为观测非
//      replay 态）；:175-178 render = JSON.stringify。
//    - index.ts:194-337 —— 三工具（get_goal / create_goal / update_goal）
//      schema 与 execute 分派 1:1（edit/pause/resume 权威=requireDirectHuman；
//      complete/blocked 权威=completionAuthority；blocked 阈值
//      GOAL_TOOL_BLOCK_THRESHOLD；goal-round 权威下 deferContext 收尾指令）。
//    - authority.ts     —— 权威检查实现在 GoalService（进程内 provenance，
//      登记见 GoalService 头注）。
//    - wrapup.ts:17-41  —— 收尾指令逐字（GoalWrapup.render）。
//
//  万我形态（登记）：
//    - dsh output structured value → ToolOutput.meta（lossless JSON），
//      content = render 文本（JSON.stringify 等价）。
//    - deferContext → AgentLoop.inject（下一步注入）。
//    - presentCall 的 kind 'read'/'other' → ToolCardIntent(kind:) 映射。
//

import Foundation

/// goal 三工具共享装配缝。
enum GoalTools {
    /// blocked 阈值缺省（index.ts:32-33）。
    static let blockedAfterConsecutiveRounds = 3

    /// guidance 文案（index.ts:112-122 逐字）。
    static func guidance(blockedAfter: Int = GoalTools.blockedAfterConsecutiveRounds) -> String {
        "Use goal tools for one long-running completion objective in the current session. "
            + "create_goal may infer goal intent from a direct human request in any language; do not "
            + "create a goal for routine single-turn work. Call get_goal before update_goal and copy its "
            + "exact goal_id and revision. After session resume or fork, an active goal is disarmed: when "
            + "a human asks to continue or resume in any wording or language, use update_goal action "
            + "resume to rearm it. Mark complete only when the objective is actually achieved. Mark "
            + "blocked only after the same blocking condition persists for at least \(blockedAfter) "
            + "consecutive goal rounds, and report that concrete condition in blocked_reason; difficulty, uncertainty, "
            + "or useful remaining work is not blocked."
    }

    /// tool:goal 系统段（index.ts:188-192；order 见 SECTION_ORDERS.toolGoal 登记）。
    static func promptSection(blockedAfter: Int = GoalTools.blockedAfterConsecutiveRounds) -> PromptSection {
        PromptSection(name: "tool:goal", order: SECTION_ORDERS.toolGoal,
                      text: guidance(blockedAfter: blockedAfter))
    }

    // MARK: - goalValue（index.ts:156-172 1:1）

    static func goalValue(_ goal: GoalView?) -> JSONValue {
        guard let goal else { return .object(["goal": .null]) }
        var fields: [String: JSONValue] = [
            "id": .string(goal.id),
            "revision": .int(goal.revision),
            "objective": .string(goal.objective),
            "phase": .string(goal.phase.rawValue),
            "roundsStarted": .int(goal.roundsStarted),
            "maxGoalRounds": .int(goal.maxGoalRounds),
        ]
        if let reason = goal.blockedReason {
            fields["blockedReason"] = .object([
                "code": .string(reason.code),
                "message": .string(reason.message),
            ])
        }
        return .object([
            "goal": .object(fields),
            "activation": .string(goal.activation.rawValue),
        ])
    }

    static func renderValue(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// goalRef 参数校验（index.ts:144-153 1:1）。
    static func goalRef(goalId: String, revision: Int) throws -> GoalRef {
        if goalId.isEmpty || goalId != goalId.trimmingCharacters(in: .whitespaces)
            || revision < 1 {
            throw GoalToolError(
                message: "goal_id must be non-empty and revision must be a positive safe integer",
                code: "GOAL_TOOL_INVALID_UPDATE")
        }
        return GoalRef(id: goalId, revision: revision)
    }
}

// MARK: - AgentLoop 弱引用缝（wrapup deferContext 注入用）

/// wrapup 注入通道（dsh exec.deferContext 等价；工具构造早于 AgentLoop 创建，
/// makeAgentStack 在 loop 建成后回填）。
final class GoalAgentLink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: AgentLoop?

    func set(_ loop: AgentLoop?) {
        lock.lock()
        stored = loop
        lock.unlock()
    }

    var loop: AgentLoop? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - get_goal

struct GetGoalTool: AgentTool {
    let name = "get_goal"
    let description = "Read the current same-session goal, including its exact id/revision, objective, phase, completed "
        + "continuation rounds, round limit, blocker reason when present, and whether another continuation is armed. "
        + "Call this before updating a goal."
    let parameters: JSONValue = .schemaObject(properties: [:], required: [])

    let service: GoalService

    // isConcurrencySafe 默认 false（dsh 未声明 parallel）。

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        do {
            let goal = try await service.get()
            let value = GoalTools.goalValue(goal)
            return .success(GoalTools.renderValue(value), meta: value)
        } catch let error as GoalError {
            return .failure(error.message, code: error.code.rawValue, name: "GoalError")
        }
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Read current goal")
    }
}

// MARK: - create_goal

struct CreateGoalTool: AgentTool {
    let name = "create_goal"
    let description = "Create one persisted same-session completion goal when the current direct human request "
        + "is a long-running objective that should continue across autonomous goal rounds. You may "
        + "infer that intent without requiring the user to say \"create a goal\". Do not use this for "
        + "trivial single-turn work. Execution rejects non-human and subagent authority."

    let parameters: JSONValue = .schemaObject(
        properties: [
            "objective": .object([
                "type": .string("string"),
                "description": .string("The concrete completion objective inferred from the direct human request."),
            ]),
            "max_goal_rounds": .object([
                "type": .string("number"),
                "description": .string("Optional positive safe-integer limit on automatic continuation rounds."),
            ]),
        ],
        required: ["objective"])

    let service: GoalService

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        do {
            // requireDirectHuman（index.ts:223）。
            try await service.requireDirectHumanAuthority(turn: ctx.turn)
            guard let objective = args.field("objective")?.stringValue else {
                return .failure("objective is required", code: "GOAL_TOOL_INVALID_UPDATE",
                                name: "GoalToolError")
            }
            let goal = try await service.create(
                objective: objective,
                maxGoalRounds: args.field("max_goal_rounds")?.intValue,
                origin: .model)
            let value = GoalTools.goalValue(goal)
            return .success(GoalTools.renderValue(value), meta: value)
        } catch let error as GoalToolError {
            return .failure(error.message, code: error.code, name: "GoalToolError")
        } catch let error as GoalError {
            return .failure(error.message, code: error.code.rawValue, name: "GoalError")
        }
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Create goal",
                       detail: args.field("objective")?.stringValue)
    }
}

// MARK: - update_goal

struct UpdateGoalTool: AgentTool {
    let name = "update_goal"
    let description = "Update the exact current goal revision. edit, pause, and resume require a direct "
        + "top-level human request. During an automatic continuation of the current goal, complete "
        + "and blocked are also allowed. blocked is rejected before the configured minimum round count; the model remains "
        + "responsible for judging that the same condition persisted across those rounds and must explain it in blocked_reason."

    let parameters: JSONValue = .schemaObject(
        properties: [
            "goal_id": .object([
                "type": .string("string"),
                "description": .string("Exact id returned by get_goal."),
            ]),
            "revision": .object([
                "type": .string("number"),
                "description": .string("Exact positive revision returned by get_goal."),
            ]),
            "action": .object([
                "type": .string("string"),
                "enum": .array(["edit", "pause", "resume", "complete", "blocked"].map { .string($0) }),
                "description": .string("edit | pause | resume | complete | blocked"),
            ]),
            "objective": .object([
                "type": .string("string"),
                "description": .string("Replacement objective; valid only with action edit."),
            ]),
            "max_goal_rounds": .object([
                "type": .string("number"),
                "description": .string("Replacement cap; valid only with action edit."),
            ]),
            "blocked_reason": .object([
                "type": .string("string"),
                "description": .string("Concrete blocking condition; required only with action blocked."),
            ]),
        ],
        required: ["goal_id", "revision", "action"])

    let service: GoalService
    /// wrapup 注入缝（goal-round 权威下 deferContext 等价）。
    let agentLink: GoalAgentLink
    /// blocked 最小轮数（index.ts:31-33 缺省 3）。
    let blockedAfterConsecutiveRounds: Int

    init(service: GoalService, agentLink: GoalAgentLink,
         blockedAfterConsecutiveRounds: Int = GoalTools.blockedAfterConsecutiveRounds) {
        self.service = service
        self.agentLink = agentLink
        self.blockedAfterConsecutiveRounds = blockedAfterConsecutiveRounds
    }

    // MARK: 参数语义辅助（index.ts:134-141 hasText/hasRoundCap 1:1）

    private static func hasText(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.isEmpty
    }

    private static func hasRoundCap(_ value: JSONValue?) -> Bool {
        guard let round = value?.intValue else { return false }
        return round != 0
    }

    private static func invalidUpdate(_ message: String) -> ToolOutput {
        .failure(message, code: "GOAL_TOOL_INVALID_UPDATE", name: "GoalToolError")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        do {
            guard let goalId = args.field("goal_id")?.stringValue,
                  let revision = args.field("revision")?.intValue,
                  let action = args.field("action")?.stringValue else {
                return Self.invalidUpdate("goal_id, revision and action are required")
            }
            let ref = try GoalTools.goalRef(goalId: goalId, revision: revision)
            let objective = args.field("objective")
            let maxGoalRounds = args.field("max_goal_rounds")
            let blockedReason = args.field("blocked_reason")

            if action == "edit" {
                try await service.requireDirectHumanAuthority(turn: ctx.turn)
                if Self.hasText(blockedReason) {
                    return Self.invalidUpdate("blocked_reason is valid only with action blocked")
                }
                let goal = try await service.edit(
                    ref: ref,
                    objective: Self.hasText(objective) ? objective?.stringValue : nil,
                    maxGoalRounds: Self.hasRoundCap(maxGoalRounds) ? maxGoalRounds?.intValue : nil,
                    origin: .model)
                return Self.output(goal)
            }
            if action == "pause" || action == "resume" {
                try await service.requireDirectHumanAuthority(turn: ctx.turn)
                if Self.hasText(objective) || Self.hasRoundCap(maxGoalRounds) || Self.hasText(blockedReason) {
                    return Self.invalidUpdate(
                        "objective and max_goal_rounds are valid only with action edit; "
                            + "blocked_reason is valid only with action blocked")
                }
                let goal = action == "pause"
                    ? try await service.pause(ref: ref, origin: .model)
                    : try await service.resume(ref: ref, origin: .model)
                return Self.output(goal)
            }
            guard action == "complete" || action == "blocked" else {
                return Self.invalidUpdate("action must be edit | pause | resume | complete | blocked")
            }
            // complete / blocked：权威 = 直接人类输入或精确已准入轮次。
            let authority = try await service.completionAuthority(turn: ctx.turn)
            if Self.hasText(objective) || Self.hasRoundCap(maxGoalRounds) {
                return Self.invalidUpdate("objective and max_goal_rounds are valid only with action edit")
            }
            if action == "complete" && Self.hasText(blockedReason) {
                return Self.invalidUpdate("blocked_reason is valid only with action blocked")
            }
            if action == "blocked",
               blockedReason?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                return Self.invalidUpdate("blocked_reason is required with action blocked")
            }
            if action == "blocked", case .goalRound(let goal) = authority,
               goal.roundsStarted < blockedAfterConsecutiveRounds {
                return .failure(
                    "blocked requires at least \(blockedAfterConsecutiveRounds) consecutive goal rounds; "
                        + "current round is \(goal.roundsStarted)",
                    code: "GOAL_TOOL_BLOCK_THRESHOLD", name: "GoalToolError")
            }
            let goal: GoalView
            if action == "complete" {
                goal = try await service.complete(ref: ref, origin: .model)
            } else {
                goal = try await service.block(
                    ref: ref,
                    reason: GoalBlockReason(code: "model-reported", message: blockedReason?.stringValue ?? ""),
                    origin: .model)
            }
            // goal-round 权威下的收尾指令（index.ts:312-324 deferContext →
            // AgentLoop.inject 下一步注入；禁再调工具语义在指令文案内逐字）。
            if case .goalRound = authority {
                let wrapup = GoalWrapup.render(
                    objective: goal.objective,
                    blockedReason: action == "blocked" ? blockedReason?.stringValue : nil)
                if let loop = agentLink.loop {
                    // QA-2 P1-1：wrapup 为宿主/系统指令注入——source .system
                    // 绝不计入 directHuman authority（原缺省 .user 会让下一
                    // 回合 provenance 误开 completion authority）。
                    await loop.inject(wrapup, source: .system)
                }
            }
            return Self.output(goal)
        } catch let error as GoalToolError {
            return .failure(error.message, code: error.code, name: "GoalToolError")
        } catch let error as GoalError {
            return .failure(error.message, code: error.code.rawValue, name: "GoalError")
        }
    }

    private static func output(_ goal: GoalView) -> ToolOutput {
        let value = GoalTools.goalValue(goal)
        return .success(GoalTools.renderValue(value), meta: value)
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let action = args.field("action")?.stringValue ?? ""
        let title: String
        if action == "blocked" {
            title = "Mark goal"
        } else if action.isEmpty {
            title = "Update goal"
        } else {
            title = action.prefix(1).uppercased() + action.dropFirst() + " goal"
        }
        let detail = Self.hasText(args.field("blocked_reason"))
            ? args.field("blocked_reason")?.stringValue
            : Self.hasText(args.field("objective"))
                ? args.field("objective")?.stringValue
                : Self.hasRoundCap(args.field("max_goal_rounds"))
                    ? args.field("max_goal_rounds")?.intValue.map(String.init)
                    : args.field("goal_id")?.stringValue
        return ToolCardIntent(title: title, detail: detail)
    }
}
