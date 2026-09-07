//
//  ChatView.swift
//  WanWo
//
//  【按设计新写 · M2 扩展】出处：10-design §7.1/§7.2（聊天流视图：消息卡片流 +
//  底部输入区 + 顶部状态条）、§7.3 交互流 1（工具卡展开流式输出（shell 卡 0.2s
//  节流）→ 完成态卡片收敛）、§7.6（token 压力状态条三档着色，F041 素净版）、
//  §7.4（视觉素净占位——正式卡片族 M9 对照 dsh Web UI）。
//

import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel

    init(environment: AppEnvironment, sessionID: String) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
            Divider()
            inputBar
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.open() }
        // 会话切换/离场即释放写柄 + 取消在途回合（dsh SessionLifecycle open/dispose 配对）。
        .onDisappear { viewModel.close() }
    }

    // MARK: - 顶部状态条（模型 + token 压力三档 + 阶段）

    private var pressureColor: Color {
        guard let pressure = viewModel.pressure else { return .clear }
        if pressure.ratio >= 1 { return .red }
        if pressure.ratio >= 0.8 { return .orange }
        return .green
    }

    private var statusBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(viewModel.modelLabel.isEmpty ? "未选择模型" : viewModel.modelLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if let pressure = viewModel.pressure {
                    Text("上下文 \(pressure.usedTokens)/\(pressure.thresholdTokens)")
                        .font(.caption2)
                        .foregroundStyle(pressureColor)
                }
                switch viewModel.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .streaming:
                    Button("停止") { viewModel.cancel() }
                        .controlSize(.small)
                case .failed, .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            // 压力细条（三档着色）。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    if let pressure = viewModel.pressure, pressure.thresholdTokens > 0 {
                        Capsule().fill(pressureColor)
                            .frame(width: geo.size.width
                                   * min(1, CGFloat(pressure.usedTokens)
                                       / CGFloat(pressure.thresholdTokens)))
                    }
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - 消息流

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let banner = viewModel.resumeBanner {
                        Text(banner)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(6)
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(6)
                    }
                    ForEach(viewModel.bubbles) { bubble in
                        bubbleView(bubble).id(bubble.id)
                    }
                    if !viewModel.streamingReasoning.isEmpty {
                        Text(viewModel.streamingReasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .id("streaming-reasoning")
                    }
                    if !viewModel.streamingText.isEmpty {
                        Text(viewModel.streamingText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .id("streaming-text")
                    }
                    if case .failed(let message) = viewModel.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.bubbles) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _ in scrollToBottom(proxy) }
        }
    }

    @ViewBuilder
    private func bubbleView(_ bubble: ChatViewModel.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(8)
            }
        case .assistant(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        case .reasoning(let text):
            Text("思考：" + text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
        case .tool(let card):
            toolCardView(card)
        case .command(_, let text):
            Text("⌘ " + text)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - 工具卡（§7.3：参数摘要 → 流式输出 → 完成收敛）

    private func toolCardView(_ card: ChatViewModel.ToolCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: card.name))
                    .font(.caption)
                    .foregroundStyle(card.isRunning ? Color.accentColor
                                                    : (card.isError ? Color.red : Color.secondary))
                Text(card.title)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
                Spacer()
                if card.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: card.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(card.isError ? Color.red : Color.green)
                }
            }
            if let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !card.liveOutput.isEmpty {
                Text(card.liveOutput)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
                    .padding(6)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)
            }
            if let result = card.resultText, !result.isEmpty {
                Text(result)
                    .font(.caption2.monospaced())
                    .foregroundStyle(card.isError ? Color.red : Color.secondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }

    private func iconName(for tool: String) -> String {
        switch tool {
        case "bash": return "terminal"
        case "read", "read_image", "write", "edit", "str_replace_editor":
            return "doc.text"
        case "glob", "grep": return "magnifyingglass"
        case "web_search", "web_fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("streaming-text", anchor: .bottom)
        }
    }

    // MARK: - 输入区

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息，/ 为命令…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { viewModel.send() }
            Button(action: { viewModel.send() }) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(viewModel.phase != .idle
                      || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }
}

extension ChatViewModel {
    /// 状态条「停止」按钮的显示条件（流式进行中）。
    var isBusy: Bool { phase == .streaming }
}
