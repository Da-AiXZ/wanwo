//
//  ChatView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.1/§7.2（聊天流视图：消息卡片流 + 底部
//  输入区 + 顶部状态条；0.2s 节流流式）、§7.4（视觉素净占位——codex 视觉规范等
//  用户截图，本页仅做素净信息架构占位）。
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
        // 会话切换/离场即释放写柄（bug1 第二层：SessionStore.openWriter 自动 close
        // 之上的显式路径；dsh SessionLifecycle open/dispose 配对语义）。
        .onDisappear { viewModel.close() }
    }

    // MARK: - 顶部状态条（§7.1：token 压力/模型；M1 显示模型 + 阶段）

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.modelLabel.isEmpty ? "未选择模型" : viewModel.modelLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            switch viewModel.phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .streaming:
                if viewModel.adapterConfigured {
                    Button("停止") { viewModel.cancel() }
                        .controlSize(.small)
                }
            case .retrying(let attempt, let delayMs, _):
                Text("重试 \(attempt)（\(delayMs)ms 后）")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("停止") { viewModel.cancel() }
                    .controlSize(.small)
            case .failed, .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            .onChange(of: viewModel.bubbles.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.streamingText) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private func bubbleView(_ bubble: ChatViewModel.Bubble) -> some View {
        switch bubble.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(bubble.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(8)
            }
        case .assistant:
            Text(bubble.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        case .reasoning:
            Text("思考：" + bubble.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
        case .toolNote:
            Text(bubble.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            TextField("输入消息…", text: $viewModel.draft, axis: .vertical)
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
    var adapterConfigured: Bool { true }
}
