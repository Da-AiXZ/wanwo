//
//  InteractionPresenter.swift
//  WanWo
//
//  【按 dsh 呈现缝新写 · M3 T1】出处：
//    - dsh .agents/notes/implemented/feature/2026-07-23-web-permission-and-approval.md
//      §Decision —— createApiProxy 的 approval/request waterfall answerer 把待决
//      审批呈递给 UI（approval/requested mux frame），UI 经 respond 回填裁决；
//      宿主注册表在途保存、刷新重放；裁决帧广播结算。WanWo 形态：MainActor
//      presenter 协议替代 mux 帧，ApprovalCoordinator/UserQuestionService 为
//      宿主侧唯一裁决登记处（host 内存唯一裁决者）。
//    - dsh 同笔记 —— 「The sidebar mirrors every blocked interaction with an
//      amber warning dot」：待决交互镜像进侧边栏（琥珀点实现见
//      SessionsSidebarView + AppEnvironment.pendingInteractionSessionIDs）。
//    - dsh .agents/notes/implemented/feature/2026-07-29-ask-question-web-presentation.md
//      §Decision —— 待决提问恰有两面：composer 接管收集回答 + 流内 toolview 行
//      命名交互结局；PendingCard 彻底移除（同一内容两份且一份不可作答被 dsh 否决）。
//

import Foundation

// MARK: - 待决审批呈现载荷

/// 待决审批的呈现快照（dsh PendingApproval 域面的 WanWo 值形态；
/// slots.ts:52-61 ApprovalPresentationRequest 字段 1:1：toolName/callId/reason）。
struct PendingApprovalPresentation: Identifiable, Equatable, Sendable {
    /// 审计配对 id（approval/asked ↔ approval/decided 的 requestId）。
    let id: String
    /// 被裁决的工具名。
    let toolName: String
    /// 关联 tool/call（live 工具卡配对；审计词汇暂无该字段——T1 零改动红线）。
    let callId: String?
    /// 请求方理由（缺省呈现走 dsh escalation 文案模板）。
    let reason: String?
    /// 配对命令/操作详情（dsh conversation.approval.detail 槽的 WanWo 形态：
    /// presentCall(intent) 复现的命令文本；呈现层不重复 args JSON）。
    let commandDetail: String?
}

// MARK: - 待决提问呈现载荷

/// 待决提问的呈现快照（dsh user-questions AskUserQuestionRequestEvent.questions
/// 1:1；composer 接管的数据源）。
struct PendingQuestionPresentation: Identifiable, Equatable, Sendable {
    /// 请求 id（UI 回答回传的配对键）。
    let id: String
    let questions: [AskUserQuestionItem]
    /// 关联 tool/call（ask_user_question 工具卡 waiting/结算态配对）。
    let callId: String?
}

// MARK: - 提问结算形态

/// 提问请求的结算形态（流内 toolview 行结局词汇的来源；
/// dsh 2026-07-29 笔记：waiting / N/M answered / cancelled / interrupted）。
enum QuestionSettlement: Equatable, Sendable {
    /// 用户提交了回答（N/M answered 计数的数据源）。
    case answered(AskUserQuestionAnswer)
    /// 用户主动关闭整组提问（ASK_CANCELLED；中性结算态——用户蓄意为之）。
    case cancelled
    /// 回合中断落在提问等待中（ASK_ABORTED；琥珀 stopped 语义）。
    case aborted
}

// MARK: - presenter 协议

/// 会话交互呈现缝（MainActor；由 ChatViewModel 实现）。
/// coordinator/service 只经此协议触达 UI——UI 不是裁决者，回答回调最终落回
/// coordinator/service 的登记表（host 内存唯一裁决者，first answer wins）。
@MainActor
protocol SessionInteractionPresenter: AnyObject {
    /// 呈现一条待决审批（composer 接管 + 工具卡 waiting 态 + 侧栏琥珀点）。
    func presentApproval(_ pending: PendingApprovalPresentation)
    /// 结算一条待决审批（面板退位恢复 composer + 工具卡结算态）。
    func settleApproval(id: String, outcome: ApprovalOutcome)
    /// 呈现一组待决提问（composer 接管 + 工具卡 waiting 态）。
    func presentQuestion(_ pending: PendingQuestionPresentation)
    /// 结算一组待决提问（toolview 行结局：N/M answered / cancelled / interrupted）。
    func settleQuestion(id: String, settlement: QuestionSettlement)
}

// MARK: - 待决提问队列纯函数（T2.3 P0 第二道防线）

/// 待决提问队列的去重并入（dsh 2026-07-23 笔记 :19——pre-instantiation
/// buffering「retains each live request identity, **replaces replay
/// duplicates**」：同 id 重放副本替换既有项，不叠加）。纯函数可测。
enum PendingQuestionMirror {
    /// 按 id 并入：既有项替换（保留原位——FIFO 呈现序稳定），否则追加。
    static func upsert(_ list: [PendingQuestionPresentation],
                       _ pending: PendingQuestionPresentation) -> [PendingQuestionPresentation] {
        if let index = list.firstIndex(where: { $0.id == pending.id }) {
            var updated = list
            updated[index] = pending
            return updated
        }
        return list + [pending]
    }
}
