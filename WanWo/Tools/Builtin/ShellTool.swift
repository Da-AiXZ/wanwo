//
//  ShellTool.swift
//  WanWo
//
//  【语义移植 · dsh + OpenMinis】出处：
//    - dsh：bash 工具（wire 名 1:1）+ 10-design §六②（shell 工具调用 → iSH fork
//      执行与流式回传全时序）、§十一 M2.4（F026）
//    - OpenMinis AIChatViewModel+ISHCommand.swift：executeCommand 的 bashism 流程、
//      runViaBash base64 自解压（哨兵 119 双形态）+ 消失自愈重装（M5）、
//      runRaw 的 ShellCommandRingBuffer didStart/didExit/didAbort 全路径配平
//    - 10-design §5.4：CrashBreadcrumb（每命令前后 O_SYNC 磁盘面包屑，M2 最小版）
//  环境纪律（08 §三）：
//    · guest 默认 busybox ash；BashismDetector 命中才按需装 bash（安装独立预算）
//    · 每命令独立 fork 无共享 PTY；stdin 注入与进程组杀均由 IshExecutorBridge 承担
//    · 输出卫生完整版（OutputSanitizer.sanitize）→ ToolOutput；永不抛穿 loop
//

import Foundation

// MARK: - CrashBreadcrumb（M2 最小版）

/// 每命令前后写一条 O_SYNC 磁盘面包屑（§5.4：进程被 jetsam 杀后可定位死时状态）。
enum CrashBreadcrumb {
    private static let lock = NSLock()

    private static var fileURL: URL {
        let base = WanWoPaths.persistentBase.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("crash-breadcrumbs.log")
    }

    static func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.synchronize()  // O_SYNC 近似：每条强制落盘
    }
}

// MARK: - ShellTool（wire 名：bash）

/// shell 执行工具（F026）。默认 900s 超时（§六②）；安装 bash 的预算独立（OnDemandBash）。
struct ShellTool: AgentTool {
    let name = "bash"
    let description = "Run a shell command inside the session's Alpine (busybox ash) environment. "
        + "Standard POSIX sh syntax; bash-only syntax is detected and bash is installed on demand. "
        + "Working directory is the session workspace (/var/wanwo/workspace). Output is sanitized and truncated."

    let parameters = JSONValue.schemaObject(
        properties: [
            "command": .stringSchema(description: "The shell command to execute."),
            "timeout_ms": .numberSchema(description: "Optional timeout in milliseconds. Defaults to 900000 (15 minutes). The tool-level cooperative cap is 960000 (16 minutes)."),
        ],
        required: ["command"])

    /// 外层协作超时（ToolTimeout）：略高于桥内 900s 默认，兜底防挂死。
    let timeoutMs: Int? = 960_000

    let sessionId: String

