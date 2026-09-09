//
//  PlanModeController.swift
//  WanWo
//
//  【语义移植 · dsh · M3 T3】出处（packages/plan/plan-mode/src/index.ts 全量
//  1:1 + packages/bundle/base/cordis.patch.yml:311-321）：
//    - index.ts:39-48 —— plan/mode 事件：log-only 非表层、整值替换，last wins，
//      无记录折叠为 inactive。WanWo 承载：E1 extensionEvent 通道（wire type =
//      "extension/plan/mode"；schema {active:bool} 由 AppEnvironment 装配期注册，
//      T3 报批项——projection=logOnly，pairing=none）。
//    - index.ts:15-17 + :56-60 —— exit_plan_mode 常驻注册（模式切换只改 prompt
//      section，不改请求工具目录——request-cache stability）。
//    - index.ts:69-75 —— REVIEW_ID="plan-review" / APPROVE_LABEL="Approve" /
//      KEEP_PLANNING_LABEL="Keep planning"。
//    - index.ts:77-81 —— EXIT_DESCRIPTION 原文逐字。
//    - index.ts:84-90 —— firstHeading（逐行 /^#{1,6}\s+(.+?)\s*$/ 首命中）。
//    - index.ts:88-148 —— exit execute 全流：plan mode 守卫 → # 标题校验 →
//      无 user-questions 通道抛错 → ask 单问题（header "Plan review"，detail=plan，
//      intent={kind:"plan-review", approve:"Approve"}——呈现意图，能力 UI 可渲染
//      计划审阅决策）→ ASK_CANCELLED 特判（驳回≠失败：用户收回发言权）→
//      恰好一个 Approve 且无 custom 才算同意（其余 fail closed 携逐字反馈）→
//      approved → 退出计划模式 + 固定 success 文案。
//    - index.ts:251-262 —— narration 两句原文（用户切换叙述；dsh 只在
//      activeAtLastHeader 纪元翻转时注入一次，WanWo 每次用户切换都叙述——偏差）。
//    - cordis.patch.yml:311-321 —— PLAN_POLICY 六段部署方守则逐字（config.section
//      原件；红线④呈现=dsh 原件）。
//  WanWo 简化（偏差登记，issue-ledger 同步条目）：
//    1. dsh set() 的 pendingIntents + agent/pre-step 两段提交（用户选择缓存到
//       下一 accepted in-turn pre-step 才落 plan/mode；同 step 重试复用组装）
//       —— WanWo 无 pre-step 缝，commit 立即落盘（writer.append 返回即 fsync，
//       model-visible=logged 等价成立；exit 工具批准后同样直接落盘）。
//    2. dsh narration 按 activeAtLastHeader 纪元去重——WanWo 不追踪纪元，每次
//       用户切换均注入（信息幂等，无害）。
//    3. dsh /plan 的 [off|message] 附加消息与附件走 agent.steer——M7 子代理缝；
//       本构建 /plan 附加消息报不支持（不切模式，fail closed）。
//    4. dsh plan:policy 段落为动态 text 函数——WanWo PromptAssembler 段落静态，
//       以 {{plan_policy}} 变量承载门控：active 时变量=PLAN_POLICY 原文，inactive
//       时=""（空段落被 assemble 丢弃，dsh text 返回 '' 等价）。变量在 init 即
//       赋值（空串也登记），interpolate 不会因未赋值抛错。
//

import Foundation

// MARK: - 控制器

/// 计划模式协调器：plan/mode 事件折叠 + plan:policy 段落门控 + /plan + 常驻
/// exit_plan_mode 的状态宿主。线程模型：/plan 在命令任务写，审批缝/工具执行在
/// 后台线程读——activeState NSLock 保护，assembler 内部自锁。
final class PlanModeController: @unchecked Sendable {

    /// plan/mode 扩展事件 kind（wire type = "extension/plan/mode"；T3 报批项）。
    static let modeEventKind = "plan/mode"

    /// plan:policy 段落的变量名（section text = "{{plan_policy}}"）。
    static let policyVariable = "plan_policy"

