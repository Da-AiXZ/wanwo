//
//  WOChatView.swift
//  WanWo
//
//  v4 片 1 → R2a 对话域保真批 1（11-ui-design §六；D6/D8 部分清偿）：
//  - 消息流全节点渲染：用户气泡圆角 22/bubble soft（原型规格）；工具卡全型 WOToolCard
//   （digest-F §41；替代片 1 简化版）；思考披露折叠（ReasoningRow 语义简化版）。
//  - composer 接管语义（ledger:256 既有裁定）：审批/提问挂起时接管 composer 座位
//   （不再是消息流下追加的独立卡）——防引擎等待死锁面不变。
//  引擎 = 既有 ChatViewModel（M3-M6 真机验证过），零引擎改动。
//  触屏纪律：无 hover 依赖；可见交互全部真响应。
//

import SwiftUI

struct WOChatView: View {
    @StateObject private var viewModel: ChatViewModel
    private let sessionId: String

    /// 简化自动跟随（批 1）：内容变化即滚底；治理=后续批（autoFollow 闸门按 digest-K 6.3#1）。
    @State private var bottomAnchor = "wo-chat-bottom"

    init(environment: AppEnvironment, sessionId: String) {
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composerSeat
        }
        .background(WOAlias.bgBase)
        .onAppear { viewModel.open() }
        .onDisappear { viewModel.close() }
    }

    // MARK: - Composer 座位（接管语义：dsh composer seat——审批 > 提问 > 常规输入；
    // ComposerSeatRoute 纯函数序在 VM 层已保证 pendingApprovals/pendingQuestions 序）

    @ViewBuilder
    private var composerSeat: some View {
        if let approval = viewModel.pendingApprovals.first {
            WOApprovalCard(viewModel: viewModel, pending: approval)
        } else if let question = viewModel.pendingQuestions.first {
            WOQuestionCard(viewModel: viewModel, pending: question)
        } else {
            WOComposer(viewModel: viewModel)
        }
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
                            // 批 1：过程组平铺渲染（不折叠）——思考与工具全可见；
                            // 组折叠行（TurnProcess 摘要）=批 2。
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
                // 思考披露（ReasoningRow 语义简化版：标题行+最新行跟随；全文在
                // 投影 reasoning 气泡，回合结束自然呈现）。
                Text("思考")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(viewModel.streamingReasoning.split(separator: "\n").last.map(String.init) ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(2)
            }
            if !viewModel.streamingText.isEmpty {
                Text(viewModel.streamingText + " ▍")
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineSpacing(3)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // 原型规格：圆角 22 + 蓝软底（WOSpecific.bubble = deepseek-50）。
                .background(RoundedRectangle(cornerRadius: 22).fill(WOSpecific.bubble))
            }

        case .assistant(let text):
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .reasoning(let text):
            // 思考披露（ReasoningRow 语义简化版：可折叠；标题「思考」+ 首行预览）。
            ReasoningDisclosure(text: text)

        case .tool(let card):
            // R2a：工具卡全型（digest-F §41；D6 清偿——替代片 1 简化版）。
            WOToolCard(card: card, sessionID: sessionId)

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
            // 回合统计等次要事件：视觉回合分隔（无假文案）。
            VStack(spacing: 0) {
                Divider().opacity(0.5)
            }
            .padding(.vertical, 2)
        }
    }
}

/// 思考披露（ReasoningRowView 语义简化版——旧件 98 行的折叠交互+WO 壳；
/// running 态扫光/尾行跟随的完整版随流式块呈现，此处为 settled 全文折叠）。
private struct ReasoningDisclosure: View {
    let text: String

    @State private var expanded = false

    private var preview: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text("思考")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                    if !expanded {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(2)
                    .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
