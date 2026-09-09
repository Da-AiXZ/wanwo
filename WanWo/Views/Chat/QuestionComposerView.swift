//
//  QuestionComposerView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T1】出处（呈现形态 = 原件）：
//    - packages/client/ui-user-questions/src/client/QuestionComposer.tsx ——
//      QuestionFlow 结构 1:1：header（eyebrow header + 标题 + 关闭）→ 滚动体
//      （detail + 选项列 + 自定义回答行）→ footer（分页 N / M + 反馈 + 跳过/
//      下一题/提交）；单选数字行、多选显式 checkbox、(Recommended)/(推荐)
//      后缀解析（parseRecommendedLabel :30-35）；提交组装语义（:205-232）：
//      skipped → {id, selected: []}；custom 非空且单选 → 仅 custom；多选保留
//      selected 并可附带 custom；未答完聚焦缺失项并提示。
    //    - packages/client/ui-user-questions/src/client/QuestionComposer.module.css
    //      —— 结构常量（卡片圆角 16、选项行内边距、footer 布局）。
    //    - packages/client/ui-user-questions/src/client/locales.ts:5-14 —— zh
    //      文案逐字（T2.2 B13 对齐）：error.incomplete「请先完成这道问题。」/
    //      error.unanswered「请选择一个选项或填写自定义答案。」/
    //      custom.placeholder「输入你的答案」/ action.skip「跳过本题」/
    //      nav.cancel「放弃整组问题」。
    //    - .agents/notes/implemented/feature/2026-07-29-ask-question-web-presentation.md
    //      —— composer 接管收集回答；跳过语义（skipped 不计入 N/M）；
    //      multi_select 是结构化元数据，标题逐字渲染（（可多选）后缀约定已删除）。
//  plan-review 意图（intent.kind = "plan-review"）随 T3 落 PlanReviewPanel；
//  本页按 dsh 契约对未知意图回退通用流（types.ts:15-19：意图只改呈现不改协议）。
//

import SwiftUI

/// 提问 composer 接管（收集整组回答；答后由 settleQuestion 退位恢复 composer）。
struct QuestionComposerView: View {
    let pending: PendingQuestionPresentation
    let busy: Bool
    let onSubmit: (AskUserQuestionAnswer) -> Void
    let onCancel: () -> Void

    /// 单题草稿（dsh QuestionDraftAnswer）。
    private struct Draft {
        var selected: [String] = []
        var custom: String = ""
        var skipped = false
    }

    @State private var index = 0
    @State private var drafts: [Draft]
    @State private var feedback: String?

    init(pending: PendingQuestionPresentation, busy: Bool,
         onSubmit: @escaping (AskUserQuestionAnswer) -> Void,
         onCancel: @escaping () -> Void) {
        self.pending = pending
        self.busy = busy
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _drafts = State(initialValue: pending.questions.map { _ in Draft() })
    }

    private var questions: [AskUserQuestionItem] { pending.questions }
    private var question: AskUserQuestionItem { questions[index] }
    private var draft: Draft { drafts[index] }
    private var hasOptions: Bool { !(question.options ?? []).isEmpty }
    private var isLast: Bool { index == questions.count - 1 }
    private var multiSelect: Bool { question.multiSelect == true }

    /// dsh parseRecommendedLabel（:30-35）：(recommended)/(推荐) 后缀仅作显示。
    private func displayLabel(_ label: String) -> (label: String, recommended: Bool) {
        if let range = label.range(of: #"\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$"#,
                                   options: .regularExpression) {
            return (String(label[..<range.lowerBound]), true)
        }
        return (label, false)
    }

