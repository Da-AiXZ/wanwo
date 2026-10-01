//
//  WOStateCards.swift
//  WanWo
//
//  件 I（搭车批）：会话状态卡两枚（digest-H 卡片族形态；引擎零改动）：
//    · WOTodoChecklistCard —— todo 清单卡（TodoProjection.fold 投影消费面；
//      三态行 + 完成计数；dsh todo/write "Log-only UI state" 的正式呈现面——
//      批1 仅落投影纯函数，本件补 UI 消费端）。
//      【M7-Fix2 批2 B2 2026-09-29】出现/消失/展开/收起/级联入场动画全套
//      按用户 HTML 原型逐值重做（挂载条件内收 WOChatView——退场动画需要
//      数据已清空仍在树的缓冲帧，卡片自管生命周期）。
//    · WOGoalStatusCard —— goal 状态卡（GoalView 快照消费面：objective +
//      phase 徽章 + 回合计数——M7 件 B goal 事件的呈现端搭车）。
//  宿主接线（登记，装配行号随报告呈报合并）：ChatViewModel 会话投影在
//  todo/goal 事件变化处挂卡（presentResult 卡意图族之外的状态卡槽）。
//

import SwiftUI

// MARK: - Todo 清单卡（件 I · M7-Fix2 批2 B2 动画原型化）

/// 原型全站曲线（todo出现消失展开收起动画.html 逐值：cubic-bezier(.22,1,.36,1)）。
fileprivate enum WOTodoMotion {
    static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}

/// 列表自然高度量测键（grid-template-rows 0fr→1fr 揭示的自然尺寸来源）。
private struct WOTodoPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// todo 清单卡（TodoItem 三态行）。
/// 【M7-E3 B2 2026-09-29】动画全套按用户 HTML 原型逐值重做
///（语义源=唯一基准 C:/Users/JuYang/Desktop/动画/todo出现消失展开收起动画.html
/// 587 行全文通读；逐值表见 analysis/m7-fix2/e3-report.md）：
///   · 出现：面板淡入 opacity .42s（伴随 translateY(18px) scale(.96)→none、
///     transform-origin 50% 100% → anchor .bottom、transform .62s）→
///     等 130ms → 展开（高度 0→自然高 .6s ≙ CSS grid-template-rows 0fr→1fr）。
///   · 消失（对称）：展开中=先收起(.6s)→等 130ms→淡出 .42s（余量等 500ms）；
///     已收起=直接淡出，440ms 后清数据（原型 clearTasks :542-572 逐值）。
///   · 数据更新（AI 重发整表）：收起 → 等 300ms → 换数据（级联重跑）→
///     等 130ms → 展开（原型 invokeAI :515-535 同款间隔）。
///   · 条目级联入场 itemIn .58s both，delay = i*72ms + 150ms，
///     from {opacity 0; translateY(14px); scale(.985); blur(3px)}。
///   · chevron 旋转 180° .55s；badge 开合态变色 .3s。
///   · header hover 底色 = 纯视觉增强（触屏无 hover，裁剪，登记）。
///   · 收起状态记住（清单5 原文）：沿用 @AppStorage("wo.todo.card.collapsed")
///     持久位——手动开合写回，动画序列展开终态 = !collapsed。
///   · 挂载条件内收（WOChatView 无条件挂载）：退场动画需要「数据已清空
///     仍在树」的缓冲帧——卡片自管 presented/open 生命周期，空态自渲染。
///  颜色/内边距沿用万我主题令牌族（原型为白底黑字版，动画值为移交物，
///  主题色不是——登记 e3-report.md）。
struct WOTodoChecklistCard: View {
    let todos: [TodoItem]

    /// 收起态（全局持久：@AppStorage 单键，用户拍板候选方案中选持久——
    /// 清单卡是常驻座位组的高密度元素，收起意图跨会话保持更符合预期）。
    @AppStorage("wo.todo.card.collapsed") private var collapsed = false

    /// 面板淡入态（opacity .42s）。
    @State private var fadeShown = false
    /// 面板位移/缩放态（translateY(18px) scale(.96)→none，.62s，anchor .bottom）。
    @State private var liftShown = false
    /// 展开态（grid-template-rows 0fr→1fr 对应的自然高揭示，.6s）。
    @State private var open = false
    /// 条目级联代际（出现/更新/手动展开重跑 itemIn——CSS .open 重挂重播语义）。
    @State private var generation = 0
    /// 展示中的条目快照（退场期间 todos 已空仍需展示到动画收尾）。
    @State private var items: [TodoItem] = []
    /// 面板在树（出现序曲前挂载 → 消失清数据后卸载）。
    @State private var presented = false
    /// 列表自然高（0fr→1fr 揭示用；隐藏副本量测）。
    @State private var naturalHeight: CGFloat = 0
    /// 节奏器（新序列取消旧序列——原型 busy 单飞语义）。
    @State private var sequencer: Task<Void, Never>?

