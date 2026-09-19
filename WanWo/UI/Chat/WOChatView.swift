//
//  WOChatView.swift
//  WanWo
//
//  v4 片 1 核心对话环（中栏）：消息流 + 流式 + composer。
//  引擎 = 既有 ChatViewModel（M3-M6 真机验证过的会话打开/事件投影/流式/发送全链），
//  本视图只做新壳渲染——零引擎改动。
//  渲染纪律（v4 片 1 拍板 A）：全事件类型可见；工具卡用诚实简化卡（片 3 精化全型）。
//  触屏纪律（9-19 铁律 1.5）：无 hover 依赖；可见交互全部真响应。
//

import SwiftUI

struct WOChatView: View {
    @StateObject private var viewModel: ChatViewModel
    private let sessionId: String

    /// 简化自动跟随（片 1）：内容变化即滚底；翻历史被拽回的治理=片 3 四机制（登记）。
    @State private var bottomAnchor = "wo-chat-bottom"

    init(environment: AppEnvironment, sessionId: String) {
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let approval = viewModel.pendingApprovals.first {
                WOApprovalCard(viewModel: viewModel, pending: approval)
            }
            if let question = viewModel.pendingQuestions.first {
                WOQuestionCard(viewModel: viewModel, pending: question)
            }
            WOComposer(viewModel: viewModel)
        }
        .background(WOAlias.bgBase)
        .onAppear { viewModel.open() }
        .onDisappear { viewModel.close() }
    }

    // MARK: - 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.phase == .loading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 48)
                    }
                    if let banner = viewModel.resumeBanner {
                        Text(banner)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.stateWarnLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    let nodes = ConversationProjector.foldTurnProcess(viewModel.bubbles)
                    ForEach(nodes) { node in
                        switch node {
                        case .plain(let bubble):
                            bubbleView(bubble)
                        case .process(let group):
                            // 片 1 简化：过程组平铺渲染（不折叠）——思考与工具全可见
                            ForEach(group.bubbles) { inner in
                                bubbleView(inner)
                            }
                        }
                    }
                    if viewModel.phase == .streaming {
                        streamingBlock
                    }
                    if case .failed(let message) = viewModel.phase {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(WOAlias.stateErrorPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(WOAlias.stateErrorSecondary))
                    }
                    Color.clear.frame(height: 8).id(bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            .onChange(of: viewModel.bubbles) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingText) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingReasoning) { _ in follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    // MARK: - 流式块

    private var streamingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.streamingReasoning.isEmpty {
                Text("思考")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(viewModel.streamingReasoning)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            if !viewModel.streamingText.isEmpty {
                Text(viewModel.streamingText + " ▍")
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 单气泡渲染（全事件类型可见）

    @ViewBuilder
    private func bubbleView(_ bubble: ConversationProjector.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, let images):
            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundColor(WOStatic.neutral00)
                        .multilineTextAlignment(.trailing)
                    if !images.isEmpty {
                        Text("📎 \(images.count) 张图片")
                            .font(.system(size: 11))
                            .foregroundColor(WOStatic.neutral00.opacity(0.75))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(WOAlias.buttonPrimaryFill))
            }

        case .assistant(let text):
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .reasoning(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("思考")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(2)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool(let card):
            toolCard(card)

        case .command(let kind, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(kind)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))

        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

        default:
            // 回合统计等次要事件：视觉回合分隔（无假文案）
            VStack(spacing: 0) {
                Divider().opacity(0.5)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 简化工具卡（片 3 精化全型；拍板 A）

    private func toolCard(_ card: ConversationProjector.ToolCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: card))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(card.isError ? WOAlias.stateErrorPrimary
                                 : card.isRunning ? WOAlias.stateBusinessPrimary
                                 : WOAlias.stateSuccessPrimary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title.isEmpty ? card.name : card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WOAlias.labelPrimary)
                if let detail = card.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(WOAlias.labelSecondary)
                        .lineLimit(2)
                }
                if let note = card.statusNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(WOAlias.stateWarnLabel)
                }
                if let result = card.resultText, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(card.isError ? WOAlias.stateErrorPrimary : WOAlias.labelSecondary)
                        .lineLimit(4)
                }
                if card.isRunning, !card.liveOutput.isEmpty {
                    Text(card.liveOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WOAlias.labelTertiary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(WOAlias.bgLayer3))
    }

    private func icon(for card: ConversationProjector.ToolCard) -> String {
        if card.isError { return "xmark.octagon.fill" }
        if card.isRunning { return "gearshape" }
        return "checkmark.circle.fill"
    }
}


// MARK: - Hero 空态（无当前会话：品牌+新会话引导；按钮真建会话）

struct WOChatHero: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            WOFishLogo.logo(size: 40)
            Text("万我")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(WOAlias.labelPrimary)
            Text("告诉我要做什么，我来在你的 iPad 上完成")
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelTertiary)
            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("新会话")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(WOStatic.neutral00)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(WOAlias.buttonPrimaryFill))
            }
            .buttonStyle(.plain)
            .woPressable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WOAlias.bgBase)
    }
}
