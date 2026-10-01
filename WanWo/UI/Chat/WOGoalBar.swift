import SwiftUI
import UIKit

// MARK: - WOGoalBar（批3 A2：dsh ui-goal/GoalBar.tsx + GoalBar.module.css 1:1 移植）
//
// 挂载于 composer 栈区（WOTodoChecklistCard 同域、其上方）。数据源 =
// ChatViewModel.goalView（GoalFold.foldGoal 快照，goal/change 事件驱动失效
// 刷新——与 todoItems 同一纪律：log-only 状态槽，不进 Bubble 流）。
//
// dsh 语义逐项对拍（GoalBar.tsx）：
// - :28-32 PHASE_LABELS——active/paused/blocked 三态标签；complete 渲染 null；
// - :44-49 goalId 变化重置编辑态/actionError/clearedGoalId（防幸存草稿的
//   Enter 写爆新 goal）；
// - :53-63 runAction pendingRef CAS——React state 下帧才生效，ref 关闭同帧
//   窗口，防连点双发同一 CAS（服务端 expectCurrent 会挡 stale，但 UI 先挡）；
// - :65-70 handleEdit——trim 空 return；保存成功才退出编辑；
// - :78 消失条件——undefined/loading、null/无 goal、phase==='complete'、
//   id===clearedGoalId 四者任一 → 无条；
// - :80-124 编辑态——input Enter 保存 / Escape 取消；保存钮 draft 空禁用；
// - :126 blocked 时整条 title = blockedReason.message。
// 几何（GoalBar.module.css）：.bar 高 36 / 圆角 12 / gap 10 / padding
// (4,12,4,5) / border 0.5 border-l1 / bg specific-tip；.label 13/24 medium；
// .objective 13/20 ellipsis primary-dimmed；.error 12/20 state-error；
// .objectiveInput 高 26 padding(0,8) 圆角 6 focus 边框 business；.iconBtn
// 28×28 圆 999 透明底 label-tertiary，禁用 opacity .4（命中区 44pt——
// WOTodoChecklistCard headerRow 同款 contentShape 负内缩先例）。
//
// 动画（用户令）：淡入淡出 cubic-bezier(.22,1,.36,1)（WOEntryModifier/
// WOTodoMotion 同曲线）；reduceMotion 静态直出（WOAgentHintPill 先例）。
// dsh 无此动画（web opacity 直挂）——平台适配登记。

/// 目标状态条（composer dock；dsh GoalBar 1:1）。
struct WOGoalBar: View {

    // MARK: 输入

    /// 当前 goal 快照（nil = 无 goal/loading——dsh undefined|null 语义合并，
    /// 两者渲染面一致：无条）。
    let goal: GoalView?
    /// 动作回调（宿主接 GoalService；async 返回错误文案，nil = 成功——
    /// dsh GoalActionResult{ok, error} 语义的 Swift 对齐）。
    let onPause: () async -> String?
    let onResume: () async -> String?
    let onEdit: (String) async -> String?
    let onClear: () async -> String?

    // MARK: 本地状态（dsh useState 全套）

    @State private var editing = false
    @State private var draft = ""
    @State private var pending = false
    @State private var actionError: String?
    @State private var clearedGoalId: String?
    /// dsh pendingRef：同步关闭连点窗口（@State 下帧才生效）。
    @State private var pendingBusy = false