    private var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    var body: some View {
        Group {
            if presented {
                panel
            }
        }
        .onAppear { handleArrival(todos) }
        .onChange(of: todos) { newValue in handleArrival(newValue) }
        .onDisappear { sequencer?.cancel() }
    }

    // MARK: 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            // grid-template-rows 0fr→1fr 折算：Color.clear 定高度动画，
            // 内容经 overlay 恒按自然尺寸布局（不被高度约束压缩），
            // clipped 裁切自上而下揭示（原型 .todo-body 语义 1:1）。
            Color.clear
                .frame(height: revealHeight)
                .overlay(alignment: .top) {
                    todoList
                }
                .clipped()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        // 淡入 .42s（原型 .todo-panel.visible opacity 逐值）。
        .opacity(fadeShown ? 1 : 0)
        // transform-origin 50% 100% → anchor .bottom；translateY(18px)
        // scale(.96)→none，.62s（原型 transform 逐值）。
        .scaleEffect(liftShown ? 1 : 0.96, anchor: .bottom)
        .offset(y: liftShown ? 0 : 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务清单：\(completedCount) / \(items.count) 完成")
        .background(
            // 隐藏副本量测自然高（fixedSize 竖向解约束 = 0fr 基准的自然尺寸；
            // 揭示容器内内容不被压缩，量测与展示解耦）。
            todoListBody
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .accessibilityHidden(true)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: WOTodoPanelHeightKey.self,
                                           value: geo.size.height)
                })
        )
        .onPreferenceChange(WOTodoPanelHeightKey.self) { naturalHeight = $0 }
    }

    /// 展开高：0（收起）→ 自然高（展开；量测未达时先不限高防首帧 0 跳变）。
    private var revealHeight: CGFloat? {
        guard open else { return 0 }
        return naturalHeight > 0 ? naturalHeight : nil
    }

    // MARK: 标题行（= 收起/展开开关）

    /// 标题行 = 收起/展开开关（44pt 命中区达标；chevron 表达当前态）。
    private var headerRow: some View {
        Button {
            toggleExpanded()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WOAlias.stateBusinessPrimary)
                Text("任务清单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
                // todo-badge（原型 :186-200：tabular-nums + 开合态变色 .3s）。
                Text("\(completedCount)/\(items.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(open ? WOAlias.labelPrimary : WOAlias.labelSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(open ? 0.1 : 0.06)))
                    .animation(WOTodoMotion.curve(0.3), value: open)
                // todo-chevron（原型 :202-218：chevron-up 开态旋转 180°，
                // .55s 全站曲线；本卡主题令牌上色）。
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(WOTodoMotion.curve(0.55), value: open)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起任务清单" : "展开任务清单")
        .accessibilityAddTraits(.isButton)
    }

    /// 手动开合：.6s 揭示 + .55s chevron + 开态级联重跑（CSS .open 重挂
    /// 重播语义）；收起位写回持久（清单5 收起状态记住）。
    private func toggleExpanded() {
        let next = !open
        withAnimation(WOTodoMotion.curve(0.6)) { open = next }
        if next { generation += 1 }
        collapsed = !next
    }

    // MARK: 条目列表

    private var todoList: some View {
        todoListBody
            .id(generation) // 代际换身份 → 级联重跑（出现/更新/手动展开）
    }

    private var todoListBody: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, todo in
                WOTodoCascadeRow(index: index, todo: todo)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: 序列编排（原型 busy 单飞 + sleep 节奏逐值）

    /// 数据到达分派（onAppear + onChange(todos) 共用）。
    private func handleArrival(_ newValue: [TodoItem]) {
        if newValue.isEmpty {
            guard presented else { return }
            run { await disappearSequence() }
        } else if !presented {
            run { await appearSequence(newValue) }
        } else if newValue != items {
            run { await updateSequence(newValue) }
        }
    }

    /// 启动序列（取消旧序列——原型 busy 互斥）。
    private func run(_ steps: @escaping () async -> Void) {
        sequencer?.cancel()
        sequencer = Task { await steps() }
    }

    /// 节奏步（返回 false = 序列被取消，后续步全部跳过）。
    private func step(_ milliseconds: UInt64) async -> Bool {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        return !Task.isCancelled
    }

    /// 出现：淡入(.42/.62) → 等 130ms → 展开（原型 invokeAI :532-534 逐值；
    /// 展开终态 = !collapsed——收起偏好被尊重）。
    private func appearSequence(_ newItems: [TodoItem]) async {
        items = newItems
        generation += 1
        presented = true
        // 先让面板以 from 态（opacity 0 / translateY(18px) scale(.96)）上树
        // 一帧——同帧同改会以终值首帧直出（无动画，CSS transition 与 class
        // 分帧的等价要求）；≈1 帧后启动淡入。
        guard await step(16) else { return }
        withAnimation(WOTodoMotion.curve(0.42)) { fadeShown = true }
        withAnimation(WOTodoMotion.curve(0.62)) { liftShown = true }
        guard await step(130) else { return }
        withAnimation(WOTodoMotion.curve(0.6)) { open = !collapsed }
    }

    /// 更新（AI 重发整表）：收起(.6s) → 等 300ms → 换数据（级联重跑）→
    /// 等 130ms → 展开（原型 :527-534：closePanel → sleep 300 → render →
    /// sleep 130 → open 逐值）。
    /// 【P1-1 修】开头恢复可见态：本序列被新数据打断旧 disappear 序列时
    /// （run() cancel——"清空后立即重发整表"必现窗），fadeShown/liftShown
    /// 可能停在 false，只恢复 open 会致卡片全透明且不自愈——三态齐恢复。
    private func updateSequence(_ newItems: [TodoItem]) async {
        withAnimation(WOTodoMotion.curve(0.42)) { fadeShown = true }
        withAnimation(WOTodoMotion.curve(0.62)) { liftShown = true }
        withAnimation(WOTodoMotion.curve(0.6)) { open = false }
        guard await step(300) else { return }
        items = newItems
        generation += 1
        guard await step(130) else { return }
        withAnimation(WOTodoMotion.curve(0.6)) { open = !collapsed }
    }

    /// 消失（对称）：展开中=收起(.6s)→等 130ms→淡出(.42s)→余量等 500ms；
    /// 已收起=直接淡出→等 440ms；末尾清数据卸载（原型 clearTasks :549-571
    /// 逐值：open 案 sleep(500)、非 open 案 sleep(440)）。
    private func disappearSequence() async {
        let wasOpen = open
        if wasOpen {
            withAnimation(WOTodoMotion.curve(0.6)) { open = false }
            guard await step(130) else { return }
        }
        withAnimation(WOTodoMotion.curve(0.42)) { fadeShown = false }
        withAnimation(WOTodoMotion.curve(0.62)) { liftShown = false }
        guard await step(wasOpen ? 500 : 440) else { return }
        items = []
        presented = false
    }
}

// MARK: - 条目行（itemIn 级联入场）

/// 条目行：级联入场 itemIn .58s both，delay = i*72ms + 150ms，
/// from {opacity 0; translateY(14px); scale(.985); blur(3px)}（原型 :259-266
/// 逐值）。状态标记：done=实心勾圈 / doing=12 叶 spinner（currentColor 语义
/// =条目文本色）/ pending=空心圈（原型 :268-338 折算）。
private struct WOTodoCascadeRow: View {
    let index: Int
    let todo: TodoItem

    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            statusIcon
                .padding(.top, 1.5)
            Text(todo.content)
                .font(.system(size: 13.5))
                .foregroundColor(todo.status == .completed
                                 ? WOAlias.labelSecondary : WOAlias.labelPrimary)
                .strikethrough(todo.status == .completed)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        // itemIn：from {opacity 0; translateY(14px); scale(.985); blur(3px)}。
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .scaleEffect(appeared ? 1 : 0.985)
        .blur(radius: appeared ? 0 : 3)
        .onAppear {
            // .58s both，delay = i*72ms + 150ms（原型逐值）。
            withAnimation(WOTodoMotion.curve(0.58)
                .delay(Double(index) * 0.072 + 0.15)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch todo.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(WOAlias.stateSuccessPrimary)
        case .inProgress:
            // 【M7-E3 B2】12 叶片渐隐 spinner（currentColor = 条目文本色）。
            WOTodoBladeSpinner(size: 17, color: WOAlias.labelPrimary)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 12 叶片渐隐 spinner（M7-E3 · 原型 .spinner-blade 规格 1:1）

/// in_progress 行图标：12 blade 每 30° 一片，原型 CSS→SwiftUI Canvas 换算：
///   · blade 宽 0.074em / 高 0.2777em / 圆角 0.0555em（:310-318 逐值）；
///     left 0.4629em + bottom 0 = blade 底边贴容器底、水平居中；
///     transform-origin `center -0.2222em` = 旋转中心恰为容器中心
///     (0.7223−0.2222=0.5001em)；1s linear infinite；
///     keyframe 0% currentColor → 100% transparent（:335-338）——SwiftUI
///     无 currentColor，折算为调用方传条目文本色（labelPrimary）；
///     第 i 片 delay (i-1)*0.083s、rotate (i-1)*30deg 交错。
///   · 落法选择（登记 e3-report.md）：TimelineView(.animation)+Canvas 按
///     相位一次画 12 个 rounded-rect（无 12 视图节点、无隐式动画树；相位
///     由时间戳直接推导，暂停/恢复无状态漂移）。
///   · 性能：纯装饰 `.accessibilityHidden(true)`。
struct WOTodoBladeSpinner: View {
    var size: CGFloat = 14
    /// currentColor 折算（原型 .todo-item.doing 的文本色 = #0b0b0e 位）。
    var color: Color = WOAlias.labelPrimary

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
                    // 第 i 片 delay = i*0.083s；相位 0=currentColor、1=透明。
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
                             with: .color(color.opacity(1 - phase)))
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