    private static let defaultTimeoutSeconds: TimeInterval = 900
    private static let logger = AppLogger(category: "ShellTool")

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .terminal,
                       title: "bash",
                       detail: args.objectValue?["command"]?.stringValue ?? "")
    }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = args.objectValue?["command"]?.stringValue, !command.isEmpty else {
            return .failure("missing required parameter \"command\"", code: "INVALID_ARGS")
        }
        // P1-3：沙箱门（resolvePolicy → 提权审批；read-only 档启发式写检测
        // 拒绝——dsh 内核围栏的 WanWo 近似，A2 不可抗力）。
        if let denial = await SandboxGate.authorizeBash(
            tool: name, command: command, args: args,
            standingMode: ctx.sandboxMode, callId: ctx.callId,
            approver: ctx.escalationApprover) {
            return denial
        }
        let timeoutSeconds = args.objectValue?["timeout_ms"]?.intValue
            .map { max(1, Double($0) / 1000) } ?? Self.defaultTimeoutSeconds

        CrashBreadcrumb.log("shell start [\(ctx.callId)]: \(command.prefix(300))")
        defer { CrashBreadcrumb.log("shell end [\(ctx.callId)]") }

        // ── bashism 流程（OpenMinis executeCommand 1:1）─────────────────
        let bashism = BashismDetector.detect(command)
        var bashReminder: String? = nil
        if bashism.needsBash {
            let outcome = await OnDemandBash.shared.ensureBash(executor: Self.executor(sessionId: sessionId))
            switch outcome {
            case .available:
                if bashism.mustSwitchInterpreter {
                    // §3.2 M3：guest 内自写脚本跑 bash（base64 单行、无宿主→fakefs 写、自清理）。
                    let result = try await runViaBash(command, timeout: timeoutSeconds, ctx: ctx)
                    return Self.finish(result, command: command)
                }
                // 仅 T1（脚本自己会调 bash）——照常在 sh 下跑。
            case .unavailable(let reason):
                // 退回 sh；非零退出或静默错误（S）类命中时附 reminder（§4.2）。
                bashReminder = BashismReminder.build(hits: bashism.hits, installFailure: reason)
            }
        }
        let result = try await runWithReminder(command, timeout: timeoutSeconds,
                                               reminder: bashReminder,
                                               silentClass: bashism.hasSilent, ctx: ctx)
        return Self.finish(result, command: command)
    }

    // MARK: - 结果组装

    private static func finish(_ result: CommandResult, command: String) -> ToolOutput {
        var text = result.output
        if result.exitCode != 0 {
            text += "\n\n[exit code: \(result.exitCode)]"
        }
        var output = ToolOutput.success(text)
        output.meta = .object([
            "exitCode": .int(result.exitCode),
            "tool": .string("bash"),
        ])
        return output
    }

    // MARK: - OnDemandBash 执行器适配（桥接 IshExecutorBridge）

    static func executor(sessionId sid: String) -> OnDemandBash.Executor {
        OnDemandBash.Executor(run: { command, timeout in
            let r = try? await IshExecutorBridge.shared.execute(
                sessionId: sid, command: command, timeout: timeout,
                lineCallback: { _ in }, pidCallback: { _ in })
            return r?.exitCode ?? -1
        })
    }

    // MARK: - 命令执行

    struct CommandResult {
        let output: String
        let exitCode: Int
    }

    /// 哨兵退出码：bash 包装器发现 bash 缺失时返回（区分"bash 没了"与脚本真退出 127）。
    private static let bashMissingSentinel = 119

    /// base64 自解压跑 bash（OpenMinis runViaBash 1:1）：无宿主→fakefs 写、无 heredoc、
    /// 同一命令行自清理；包装器先 `command -v bash` 守卫，缓存失效（用户 apk del）
    /// 被精确检出（M5）并自愈重装一次。
    private func runViaBash(_ script: String, timeout: TimeInterval,
                            ctx: ToolExecutionContext,
                            allowReinstall: Bool = true) async throws -> CommandResult {
        // heredoc 尾换行规则：文件结尾无换行的 heredoc 会报
        // "unexpected end of file"——补一个。
        let normalized = script.hasSuffix("\n") ? script : script + "\n"
        let b64 = Data(normalized.utf8).base64EncodedString()
        let f = "/tmp/.wanwo-exec-$$.sh"
        let wrapped = "command -v bash >/dev/null 2>&1 || exit \(Self.bashMissingSentinel); "
            + "printf %s '\(b64)' | base64 -d > \(f) && bash \(f); rc=$?; rm -f \(f); exit $rc"
        let result = try await runRaw(wrapped, timeout: timeout, ctx: ctx)

        // M5 自愈：bash 在缓存 available 后消失。重探测并只重装重跑一次，
        // 让本命令当场成功而不是把失败留给下一条。
        // 桥可能返回裸退出码（119）或 wait(2) 编码状态（119 << 8 = 30464），两者都接受。
        if result.exitCode == Self.bashMissingSentinel
            || result.exitCode == (Self.bashMissingSentinel << 8) {
            await OnDemandBash.shared.markDisappeared()
            if allowReinstall {
                let outcome = await OnDemandBash.shared.ensureBash(
                    executor: Self.executor(sessionId: sessionId))
                if case .available = outcome {
                    return try await runViaBash(script, timeout: timeout, ctx: ctx,
                                                allowReinstall: false)
                }
            }
            // 重装不可用 → 降级 sh 让脚本至少跑起来。
            return try await runRaw(script, timeout: timeout, ctx: ctx)
        }
        return result
    }

    /// 跑命令并按 §4.2 触发规则附 bashism reminder（非零退出，或任意静默类命中）。
    private func runWithReminder(_ command: String, timeout: TimeInterval,
                                 reminder: String?, silentClass: Bool,
                                 ctx: ToolExecutionContext) async throws -> CommandResult {
        let result = try await runRaw(command, timeout: timeout, ctx: ctx)
        guard let reminder else { return result }
        let shouldAppend = result.exitCode != 0 || silentClass
        guard shouldAppend else { return result }
        return CommandResult(output: result.output + "\n\n" + reminder, exitCode: result.exitCode)
    }

    /// 桥调用 + 环形缓冲配平 + 输出卫生（OpenMinis runRaw 语义 1:1）。
    private func runRaw(_ command: String, timeout: TimeInterval,
                        ctx: ToolExecutionContext) async throws -> CommandResult {
        let sid = sessionId
        let ring = ShellCommandRingBuffer.shared
        let cmdIdx = await ring.didStart(command: command, sessionId: sid)

        // [T-ios-shellring-counter-leak] 每条退出路径都配平 didStart：do-catch 而非
        // defer { Task { … } }——取消期 defer 派生的 detached Task 可能永不调度。
        // exitCode 保持 nil，面包屑记 abort 而非伪造退出状态。
        let result: ISHCommandResult
        do {
            result = try await IshExecutorBridge.shared.execute(
                sessionId: sid,
                command: command,
                timeout: timeout,
                // 流式行：先卫生处理再驱动工具卡（onShellLine 缝；UI 侧 0.2s 节流）。
                lineCallback: { [onShellLine = ctx.onShellLine, callId = ctx.callId] line in
                    let clean = OutputSanitizer.sanitizeTerminalOutput(line)
                    guard !clean.isEmpty else { return }
                    onShellLine(callId, clean)
                },
                pidCallback: { _ in })
        } catch {
            await ring.didAbort(index: cmdIdx)
            throw error
        }
        await ring.didExit(index: cmdIdx, exitCode: result.exitCode)

        // 输出卫生完整版：CR 折叠 → ANSI 剥离 → 15000 头尾截断（§5.4）。
        let output = OutputSanitizer.sanitize(result.output)
        return CommandResult(output: output, exitCode: result.exitCode)
    }
}
