//
//  WOStateCards.swift
//  WanWo
//
//  件 I（搭车批）：会话状态卡两枚（digest-H 卡片族形态；引擎零改动）：
//    · WOTodoChecklistCard —— todo 清单卡（TodoProjection.fold 投影消费面；
//      三态行 + 完成计数；dsh todo/write "Log-only UI state" 的正式呈现面——
//      批1 仅落投影纯函数，本件补 UI 消费端）。
//    · WOGoalStatusCard —— goal 状态卡（GoalView 快照消费面：objective +
//      phase 徽章 + 回合计数——M7 件 B goal 事件的呈现端搭车）。
//  宿主接线（登记，装配行号随报告呈报合并）：ChatViewModel 会话投影在
//  todo/goal 事件变化处挂卡（presentResult 卡意图族之外的状态卡槽）。
//

import SwiftUI

// MARK: - Todo 清单卡（件 I）

/// todo 清单卡（TodoItem 三态行；digest-H 卡片圆角/字号令牌族）。
struct WOTodoChecklistCard: View {
    let todos: [TodoItem]

    private var completedCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WOAlias.stateBusinessPrimary)
                Text("任务清单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
                Text("\(completedCount)/\(todos.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 8) {
                    statusIcon(todo.status)
                    Text(todo.content)
                        .font(.system(size: 13))
                        .foregroundColor(todo.status == .completed
                                         ? WOAlias.labelSecondary : WOAlias.labelPrimary)
                        .strikethrough(todo.status == .completed)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("任务清单：\(completedCount) / \(todos.count) 完成")
    }

    @ViewBuilder
    private func statusIcon(_ status: TodoStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(WOAlias.stateSuccessPrimary)
        case .inProgress:
            Image(systemName: "circle.dotted")
                .font(.system(size: 14))
                .foregroundStyle(WOAlias.stateBusinessPrimary)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Goal 状态卡（件 I）

/// goal 状态卡（GoalView 消费面；phase 徽章配色 = 语义态令牌）。
struct WOGoalStatusCard: View {
    let goal: GoalView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WOAlias.stateBusinessPrimary)
                Text("目标")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
                phaseBadge
            }
            Text(goal.objective)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelPrimary)
                .lineLimit(3)
            if let reason = goal.blockedReason {
                Text(reason.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("第 \(goal.roundsStarted) / \(goal.maxGoalRounds) 回合")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目标：\(goal.objective)，阶段 \(phaseLabel)")
    }

    private var phaseLabel: String {
        switch goal.phase {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .blocked: return "受阻"
        case .complete: return "已完成"
        }
    }

    private var phaseColor: Color {
        switch goal.phase {
        case .active: return WOAlias.stateBusinessPrimary
        case .paused: return Color.secondary
        case .blocked: return WOAlias.stateWarnPrimary
        case .complete: return WOAlias.stateSuccessPrimary
        }
    }

    private var phaseBadge: some View {
        Text(phaseLabel)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(phaseColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(phaseColor.opacity(0.12)))
    }
}
