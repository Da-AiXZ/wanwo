//
//  WOInteractionCards.swift
//  WanWo
//
//  v4 片 1：审批卡 + 提问卡（防对话死锁的最小真交互——审批/提问挂起时若不可
//  作答，AgentLoop 会永久等待=看不见的死锁，故本片必带）。全部动作走既有
//  ChatViewModel 方法（零引擎改动）。
//  R2c：接管语义不动（composer 座位路由 WOChatView 层已保证），视觉按原型卡
//  规格精修——白底 r22 + shadow-soft + 0.5px l3 发丝描边（digest-H composer
//  卡体规格同源）；composer 本体迁至 WOComposer.swift。
//

import SwiftUI

// MARK: - 审批卡（工具需要授权时；挂起不可见=对话永久卡死，故片 1 必带）

struct WOApprovalCard: View {
    @ObservedObject var viewModel: ChatViewModel
    let pending: PendingApprovalPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.stateWarnLabel)
                Text("需要你的授权")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Text(pending.toolName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            if let reason = pending.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            if let detail = pending.commandDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.bgModulePlatform))
                    .lineLimit(6)
            }
            HStack(spacing: 10) {
                Button {
                    viewModel.answerApproval(pending, allow: true)
                } label: {
                    Text("允许")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.buttonPrimaryFill))
                }
                .buttonStyle(.plain)
                .woPressable()

                Button {
                    viewModel.answerApproval(pending, allow: false)
                } label: {
                    Text("拒绝")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                }
                .buttonStyle(.plain)
                .woPressable()
            }
        }
        .padding(14)
        // 原型卡规格：白底 r22 + soft 阴影 + 0.5px l3 发丝描边（琥珀语义保留在
        // 图标与细节底，接管语义不变）。
        .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.03), radius: 24)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

// MARK: - 提问卡（ask_user_question；选项点选+自由文本，全部真提交）

struct WOQuestionCard: View {
    @ObservedObject var viewModel: ChatViewModel
    let pending: PendingQuestionPresentation

    @State private var selected: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.stateBusinessPrimary)
                Text("AI 有问题要问你")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
            }

            ForEach(pending.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(WOAlias.labelTertiary)
                    }
                    Text(question.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                    if let detail = question.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelSecondary)
                    }
                    if let options = question.options, !options.isEmpty {
                        FlowChips(options: options,
                                  selected: selected[question.id] ?? [],
                                  onToggle: { label in
                                      var cur = selected[question.id] ?? []
                                      if cur.contains(label) {
                                          cur.removeAll { $0 == label }
                                      } else {
                                          cur.append(label)
                                      }
                                      selected[question.id] = cur
                                  })
                    }
                    TextField("或者自己说…", text: bindingCustom(question.id))
                        .font(.system(size: 13))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.bgModulePlatform))
                }
            }

            HStack(spacing: 10) {
                Button(action: submit) {
                    Text("提交回答")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.buttonPrimaryFill))
                }
                .buttonStyle(.plain)
                .woPressable()

                Button {
                    viewModel.cancelQuestion(pending)
                } label: {
                    Text("跳过")
                        .font(.system(size: 13))
                        .foregroundColor(WOAlias.labelSecondary)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                }
                .buttonStyle(.plain)
                .woPressable()
            }
        }
        .padding(14)
        // 原型卡规格：白底 r22 + soft 阴影 + 0.5px l3 发丝描边。
        .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.03), radius: 24)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func bindingCustom(_ id: String) -> Binding<String> {
        Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 })
    }

    private func submit() {
        let answers = pending.questions.map { question -> AskUserQuestionAnswerItem in
            AskUserQuestionAnswerItem(id: question.id,
                                      selected: selected[question.id] ?? [],
                                      custom: custom[question.id]?.isEmpty == false ? custom[question.id] : nil)
        }
        viewModel.submitQuestionAnswer(pending, answer: AskUserQuestionAnswer(answers: answers))
    }
}

/// 简易流式 chips（片 1 够用；片 2 换 Menu 组件）
private struct FlowChips: View {
    let options: [AskUserQuestionOption]
    let selected: [String]
    let onToggle: (String) -> Void

    var body: some View {
        FlexibleChips(items: options.map { ($0.label, $0.description) },
                      isSelected: { selected.contains($0) },
                      onTap: onToggle)
    }
}

/// 流式换行 chips（dsh QuestionFlow 选项横向流式布局；iOS16 Layout 协议——
/// 2026-09-21 纵向堆叠极简版退役）。
private struct FlexibleChips: View {
    let items: [(String, String?)]
    let isSelected: (String) -> Bool
    let onTap: (String) -> Void

    var body: some View {
        HFlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Button {
                    onTap(item.0)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected(item.0) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0)
                                .font(.system(size: 13, weight: .medium))
                            if let desc = item.1, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundColor(WOAlias.labelTertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected(item.0) ? WOAlias.interactiveBgHoverAccent : WOAlias.bgBase))
                    .foregroundColor(isSelected(item.0) ? WOAlias.stateBusinessPrimary : WOAlias.labelPrimary)
                }
                .buttonStyle(.plain)
                .woPressable()
            }
        }
    }
}

/// 单行流式布局（iOS16 Layout 协议：放不下即换行；行内 leading 对齐）。
private struct HFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth,
                      height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