    var body: some View {
        // dsh GoalBar.tsx:78 消失四条件。
        if let goal, goal.phase != .complete, goal.id != clearedGoalId {
            Group {
                if editing {
                    editingBar(goal: goal)
                } else {
                    displayBar(goal: goal)
                }
            }
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            // 淡入淡出（用户令）：cubic-bezier(.22,1,.36,1)——goal 快照
            // 变化（出现/消失/phase 翻转）统一时钟；reduceMotion 静态直出
            // （WOAgentHintPill 先例）。
            .animation(Self.reduceMotion ? nil : Self.motionCurve, value: goal)
            // 【批3 复审修 P1-3】dsh GoalBar.tsx:42-49：goalId 变化重置
            // editing/draft/actionError/clearedGoalId——「without the reset
            // a surviving draft's Enter would write over the NEW goal」。
            // 万我宿主无条件挂载、@State 跨 goal 存续（React 每 props 渲染
            // 同组件实例，二者同病），原实现缺失重置：goal 被外部替换时
            // editing 残留 + 旧 draft，Enter 把旧 objective 写爆新 goal
            // （CAS 挡不住——服务端只校验 revision，ref 恰取自新快照）。
            // 双路径覆盖：①挂载中 id 替换（A→B）走 onChange（dsh useEffect
            // [goal?.id] 同语义）；②nil→新 goal 重挂（A 清除→C 重建，分支
            // unmount/remount）走 onAppear（@State 不随分支重置的补偿——
            // dsh 组件渲染 null 时 hooks 仍运行，万我分支卸载期间 onChange
            // 不可达，等价语义由 appear 补齐）。首装 appear 重置=初值重置，
            // 无副作用。
            .onChange(of: goal.id) { _ in resetTransientState() }
            .onAppear { resetTransientState() }
        } else {
            // 保持挂载稳定（EmptyView 不参与动画差分—— disappearance 由
            // Group transition 承担）。
            EmptyView()
        }
    }

    /// 入/退场曲线：cubic-bezier(.22,1,.36,1)（WOEntryModifier/WOTodoMotion
    /// 同款参数；时长 0.35s——todo 卡同级观感）。
    private static let motionCurve = Animation.timingCurve(0.22, 1, 0.36, 1,
                                                           duration: 0.35)
    /// 辅助功能「减弱动态效果」开启 → 静态直出（无过渡）。
    private static var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    // MARK: 展示态（GoalBar.tsx:127-167）

    /// 【批3 复审修 P1-3】dsh GoalBar.tsx:44-49 reset 1:1（goalId 变化 /
    /// 重挂路径共用）：编辑态、幸存草稿、动作错误、清除标记四件全复位。
    /// pending/pendingBusy 不复位——在途动作随 await 自然落定（dsh 同不
    /// 重置）。
    private func resetTransientState() {
        editing = false
        draft = ""
        actionError = nil
        clearedGoalId = nil
    }

