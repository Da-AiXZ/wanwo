//
//  SideChatView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.2（codex 截图「侧边聊天」）】
//  侧聊视图：父会话状态行（用户拍板加——主对话 等输入/等审批/运行中/空闲
//  徽标）+ 卡片流（主对话同一折叠规则投影）+ 独立 composer（从简形态：文本
//  + 发送/停止——codex 的 +/请求批准/模型选择随父会话挡位，侧聊不另设）。
//  空态 = "侧边聊天是临时聊天，关闭应用后会消失。"
//

import SwiftUI

struct SideChatView: View {
    @ObservedObject var environment: AppEnvironment
    let parentSessionID: String?
    @StateObject private var viewModel: SideChatViewModel
    @State private var autoFollow = true

    init(environment: AppEnvironment, parentSessionID: String?) {
        self.environment = environment
        self.parentSessionID = parentSessionID
        _viewModel = StateObject(wrappedValue: SideChatViewModel(
            environment: environment, parentSessionID: parentSessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            parentStatusRow
            Divider()
            messageStream
            Divider()
            composer
        }
        .onAppear { viewModel.open() }
        .onChange(of: environment.pendingInteractionSessionIDs) { _ in
            // 状态行镜像驱动（@Published 集合变化重算）。
            viewModel.objectWillChange.send()
        }
        .onChange(of: environment.activeRunSessionIDs) { _ in
            viewModel.objectWillChange.send()
        }
    }

    // MARK: - 父会话状态行（用户拍板加）

    @ViewBuilder
    private var parentStatusRow: some View {
        let status = viewModel.parentStatus()
        HStack(spacing: 6) {
            switch status {
            case .noParent:
                Text("侧边聊天 · 未选择主会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsInput:
                Circle()
                    .fill(ApprovalPanelStyle.warnPrimary)
                    .frame(width: 7, height: 7)
                Text("主对话在等你（输入 / 审批）")
                    .font(.caption)
                    .foregroundStyle(ApprovalPanelStyle.warnPrimary)
            case .running:
                ProgressView().controlSize(.mini)
                Text("主对话运行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("主对话空闲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 卡片流（主对话同一投影产物；紧凑渲染）

    private var messageStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                messageStreamContent
            }
            .onChange(of: viewModel.bubbles) { _ in
                guard autoFollow else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("side-bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingText) { _ in
                guard autoFollow else { return }
                proxy.scrollTo("side-bottom-anchor", anchor: .bottom)
            }
        }
    }

    /// 卡片流内容（从 messageStream 拆出：长 SwiftUI 链会触发编译器
    /// 类型检查超时——错误 8 的最小拆解，不改动任何语义）。
    @ViewBuilder
    private var messageStreamContent: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if let note = viewModel.boundaryNote, viewModel.bubbles.isEmpty {
                Text("侧边聊天是临时聊天，关闭应用后会消失。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 18)
            }
            ForEach(viewModel.bubbles) { bubble in
                bubbleView(bubble).id(bubble.id)
            }
            if !viewModel.streamingReasoning.isEmpty {
                ReasoningRowView(text: viewModel.streamingReasoning, running: true)
                    .id("side-streaming-reasoning")
            }
            if !viewModel.streamingText.isEmpty {
                Text(viewModel.streamingText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .id("side-streaming-text")
            }
            if case .failed(let message) = viewModel.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Color.clear.frame(height: 1).id("side-bottom-anchor")
        }
        .padding(10)
    }

    @ViewBuilder
    private func bubbleView(_ bubble: ConversationProjector.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, _):
            HStack {
                Spacer(minLength: 32)
                Text(text)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(8)
            }
        case .assistant(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        case .reasoning(let text):
            ReasoningRowView(text: text, running: false)
        case .tool(let card):
            sideToolCard(card)
        case .command(_, let text):
            Text("⌘ " + text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .turnUsage:
            // 【批2 2B 件4】侧聊为紧凑只读面——轮次用量 pill 不呈现
            //（主对话区 ChatView 专属；投影枚举新增 case 的编译完备项）。
            EmptyView()
        }
    }

    /// 侧聊工具卡（紧凑态；只读工具面）。
    private func sideToolCard(_ card: ConversationProjector.ToolCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(card.isRunning ? Color.accentColor
                                     : (card.isError ? Color.red : Color.secondary))
                Text(card.title)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                Spacer()
                if card.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: card.isError
                            ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(card.isError ? Color.red : Color.green)
                }
            }
            if let result = card.resultText, !result.isEmpty {
                Text(result)
                    .font(.caption2.monospaced())
                    .foregroundStyle(card.isError ? Color.red : Color.secondary)
                    .lineLimit(6)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(6)
    }

    // MARK: - 独立 composer（从简形态）

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("问点什么…（只读探索）", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { viewModel.send() }
            let stops = viewModel.phase == .streaming
                && viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                if stops {
                    viewModel.cancel()
                } else {
                    autoFollow = true
                    viewModel.send()
                }
            } label: {
                Image(systemName: stops ? "stop.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(stops ? false : !viewModel.canSend
                      || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(stops ? "停止" : "发送")
        }
        .padding(8)
    }
}
