//
//  LocalJobRegistryTests.swift
//  WanWoTests
//
//  【M5-A 批 J2 测试 · 本地注册表 + ShellTool 后台接线】三面：
//    1. registry preflight 拒绝无残留（controller 门控/label 空/outputLimit
//       非正/并发上限——错误文案逐字对拍 jobs-local index.ts）
//    2. 生命周期语义：start→快照→first-wins settle（waiter 在场标 reported）
//       /wait 超时返回 running 快照/caller 取消仅 live 抛/kill→stopping→
//       settle killed/read 光标与终态 reported/owner 围栏/notifyChanged
//       触发点（start/kill/settle）/disposeAll 清空+关 listener
//    3. ShellTool run_in_background 接线（桩 spawner + 真 LocalJobRegistry）
//       ——dsh detached 通道真机面（iSH spawn）不在 CI，桥增量由真机验收。
//

import XCTest
@testable import WanWo

// MARK: - 测试夹具

/// 手动结算的 Promise 替身（dsh done/readOutput 生产者驱动面）。
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?

    func wait() async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            lock.lock()
            if let value = pending {
                lock.unlock()
                cont.resume(returning: value)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func fulfill(_ value: T) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
        } else {
            pending = value
            lock.unlock()
        }
    }
}

/// cancel 调用记录（线程安全）。
private final class CancelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func append(_ reason: String?) {
        lock.lock(); items.append(reason); lock.unlock()
    }
    var all: [String?] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

/// 线程安全收集器（listener 回调记录用——@Sendable 闭包不得捕获局部 var）。
private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }
    var all: [T] {
        lock.lock(); defer { lock.unlock() }; return items
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return items.count
    }
}

/// 单值线程安全槽（spawn 参数记录用）。
private final class ValueSink<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    var current: T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// 手动结算的 bash 生产者：run() 返回 hooks，测试经 box 驱动结算。
private func makeBashProducer(label: String = "sleep 100")
        -> (spec: JobStart, box: ResultBox<JobOutcome>, cancels: CancelLog) {
    let box = ResultBox<JobOutcome>()
    let cancels = CancelLog()
    let spec = JobStart(kind: .bash, label: label, run: {
        JobHooks(cancel: { cancels.append($0) }, done: { await box.wait() })
    })
    return (spec, box, cancels)
}

// MARK: - LocalJobRegistry

final class LocalJobRegistryTests: XCTestCase {

    private var registry: LocalJobRegistry!
    private var controllerDisposer: (() -> Void)!

    override func setUp() {
        super.setUp()
        registry = LocalJobRegistry()
        controllerDisposer = registry.attachController(name: "test")
    }

    override func tearDown() {
        controllerDisposer = nil
        registry = nil
        super.tearDown()
    }

    private func message(of error: Error) -> String {
        (error as? JobRegistryError)?.message ?? String(describing: error)
    }

    // MARK: preflight 拒绝（文案逐字）

    func testStartWithoutControllerRejectedVerbatim() throws {
        controllerDisposer()
        do {
            _ = try registry.start(makeBashProducer().spec)
            XCTFail("start 应被门控拒绝")
        } catch {
            XCTAssertEqual(message(of: error),
                "background jobs unavailable: no job controller serves this agent (load @deepseek-ai/dsh-tool-jobs in its composition)")
        }
        XCTAssertTrue(registry.list(callerSessionId: nil).isEmpty,
                      "preflight 拒绝不得留下任何记录")
    }

    func testControllerDisposeReenablesGate() {
        // J2 AppEnvironment 语义：disposer 摘除后 start 再次被拒。
        controllerDisposer()
        XCTAssertThrowsError(try registry.start(makeBashProducer().spec))
    }

    func testEmptyLabelRejectedVerbatim() {
        let box = ResultBox<JobOutcome>()
        let spec = JobStart(kind: .bash, label: "", run: {
            JobHooks(cancel: { _ in }, done: { await box.wait() })
        })
        XCTAssertThrowsError(try registry.start(spec)) { error in
            XCTAssertEqual(message(of: error),
                           "invalid job label: expected a non-empty string")
        }
        XCTAssertTrue(registry.list(callerSessionId: nil).isEmpty)
    }

    func testNonPositiveOutputLimitRejectedVerbatim() {
        for bad in [0, -5] {
            let box = ResultBox<JobOutcome>()
            let spec = JobStart(kind: .bash, label: "x", outputLimitBytes: bad, run: {
                JobHooks(cancel: { _ in }, done: { await box.wait() })
            })
            XCTAssertThrowsError(try registry.start(spec)) { error in
                XCTAssertEqual(message(of: error),
                    "invalid outputLimitBytes: expected a positive safe integer, got \(bad)")
            }
        }
        XCTAssertTrue(registry.list(callerSessionId: nil).isEmpty)
    }

