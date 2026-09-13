//
//  JobToolsTests.swift
//  WanWoTests
//
//  【M5-A 批 J3 测试 · 三工具 + 通知文本 + prompt 段】四面：
//    1. 纯函数面：statusLine 双形态 / publicJob 剥字段 / validateJobId 逐字 /
//       retainHead/retainTail UTF-8 边界 / fitWithSuffix 分支 /
//       fitCompletionNotice 四段降级链（字节边界逐一对拍 tool-jobs index.ts）
//    2. job_output：'(no new output)' + status 行 / 等待超时返 running 非错 /
//       wait→settle 终态输出 / 流式增量 / 缺参与未知作业
//    3. job_list：空集与单行渲染（含 stopping 迁移）；job_kill：requested 与
//       already-finished 双渲染（逐字）
//    4. SECTION_ORDERS 纠偏断言（TOOL_JOBS=1600，dsh system-prompt/src/
//       index.ts:135 逐字）+ tool:jobs 段注册与位序（grep 1500 < jobs 1600
//       < web_search 2000）
//  （dsh detached 通道真机面与 AgentLoop.inject 投递面不在 CI——真机验收，
//   与 J2 同纪律。）
//

import XCTest
@testable import WanWo

// MARK: - 测试夹具

/// 手动放行的生产者 done 门（never-settle 等待超时面）。
private final class ManualSettler: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var settled = false

    /// 生产者 done 面：等 settle 放行。
    func waitDone() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if settled {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// 放行（幂等）。
    func settle() {
        lock.lock()
        settled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// 流式 readOutput 游标（jobs-local index.ts readOutput 增量语义）。
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

final class JobToolsTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("job-tools-tests-\(UUID().uuidString)",
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

    /// 起一个手动结算的 held 作业（controller 已挂、owner=s1）。
    private func startHeldJob(_ registry: LocalJobRegistry,
                              settler: ManualSettler,
                              label: String = "sleep 30",
                              outputLimitBytes: Int? = nil,
                              outcome: JobOutcome = JobOutcome(status: .completed,
                                                               detail: "exit code: 0",
                                                               output: "result text"),
                              readOutput: (@Sendable () -> String)? = nil) throws -> String {
        return try registry.start(JobStart(
            kind: .bash,
            label: label,
            outputLimitBytes: outputLimitBytes,
            ownerSessionId: "s1",
            run: {
                JobHooks(
                    cancel: { _ in },
                    done: {
                        await settler.waitDone()
                        return outcome
                    },
                    readOutput: readOutput)
            }))
    }

    // MARK: 1a. statusLine / publicJob / validateJobId

    func testStatusLineBothForms() {
        // index.ts:102-106：detail 在场/缺席双形态。
        XCTAssertEqual(jobStatusLine(status: .running, detail: nil), "[status: running]")
        XCTAssertEqual(jobStatusLine(status: .completed, detail: "exit code: 3"),
                       "[status: completed, exit code: 3]")
    }

    func testPublicJobStripsBookkeeping() {
        let snapshot = JobSnapshot(id: "bash-1", kind: .bash, label: "sleep 1",
                                   outputLimitBytes: 4096, ownerSessionId: "s1",
                                   status: .killed, detail: "killed before exit",
                                   startedAt: 100, finishedAt: 200, reported: true)
        let job = publicJob(snapshot)
        XCTAssertEqual(job.id, "bash-1")
        XCTAssertEqual(job.kind, .bash)
        XCTAssertEqual(job.label, "sleep 1")
        XCTAssertEqual(job.status, .killed)
        XCTAssertEqual(job.detail, "killed before exit")
        XCTAssertEqual(job.startedAt, 100)
        XCTAssertEqual(job.finishedAt, 200)
        // bookkeeping 三字段不在投影类型上（编译期剥除——index.ts:85-95）。
        let mirror = Mirror(reflecting: job)
        let fieldNames = mirror.children.compactMap(\.label)
        XCTAssertFalse(fieldNames.contains("outputLimitBytes"))
        XCTAssertFalse(fieldNames.contains("ownerSessionId"))
        XCTAssertFalse(fieldNames.contains("reported"))
    }

    func testValidateJobIdEmptyVerbatim() throws {
        // index.ts:194 文案逐字（JSON.stringify("") = `""`）。
        XCTAssertThrowsError(try validateJobId("")) { error in
            XCTAssertEqual((error as? JobRegistryError)?.message,
                           "invalid job_id: expected a non-empty string, got \"\"")
        }
        XCTAssertEqual(try validateJobId("bash-1"), "bash-1")
    }

    // MARK: 1b. UTF-8 边界保留截断（output-retention 对拍）

    func testRetainHeadTailUtf8Boundaries() {
        // 你 = E4 BD A0 / 好 = E5 A5 BD。
        XCTAssertEqual(retainHead("你好", maxBytes: 4), "你", "头部截点裁掉残缺好")
        XCTAssertEqual(retainTail("你好", maxBytes: 4), "好", "尾部截点丢弃孤立 continuation")
        XCTAssertEqual(retainHead("你好", maxBytes: 6), "你好", "预算内全保")
        XCTAssertEqual(retainTail("abc", maxBytes: 10), "abc")
        XCTAssertEqual(retainHead("abc", maxBytes: 0), "")
        XCTAssertEqual(retainTail("abc", maxBytes: 0), "")
    }

    func testFitWithSuffixBranches() {
        // 无预算：直拼。
        XCTAssertEqual(fitWithSuffix("abc", "!", nil, "\n[omitted]"), "abc!")
        // 预算内：直拼。
        XCTAssertEqual(fitWithSuffix("abc", "!", 10, "\n[omitted]"), "abc!")
        // 分支②：fixed < maxBytes → 尾部保留 content 腾位再接 fixed。
        let content = String(repeating: "a", count: 50)
        XCTAssertEqual(fitWithSuffix(content, "\nSUFFIX", 40, "\n[omitted]"),
                       String(repeating: "a", count: 22) + "\n[omitted]\nSUFFIX")
        // 分支①：fixed ≥ maxBytes → 尾部保留整串。
        XCTAssertEqual(fitWithSuffix("hi", "\nSUFFIX", 5, "\n[omitted]"), "UFFIX")
        // content 已带 omitted 标记（trimStart 后）→ 不重复补。
        XCTAssertEqual(fitWithSuffix("abc\n[output truncated]", "", 10, "\n[output truncated]"),
                       "truncated]")
    }

    func testFitCompletionNoticeFourStages() {
        // 字节账（逐一对拍 index.ts:145-166）：
        // prefix=21 / action=18 / omitted=19 / fixed=58 / compact=39。
        let snapshot = JobSnapshot(id: "bash-1", kind: .bash,
                                   label: "abcdefghij",
                                   outputLimitBytes: nil, ownerSessionId: "s1",
                                   status: .completed, detail: "exit code: 0",
                                   startedAt: 1, finishedAt: 2)
        let complete = "background job bash-1 (bash: abcdefghij) finished "
            + "[status: completed, exit code: 0]. Read its output with job_output."

        // 段①：无预算 / 预算足够 → 完整文本。
        XCTAssertEqual(JobCompletionNotice.text(for: snapshot), complete)
        var limited = JobSnapshot(id: "bash-1", kind: .bash, label: "abcdefghij",
                                  outputLimitBytes: 200, ownerSessionId: "s1",
                                  status: .completed, detail: "exit code: 0",
                                  startedAt: 1, finishedAt: 2)
        XCTAssertEqual(JobCompletionNotice.text(for: limited), complete)

        // 段②：58 ≤ max < complete → prefix + retainHead(detail) + omitted + action。
        // complete=117；maxBytes=70 → detail 头部保留 12 字节。
        limited = JobSnapshot(id: "bash-1", kind: .bash, label: "abcdefghij",
                              outputLimitBytes: 70, ownerSessionId: "s1",
                              status: .completed, detail: "exit code: 0",
                              startedAt: 1, finishedAt: 2)
        XCTAssertEqual(JobCompletionNotice.text(for: limited),
                       "background job bash-1 (bash: abcd\n[notice truncated]\nDone; job_output.")

        // 段③：compact ≤ max < fixed（39 ≤ 50 < 58）→ prefix + action。
        limited = JobSnapshot(id: "bash-1", kind: .bash, label: "abcdefghij",
                              outputLimitBytes: 50, ownerSessionId: "s1",
                              status: .completed, detail: "exit code: 0",
                              startedAt: 1, finishedAt: 2)
        XCTAssertEqual(JobCompletionNotice.text(for: limited),
                       "background job bash-1\nDone; job_output.")

        // 段④a：action(18) ≥ max(10) → retainTail(action, max)。
        limited = JobSnapshot(id: "bash-1", kind: .bash, label: "abcdefghij",
                              outputLimitBytes: 10, ownerSessionId: "s1",
                              status: .completed, detail: "exit code: 0",
                              startedAt: 1, finishedAt: 2)
        XCTAssertEqual(JobCompletionNotice.text(for: limited), "ob_output.")

        // 段④b：compact > max > action(18)（18 < 30 < 39）→
        // retainHead(prefix, 12) + action。
        limited = JobSnapshot(id: "bash-1", kind: .bash, label: "abcdefghij",
                              outputLimitBytes: 30, ownerSessionId: "s1",
                              status: .completed, detail: "exit code: 0",
                              startedAt: 1, finishedAt: 2)
        XCTAssertEqual(JobCompletionNotice.text(for: limited),
                       "background j\nDone; job_output.")
    }

    // MARK: 2. job_output

    func testJobOutputNoWaitAndTimeoutReturnRunning() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let settler = ManualSettler()
        let id = try startHeldJob(registry, settler: settler)
        let tool = JobOutputTool(sessionId: "s1", jobs: registry)

        // 非 blocking 读：流式空增量 → '(no new output)' + running 状态行。
        var output = try await tool.execute(.object(["job_id": .string(id)]),
                                            makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "(no new output)\n[status: running]")

        // 等待超时：返回 running 快照而非错误，作业存活（dsh :306-308）。
        output = try await tool.execute(.object([
            "job_id": .string(id), "wait": .bool(true), "timeout_ms": .int(50),
        ]), makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "(no new output)\n[status: running]")
        XCTAssertEqual(try registry.get(id: id, callerSessionId: "s1").status, .running)

        // 收尾放行并排空（不悬挂观察 Task）。
        settler.settle()
        _ = try await registry.wait(id: id, timeoutMs: 2_000, callerSessionId: "s1")
    }

    func testJobOutputWaitSettlesWithFinalOutput() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let settler = ManualSettler()
        let id = try startHeldJob(registry, settler: settler)
        let tool = JobOutputTool(sessionId: "s1", jobs: registry)

        Task { try? await Task.sleep(nanoseconds: 50_000_000); settler.settle() }
        let output = try await tool.execute(.object([
            "job_id": .string(id), "wait": .bool(true), "timeout_ms": .int(5_000),
        ]), makeContext())
        XCTAssertFalse(output.isError)
        // dsh render + finalize 规范路径合流：终态输出 + status 行
        // （detail 在场形态）。
        XCTAssertEqual(output.text, "result text\n[status: completed, exit code: 0]")
        // 终态读取标 reported（jobs-local index.ts:211 经 read 生效）。
        XCTAssertTrue(try registry.get(id: id, callerSessionId: "s1").reported)
    }

    func testJobOutputStreamingDelta() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let settler = ManualSettler()
        let cursor = CursorBox()
        let id = try startHeldJob(registry, settler: settler,
                                  outcome: JobOutcome(status: .completed),
                                  readOutput: { cursor.readDelta() })
        let tool = JobOutputTool(sessionId: "s1", jobs: registry)

        // 第一次读前无增量。
        var output = try await tool.execute(.object(["job_id": .string(id)]),
                                            makeContext())
        XCTAssertEqual(output.text, "(no new output)\n[status: running]")

        cursor.append("line1")
        output = try await tool.execute(.object(["job_id": .string(id)]), makeContext())
        XCTAssertEqual(output.text, "line1\n[status: running]")

        cursor.append("line2")
        output = try await tool.execute(.object(["job_id": .string(id)]), makeContext())
        XCTAssertEqual(output.text, "line2\n[status: running]")

        settler.settle()
        _ = try await registry.wait(id: id, timeoutMs: 2_000, callerSessionId: "s1")
    }

    func testJobOutputOutputLimitTruncation() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let settler = ManualSettler()
        // output="0123456789…"(30B) / suffix="\n[status: completed, exit code: 0]"(34B)
        // → complete=64 > 70? 否——预算 70 不足以让 complete 过？64 ≤ 70。
        // 取预算 60：complete 64 > 60；fixed = 19+34 = 53 < 60 →
        // retainTail(content, 7) + fixed（分支②路径）。
        let id = try startHeldJob(registry, settler: settler,
                                  outputLimitBytes: 60)
        let tool = JobOutputTool(sessionId: "s1", jobs: registry)
        settler.settle()
        _ = try await registry.wait(id: id, timeoutMs: 2_000, callerSessionId: "s1")

        let output = try await tool.execute(.object(["job_id": .string(id)]),
                                            makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text,
                       "2345678\n[output truncated]\n[status: completed, exit code: 0]")
    }

    func testJobOutputInvalidAndUnknownJob() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let tool = JobOutputTool(sessionId: "s1", jobs: registry)

        // 缺 job_id（schema required 的 WanWo 参数面兜底）。
        var output = try await tool.execute(.object([:]), makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "INVALID_ARGS")
        XCTAssertTrue(output.text.contains("missing required parameter \"job_id\""))

        // 空串：validateJobId 逐字文案。
        output = try await tool.execute(.object(["job_id": .string("")]),
                                        makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "INVALID_JOB_ID")
        XCTAssertTrue(output.text.contains(
            "invalid job_id: expected a non-empty string, got \"\""))

        // 未知作业：注册表逐字文案。
        output = try await tool.execute(.object(["job_id": .string("bash-99")]),
                                        makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("unknown job bash-99"))
    }

    // MARK: 3. job_list / job_kill

    func testJobListEmptyAndRendered() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let tool = JobListTool(sessionId: "s1", jobs: registry)

        var output = try await tool.execute(.object([:]), makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "(no background jobs)")

        let settlerA = ManualSettler()
        let settlerB = ManualSettler()
        _ = try startHeldJob(registry, settler: settlerA, label: "sleep 30")
        _ = try startHeldJob(registry, settler: settlerB, label: "sleep 40")
        output = try await tool.execute(.object([:]), makeContext())
        // dsh :351 单行形态 `<id> [<kind>] <status> — <label>`。
        XCTAssertEqual(output.text,
                       "bash-1 [bash] running — sleep 30\nbash-2 [bash] running — sleep 40")

        // kill 迁移 stopping 在 list 可见（jobs-local :222-227）。
        _ = try registry.kill(id: "bash-1", callerSessionId: "s1", reason: nil)
        output = try await tool.execute(.object([:]), makeContext())
        XCTAssertTrue(output.text.contains("bash-1 [bash] stopping — sleep 30"))

        settlerA.settle()
        settlerB.settle()
        _ = try await registry.wait(id: "bash-1", timeoutMs: 2_000, callerSessionId: "s1")
        _ = try await registry.wait(id: "bash-2", timeoutMs: 2_000, callerSessionId: "s1")
    }

    func testJobKillRequestedAndAlreadyFinished() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let settler = ManualSettler()
        let id = try startHeldJob(registry, settler: settler,
                                  outcome: JobOutcome(status: .killed))
        let tool = JobKillTool(sessionId: "s1", jobs: registry)

        // 在飞 → 'requested cancellation of job N'（dsh :386 逐字）。
        var output = try await tool.execute(.object([
            "job_id": .string(id), "reason": .string("no longer needed"),
        ]), makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "requested cancellation of job bash-1")
        XCTAssertEqual(try registry.get(id: id, callerSessionId: "s1").status, .stopping)

        // 生产者释放 → settle killed（无 detail → 状态行无 detail 形态）。
        settler.settle()
        _ = try await registry.wait(id: id, timeoutMs: 2_000, callerSessionId: "s1")

        // 已终态 → 'job N had already finished [status: killed]'（dsh :385 逐字）。
        output = try await tool.execute(.object(["job_id": .string(id)]),
                                        makeContext())
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "job bash-1 had already finished [status: killed]")
    }

    func testJobKillUnknownJob() async throws {
        let registry = LocalJobRegistry()
        _ = registry.attachController(name: "test")
        let tool = JobKillTool(sessionId: "s1", jobs: registry)
        let output = try await tool.execute(.object(["job_id": .string("bash-99")]),
                                            makeContext())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "JOB_KILL_FAILED")
        XCTAssertTrue(output.text.contains("unknown job bash-99"))
    }

    // MARK: 4. schema 形态 + SECTION_ORDERS 纠偏 + 段注册

    func testToolSchemasShape() {
        guard case .object(let outSchema) = JobOutputTool(sessionId: "s",
                                                          jobs: LocalJobRegistry()).parameters,
              case .object(let outProps)? = outSchema["properties"],
              outProps.keys.contains("job_id"),
              outProps.keys.contains("wait"),
              outProps.keys.contains("timeout_ms"),
              case .array(let outRequired)? = outSchema["required"] else {
            return XCTFail("job_output schema missing")
        }
        XCTAssertTrue(outRequired.contains(.string("job_id")))

        guard case .object(let killSchema) = JobKillTool(sessionId: "s",
                                                         jobs: LocalJobRegistry()).parameters,
              case .object(let killProps)? = killSchema["properties"],
              killProps.keys.contains("reason"),
              case .array(let killRequired)? = killSchema["required"] else {
            return XCTFail("job_kill schema missing")
        }
        XCTAssertTrue(killRequired.contains(.string("job_id")))
        XCTAssertFalse(killRequired.contains(.string("reason")))

        // job_list 无参数（dsh :344 parameters: {}）。
        let listTool = JobListTool(sessionId: "s", jobs: LocalJobRegistry())
        XCTAssertEqual(listTool.name, "job_list")
    }

    func testSectionOrdersJ3Correction() {
        // dsh system-prompt/src/index.ts:135-136 逐字：TOOL_JOBS=1600、
        // TOOL_PTY=1700——M2 误占位的纠偏断言。
        XCTAssertEqual(SECTION_ORDERS.toolJobs, 1600)
        XCTAssertEqual(SECTION_ORDERS.toolReadImage, 1610)
        XCTAssertEqual(SECTION_ORDERS.toolStrReplaceEditor, 1620)
        // 邻位不漂移：grep 1500 / web_search 2000 / web_fetch 2100。
        XCTAssertEqual(SECTION_ORDERS.toolGrep, 1500)
        XCTAssertEqual(SECTION_ORDERS.toolWebSearch, 2000)
        XCTAssertEqual(SECTION_ORDERS.toolWebFetch, 2100)
    }

    func testToolJobsSectionRegistersBetweenGrepAndWebSearch() throws {
        let assembler = PromptAssembler()
        // 相邻既有段（PromptSections 同形态注册）。
        assembler.section(PromptSection(name: "tool:grep",
                                        order: SECTION_ORDERS.toolGrep,
                                        text: "GREP_MARKER"))
        assembler.section(JobTools.promptSection())
        assembler.section(PromptSection(name: "tool:web_search",
                                        order: SECTION_ORDERS.toolWebSearch,
                                        text: "WEBSEARCH_MARKER"))
        let (system, _, _) = try assembler.assemble(toolSchemas: [])

        // 文本逐字在场（dsh tool-jobs index.ts:265）。
        XCTAssertTrue(system.contains(JobTools.promptSectionText))
        // 位序：grep 1500 < tool:jobs 1600 < web_search 2000。
        let grepAt = try XCTUnwrap(system.range(of: "GREP_MARKER")).lowerBound
        let jobsAt = try XCTUnwrap(system.range(of: JobTools.promptSectionText)).lowerBound
        let webAt = try XCTUnwrap(system.range(of: "WEBSEARCH_MARKER")).lowerBound
        XCTAssertLessThan(grepAt, jobsAt)
        XCTAssertLessThan(jobsAt, webAt)
    }
}
