//
//  GoalCommand.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 B · F006】出处（packages/goal/command-goal/src/index.ts
//  全文对拍）：
//    - :15     —— USAGE 逐字。
//    - :34-44  —— parseGoalCommand 1:1（show/clear/pause/resume/invalid-edit/
//      edit <objective>/其余整句=create）。
//    - :47-56  —— phaseLabel。
//    - :59-74  —— commandHint（active+armed / active+disarmed / paused·blocked /
//      complete 四态提示逐字）。
//    - :77-95  —— renderGoal（Status/Blocker/Objective/Rounds/Activation/Commands）。
//    - :103-108 —— missingGoal。
//    - :125-186 —— executeGoalCommand 1:1（create 仅替换 complete；edit 对
//      complete 走替换；GoalError 归一为通用提示；图片附件分支不移植——万我
//      命令通道无 attachments 载荷，登记）。
//  万我形态：经 SlashCommandRegistry.makeDefault 注册（args = 命令名后原文；
//  返回用户可见结果文本）。变更以 origin .host 提交（运行中宿主 pause 触发
//  回合取消——AgentLoop.onGoalChanged 消费）。
//

import Foundation

/// /goal 斜杠命令 handler（dsh command-goal 1:1）。
enum GoalCommandHandler {
    private static let usage = "Usage: /goal [<objective>|clear|edit <objective>|pause|resume]"

    private enum CommandKind: Equatable {
        case show
        case create(objective: String)
        case edit(objective: String)
        case invalidEdit
        case pause
        case resume
        case clear
    }

    /// Parse only the grammar owned by `/goal`; arbitrary other input is an
    /// objective（index.ts:34-44 1:1）。
    static func parse(_ rawInput: String) -> CommandKind {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return .show }
        let control = input.lowercased()
        if control == "clear" { return .clear }
        if control == "pause" { return .pause }
        if control == "resume" { return .resume }
        if control == "edit" { return .invalidEdit }
        if input.range(of: "^edit(?=\\s)", options: [.regularExpression, .caseInsensitive]) != nil {
            return .edit(objective: String(input.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .create(objective: input)
    }

    /// Human label for one durable goal phase（index.ts:47-56）。
    private static func phaseLabel(_ phase: GoalPhase) -> String {
        phase.rawValue
    }

    /// Commands that are meaningful from one exact live state（index.ts:59-74 1:1）。
    private static func commandHint(_ goal: GoalView) -> String {
        if goal.phase == .active {
            return goal.activation == .armed
                ? "/goal edit <objective>, /goal pause, /goal clear"
                : "/goal edit <objective>, /goal resume, /goal clear"
        }
        switch goal.phase {
        case .paused, .blocked:
            return "/goal edit <objective>, /goal resume, /goal clear"
        case .complete:
            return "/goal <objective>, /goal clear"
        case .active:
            return "" // 不可达（上方分支已处理）
        }
    }

    /// Render direct UI output without exposing compare-and-set internals
    ///（index.ts:77-95 1:1）。
    private static func renderGoal(title: String, goal: GoalView) -> String {
        var lines = [title, "Status: \(phaseLabel(goal.phase))"]
        if goal.phase == .blocked, let reason = goal.blockedReason {
            lines.append("Blocker: \(reason.code): \(reason.message)")
        }
        lines.append("Objective: \(goal.objective)")
        lines.append("Rounds: \(goal.roundsStarted)/\(goal.maxGoalRounds)")
        lines.append("Activation: \(goal.activation.rawValue)")
        lines.append("")
        lines.append("Commands: \(commandHint(goal))")
        return lines.joined(separator: "\n")
    }

    /// Direct error for an operation that requires a current goal（index.ts:103-108）。
    private static func missingGoal(_ action: String) -> String {
        "No goal is currently set; /goal \(action) requires one. \(usage)"
    }

    /// Execute one parsed human command through the domain that owns
    /// persistence（index.ts:125-186 1:1；图片附件分支登记不移植）。
    static func run(service: GoalService, rawInput: String) async -> String {
        let command = parse(rawInput)
        do {
            let current = try await service.get()
            switch command {
            case .show:
                guard let current else {
                    return "No goal is currently set.\n\(usage)"
                }
                return renderGoal(title: "Goal", goal: current)
            case .invalidEdit:
                return "Goal editing requires a replacement objective.\n\(usage)"
            case .create(let objective):
                if let current, current.phase != .complete {
                    return "A goal is already \(phaseLabel(current.phase)). "
                        + "Use /goal edit <objective> to change it or /goal clear before replacing it."
                }
                let created = try await service.create(objective: objective, origin: .host)
                return renderGoal(title: "Goal created", goal: created)
            case .edit(let objective):
                guard let current else { return missingGoal("edit") }
                if current.phase == .complete {
                    let replaced = try await service.create(objective: objective, origin: .host)
                    return renderGoal(title: "Goal created", goal: replaced)
                }
                let edited = try await service.edit(ref: current.ref, objective: objective,
                                                    maxGoalRounds: nil, origin: .host)
                return renderGoal(title: "Goal updated", goal: edited)
            case .pause:
                guard let current else { return missingGoal("pause") }
                let paused = try await service.pause(ref: current.ref, origin: .host)
                return renderGoal(title: "Goal paused", goal: paused)
            case .resume:
                guard let current else { return missingGoal("resume") }
                let resumed = try await service.resume(ref: current.ref, origin: .host)
                return renderGoal(title: "Goal resumed", goal: resumed)
            case .clear:
                guard let current else { return "No goal to clear." }
                _ = try await service.clear(ref: current.ref, origin: .host)
                return "Goal cleared."
            }
        } catch let error as GoalError {
            // index.ts:177-185：GoalError 归一为通用提示（不暴露 CAS 内部）。
            return "The goal command is not valid for the current state. Run /goal to view available commands."
                + "（\(error.code.rawValue)）"
        } catch {
            return "Error: \(String(describing: error))"
        }
    }
}