    func testConcurrencyLimitPerOwnerBucket() async throws {
        let limited = LocalJobRegistry(maxConcurrentJobsPerOwner: 2)
        _ = limited.attachController(name: "test")

        // 同 owner 两个活跃作业（owner=s1）。
        var boxes: [ResultBox<JobOutcome>] = []
        for _ in 0..<2 {
            var producer = makeBashProducer()
            producer.spec = JobStart(kind: .bash, label: producer.spec.label,
                                     ownerSessionId: "s1", run: producer.spec.run)
            _ = try limited.start(producer.spec)
            boxes.append(producer.box)
        }
        // 同 owner 第三个 → 拒绝（文案逐字，limit 值内插）。
        do {
            _ = try limited.start(makeBashProducer().spec)
            XCTFail("应触发并发上限")
        } catch {
            XCTAssertEqual(message(of: error),
                "background job limit reached for this owner (limit: 2); use job_kill to stop an unneeded job, wait for it to finish, then retry")
        }
        // unowned 是独立桶；s2 也是独立桶 → 均可 start。
        _ = try limited.start(makeBashProducer().spec)
        let s2 = JobStart(kind: .bash, label: "s2 job", ownerSessionId: "s2", run: {
            JobHooks(cancel: { _ in }, done: { await ResultBox<JobOutcome>().wait() })
        })
        _ = try limited.start(s2)
        // 一个 s1 作业结算后桶位释放 → s1 可再 start。
        boxes[0].fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        let waitDeadline = Date().addingTimeInterval(2)
        while Date() < waitDeadline {
            if limited.list(callerSessionId: "s1").first?.status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try limited.start(makeBashProducer().spec)
    }

    func testThrowingRunLeavesNothingRegisteredAndOrdinalNotConsumed() throws {
        struct Boom: Error {}
        let failing = JobStart(kind: .bash, label: "boom", run: { throw Boom() })
        XCTAssertThrowsError(try registry.start(failing))
        XCTAssertTrue(registry.list(callerSessionId: nil).isEmpty,
                      "抛错的 starter 不留下任何已注册物")
        // 序数在 run 之后消费（index.ts:150-153）——下次成功 start 仍是 bash-1。
        let producer = makeBashProducer()
        XCTAssertEqual(try registry.start(producer.spec), "bash-1")
    }

    // MARK: start → 快照 → settle

    func testStartRegistersRunningSnapshotAndNotifiesChanged() throws {
        let changedOwners = Collector<String?>()
        registry.onJobsChanged { changedOwners.append($0) }
        let producer = makeBashProducer(label: "long build")
        let id = try registry.start(producer.spec)

        XCTAssertEqual(id, "bash-1")
        let snap = try registry.get(id: id, callerSessionId: nil)
        XCTAssertEqual(snap.id, "bash-1")
        XCTAssertEqual(snap.kind, .bash)
        XCTAssertEqual(snap.label, "long build")
        XCTAssertEqual(snap.status, .running)
        XCTAssertFalse(snap.reported)
        XCTAssertNil(snap.finishedAt)
        XCTAssertGreaterThanOrEqual(snap.startedAt, 0)
        // notifyChanged 触发点①：注册。
        XCTAssertEqual(changedOwners.all, [nil])
    }

    func testSettleFirstWinsAndListenerOnce() async throws {
        let notices = Collector<(id: String, owner: String?)>()
        registry.onJobDone { snap, owner in notices.append((snap.id, owner)) }
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)

        producer.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        producer.box.fulfill(JobOutcome(status: .failed, detail: "late"))

        let waitDeadline = Date().addingTimeInterval(2)
        while Date() < waitDeadline {
            if try registry.get(id: id, callerSessionId: nil).status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snap = try registry.get(id: id, callerSessionId: nil)
        XCTAssertEqual(snap.status, .completed, "first-wins：迟到结算零效果")
        XCTAssertEqual(snap.detail, "exit code: 0")
        XCTAssertNotNil(snap.finishedAt)
        XCTAssertGreaterThanOrEqual(snap.finishedAt ?? 0, snap.startedAt)
        XCTAssertEqual(notices.count, 1, "结算只通知一轮")
        XCTAssertEqual(notices.all.first?.id, "bash-1")
    }

    // MARK: wait 语义

    func testWaitReturnsTerminalSnapshotAfterSettle() async throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        let waiter = Task {
            try await registry.wait(id: id, timeoutMs: 5_000, callerSessionId: nil)
        }
        // 等 waiter 登记进活跃集。
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, registry.waiterCount(id: id) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(registry.waiterCount(id: id), 1)

        producer.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        let snap = try await waiter.value
        XCTAssertEqual(snap.status, .completed)
        // waiter 在场结算 → reported 置位（index.ts:422）。
        XCTAssertTrue(snap.reported)
    }

