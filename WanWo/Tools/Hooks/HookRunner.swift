//
//  HookRunner.swift
//  WanWo
//
//  【语义移植 · dsh packages/hooks/hook-protocol/src/runner.ts + 平台映射】
//  出处（主理人亲读锚点，M4-E 批 E2）：
//    - runner.ts:20 DEFAULT_HOOK_TIMEOUT_MS=600_000（未配 timeout 的默认）
//    - runner.ts:74 CommandHook.timeoutSec（秒）×1000 覆盖默认（JS falsy 0 → 默认）
//    - runner.ts:77-84 request{command,timeoutMs,stdin,signal,cwd,env} 六要素
//    - runner.ts:87-95 bash.run → exitCode ?? undefined（signal 死亡 null→undefined，
//      非阻断错误）+ durationMs（now() 差值，供 hook/result 事件；dsh now=
//      performance.now() 毫秒——WanWo 默认时钟为秒，差值 ×1000 换算毫秒）
//    - runner.ts:96-105 executor 基础设施故障 → 无 exit code 的 outcome（message
//      进 stderr 位），从不抛进 loop（R5 fail open）
//    - runner.ts:75 stdin = JSON.stringify(payload) + (trailingNewline ? '\n' : '')
//      ——方言轴：CC 桥 true、Codex 桥 false（两桥 index.ts 实证）
//
//  平台映射（简报 §八.1 预判的落地，取证证据见 E2 呈报①）：
//    · stdin 承载：iSH 通道 stdin 被脚本注入占用（IshExecutorBridge.swift:326
//      scriptContent 经 stdin + exec 0</dev/null 包装）→ payload 写 guest 临时
//      文件（/var/wanwo/workspace/.wanwo-hooks/payload-<uuid>.json，宿主写入经
//      FsContextRouter 翻译——与 M4-D「宿主直写→guest 可见」同链路）+ 命令行
//      `< file` 重定向（命令级重定向覆盖 exec 0</dev/null 的 fd0）。语义等价：
//      hook 的 stdin 收到 JSON±尾换行。
//    · 分支 A（已取证成立）：C 桥层双管道分离捕获（ISHShellExecutor.m:57-58/
//      :563；h:26-43 output/errorOutput 分离字段），HookRunner 走
//      IshExecutorBridge.executeSeparated 分离通道——dsh runner 语义 1:1。
//    · exitCode 映射：桥的 spawn 失败/超时=exitCode -1（负值）→ dsh undefined
//      （runner.ts:88-91 signal 死亡=null→undefined）——HookRunner 统一映射负值
//      为 nil，行为面均非阻断。
//    · 取消：dsh signal → Swift Task cancellation（withTaskCancellationHandler
//      → executor.cancel(pid:) 杀进程组——[T-shell-stop-blocked-by-actor] 纪律：
//      停止路径不经 actor）。
//

import Foundation

/// hook 执行请求（dsh runner.ts:77-84 request 六要素的平台映射形态）。
struct HookExecutionRequest: Sendable {
    /// 最终命令行（hook 命令 + `< payload 临时文件` 重定向，由 HookRunner 组装）。
    let command: String
    /// 毫秒超时（timeoutSec×1000 或默认 600_000）。
    let timeoutMs: Int
    /// guest 工作目录（会话工作区 /var/wanwo/workspace——dsh session.header.cwd）。
    let cwd: String
    /// 额外环境变量（CLAUDE_PROJECT_DIR 等——与 WanWoEnvStore 用户 env 同通道合并）。
    let env: [String: String]
    /// 进程 PID 观测（取消杀进程组用——[T-shell-stop-blocked-by-actor] 纪律）。
    let pid: @Sendable (Int32) -> Void
}

/// hook 命令的分离执行结果（stdout/stderr 不合并不装饰）。
struct HookShellOutcome: Sendable {
    /// 进程退出码；负值（spawn 失败/超时——桥内哨兵）由 HookRunner 映射为 nil
    /// （= dsh undefined，非阻断错误）。
    let exitCode: Int32?
    let stdout: String
    let stderr: String
}

