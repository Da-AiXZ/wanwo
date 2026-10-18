//
//  WorkspaceTerminalTabView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.4（codex 截图「终端」）】
//  iSH 终端白底嵌入（dsh Web UI 白底一致）：把 M0 ShellTestView 的可用终端
//  面（boot 编排 + 手动命令 + 流式回显）组件化为会话作用域页签视图——
//  sessionId = 当前会话（fs_context 路由到该会话工作区桶）；未选会话回落
//  M0 诊断 sid（与 ShellTestView 同款行为）。
//  诊断区旧 ShellTestView 入口随本批降级为 DEBUG-only（SessionsSidebarView；
//  ia-audit §3.1 计划）。
//

import SwiftUI

/// 会话作用域终端模型（ShellTestViewModel 同构；sid 可变——右栏页签挂当前会话）。
@MainActor
final class WorkspaceTerminalViewModel: ObservableObject {
    enum BootPhase: Equatable {
        case idle
        case installing
        case booting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: BootPhase = .idle
    @Published private(set) var outputText: String = ""
    @Published private(set) var isRunningCommand: Bool = false
    @Published var draftCommand: String = ""

    /// 未选会话时的回落 sid（M0 诊断会话——ShellTestViewModel.sessionId 同值）。
    static let fallbackSessionId = "m0-shell-test"

    private var sessionID: String
    private var pendingLines: [String] = []
    private var flushTimer: Timer?

    init(sessionID: String?) {
        self.sessionID = sessionID ?? Self.fallbackSessionId
    }

    /// 会话切换：仅影响后续命令的 fs 路由（输出缓冲保留）。
    func updateSession(_ sessionID: String?) {
        self.sessionID = sessionID ?? Self.fallbackSessionId
    }

    private var sid: String { sessionID }

    func bootIfNeeded() async {
        guard phase == .idle || phase == .installing else { return }
        phase = .installing
        do {
            // ERR-022 共享 boot 编排（与 ShellTestView / 聊天链路同层）。
            try await KernelBootCoordinator.ensureKernelBooted { [weak self] bootPhase in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch bootPhase {
                    case .installing: self.phase = .installing
                    case .booting: self.phase = .booting
                    }
                }
            }
        } catch {
            phase = .failed((error as NSError).localizedDescription)
            return
        }
        phase = .ready
        appendSanitized("=== 万我终端 · 内核已启动，输入命令（如 ls）===\n")
    }

    /// 执行一条手动命令（每命令一 fork + stdin 注入，流式回显；
    /// OutputSanitizer + 0.2s 节流 flush 与 ShellTestView 同钟）。
    func runCommand() async {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard phase == .ready else { return }
        guard !isRunningCommand else { return }

        draftCommand = ""
        isRunningCommand = true
        appendSanitized("\n$ \(command)\n")

        let sid = self.sid
        let ringIndex = await ShellCommandRingBuffer.shared.didStart(command: command,
                                                                     sessionId: sid)
        do {
            let result = try await IshExecutorBridge.shared.execute(
                sessionId: sid,
                command: command,
                timeout: nil,
                lineCallback: { [weak self] line in
                    self?.appendSanitized(line + "\n")
                },
                pidCallback: { _ in }
            )
            await ShellCommandRingBuffer.shared.didExit(index: ringIndex,
                                                        exitCode: result.exitCode)
            appendSanitized("（exit code: \(result.exitCode)）\n")
        } catch is CancellationError {
            await ShellCommandRingBuffer.shared.didAbort(index: ringIndex)
            appendSanitized("（已取消）\n")
        } catch {
            await ShellCommandRingBuffer.shared.didAbort(index: ringIndex)
            appendSanitized("（错误：\(error.localizedDescription)）\n")
        }
        isRunningCommand = false
    }

    /// 停止当前命令（kill 整进程组）。
    func stopCurrentCommand() {
        let sid = self.sid
        Task { await IshExecutorBridge.shared.stopCurrentCommand(sessionId: sid) }
    }

    func clearOutput() {
        outputText = ""
        pendingLines.removeAll()
    }

    // MARK: - 流式显示（OutputSanitizer + 0.2s 节流 flush；M0 同款）

    private func appendSanitized(_ line: String) {
        pendingLines.append(OutputSanitizer.sanitize(line))
        flushIfIdle()
    }

    private func flushIfIdle() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushTimer = nil
                guard !self.pendingLines.isEmpty else { return }
                let chunk = self.pendingLines.joined()
                self.pendingLines.removeAll()
                self.outputText += chunk
                if self.outputText.count > 64_000 {
                    self.outputText = String(self.outputText.suffix(32_000))
                }
            }
        }
    }
}

/// 白底终端页签（dsh Web UI 一致——黑字白底，非 M0 诊断页的黑底绿字）。
struct WorkspaceTerminalTabView: View {
    @ObservedObject var environment: AppEnvironment
    @StateObject private var viewModel: WorkspaceTerminalViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: WorkspaceTerminalViewModel(
            sessionID: WorkspaceRightSidebarView.sessionID(of: environment.selection)))
    }

    var body: some View {
        VStack(spacing: 0) {
            bootStatusRow
            Divider()
            ScrollView {
                ScrollViewReader { proxy in
                    Text(viewModel.outputText.isEmpty ? "（等待输出…）" : viewModel.outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(viewModel.outputText.isEmpty
                                         ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("terminal-output-bottom")
                        .onChange(of: viewModel.outputText) { _ in
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo("terminal-output-bottom", anchor: .bottom)
                            }
                        }
                }
            }
            .background(Color.white)
            .colorScheme(.light)   // 白底终端：暗色模式下同样白底黑字（dsh Web UI 一致）。
            Divider()
            HStack(spacing: 8) {
                TextField("输入命令，如 ls", text: $viewModel.draftCommand)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.runCommand() }
                    }
                Button {
                    Task { await viewModel.runCommand() }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(viewModel.phase != .ready || viewModel.isRunningCommand)
                .buttonStyle(.borderedProminent)
                Button {
                    viewModel.stopCurrentCommand()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!viewModel.isRunningCommand)
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(8)
        }
        .task { await viewModel.bootIfNeeded() }
        .onChange(of: environment.selection) { selection in
            viewModel.updateSession(
                WorkspaceRightSidebarView.sessionID(of: selection))
        }
    }

    @ViewBuilder
    private var bootStatusRow: some View {
        HStack(spacing: 6) {
            switch viewModel.phase {
            case .idle, .installing:
                ProgressView().controlSize(.mini)
                Text("正在装配 Alpine rootfs…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .booting:
                ProgressView().controlSize(.mini)
                Text("内核启动中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Linux 已启动（aarch64）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text("失败：\(msg)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.clearOutput()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("清空终端输出")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
