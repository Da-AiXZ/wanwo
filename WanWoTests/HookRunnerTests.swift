//
//  HookRunnerTests.swift
//  WanWoTests
//
//  【M4-E 批 E2 测试 · hooks 执行面】桩 executor 注入（真实 iSH 通道靠 CI/真机
//  ——dsh runner 语义 1:1 断言）：timeoutSec 覆盖默认（含 JS falsy 0 归默认）/
//  infrastructure rejection → 无 exit code outcome 从不抛 / durationMs 注入时钟
//  单调 / payload 尾换行方言轴（CC 有 \n、Codex 无）/ 慢桩超时非阻断 / 取消杀
//  pid + 非阻断 outcome / 负值 exitCode → dsh undefined 映射 / payload 临时文件
//  清理（成功与失败两路径）/ E1 codec 集成缝（exit 2 阻断）。
//

import XCTest
@testable import WanWo

/// 桩执行器：全行为记录 + runBehavior 可编程。
private final class StubHookExecutor: HookCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()

    private(set) var stagedPayloads: [Data] = []
    private(set) var cleanedPaths: [String] = []
    private(set) var requests: [HookExecutionRequest] = []
    private(set) var cancelledPids: [Int32] = []

    /// staging 失败注入面（nil = 失败）。
    var stagedPath: String? = "/var/wanwo/workspace/.wanwo-hooks/payload-stub.json"
    /// run 可编程行为。
    var runBehavior: @Sendable (HookExecutionRequest) async throws -> HookShellOutcome = { _ in
        HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
    }

    func stagePayload(_ data: Data) -> String? {
        lock.lock(); stagedPayloads.append(data); lock.unlock()
        return stagedPath
    }

    func cleanupPayload(_ guestPath: String) {
        lock.lock(); cleanedPaths.append(guestPath); lock.unlock()
    }

    func cancel(pid: Int32) {
        lock.lock(); cancelledPids.append(pid); lock.unlock()
    }

    func run(_ request: HookExecutionRequest) async throws -> HookShellOutcome {
        lock.lock(); requests.append(request); lock.unlock()
        request.pid(42) // 桩 pid——取消测试断言此值被杀
        return try await runBehavior(request)
    }

    // 读取快照（锁内拷贝）。
    func snapshotStaged() -> [Data] { lock.lock(); defer { lock.unlock() }; return stagedPayloads }
    func snapshotCleaned() -> [String] { lock.lock(); defer { lock.unlock() }; return cleanedPaths }
    func snapshotRequests() -> [HookExecutionRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func snapshotCancelled() -> [Int32] { lock.lock(); defer { lock.unlock() }; return cancelledPids }
}

final class HookRunnerTests: XCTestCase {

    private let hook = CommandHook(command: "run-hook.sh")

    private func makeClock(times: [Double]) -> () -> Double {
        var index = 0
        return {
            defer { index = min(index + 1, times.count - 1) }
            return times[index]
        }
    }

    // MARK: timeoutSec 覆盖默认（runner.ts:74，JS falsy 0 归默认）

    func testTimeoutSecOverridesDefault() async {
        let executor = StubHookExecutor()
        _ = await HookRunner.run(
            executor: executor, hook: CommandHook(command: "x", timeoutSec: 7),
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertEqual(executor.snapshotRequests().first?.timeoutMs, 7000)

        _ = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertEqual(executor.snapshotRequests().last?.timeoutMs,
                       HookRunner.defaultHookTimeoutMs)
        XCTAssertEqual(HookRunner.defaultHookTimeoutMs, 600_000) // runner.ts:20
    }

    func testTimeoutSecZeroFallsBackToDefault() async {
        // JS `hook.timeoutSec ? … : DEFAULT`——0 为 falsy 归默认（语义保真）。
        let executor = StubHookExecutor()
        _ = await HookRunner.run(
            executor: executor, hook: CommandHook(command: "x", timeoutSec: 0),
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertEqual(executor.snapshotRequests().first?.timeoutMs,
                       HookRunner.defaultHookTimeoutMs)
    }

    // MARK: infrastructure rejection → 无 exit code outcome，从不抛（runner.ts:96-105）

    func testInfrastructureRejectionYieldsNoExitCodeOutcome() async {
        let executor = StubHookExecutor()
        executor.runBehavior = { _ in
            throw NSError(domain: "stub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unusable workdir"])
        }
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertNil(output.exitCode) // 无 exit code 的 outcome
        XCTAssertNil(output.decision) // 非阻断
        // message 进 stderr 位
        XCTAssertTrue(output.stderr.contains("unusable workdir"))
    }

    func testPayloadStagingFailureYieldsNoExitCodeOutcome() async {
        let executor = StubHookExecutor()
        executor.stagedPath = nil
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertNil(output.exitCode)
        XCTAssertNil(output.decision)
        XCTAssertTrue(output.stderr.contains("payload staging failed"))
        // staging 失败 = 未执行，run 从未被调。
        XCTAssertTrue(executor.snapshotRequests().isEmpty)
    }

    // MARK: durationMs 注入时钟单调（runner.ts:88-95）

    func testDurationMsMeasuredWithInjectedClock() async {
        let executor = StubHookExecutor()
        let (_, durationMs) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace",
            now: makeClock(times: [100.0, 100.25]))
        XCTAssertEqual(durationMs, 250)
    }

    // MARK: payload 尾换行方言轴（runner.ts:75——CC true / Codex false）