/// 执行器抽象（生产=IshHookCommandExecutor 包装宿主桥；测试=桩注入）。
protocol HookCommandExecuting: Sendable {
    /// 把 payload 写入 guest 可读的临时文件；返回 guest 路径，nil = staging 失败
    /// （基础设施故障 → 无 exit code outcome）。
    func stagePayload(_ data: Data) -> String?
    /// 清理 payload 临时文件（失败容忍不抛——残留下次覆盖，uuid 命名不撞）。
    func cleanupPayload(_ guestPath: String)
    /// 取消运行中的命令（杀整进程组；pid<=0 忽略——尚未 spawn）。
    func cancel(pid: Int32)
    /// 执行（超时/取消/双流分离由实现承载）。
    func run(_ request: HookExecutionRequest) async throws -> HookShellOutcome
}

/// dsh runner.ts 的 Swift 端口（纯编排层：超时换算/payload staging/取消映射/
/// E1 codec 消费；执行细节全在 executor 注入面）。
enum HookRunner {
    /// runner.ts:20——hook 未配 timeout 时的默认（600s）。
    static let defaultHookTimeoutMs = 600_000

    /// runner.ts:62-74 + :87-105 的等价端口。
    /// - Parameters:
    ///   - executor: 执行器（注入抽象——测试桩/生产宿主桥）。
    ///   - hook: 待执行的一条 command hook（E1 types 端口）。
    ///   - payload: JSON payload 原文（E4/E5 组装——本层不构造方言 payload）。
    ///   - trailingNewline: stdin 尾换行方言轴（CC true / Codex false）。
    ///   - defaultTimeoutMs: hook 未配 timeoutSec 时的默认。
    ///   - env: 注入 hook 进程的额外变量（CLAUDE_PROJECT_DIR 等）。
    ///   - cwd: guest 工作目录（会话工作区）。
    ///   - expectedEventName: E1 codec 的 hookSpecificOutput 守卫（触发事件）。
    ///   - now: 时钟注入（durationMs 单调可测）。
    /// - Returns: 解码 outcome + durationMs（供 hook/result 事件——E3）。
    ///   全函数（total）：基础设施故障/取消一律折为无 exit code 的非阻断
    ///   outcome，从不抛进 loop（R5——dsh "never throw into the loop"）。
    static func run(
        executor: HookCommandExecuting,
        hook: CommandHook,
        payload: String,
        trailingNewline: Bool,
        defaultTimeoutMs: Int = HookRunner.defaultHookTimeoutMs,
        env: [String: String] = [:],
        cwd: String,
        expectedEventName: String? = nil,
        now: @escaping () -> Double = { CFAbsoluteTimeGetCurrent() }
    ) async -> (output: HookOutput, durationMs: Int) {
        let startedAt = now()
        // runner.ts:74——timeoutSec（秒）×1000 覆盖默认；JS falsy 0 → 默认。
        let timeoutMs: Int
        if let sec = hook.timeoutSec, sec > 0 {
            timeoutMs = sec * 1000
        } else {
            timeoutMs = defaultTimeoutMs
        }

        // runner.ts:75——stdin = payload + 尾换行（方言轴）。
        var payloadData = Data(payload.utf8)
        if trailingNewline { payloadData.append(0x0A) }

        // 平台映射：payload 落 guest 临时文件 + 命令行重定向（stdin 通道被
        // 脚本注入占用——取证见文件头注）。
        guard let payloadPath = executor.stagePayload(payloadData) else {
            return (nonBlockingOutcome(
                stderr: "hook payload staging failed",
                expectedEventName: expectedEventName),
                Int((now() - startedAt) * 1000))
        }
        defer { executor.cleanupPayload(payloadPath) }

        let pidBox = PidBox()
        let request = HookExecutionRequest(
            command: "\(hook.command) < \(payloadPath)",
            timeoutMs: timeoutMs,
            cwd: cwd,
            env: env,
            pid: { pidBox.set($0) })

        let outcome: HookShellOutcome
        do {
            // dsh signal → Swift Task cancellation：取消时杀进程组（桥内
            // completion/timeout 安全网恰一次 resume——[T-ish-*] 修复复用）。
            outcome = try await withTaskCancellationHandler(operation: {
                try await executor.run(request)
            }, onCancel: {
                executor.cancel(pid: pidBox.get())
            })
        } catch is CancellationError {
            return (nonBlockingOutcome(stderr: "hook run cancelled",
                                       expectedEventName: expectedEventName),
                    Int((now() - startedAt) * 1000))
        } catch {
            // runner.ts:96-105：基础设施故障 → 无 exit code outcome（message
            // 进 stderr 位），从不抛。
            return (nonBlockingOutcome(
                stderr: "hook execution failed: \(error)",
                expectedEventName: expectedEventName),
                Int((now() - startedAt) * 1000))
        }

        // runner.ts:88-91——负值 exitCode（spawn 失败/超时哨兵）→ nil（dsh
        // undefined），非阻断；正常码原样交 E1 codec（exit 2 阻断/exit 0 结构化）。
        // （flatMap + 显式闭包签名——map 内三元 nil 分支无法从上下文推断，
        // CI 第一轮 34751424937 实证。）
        let exitCode: Int? = outcome.exitCode.flatMap { (code: Int32) -> Int? in
            code < 0 ? nil : Int(code)
        }
        let output = HookCodec.parseHookOutput(
            exitCode: exitCode,
            stdout: outcome.stdout,
            stderr: outcome.stderr,
            expectedEventName: expectedEventName)
        return (output, Int((now() - startedAt) * 1000))
    }

