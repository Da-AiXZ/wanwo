//
//  ShellTestView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §十一 M0.4 ——
//  "最小执行链：Shell 测试页 → fork 执行 → 流式显示"，
//  验收口径（v2.2 ⑦）：**手动输入 `ls` 看到目录列表**。
//  薄层职责：boot 编排（RootfsInstaller → ISHKernel.boot → FsContextRouter
//  装钩子）+ 手动命令输入框 + 经 IshExecutorBridge 的流式输出显示
//  （OutputSanitizer 最小版 + 0.2s 节流 flush）。UI 形态全新，不复用
//  OpenMinis Views/（附录 A.8）。
//

import SwiftUI

@MainActor
final class ShellTestViewModel: ObservableObject {
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

    /// M0 测试会话 ID：fs_context 令牌的分配键（四桶路由生效所需）。
    static let sessionId = "m0-shell-test"

    private var pendingLines: [String] = []
    private var flushTimer: Timer?

    func bootIfNeeded() async {
        guard phase == .idle || phase == .installing else { return }

        // 1. rootfs 安装（自带 .arch 标签 / move-aside / zip 解析器）
        phase = .installing
        do {
            try RootfsInstaller.shared.installIfNeeded()
        } catch {
            phase = .failed("rootfs 安装失败：\((error as NSError).localizedDescription)")
            return
        }

        // 2. 内核启动（bootWithRootPath 重量级，后台线程；轮询 isBooted 兜底）
        phase = .booting
        let rootPath = RootfsInstaller.shared.rootfsPath.path
        let bootResult: Int32 = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let rc = ISHKernel.shared.boot(withRootPath: rootPath)
            guard rc == 0 else { return rc }
            for _ in 0..<300 {
                if ISHKernel.shared.isBooted { return 0 }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return -99
        }.value

        guard bootResult == 0 else {
            phase = .failed("boot 失败 rc=\(bootResult)")
            return
        }

        // 3. fs_context 路径翻译钩子（boot 后、任何命令前，一次性）
        FsContextRouter.shared.installHook()

        phase = .ready
        appendSanitized("=== 万我 M0.4 · 内核已启动，输入命令（如 ls）===\n")
    }

    /// 执行一条手动输入的命令：每命令一 fork + stdin 注入，流式回显。
    func runCommand() async {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard phase == .ready else { return }
        guard !isRunningCommand else { return }

        draftCommand = ""
        isRunningCommand = true
        appendSanitized("\n$ \(command)\n")

        let sid = Self.sessionId
        let ringIndex = await ShellCommandRingBuffer.shared.didStart(command: command, sessionId: sid)
        do {
            let result = try await IshExecutorBridge.shared.execute(
                sessionId: sid,
                command: command,
                timeout: nil,
                lineCallback: { [weak self] line in
                    // ISHShellExecutor 行回调在 main queue 上；进节流缓冲。
                    self?.appendSanitized(line + "\n")
                },
                pidCallback: { _ in }
            )
            await ShellCommandRingBuffer.shared.didExit(index: ringIndex, exitCode: result.exitCode)
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

    /// 停止当前命令（kill 整进程组，TERM→KILL 升级在 ObjC 原件内）。
    func stopCurrentCommand() {
        let sid = Self.sessionId
        Task { await IshExecutorBridge.shared.stopCurrentCommand(sessionId: sid) }
    }

    func clearOutput() {
        outputText = ""
        pendingLines.removeAll()
    }

    // MARK: - 流式显示（OutputSanitizer 最小版 + 0.2s 节流 flush）

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

/// M0.4 Shell 测试页：手动命令输入框 + 流式输出显示。
struct ShellTestView: View {
    @StateObject private var viewModel = ShellTestViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("万我 · Shell 测试")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await viewModel.bootIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            bootStatus

            ScrollView {
                ScrollViewReader { proxy in
                    Text(viewModel.outputText.isEmpty ? "（等待输出…）" : viewModel.outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(viewModel.outputText.isEmpty ? Color.secondary : Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("output-bottom")
                        .onChange(of: viewModel.outputText) { _ in
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo("output-bottom", anchor: .bottom)
                            }
                        }
                }
            }
            .background(Color.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                TextField("输入命令，如 ls", text: $viewModel.draftCommand)
                    .font(.system(size: 14, design: .monospaced))
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
        }
        .padding(16)
    }

    @ViewBuilder
    private var bootStatus: some View {
        switch viewModel.phase {
        case .idle, .installing:
            Label("正在装配 Alpine rootfs…", systemImage: "externaldrive.badge.timemachine")
                .font(.footnote).foregroundStyle(Color.secondary)
        case .booting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
            }
        case .ready:
            Label("Linux 已启动（aarch64）", systemImage: "checkmark.seal.fill")
                .font(.footnote).foregroundStyle(Color.green)
        case .failed(let msg):
            Label("失败：\(msg)", systemImage: "xmark.octagon.fill")
                .font(.footnote).foregroundStyle(Color.red)
        }
    }
}