    /// 用户切换叙述的投影过滤前缀（ConversationProjector.markerPrefixes 对齐）。
    static let narrationPrefix = "<plan-mode-update>"

    private let writer: SessionWriter
    private let assembler: PromptAssembler
    private let lock = NSLock()
    private var activeState = false

    private static let logger = AppLogger(category: "PlanModeController")

    init(writer: SessionWriter, assembler: PromptAssembler) {
        self.writer = writer
        self.assembler = assembler
        // plan:policy 段落注册（order = SECTION_ORDERS.planPolicy = dsh
        // PLAN_POLICY 布局位 500，system-prompt/src/index.ts:126）。
        assembler.section(PromptSection(
            name: "plan:policy",
            order: SECTION_ORDERS.planPolicy,
            text: "{{\(Self.policyVariable)}}"))
        // resume/fork 恢复：取事件流中最后一条 plan/mode（last wins 整值替换；
        // 无记录折叠为 inactive——dsh plan projection fold 语义）。
        var restored = false
        for event in writer.events.reversed() {
            if case .extensionEvent(Self.modeEventKind, let payload) = event.payload,
               let active = payload.field("active")?.boolValue {
                restored = active
                break
            }
        }
        installState(restored)
    }

    /// 计划模式当前是否生效（内存折叠值；与最后一条 plan/mode 事件一致）。
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeState
    }

    /// 切换计划模式并持久化（dsh set() 的 committed/noop 两态——WanWo 无 open
    /// turn pending 缝，一律立即提交）。
    /// - Parameters:
    ///   - active: 目标状态。
    ///   - narrate: 是否注入用户切换叙述（用户选择 true；exit 工具 false——
    ///     其工具结果已叙述转变，dsh index.ts:177-181 注释语义）。
    /// - Returns: true = 状态发生变化（plan/mode 事件已落盘）；false = noop。
    /// - Throws: 落盘失败（状态不变，fail closed 可重试——dsh :222-227 注释：
    ///   "a failed durable write leaves the selection retryable, not dropped"）。
    @discardableResult
    func commit(_ active: Bool, narrate: Bool) async throws -> Bool {
        if isActive == active { return false }
        // 先落盘后进内存（fail closed；写侧 schema 门校验词汇恒合法）。
        _ = try await writer.append(.extensionEvent(
            kind: Self.modeEventKind,
            payload: .object(["active": .bool(active)])))
        installState(active)
        if narrate {
            // dsh narration 原文两句（index.ts:254-256）；<plan-mode-update>
            // 前缀由投影层过滤不渲染气泡，但进派生历史（model-visible=logged）。
            let text = active
                ? "The user switched this session to plan mode."
                : "The user switched this session back to the default mode."
            try? await writer.append(
                .userMessage(text: Self.narrationPrefix + "\n" + text))
        }
        return true
    }

    /// 内存 + 提示词变量同步落位（init 恢复与 commit 共用）。
    private func installState(_ value: Bool) {
        lock.lock()
        activeState = value
        lock.unlock()
        assembler.setVariable(Self.policyVariable, value ? Self.planPolicy : "")
    }

    // MARK: - PLAN_POLICY（cordis.patch.yml:311-321 部署方 config.section 原文逐字）

    static let planPolicy = """
    You are in plan mode. Stay in plan mode until exit_plan_mode succeeds or the user switches the session mode. Imperative language to implement changes means plan the implementation, not execute it. A user's conversational agreement — including an answer confirming something you asked — approves nothing and does not end plan mode; fold the confirmed decision into the plan and submit it through exit_plan_mode.

    Explore first. Use non-mutating reads, searches, static analysis, and checks to ground the plan in the actual repository. Do not edit or write files, change configuration, run formatters or code generation that rewrites tracked files, commit, or otherwise carry out the plan. Prefer existing functions and patterns over new machinery.

    The tool catalog stays the same across modes for request-cache stability. These plan-mode rules override any later tool description or guidance that suggests using mutation tools; those tools remain listed only to keep the request shape stable. Do not use todo_write to track this planning phase: it tracks implementation after an approved plan, while the plan itself belongs in exit_plan_mode.

    Resolve discoverable facts by inspection. Use ask_user_question only for user-owned choices or material ambiguity that inspection cannot answer. Do not ask the user where code lives or how current behavior works when you can find out.

    Make the plan decision-complete: state the goal and success criteria; group implementation changes by subsystem; identify public API, schema, and data-flow changes; cover edge cases, failure modes, tests, acceptance criteria, and explicit assumptions. Keep it concise enough to review but detailed enough that another engineer can implement it without making design decisions.

    When ready, call exit_plan_mode with the complete plan markdown, starting with a # title. Make exit_plan_mode the only and final tool call in that assistant response: it presents the plan for approval, and implementation begins only in a later step after approval. Do not paste the final plan as a plain reply or ask "should I proceed?" through prose or ask_user_question. If review rejects it, incorporate the feedback and present again. If the review channel is unavailable or aborted, stay in plan mode and ask the user to switch modes manually; do not proceed with implementation.
    """
}