    /// runner.ts:96-105——无 exit code 的非阻断 outcome（message 进 stderr 位）。
    private static func nonBlockingOutcome(stderr: String,
                                           expectedEventName: String?) -> HookOutput {
        HookCodec.parseHookOutput(exitCode: nil, stdout: "", stderr: stderr,
                                  expectedEventName: expectedEventName)
    }
}

/// pid 观测盒（onCancel 回调与 run 并发——锁保护）。
private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0

    func set(_ pid: Int32) {
        lock.lock(); value = pid; lock.unlock()
    }

    func get() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - 生产执行器（宿主桥包装；E5 装配消费）

/// 真实执行器：payload 落会话 workspace 桶 .wanwo-hooks/（宿主写入经
/// FsContextRouter 翻译——guest 视角 /var/wanwo/workspace/.wanwo-hooks/），
/// 执行走 IshExecutorBridge.executeSeparated 分离通道。
/// 注意：.wanwo-hooks 不在 .agents/skills 下，payload 落盘不经
/// WorkspaceFileAccess.writeAt（不触发 onMutation）——技能失效判定双保险不误伤。
final class IshHookCommandExecutor: HookCommandExecuting, @unchecked Sendable {
    private static let logger = AppLogger(category: "hook-runner")
    /// payload 目录（guest 视角；workspace 桶内隐藏目录）。
    private static let payloadDirGuest = WanWoPaths.workspaceLinuxDir + "/.wanwo-hooks"

    let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func stagePayload(_ data: Data) -> String? {
        let guestPath = "\(Self.payloadDirGuest)/payload-\(UUID().uuidString).json"
        guard let hostURL = FsContextRouter.shared.hostURL(forGuest: guestPath,
                                                           sid: sessionId) else {
            Self.logger.error("hook payload staging failed: no host translation for \(guestPath)")
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: hostURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: hostURL, options: .atomic)
            return guestPath
        } catch {
            Self.logger.error("hook payload staging failed: \(String(describing: error))")
            return nil
        }
    }

    func cleanupPayload(_ guestPath: String) {
        guard let hostURL = FsContextRouter.shared.hostURL(forGuest: guestPath,
                                                           sid: sessionId) else { return }
        // 失败容忍：残留文件由 uuid 命名保证不撞，下次启动 workspace 迁移/
        // 会话删除时随桶清理。
        try? FileManager.default.removeItem(at: hostURL)
    }

    func cancel(pid: Int32) {
        guard pid > 0 else { return }
        Self.logger.info("hook command cancelled — killing process group pid=\(pid)")
        ISHShellExecutor.killProcessGroup(pid)
    }

    func run(_ request: HookExecutionRequest) async throws -> HookShellOutcome {
        let result = try await IshExecutorBridge.shared.executeSeparated(
            sessionId: sessionId,
            command: request.command,
            timeout: Double(request.timeoutMs) / 1000.0,
            workingDirectory: request.cwd,
            extraEnvironment: request.env,
            pidCallback: request.pid)
        return HookShellOutcome(exitCode: result.exitCode,
                                stdout: result.stdout,
                                stderr: result.stderr)
    }
}