    @ViewBuilder
    private func displayBar(goal: GoalView) -> some View {
        HStack(spacing: 10) {
            // goalGlyph：目标图示（IconGoalOutline16 对齐——SF Symbol）。
            Image(systemName: "target")
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(width: 20, height: 20)
            // .label：13/24 medium primary（PHASE_LABELS 三态）。
            Text(Self.phaseLabel(goal.phase))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WOAlias.labelPrimary)
                .lineSpacing(4)
                .fixedSize()
            // .objective：13/20 ellipsis primary-dimmed。
            Text(goal.objective)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelPrimaryDimmed)
                .lineLimit(1)
                .truncationMode(.tail)
            if let actionError {
                // .error：12/20 state-error（role=alert）。
                Text(actionError)
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateErrorPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            actionsRow(goal: goal)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 5))
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(WOSpecific.tip)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(WOAlias.borderL1, lineWidth: 0.5)
                )
        )
        // dsh :126 blocked 时 title=blockedReason.message（web hover title
        // 的 iOS 对齐：LongPress 长文案提示走 accessibilityHint + 视觉提示
        // 省略——条内 error 槽已承载运行错误，blocked 文案经辅助功能透出）。
        .accessibilityHint(goal.phase == .blocked ? (goal.blockedReason?.message ?? "") : "")
    }

    /// 图标动作排（active→暂停；paused→恢复；恒有 编辑/清除；28px 视觉 +
    /// 44pt 命中区）。
    @ViewBuilder
    private func actionsRow(goal: GoalView) -> some View {
        HStack(spacing: 4) {
            if goal.phase == .active {
                iconButton(title: "暂停目标", icon: "pause.fill", disabled: pending) {
                    await run { await onPause() }
                }
            }
            if goal.phase == .paused {
                iconButton(title: "恢复目标", icon: "play.fill", disabled: pending) {
                    await run { await onResume() }
                }
            }
            iconButton(title: "编辑目标", icon: "pencil", disabled: pending) {
                // dsh :154：进入编辑态预填当前 objective。
                draft = goal.objective
                actionError = nil
                editing = true
            }
            iconButton(title: "清除目标", icon: "trash", disabled: pending) {
                let id = goal.id
                let error = await run { await onClear() }
                if error == nil { clearedGoalId = id }
            }
        }
    }

    // MARK: 编辑态（GoalBar.tsx:80-124）

    @ViewBuilder
    private func editingBar(goal: GoalView) -> some View {
        HStack(spacing: 10) {
            TextField("目标内容", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelPrimary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(WOAlias.bgLayer1)
                        // focus 边框 business——SwiftUI .plain 样式
                        // 无 focus 态边框钩子，恒以 1px business
                        // 描边对齐（placeholder 语义由占位文本承
                        // 担；平台适配登记）。
                        // 【CI修39】原嵌套 strokeBorder 把内层 `some View`
                        // 当 ShapeStyle 实参传外层=类型错；单层描边即语义。
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(WOAlias.stateBusinessPrimary,
                                              lineWidth: 1)
                        )
                )
                .accessibilityLabel("目标内容")
                .onSubmit { Task { await handleEditSave() } }
                // Escape 取消（iOS 16.6：键盘 Esc 无系统回调——外接键盘场景
                // 经取消按钮承担；登记平台差异）。
            if let actionError {
                Text(actionError)
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateErrorPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                // 保存（IconCheckOutline16；draft trim 空禁用）。
                iconButton(title: "保存目标", icon: "checkmark", disabled: pending || draft.trimmingCharacters(in: .whitespaces).isEmpty) {
                    await handleEditSave()
                }
                // 取消（IconCloseOutline16）。
                iconButton(title: "取消编辑", icon: "xmark", disabled: pending) {
                    editing = false
                    actionError = nil
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 5))
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(WOSpecific.tip)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(WOAlias.borderL1, lineWidth: 0.5)
                )
        )
    }

    /// 保存（dsh handleEdit :65-70：trim 空 return；成功才退出编辑）。
    private func handleEditSave() async {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let error = await run { await onEdit(trimmed) }
        if error == nil { editing = false }
    }

    // MARK: 动作执行（dsh runAction :53-63 CAS 1:1）

    /// CAS 包装：busy ref 关闭同帧连点窗口；失败回填 actionError（含 code
    /// 语义——服务层错误码透出）。返回错误文案（nil=成功）。
    private func run(_ action: () async -> String?) async -> String? {
        guard !pendingBusy else { return nil }
        pendingBusy = true
        pending = true
        actionError = nil
        let error = await action()
        pendingBusy = false
        pending = false
        if let error { actionError = error }
        return error
    }

    // MARK: 图标按钮（.iconBtn 28 视觉 / 44 命中）

    @ViewBuilder
    private func iconButton(title: String, icon: String, disabled: Bool,
                            action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.clear))
                .contentShape(Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        // 44pt 命中区（HIG；视觉 28 保持 dsh 几何——WOTodoChecklistCard
        // headerRow 同款手法：frame 外扩 + contentShape）。
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }

    // MARK: 文案（locales.ts zh 1:1）

    /// dsh PHASE_LABELS：strip 标签按可见 phase；complete 不渲染（:78）。
    private static func phaseLabel(_ phase: GoalPhase) -> String {
        switch phase {
        case .active: return "进行中的目标"
        case .paused: return "已暂停的目标"
        case .blocked: return "受阻的目标"
        case .complete: return "" // 不可达（消失条件已拦）
        }
    }
}