    private func answered(_ d: Draft) -> Bool {
        !d.selected.isEmpty || !d.custom.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let detail = question.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    optionRows
                    customRow
                }
                .padding(12)
            }
            .frame(maxHeight: ApprovalPanelStyle.textMaxHeight, alignment: .top)
            Divider()
            footer
        }
        .background(ApprovalPanelStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(ApprovalPanelStyle.warnPrimary.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: header（eyebrow + 标题 + 关闭）

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow = question.header, !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(question.question)
                    .font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            // B13：zh nav.cancel 逐字（放弃整组问题）。
            .accessibilityLabel("放弃整组问题")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 选项列（单选数字行 / 多选 checkbox 行）

    @ViewBuilder
    private var optionRows: some View {
        ForEach(Array((question.options ?? []).enumerated()),
                id: \.offset) { optionIndex, option in
            let display = displayLabel(option.label)
            let isSelected = draft.selected.contains(option.label)
            Button {
                choose(option.label)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if multiSelect {
                        Image(systemName: isSelected ? "checkmark.square.fill"
                                                     : "square")
                            .foregroundStyle(isSelected ? ApprovalPanelStyle.warnPrimary
                                                        : Color.secondary)
                    } else {
                        Text("\(optionIndex + 1)")
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(display.label)
                            if display.recommended {
                                Text("推荐")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(ApprovalPanelStyle.warnTertiary)
                                    .foregroundStyle(ApprovalPanelStyle.warnPrimary)
                                    .cornerRadius(4)
                            }
                        }
                        if let description = option.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected && !multiSelect
                            ? ApprovalPanelStyle.warnTertiary
                            : Color(.tertiarySystemFill).opacity(0.5))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    // MARK: 自定义回答行（恒可见；有选项 = 行内列，无选项 = 主体文本域）

    @ViewBuilder
    private var customRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if multiSelect {
                Image(systemName: draft.custom.isEmpty ? "square" : "checkmark.square.fill")
                    .foregroundStyle(draft.custom.isEmpty ? Color.secondary
                                                          : ApprovalPanelStyle.warnPrimary)
            } else {
                Image(systemName: "pencil.line")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // B13：custom.placeholder zh 逐字「输入你的答案」。
            TextField("输入你的答案", text: customBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Color(.tertiarySystemFill).opacity(0.5))
                .cornerRadius(10)
        }
        .padding(hasOptions ? 0 : 10)
        .opacity(busy ? 0.6 : 1)
        .disabled(busy)
    }

    private var customBinding: Binding<String> {
        Binding {
            drafts[index].custom
        } set: { value in
            guard index < drafts.count else { return }
            // dsh draftCustom（:250-258）：单选自定义回答替换选择；多选共存。
            drafts[index].custom = value
            drafts[index].skipped = false
            if !multiSelect { drafts[index].selected = [] }
            feedback = nil
        }
    }

    // MARK: footer（分页 + 反馈 + 跳过/下一题/提交）

    private var footer: some View {
        VStack(spacing: 6) {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button {
                    guard index > 0 else { return }
                    index -= 1
                    self.feedback = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0 || busy)

                Text("\(index + 1) / \(questions.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    guard !isLast else { return }
                    index += 1
                    self.feedback = nil
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(isLast || busy)

                Spacer()

                // B13：action.skip zh 逐字「跳过本题」。
                Button("跳过本题") { skipQuestion() }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                Button(continueTitle) { continueFlow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (!isLast && !answered(draft)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var continueTitle: String {
        isLast ? "提交" : "下一题"
    }

    // MARK: 交互（dsh choose/continueFlow/skipQuestion/submitDrafts 语义）

    private func choose(_ label: String) {
        guard index < drafts.count else { return }
        if multiSelect {
            if let at = drafts[index].selected.firstIndex(of: label) {
                drafts[index].selected.remove(at: at)
            } else {
                drafts[index].selected.append(label)
            }
        } else {
            drafts[index].selected = [label]
            drafts[index].custom = ""
        }
        drafts[index].skipped = false
        feedback = nil
        // dsh choose（:188-198）：单选选择后自动进入下一题。
        if !multiSelect, !isLast {
            index += 1
        }
    }

    private func continueFlow() {
        if !answered(draft) {
            // B13：error.unanswered zh 逐字（单题未答）。
            feedback = "请选择一个选项或填写自定义答案。"
            return
        }
        if !isLast {
            index += 1
            feedback = nil
            return
        }
        submitDrafts(drafts)
    }

    private func skipQuestion() {
        guard index < drafts.count else { return }
        drafts[index] = Draft(skipped: true)
        feedback = nil
        if !isLast {
            index += 1
            return
        }
        submitDrafts(drafts)
    }

    /// 提交组装（dsh submitDrafts :205-232 逐条 1:1；skipped → {id, selected:[]}；
    /// custom 非空且单选 → 仅 custom；多选保留 selected 可附带 custom）。
    private func submitDrafts(_ values: [Draft]) {
        if let missing = values.firstIndex(where: { !$0.skipped && !answered($0) }) {
            index = missing
            // B13：error.incomplete zh 逐字（提交前聚焦缺失项）。
            feedback = "请先完成这道问题。"
            return
        }
        let answers = questions.enumerated().map { questionIndex, item -> AskUserQuestionAnswerItem in
            let value = values[questionIndex]
            if value.skipped {
                return AskUserQuestionAnswerItem(id: item.id, selected: [], custom: nil)
            }
            let custom = value.custom.trimmingCharacters(in: .whitespaces)
            if custom.isEmpty {
                return AskUserQuestionAnswerItem(id: item.id, selected: value.selected,
                                                 custom: nil)
            }
            return AskUserQuestionAnswerItem(
                id: item.id,
                selected: multiSelect ? value.selected : [],
                custom: custom)
        }
        onSubmit(AskUserQuestionAnswer(answers: answers))
    }
}
