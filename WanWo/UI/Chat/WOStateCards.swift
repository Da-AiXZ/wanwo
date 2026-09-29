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
/// 【M7-E3 修 2026-09-29】：a) 标题行（"任务清单 N/M"）可点收起/展开
/// （withAnimation 高度过渡；收起态经 @AppStorage 全局持久——用户对卡片
/// 密度的偏好属全局习惯，跨会话保持；非会话数据故不入会话存储）。
/// b) in_progress 行图标：静止 `circle.dotted` 换 12 叶片渐隐 spinner
/// （WOTodoBladeSpinner，规格 1:1 见该类型头注）。
struct WOTodoChecklistCard: View {
    let todos: [TodoItem]

    /// 收起态（全局持久：@AppStorage 单键，用户拍板候选方案中选持久——
    /// 清单卡是常驻座位组的高密度元素，收起意图跨会话保持更符合预期）。
    @AppStorage("wo.todo.card.collapsed") private var collapsed = false

    private var completedCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if !collapsed {
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
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务清单：\(completedCount) / \(todos.count) 完成")
    }

    /// 标题行 = 收起/展开开关（44pt 命中区达标；chevron 表达当前态）。
    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
        } label: {
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
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "展开任务清单" : "收起任务清单")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func statusIcon(_ status: TodoStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(WOAlias.stateSuccessPrimary)
        case .inProgress:
            // 【M7-E3】12 叶片渐隐 spinner（静止蓝圈退役；规格见 spinner 类型）。
            WOTodoBladeSpinner(size: 14)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 12 叶片渐隐 spinner（M7-E3 · Uiverse mrhyddenn「加载动画.txt」规格 1:1）

/// in_progress 行图标：12 blade 每 30° 一片，CSS 规格→SwiftUI Canvas 换算：
///   · blade 宽 0.074em / 高 0.2777em / 圆角 0.0555em；transform-origin
///     `center -0.2222em` ≈ 旋转中心=容器中心（blade 底边贴容器底，origin
///     距 blade 底 0.2777+0.2222≈0.5em）；1s linear infinite；
///     #69717d→transparent，第 i 片 delay 0.083s 交错。
///   · 性能：TimelineView(.animation)+Canvas 按相位画 blade（每帧 12 个
///     rounded-rect 填充，无隐式动画树）；纯装饰 `.accessibilityHidden(true)`。
struct WOTodoBladeSpinner: View {
    var size: CGFloat = 14

    /// CSS #69717d。
    private static let bladeColor = Color(red: 0x69 / 255.0,
                                          green: 0x71 / 255.0,
                                          blue: 0x7d / 255.0)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, canvasSize in
                let em = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: canvasSize.width / 2,
                                     y: canvasSize.height / 2)
                let bladeW = em * 0.074
                let bladeH = em * 0.2777
                let cornerR = em * 0.0555
                let now = timeline.date.timeIntervalSinceReferenceDate
                for i in 0..<12 {
                    // 第 i 片 delay = i*0.083s；相位 0=全色、1=透明。
                    var phase = now - Double(i) * 0.083
                    phase = phase.truncatingRemainder(dividingBy: 1.0)
                    if phase < 0 { phase += 1 }
                    let blade = CGRect(x: center.x - bladeW / 2,
                                       y: center.y + em / 2 - bladeH,
                                       width: bladeW,
                                       height: bladeH)
                    var ctx = context
                    ctx.translateBy(x: center.x, y: center.y)
                    ctx.rotate(by: .degrees(Double(i) * 30))
                    ctx.translateBy(x: -center.x, y: -center.y)
                    ctx.fill(Path(roundedRect: blade, cornerRadius: cornerR),
                             with: .color(Self.bladeColor.opacity(1 - phase)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - goal_round 注入呈现（M7-E3）

/// goal 自动续轮指令卡：引擎经 GoalRoundPrompt.render（GoalService.swift:485-499，
/// 语义源 dsh prompt.ts:12-26 逐字）注入的 `<goal_round>\nObjective:…\nRound: N/M…`
/// 用户消息不再渲染成巨大用户气泡，收起成小系统卡（形态对齐 WOStateCards 卡片族）。
///
/// dsh 语义查证（铁律先查）：dsh web 聊天流（ui-chat/ui-conversation）对
/// `<goal_round>` 注入**无专门渲染语义**（grep 无结果）——仅 trajectory 表有
/// 来源标签语义：TrajectoryTable.tsx:879-884 messageSourceLabel kind==='goal'
/// → locales.ts:86 `source.goalRound`='目标 · Round {round}'。本卡标题措辞
/// 借该 locale（"目标续轮指令 · 第 N/M 轮"），折叠形态为平台差异自定方案
/// （web 表格交互无法 1:1 到 iOS 聊天流），登记 analysis/m7-fix/e3-report.md。
struct WOGoalRoundCard: View {
    /// 原始注入全文（点开呈现）。
    let text: String

    /// 注入识别前缀（= GoalRoundPrompt.render 模板头，M7GoalTests
    /// testGoalRoundPromptShape hasPrefix 断言同款）。
    static let injectionPrefix = "<goal_round>\n"

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if expanded {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目标续轮指令，第 \(roundText) 轮")
    }

    /// 标题行 = 展开/收起开关（44pt 命中区达标；措辞借 dsh ui-trajectory
    /// `source.goalRound` locale）。
    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WOAlias.stateBusinessPrimary)
                Text("目标续轮指令 · 第 \(roundText) 轮")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起目标续轮指令全文" : "展开目标续轮指令全文")
        .accessibilityAddTraits(.isButton)
    }

    /// "N/M"（Round 行解析失败兜底 "?"，不崩不编造）。
    private var roundText: String {
        Self.parseRound(from: text) ?? "?"
    }

    /// 从注入全文解析 `Round: N/M` 行（单测缝：纯函数可抽测；前缀行
    /// `<goal_round>`/`Objective:`/`</goal_round>` 均跳过）。
    static func parseRound(from text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Round:") else { continue }
            let value = trimmed.dropFirst("Round:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
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