// MARK: - exit_plan_mode（dsh defineTool 1:1）

/// exit_plan_mode（M3 T3）：常驻注册（模式切换不改工具目录）；只在 plan mode
/// 可用；把完整计划呈现给用户审阅，批准后退出计划模式。
struct ExitPlanModeTool: AgentTool {
    /// dsh EXIT_PLAN_MODE（index.ts:60）。
    static let toolName = "exit_plan_mode"

    /// dsh REVIEW_ID / APPROVE_LABEL / KEEP_PLANNING_LABEL（index.ts:69-75）。
    static let reviewID = "plan-review"
    static let approveLabel = "Approve"
    static let keepPlanningLabel = "Keep planning"

    let name = Self.toolName

    /// dsh EXIT_DESCRIPTION 原文（index.ts:77-81）。
    let description = "Use only in plan mode. Present your plan for the user's review and, on approval, leave plan mode. "
        + "Send the COMPLETE plan as markdown, starting with a # heading that names it. "
        + "The user may approve (carry out the plan from your next step) or keep "
        + "planning — their feedback comes back in the tool result; revise and present again."

    /// 参数 schema（dsh index.ts:75-77 1:1：plan string required）。
    let parameters: JSONValue = .schemaObject(
        properties: [
            "plan": .object([
                "type": .string("string"),
                "description": .string("The complete plan, as markdown, starting with a # heading that names it."),
            ]),
        ],
        required: ["plan"])

    /// 计划模式状态宿主（makeAgentStack 装配；同一会话同一实例）。
    let controller: PlanModeController
    /// 审阅通道（T1 预建 UserQuestionService；BAD_INTENT 校验在 ask 内）。
    let service: UserQuestionService

    // 人类审阅耗时不可预算，不设 deadline（与 ask_user_question 同纪律）。
    var timeoutMs: Int? { nil }

    // MARK: - 首个标题（dsh firstHeading 1:1）