    func testPayloadTrailingNewlineDialectAxis() async {
        let executor = StubHookExecutor()
        _ = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{\"k\":1}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        let ccPayload = executor.snapshotStaged().first
        XCTAssertEqual(ccPayload, Data("{\"k\":1}\n".utf8)) // CC：尾换行在场

        _ = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{\"k\":1}", trailingNewline: false, cwd: "/var/wanwo/workspace")
        let codexPayload = executor.snapshotStaged().last
        XCTAssertEqual(codexPayload, Data("{\"k\":1}".utf8)) // Codex：无尾换行
    }

    // MARK: 命令组装（payload 重定向 + cwd + env 六要素）

    func testRequestCarriesCommandCwdAndEnv() async {
        let executor = StubHookExecutor()
        _ = await HookRunner.run(
            executor: executor, hook: CommandHook(command: "/bin/hook --flag"),
            payload: "{}", trailingNewline: true,
            env: ["CLAUDE_PROJECT_DIR": "/var/wanwo/workspace"],
            cwd: "/var/wanwo/workspace")
        let request = executor.snapshotRequests().first
        XCTAssertEqual(request?.command,
                       "/bin/hook --flag < /var/wanwo/workspace/.wanwo-hooks/payload-stub.json")
        XCTAssertEqual(request?.cwd, "/var/wanwo/workspace")
        XCTAssertEqual(request?.env["CLAUDE_PROJECT_DIR"], "/var/wanwo/workspace")
        XCTAssertEqual(request?.timeoutMs, HookRunner.defaultHookTimeoutMs)
    }

    // MARK: 慢桩超时 → 非阻断 outcome

    func testSlowExecutorTimeoutYieldsNonBlockingOutcome() async {
        let executor = StubHookExecutor()
        // 桩模拟真实桥超时形态：负值 exitCode（哨兵）+ 超时消息进 stderr。
        executor.runBehavior = { request in
            try? await Task.sleep(nanoseconds: UInt64(request.timeoutMs) * 1_000_000)
            return HookShellOutcome(exitCode: -1, stdout: "",
                                    stderr: "(hook command timed out after 0s)")
        }
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true,
            defaultTimeoutMs: 20, cwd: "/var/wanwo/workspace")
        XCTAssertNil(output.exitCode) // 负值哨兵 → dsh undefined
        XCTAssertNil(output.decision) // 超时非阻断
        XCTAssertTrue(output.stderr.contains("timed out"))
    }

    // MARK: 负值 exitCode → dsh undefined 映射（runner.ts:88-91）

    func testNegativeExitCodeMapsToUndefined() async {
        let executor = StubHookExecutor()
        executor.runBehavior = { _ in
            HookShellOutcome(exitCode: -1, stdout: "", stderr: "Error: Failed to create process")
        }
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertNil(output.exitCode)
        XCTAssertNil(output.decision)
        XCTAssertTrue(output.stderr.contains("Failed to create process"))
    }

    // MARK: 取消 → 杀 pid + 非阻断 outcome（dsh signal → Task cancellation）

    func testCancellationKillsPidAndYieldsNonBlockingOutcome() async {
        let executor = StubHookExecutor()
        executor.runBehavior = { _ in
            // 挂起直到取消（桩侧 Task.sleep 捕获取消抛 CancellationError——
            // 对应真实桥：kill 进程组 → completion 恰一次 resume）。
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return HookShellOutcome(exitCode: 0, stdout: "", stderr: "")
        }
        let task = Task {
            await HookRunner.run(
                executor: executor, hook: hook,
                payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        }
        // 让 run 先进桩（pid 已登记）再取消。
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let (output, _) = await task.value
        XCTAssertTrue(executor.snapshotCancelled().contains(42), "取消必须杀进程组")
        XCTAssertNil(output.exitCode)
        XCTAssertNil(output.decision)
        XCTAssertTrue(output.stderr.contains("cancelled"))
    }

    // MARK: payload 临时文件清理（成功与失败两路径）

    func testPayloadTempFileCleanedUpOnSuccessAndFailure() async {
        let executor = StubHookExecutor()
        _ = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertEqual(executor.snapshotCleaned().count, 1) // 成功路径清理

        executor.runBehavior = { _ in throw NSError(domain: "stub", code: 2) }
        _ = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true, cwd: "/var/wanwo/workspace")
        XCTAssertEqual(executor.snapshotCleaned().count, 2) // 失败路径同样清理
    }

    // MARK: E1 codec 集成缝（exit 2 阻断 / exit 0 结构化直通）

    func testExit2BlockingIntegration() async {
        let executor = StubHookExecutor()
        executor.runBehavior = { _ in
            HookShellOutcome(exitCode: 2, stdout: "",
                             stderr: "this command is not allowed")
        }
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true,
            cwd: "/var/wanwo/workspace", expectedEventName: "PreToolUse")
        XCTAssertEqual(output.decision, HookDecision.block)
        XCTAssertEqual(output.reason, "this command is not allowed")
    }

    func testExit0StructuredIntegration() async {
        let executor = StubHookExecutor()
        executor.runBehavior = { _ in
            HookShellOutcome(exitCode: 0,
                             stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"policy\"}}",
                             stderr: "")
        }
        let (output, _) = await HookRunner.run(
            executor: executor, hook: hook,
            payload: "{}", trailingNewline: true,
            cwd: "/var/wanwo/workspace", expectedEventName: "PreToolUse")
        XCTAssertEqual(output.decision, HookDecision.deny)
        XCTAssertEqual(output.reason, "policy")
    }
}