    func testWaitTimeoutReturnsRunningSnapshot() async throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        // 超时返回当前快照不取消不抛（index.ts:230-279 语义）。
        let snap = try await registry.wait(id: id, timeoutMs: 80, callerSessionId: nil)
        XCTAssertEqual(snap.status, .running)
        XCTAssertFalse(snap.reported, "无 waiter 的结算面未触发——running 快照不标 reported")
        XCTAssertEqual(try registry.get(id: id, callerSessionId: nil).status, .running)
    }

    func testWaitCallerCancelThrowsWhileLive() async throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        let waiter = Task {
            try await registry.wait(id: id, timeoutMs: 60_000, callerSessionId: nil)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, registry.waiterCount(id: id) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("live 作业的 caller 取消应抛")
        } catch {
            XCTAssertTrue(message(of: error).contains("wait aborted"))
        }
        XCTAssertEqual(registry.waiterCount(id: id), 0, "取消后计数归还")
        // 取消的 waiter 不计入 reported（结算时无 waiter）。
        producer.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        let settleDeadline = Date().addingTimeInterval(2)
        var settledSnap: JobSnapshot?
        while Date() < settleDeadline {
            if try registry.get(id: id, callerSessionId: nil).status == .completed {
                settledSnap = try registry.get(id: id, callerSessionId: nil)
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(settledSnap?.status, .completed)
        XCTAssertFalse(settledSnap?.reported ?? true)
    }

    // MARK: kill / read

    func testKillRequestsMarksStoppingThenSettlesKilled() async throws {
        let changed = Collector<String?>()
        registry.onJobsChanged { changed.append($0) }
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        let afterStart = changed.count  // notifyChanged 触发点①：注册

        XCTAssertEqual(try registry.kill(id: id, callerSessionId: nil,
                                         reason: "user asked"), .requested)
        XCTAssertEqual(producer.cancels.all, ["user asked"], "cancel 先行且 reason 原样转发")
        var snap = try registry.get(id: id, callerSessionId: nil)
        XCTAssertEqual(snap.status, .stopping)
        XCTAssertTrue(snap.reported, "kill 标 reported（index.ts:225）")
        XCTAssertGreaterThanOrEqual(changed.count, afterStart + 1,
                                    "notifyChanged 触发点②：kill")

        // 生产者随后给出 killed → 结算。
        producer.box.fulfill(JobOutcome(status: .killed))
        let settleDeadline = Date().addingTimeInterval(2)
        while Date() < settleDeadline {
            if try registry.get(id: id, callerSessionId: nil).status == .killed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        snap = try registry.get(id: id, callerSessionId: nil)
        XCTAssertEqual(snap.status, .killed)
        XCTAssertNil(snap.detail)

        // 终态后再 kill → already-finished。
        XCTAssertEqual(try registry.kill(id: id, callerSessionId: nil, reason: nil),
                       .alreadyFinished)
    }

    func testKillAfterTerminalReturnsAlreadyFinished() async throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        producer.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try registry.get(id: id, callerSessionId: nil).status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try registry.kill(id: id, callerSessionId: nil, reason: nil),
                       .alreadyFinished)
        XCTAssertTrue(try registry.get(id: id, callerSessionId: nil).reported)
    }

    func testReadCursorDeltaAndTerminalReported() throws {
        let lines = ResultBox<JobOutcome>()
        let cursor = CursorBox()
        let spec = JobStart(kind: .bash, label: "stream", run: {
            JobHooks(cancel: { _ in }, done: { await lines.wait() },
                     readOutput: { cursor.readDelta() })
        })
        let id = try registry.start(spec)
        cursor.append("one")
        XCTAssertEqual(try registry.read(id: id, callerSessionId: nil).text, "one")
        cursor.append("two")
        XCTAssertEqual(try registry.read(id: id, callerSessionId: nil).text, "two",
                       "游标增量：只给新行")
        // 流式读取不标 reported（live 期间）。
        XCTAssertFalse(try registry.get(id: id, callerSessionId: nil).reported)

        lines.fulfill(JobOutcome(status: .completed, output: "final"))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try registry.get(id: id, callerSessionId: nil).status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let read = try registry.read(id: id, callerSessionId: nil)
        XCTAssertEqual(read.snapshot.status, .completed)
        XCTAssertTrue(read.snapshot.reported, "终态读取标 reported（index.ts:211）")
    }

    func testFinalOutputOnlyJobRead() async throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)  // 无 readOutput
        XCTAssertEqual(try registry.read(id: id, callerSessionId: nil).text, "",
                       "仅终态输出作业：活着时读空")
        producer.box.fulfill(JobOutcome(status: .completed, output: "done-out"))
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try registry.get(id: id, callerSessionId: nil).status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // 结算后幂等终态输出——两次读同值（永不消费）。
        XCTAssertEqual(try registry.read(id: id, callerSessionId: nil).text, "done-out")
        XCTAssertEqual(try registry.read(id: id, callerSessionId: nil).text, "done-out")
    }

    // MARK: owner 围栏 / unknown / timeout 校验

    func testOwnerFenceBlocksForeignCaller() throws {
        let producer = makeBashProducer()
        let spec = JobStart(kind: .bash, label: producer.spec.label,
                            ownerSessionId: "s1", run: producer.spec.run)
        let id = try registry.start(spec)

        // 异 session 抛（文案逐字）。
        XCTAssertThrowsError(try registry.get(id: id, callerSessionId: "s2")) { error in
            XCTAssertEqual(message(of: error), "job \(id) belongs to another session")
        }
        XCTAssertThrowsError(try registry.get(id: id, callerSessionId: nil))
        // list 只见自家 + unowned。
        XCTAssertEqual(registry.list(callerSessionId: "s2").count, 0)
        XCTAssertEqual(registry.list(callerSessionId: nil).count, 0)
        XCTAssertEqual(registry.list(callerSessionId: "s1").count, 1)
        // 异 session 的 kill/read/wait 同被围栏。
        XCTAssertThrowsError(try registry.kill(id: id, callerSessionId: "s2", reason: nil))
        XCTAssertThrowsError(try registry.read(id: id, callerSessionId: "s2"))
    }

    func testUnknownJobThrowsVerbatim() {
        XCTAssertThrowsError(try registry.get(id: "bash-9", callerSessionId: nil)) { error in
            XCTAssertEqual(message(of: error), "unknown job bash-9")
        }
    }

    func testInvalidWaitTimeoutVerbatim() throws {
        let producer = makeBashProducer()
        let id = try registry.start(producer.spec)
        XCTAssertThrowsError(try registry.wait(id: id, timeoutMs: 0, callerSessionId: nil)) { error in
            XCTAssertEqual(message(of: error),
                "invalid wait timeout: expected a positive number of milliseconds, got 0")
        }
    }

    // MARK: teardown

    func testDisposeAllCancelsClearsAndClosesListeners() async throws {
        let notices = Collector<String>()
        registry.onJobDone { snap, _ in notices.append(snap.id) }
        let producerA = makeBashProducer(label: "a")
        let producerB = makeBashProducer(label: "b")
        let idA = try registry.start(producerA.spec)
        let idB = try registry.start(producerB.spec)

        let disposeTask = Task { await registry.disposeAll() }
        let cancelDeadline = Date().addingTimeInterval(2)
        while Date() < cancelDeadline {
            if producerA.cancels.all.count == 1 && producerB.cancels.all.count == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // teardown cancel=无 caller 的 kill：reason 逐字 + 标 reported + stopping。
        XCTAssertEqual(producerA.cancels.all, ["jobs service disposed"])
        XCTAssertEqual(producerB.cancels.all, ["jobs service disposed"])
        XCTAssertEqual(try registry.get(id: idA, callerSessionId: nil).status, .stopping)
        XCTAssertTrue(try registry.get(id: idA, callerSessionId: nil).reported)

        // 生产者释放 → disposeAll 的 await settled 放行。
        producerA.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        producerB.box.fulfill(JobOutcome(status: .completed, detail: "exit code: 0"))
        await disposeTask.value

        XCTAssertTrue(registry.list(callerSessionId: nil).isEmpty, "store 清空")
        XCTAssertThrowsError(try registry.get(id: idA, callerSessionId: nil))
        XCTAssertEqual(notices.count, 0, "listenersClosed：disposeAll 后无完成通知")
    }
}