    /// 计划的首个 markdown 标题（任意层级 ^#{1,6}\s+(.+?)\s*$），无则 nil。
    static func firstHeading(_ plan: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^#{1,6}\\s+(.+?)\\s*$") else {
            return nil
        }
        for line in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let ns = String(line) as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: String(line), range: range),
               match.range.length > 1 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// 标题校验（dsh index.ts:94：/^#\s+\S/.test(plan.trim())——必须以 # 级标题起头）。
    static func hasTopLevelHeading(_ plan: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^#\\s+\\S") else { return false }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        return regex.firstMatch(in: trimmed,
                                range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: - 执行（dsh execute index.ts:88-148 1:1）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let plan = args.field("plan")?.stringValue ?? ""
        // 非 plan mode（dsh :91-93；fail closed：模式外不得经此工具退场）。
        guard controller.isActive else {
            return .failure("\(Self.toolName) is only available in plan mode",
                            code: "NOT_IN_PLAN_MODE", name: "Error")
        }
        // 标题校验（dsh :94-96；缺 plan 参数同口径拒绝）。
        guard !plan.isEmpty, Self.hasTopLevelHeading(plan) else {
            return .failure("\(Self.toolName) requires a non-empty markdown plan "
                + "starting with a # heading",
                            code: "INVALID_PLAN", name: "Error")
        }
        // 无审阅通道（dsh :97-100 原文；fail closed——请用户手动切模式）。
        guard service.hasAnswerer else {
            return .failure("no user-questions channel is available to review the plan; "
                + "ask the user to switch the session mode instead",
                            code: "NO_REVIEW_CHANNEL", name: "Error")
        }
        // 审阅问题（dsh :101-115 逐字段 1:1；intent 仅呈现意图——能力 UI 渲染
        // 计划审阅决策，通用 composer 回退形态同协议）。
        let question = AskUserQuestionItem(
            id: Self.reviewID,
            question: "Approve this plan and leave plan mode?",
            detail: plan,
            header: "Plan review",
            options: [
                AskUserQuestionOption(
                    label: Self.approveLabel,
                    description: "Leave plan mode; the plan is carried out from the next step."),
                AskUserQuestionOption(
                    label: Self.keepPlanningLabel,
                    description: "Stay in plan mode; feedback goes back to the model."),
            ],
            multiSelect: nil,
            intent: AskUserQuestionIntent(kind: "plan-review", approve: Self.approveLabel))
        let answer: AskUserQuestionAnswer
        do {
            answer = try await service.ask(questions: [question], callId: ctx.callId)
        } catch let error as UserQuestionError {
            // ASK_CANCELLED 特判（dsh :124-127 原文）：驳回≠失败——用户收回
            // 发言权要说而两个选项未覆盖的内容；留在计划模式等待其消息。
            // 其余（ASK_ABORTED 等）保留自身消息（dsh :128 rethrow）。
            if error.code == "ASK_CANCELLED" {
                return .failure("The user dismissed the plan review to speak instead; "
                    + "stay in plan mode, stop here, and wait for their message.",
                                code: "ASK_CANCELLED", name: "Error")
            }
            return .failure(error.message, code: error.code, name: "UserQuestionError")
        }
        // 裁决（dsh :135-142 1:1）：恰好一个 plan-review 回答项、恰好一个选项
        // 且为 Approve、无 custom——三者缺一即拒绝（fail closed 携逐字反馈）。
        let reviewItems = answer.answers.filter { $0.id == Self.reviewID }
        let item = reviewItems.count == 1 ? reviewItems[0] : nil
        if item?.selected.count != 1 || item?.selected.first != Self.approveLabel
            || item?.custom != nil {
            let feedback = item?.custom ?? ""
            return .failure(feedback.isEmpty
                ? "The user chose to keep planning; revise the plan and present it again."
                : "The user chose to keep planning; their feedback: \(feedback)",
                            code: "PLAN_REJECTED", name: "Error")
        }
        // 批准 → 退出计划模式（dsh :146 pendingIntents 缓存随 pre-step 落盘；
        // WanWo 立即落盘——偏差 1。落盘失败 fail closed：状态不变、工具报错，
        // 计划模式保持生效）。
        do {
            _ = try await controller.commit(false, narrate: false)
        } catch {
            Self.logger.error("plan mode exit append failed: "
                + "\(String(describing: error))")
            return .failure("failed to record the plan mode exit; stay in plan mode "
                + "and present the plan again",
                            code: "PLAN_COMMIT_FAILED", name: "Error")
        }
        // dsh output.render 原文（index.ts:86）。
        return .success("Plan approved — plan mode exited; carry out the plan "
            + "starting with your next step.")
    }

    private static let logger = AppLogger(category: "ExitPlanModeTool")

    // MARK: - 呈现（dsh presentCall/presentResult index.ts:149-159）

    /// 待执行卡：标题=首个标题 ?? "Plan"；detail=计划原文（dsh content=plan）。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let plan = args.field("plan")?.stringValue ?? ""
        return ToolCardIntent(title: Self.firstHeading(plan) ?? "Plan",
                              detail: plan.isEmpty ? nil : plan)
    }

    /// 结算卡：标题固定 "Plan review"（成功/失败同形，dsh presentResult 不分流）。
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? {
        ToolCardIntent(title: "Plan review", detail: output.text)
    }
}