// MARK: - 游标箱（readOutput 增量面）

private final class CursorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var readIndex = 0

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func readDelta() -> String {
        lock.lock(); defer { lock.unlock() }
        guard readIndex < lines.count else { return "" }
        let delta = lines[readIndex...].joined(separator: "\n")
        readIndex = lines.count
        return delta
    }
}

// MARK: - ShellTool 后台接线（桩 spawner + 真 LocalJobRegistry）

final class ShellToolBackgroundTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-bg-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBase)
        try super.tearDownWithError()
    }

    private func makeContext() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "s1",
            turn: 0,
            step: 0,
            callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "s1"),
            spill: SpillStore(root: tempBase.appendingPathComponent("spill")),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .readOnly,
            escalationApprover: nil)
    }

    func testBackgroundStartKillAndKilledSettlement() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let resultBox = ResultBox<DetachedShellResult>()
        let cancelLog = CancelLog()
        let spawned = ValueSink<String>()
        var tool = ShellTool(sessionId: "s1", jobs: registry)
        tool.prepareBackground = { _ in }   // 测试跳过真桥挂载
        tool.spawnDetached = { _, cmd in
            spawned.set(cmd)
            return DetachedShellHandle(
                pid: 4242,
                done: { await resultBox.wait() },
                cancel: { cancelLog.append(nil) },
                readOutput: { "" })
        }

        let output = try await tool.execute(.object([
            "command": .string("sleep 100"),
            "run_in_background": .bool(true),
        ]), makeContext())

        // 返回 {kind:'background', jobId} 形态文本。
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.text.contains("\"kind\": \"background\""), output.text)
        XCTAssertTrue(output.text.contains("\"jobId\": \"bash-1\""), output.text)
        XCTAssertEqual(spawned.current, "sleep 100", "label=command 进 producer run")

        // registry 出现 running 记录（owner=会话 id）。
        let running = try registry.get(id: "bash-1", callerSessionId: "s1")
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.ownerSessionId, "s1")
        XCTAssertEqual(running.label, "sleep 100")

        // kill → producer cancel → done=killed → registry 结算 killed。
        XCTAssertEqual(try registry.kill(id: "bash-1", callerSessionId: "s1",
                                         reason: "no longer needed"), .requested)
        XCTAssertEqual(cancelLog.all, [nil], "handle.cancel 经 JobHooks.cancel 转发")
        resultBox.fulfill(DetachedShellResult(mergedOutput: "",
                                              exitCode: -9,
                                              error: ISHShellExecutorError.cancelled))
        let final = try await registry.wait(id: "bash-1", timeoutMs: 3_000,
                                            callerSessionId: "s1")
        XCTAssertEqual(final.status, .killed)
        XCTAssertEqual(final.detail, "killed before exit")
    }

    func testBackgroundStartWithoutRegistryFailsVerbatim() async throws {
        let tool = ShellTool(sessionId: "s1")   // jobs=nil
        let output = try await tool.execute(.object([
            "command": .string("sleep 100"),
            "run_in_background": .bool(true),
        ]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "JOBS_UNAVAILABLE")
        XCTAssertTrue(output.text.contains(
            "background jobs unavailable: load @deepseek-ai/dsh-jobs and @deepseek-ai/dsh-tool-jobs"))
    }

    func testProcessOutcomeMapping() {
        // 非零退出=completed 不是 failed（background.ts:26）。
        let completed = ShellTool.processOutcome(from: DetachedShellResult(
            mergedOutput: "", exitCode: 3, error: ISHShellExecutorError.none))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.detail, "exit code: 3")
        // killed → killed + fallback detail（C 层无 signal 粒度，登记）。
        let killed = ShellTool.processOutcome(from: DetachedShellResult(
            mergedOutput: "", exitCode: -9, error: ISHShellExecutorError.cancelled))
        XCTAssertEqual(killed.status, .killed)
        XCTAssertEqual(killed.detail, "killed before exit")
    }

    func testRunInBackgroundSchemaFieldPresent() {
        guard case .object(let schema) = ShellTool(sessionId: "s").parameters,
              case .object(let props) = schema["properties"],
              case .object(let bg) = props["run_in_background"],
              case .string(let type)? = bg["type"] else {
            return XCTFail("run_in_background schema missing")
        }
        XCTAssertEqual(type, "boolean")
        // 不进 required（可选参数）。
        guard case .array(let required) = schema["required"] else {
            return XCTFail("required missing")
        }
        XCTAssertFalse(required.contains(.string("run_in_background")))
    }
}
