//
//  P13SandboxGateTests.swift
//  WanWoTests
//
//  【P1-3 判定矩阵重做 · 回归测试】围栏矩阵（三挡 × fs/bash × 边界内外 ×
//  提权成败 × never）+ dsh escalation 逐字文案直证。出处：dsh escalation.ts
//  （WIDER_MODES / validateEscalationArgs / markers / approveEscalation）、
//  fs-sandbox checkedTarget 三分支、tool-fs resolvePolicy/mapError。
//

import XCTest
@testable import WanWo

final class P13SandboxGateTests: XCTestCase {

    // MARK: - 词汇与逐字文案（dsh escalation.ts 直证）

    func testWiderModesTable() {
        XCTAssertEqual(SandboxWiderModes.targets(from: .readOnly),
                       [.workspaceWrite, .dangerFullAccess])
        XCTAssertEqual(SandboxWiderModes.targets(from: .workspaceWrite),
                       [.dangerFullAccess])
        XCTAssertEqual(SandboxWiderModes.targets(from: .dangerFullAccess), [])
        XCTAssertEqual(SandboxEscalationTargets.all,
                       [.workspaceWrite, .dangerFullAccess])
    }

    func testValidateEscalationArgsVerbatimErrors() {
        // 成对校验三条错误（dsh escalation.ts:53/56/59 逐字）。
        func message(_ permissions: String?, _ justification: String?) -> String {
            do {
                try validateEscalationArgs(sandboxPermissions: permissions,
                                           justification: justification)
                return ""
            } catch let error as SandboxEscalationError {
                return error.message
            } catch {
                return "unexpected"
            }
        }
        XCTAssertEqual(message("workspace-write", nil),
                       "invalid escalation: sandbox_permissions requires a justification")
        XCTAssertEqual(message(nil, "because"),
                       "invalid escalation: justification is only valid together with sandbox_permissions")
        XCTAssertEqual(message("workspace-write", "   "),
                       "invalid justification: expected a non-empty sentence")
        // 成对合法 → 不抛。
        XCTAssertNoThrow(try validateEscalationArgs(
            sandboxPermissions: "workspace-write", justification: "need to write logs"))
        // 都缺省 → 不抛（standing policy 路径）。
        XCTAssertNoThrow(try validateEscalationArgs(sandboxPermissions: nil,
                                                    justification: nil))
    }

    func testMarkersVerbatim() {
        XCTAssertEqual(sandboxDenialMarker(.readOnly),
                       "[sandbox: file access denied under read-only mode]")
        XCTAssertEqual(sandboxDenialMarker(.workspaceWrite),
                       "[sandbox: file access denied under workspace-write mode]")
        XCTAssertEqual(escalationHintMarker("command"),
                       "[sandbox: escalation available — retry this exact command once with "
                           + "sandbox_permissions (the narrowest wider mode that suffices) + justification; "
                           + "the approval prompt asks the user]")
        XCTAssertEqual(escalationHintMarker("operation"),
                       "[sandbox: escalation available — retry this exact operation once with "
                           + "sandbox_permissions (the narrowest wider mode that suffices) + justification; "
                           + "the approval prompt asks the user]")
    }

    // MARK: - approveEscalation（有序 fail-closed）

    /// 非加宽请求：绝不惊动真人（approver 不被调用），逐字错误。
    func testApproveRejectsNonWideningWithoutPrompting() async {
        var prompted = false
        let approver: SandboxEscalationApprover = { _, _, _ in
            prompted = true
            return .allowedOnce
        }
        // danger-full-access 无更宽目标；workspace-write 不能提到 danger 之外的
        // 非法值；read-only 不能原地提 read-only。
        for (effective, requested) in [
            (SandboxMode.dangerFullAccess, "danger-full-access"),
            (SandboxMode.workspaceWrite, "workspace-write"),
            (SandboxMode.readOnly, "read-only"),
            (SandboxMode.readOnly, "yolo"),
        ] {
            do {
                _ = try await SandboxEscalation.approve(
                    requestedMode: requested, justification: "why",
                    effectiveMode: effective, subject: "operation",
                    toolName: "write", callId: "c1", approver: approver)
                XCTFail("must throw for \(effective)/\(requested)")
            } catch let error as SandboxEscalationError {
                XCTAssertEqual(error.message,
                    "sandbox escalation to \"\(requested)\" is not strictly wider than "
                        + "this call's current \"\(effective.rawValue)\" mode")
            } catch {
                XCTFail("unexpected error type")
            }
        }
        XCTAssertFalse(prompted, "非加宽请求不得触发审批")
    }

    /// 无审批服务 → fail closed 逐字文案（dsh :166）。
    func testApproveFailsClosedWithoutApprover() async {
        do {
            _ = try await SandboxEscalation.approve(
                requestedMode: "workspace-write", justification: "why",
                effectiveMode: .readOnly, subject: "operation",
                toolName: "write", callId: "c1", approver: nil)
            XCTFail("must throw")
        } catch let error as SandboxEscalationError {
            XCTAssertEqual(error.message,
                "sandbox escalation to \"workspace-write\" requires approval, but no "
                    + "approval service is composed")
        } catch {
            XCTFail("unexpected error type")
        }
    }

    /// 四值结算映射（dsh :183-186 逐字）+ reason 固定格式（:177）。
    func testApproveOutcomeMappingAndReasonFormat() async {
        var capturedReason: String?
        let approver: SandboxEscalationApprover = { _, _, reason in
            capturedReason = reason
            return .rejected
        }
        do {
            _ = try await SandboxEscalation.approve(
                requestedMode: "danger-full-access", justification: "need /etc write",
                effectiveMode: .workspaceWrite, subject: "command",
                toolName: "bash", callId: "c1", approver: approver)
            XCTFail("must throw")
        } catch let error as SandboxEscalationError {
            XCTAssertEqual(error.message,
                           "the user rejected escalating this command to \"danger-full-access\"")
        } catch {
            XCTFail("unexpected error type")
        }
        XCTAssertEqual(capturedReason, "escalate sandbox to danger-full-access: need /etc write")

        for (outcome, expected) in [
            (ApprovalOutcome.cancelled, "approval for escalating to \"workspace-write\" was cancelled"),
            (ApprovalOutcome.unavailable, "sandbox escalation to \"workspace-write\" requires approval, but no approval channel is available"),
        ] {
            let mapped: SandboxEscalationApprover = { _, _, _ in outcome }
            do {
                _ = try await SandboxEscalation.approve(
                    requestedMode: "workspace-write", justification: "why",
                    effectiveMode: .readOnly, subject: "operation",
                    toolName: "write", callId: "c1", approver: mapped)
                XCTFail("must throw")
            } catch let error as SandboxEscalationError {
                XCTAssertEqual(error.message, expected)
            } catch {
                XCTFail("unexpected error type")
            }
        }
        // allowed-once → 授予模式（仅 stamp 本调用——返回值即凭证）。
        let granted: SandboxEscalationApprover = { _, _, _ in .allowedOnce }
        let mode = try? await SandboxEscalation.approve(
            requestedMode: "workspace-write", justification: "why",
            effectiveMode: .readOnly, subject: "operation",
            toolName: "write", callId: "c1", approver: granted)
        XCTAssertEqual(mode, .workspaceWrite)
    }

    // MARK: - resolveMode（tool-fs resolvePolicy 语义）

    func testResolveModeStandingAndEscalation() async {
        let args = JSONValue.object(["file_path": .string("a.txt")])
        // 无提权参数 → standing 模式。
        let standing = await SandboxGate.resolveMode(
            tool: "write", args: args, standingMode: .workspaceWrite,
            subject: "operation", callId: "c1", approver: nil)
        XCTAssertEqual(try? standing.get(), .workspaceWrite)
        // 提权成对合法但无 approver → 逐字错误。
        let escalating = JSONValue.object([
            "file_path": .string("a.txt"),
            "sandbox_permissions": .string("workspace-write"),
            "justification": .string("need logs"),
        ])
        let failed = await SandboxGate.resolveMode(
            tool: "write", args: escalating, standingMode: .readOnly,
            subject: "operation", callId: "c1", approver: nil)
        XCTAssertEqual(try? failed.get(), nil)
        if case .failure(let failure) = failed {
            XCTAssertTrue(failure.message.contains("requires approval, but no approval service is composed"))
        } else {
            XCTFail("expected failure")
        }
        // 成对校验错误（只给一半）。
        let half = JSONValue.object(["sandbox_permissions": .string("workspace-write")])
        let invalid = await SandboxGate.resolveMode(
            tool: "write", args: half, standingMode: .readOnly,
            subject: "operation", callId: "c1", approver: nil)
        if case .failure(let failure) = invalid {
            XCTAssertEqual(failure.message, "invalid escalation: sandbox_permissions requires a justification")
        } else {
            XCTFail("expected failure")
        }
    }

    // MARK: - fs 词法围栏（checkedTarget 三分支）

    func testFsPathContainment() {
        // danger-full-access 直通（dsh :125）。
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("/etc/passwd",
                                                           mode: .dangerFullAccess))
        // read-only 一律拒（dsh :127）。
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("a.txt", mode: .readOnly))
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("/var/wanwo/workspace/a",
                                                            mode: .readOnly))
        // workspace-write：相对路径归 cwd=工作区；workspace root 内放行；
        // /tmp 白名单放行；root 前缀相似但不带边界段拒绝；越界拒绝。
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("a.txt", mode: .workspaceWrite))
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("./sub/a.txt", mode: .workspaceWrite))
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("/var/wanwo/workspace",
                                                           mode: .workspaceWrite))
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("/var/wanwo/workspace/sub/a",
                                                           mode: .workspaceWrite))
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("/tmp/x", mode: .workspaceWrite))
        XCTAssertTrue(SandboxGate.fsPathUnderWritableRoots("/tmp", mode: .workspaceWrite))
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("/var/wanwo/workspaceX",
                                                            mode: .workspaceWrite))
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("/tmpx", mode: .workspaceWrite))
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("/etc/passwd", mode: .workspaceWrite))
        XCTAssertFalse(SandboxGate.fsPathUnderWritableRoots("/var/wanwo/shared/x",
                                                            mode: .workspaceWrite))
    }

    /// fs 门端到端：read-only 拒绝（marker+hint 逐字、isError）→ 提权重试
    /// approved → 放行（携带 granted mode——P0-1 执行层兑现缝）；提权被拒 →
    /// 逐字拒绝文案。
    func testFsGateDenyAndEscalate() async {
        let path = JSONValue.object(["file_path": .string("/etc/hosts")])
        // read-only standing → deny（marker + hint('operation')）。
        let denied = await SandboxGate.authorizeFsMutation(
            tool: "write", path: "/etc/hosts", args: path,
            standingMode: .readOnly, callId: "c1", approver: nil)
        guard case .denied(let denial) = denied else {
            return XCTFail("expected .denied, got \(denied)")
        }
        XCTAssertEqual(denial.isError, true)
        XCTAssertEqual(denial.errorCode, "FS_SANDBOX_DENIED")
        XCTAssertEqual(denial.text,
                       "Error: [sandbox: file access denied under read-only mode]\n"
                           + "[sandbox: escalation available — retry this exact operation once with "
                           + "sandbox_permissions (the narrowest wider mode that suffices) + justification; "
                           + "the approval prompt asks the user]")
        // 带提权参数 + allowed-once → 放行（danger-full-access 越界路径直通，
        // granted mode 随行——工具体凭此打通执行层写入通道）。
        var promptedReason: String?
        let allow: SandboxEscalationApprover = { tool, callId, reason in
            promptedReason = "\(tool)|\(callId ?? "")|\(reason)"
            return .allowedOnce
        }
        let escalatedArgs = JSONValue.object([
            "file_path": .string("/etc/hosts"),
            "sandbox_permissions": .string("danger-full-access"),
            "justification": .string("append a host entry"),
        ])
        let passed = await SandboxGate.authorizeFsMutation(
            tool: "write", path: "/etc/hosts", args: escalatedArgs,
            standingMode: .readOnly, callId: "c1", approver: allow)
        XCTAssertEqual(passed, .granted(.dangerFullAccess))
        XCTAssertEqual(promptedReason,
                       "write|c1|escalate sandbox to danger-full-access: append a host entry")
        // 提权被拒 → 逐字文案。
        let reject: SandboxEscalationApprover = { _, _, _ in .rejected }
        let rejected = await SandboxGate.authorizeFsMutation(
            tool: "write", path: "/etc/hosts", args: escalatedArgs,
            standingMode: .readOnly, callId: "c1", approver: reject)
        guard case .denied(let rejection) = rejected else {
            return XCTFail("expected .denied, got \(rejected)")
        }
        XCTAssertEqual(rejection.text,
                       "Error: the user rejected escalating this operation to \"danger-full-access\"")
        XCTAssertEqual(rejection.errorCode, "SANDBOX_ESCALATION_ERROR")
        // workspace-write 内路径放行。
        let inside = await SandboxGate.authorizeFsMutation(
            tool: "write", path: "notes.md", args: path,
            standingMode: .workspaceWrite, callId: "c1", approver: nil)
        XCTAssertEqual(inside, .granted(.workspaceWrite))
    }

    // MARK: - P0-1 提权批准后写入兑现（双层围栏打通）

    /// 提权（danger-full-access）→ writeData 落在工作区外 guest 路径：
    /// guest 绝对路径映射到注入的 guest 根（rootfs data 模拟），写入成功。
    func testEscalatedWriteOutsideWorkspaceSucceeds() throws {
        let guestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p24-guest-\(UUID().uuidString)", isDirectory: true)
        let workspace = WorkspaceFileAccess(sessionId: "p24-\(UUID().uuidString)",
                                            guestRoot: guestRoot)
        defer { try? FileManager.default.removeItem(at: guestRoot) }
        // danger-full-access：/etc/hosts 落在 guest 根/etc/hosts。
        let url = try workspace.writeData("/etc/hosts", data: Data("127.0.0.1\n".utf8),
                                          mode: .dangerFullAccess)
        XCTAssertTrue(url.path.hasPrefix(guestRoot.standardizedFileURL.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "127.0.0.1\n")
        // 同路径读放行（reads pass through）。
        XCTAssertEqual(try workspace.readText("/etc/hosts"), "127.0.0.1\n")
    }

    /// workspace-write：/tmp 白名单兑现（gate 放行、执行层同墙兑现）；
    /// /etc 越界仍拒绝（fail closed 不放宽）。
    func testWorkspaceWriteTmpHonorAndEtcRejected() {
        let guestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p24-guest-\(UUID().uuidString)", isDirectory: true)
        let workspace = WorkspaceFileAccess(sessionId: "p24-\(UUID().uuidString)",
                                            guestRoot: guestRoot)
        defer { try? FileManager.default.removeItem(at: guestRoot) }
        // /tmp 白名单：gate fsPathUnderWritableRoots 放行 → 执行层同样解析成功。
        XCTAssertNoThrow(try workspace.writeData("/tmp/scratch.txt",
                                                 data: Data("x".utf8),
                                                 mode: .workspaceWrite))
        // 越界：执行层拒绝（与 gate 判定一致）。
        XCTAssertThrowsError(try workspace.writeData("/etc/passwd",
                                                     data: Data("x".utf8),
                                                     mode: .workspaceWrite))
        // `..` 逃逸：即使 danger 模式也拦在 guest 根内（词法 containment）。
        XCTAssertThrowsError(try workspace.writeData("/../escape.txt",
                                                     data: Data("x".utf8),
                                                     mode: .dangerFullAccess))
    }

    // MARK: - bash 启发式（A2 近似）

    func testBashWriteHeuristics() {
        // 写命令表。
        XCTAssertTrue(SandboxGate.bashLikelyWrites("rm -rf /tmp/x"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("cp a b"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("mv a b"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("mkdir -p d"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("touch f"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("dd if=/dev/zero of=x"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("chmod +x run.sh"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("chown root f"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("ln -s a b"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("truncate -s 0 f"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("sed -i 's/a/b/' f"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("apk add curl"))
        // 重定向（含管道中段与追加）。
        XCTAssertTrue(SandboxGate.bashLikelyWrites("echo hi > out.txt"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("echo hi >> out.txt"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("cat in | tee out"))
        XCTAssertTrue(SandboxGate.bashLikelyWrites("grep x f 2>err.txt"))
        // /dev/null 必需 sink 豁免（dsh read-only 语义）。
        XCTAssertFalse(SandboxGate.bashLikelyWrites("echo hi > /dev/null"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("ls nope 2>/dev/null"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("command -v bash >/dev/null 2>&1"))
        // 只读命令。
        XCTAssertFalse(SandboxGate.bashLikelyWrites("ls -la"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("cat a.txt"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("grep -n pattern file"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("echo hello"))
        XCTAssertFalse(SandboxGate.bashLikelyWrites("sed -n 1,5p file"))
    }

    /// bash 门端到端：read-only + 写命令 → marker+hint('command')；读命令放行；
    /// workspace-write 不设围栏（A2）；提权 approved 后写命令放行。
    func testBashGateEndToEnd() async {
        let write = JSONValue.object(["command": .string("rm -rf /tmp/x")])
        // read-only + rm → deny。
        let denied = await SandboxGate.authorizeBash(
            tool: "bash", command: "rm -rf /tmp/x", args: write,
            standingMode: .readOnly, callId: "c1", approver: nil)
        XCTAssertEqual(denied?.errorCode, "FS_SANDBOX_DENIED")
        XCTAssertEqual(denied?.text,
                       "Error: [sandbox: file access denied under read-only mode]\n"
                           + "[sandbox: escalation available — retry this exact command once with "
                           + "sandbox_permissions (the narrowest wider mode that suffices) + justification; "
                           + "the approval prompt asks the user]")
        // read-only + 读命令 → 放行。
        let read = JSONValue.object(["command": .string("ls -la")])
        let readPassed = await SandboxGate.authorizeBash(
            tool: "bash", command: "ls -la", args: read,
            standingMode: .readOnly, callId: "c1", approver: nil)
        XCTAssertNil(readPassed)
        // workspace-write + rm → 放行（启发式不设围栏，A2 登记）。
        let writePassed = await SandboxGate.authorizeBash(
            tool: "bash", command: "rm -rf /tmp/x", args: write,
            standingMode: .workspaceWrite, callId: "c1", approver: nil)
        XCTAssertNil(writePassed)
        // read-only + rm + 提权 approved → 放行（本调用 stamp）。
        let escalated = JSONValue.object([
            "command": .string("rm -rf /tmp/x"),
            "sandbox_permissions": .string("danger-full-access"),
            "justification": .string("clean stale temp dir"),
        ])
        let grant: SandboxEscalationApprover = { _, _, _ in .allowedOnce }
        let escalatePassed = await SandboxGate.authorizeBash(
            tool: "bash", command: "rm -rf /tmp/x", args: escalated,
            standingMode: .readOnly, callId: "c1", approver: grant)
        XCTAssertNil(escalatePassed)
    }

    // MARK: - schema 呈现（四工具提权字段）

    func testEscalationSchemaFieldsOnFourTools() {
        let registry = ToolRegistry()
        registry.register(ShellTool(sessionId: "s"))
        FsTools.registerAll(into: registry, sessionId: "s")
        for name in ["bash", "write", "edit", "str_replace_editor"] {
            guard let tool = registry.get(name) else {
                return XCTFail("missing tool \(name)")
            }
            guard case .object(let schema) = tool.parameters,
                  case .object(let props) = schema["properties"] else {
                return XCTFail("schema shape for \(name)")
            }
            guard case .object(let perm) = props["sandbox_permissions"] else {
                return XCTFail("sandbox_permissions missing on \(name)")
            }
            // enum = ESCALATION_TARGETS 闭集（registry-global）。
            guard case .array(let values) = perm["enum"] else {
                return XCTFail("enum missing on \(name)")
            }
            XCTAssertEqual(values.compactMap { $0.stringValue },
                           ["workspace-write", "danger-full-access"], name)
            // justification 必在（description 逐字尾段）。
            guard case .object(let just) = props["justification"],
                  case .string(let justDesc)? = just["description"] else {
                return XCTFail("justification missing on \(name)")
            }
            XCTAssertTrue(justDesc.hasPrefix(
                "Required with sandbox_permissions: one sentence for the user explaining"), name)
            // 提权字段不进 required（可选参数）。
            guard case .array(let required) = schema["required"] else {
                return XCTFail("required missing on \(name)")
            }
            XCTAssertFalse(required.contains(.string("sandbox_permissions")), name)
            XCTAssertFalse(required.contains(.string("justification")), name)
        }
        // 只读工具不携带提权字段（触发面结构性收窄）。
        for name in ["read", "glob", "grep", "read_image"] {
            guard let tool = registry.get(name),
                  case .object(let schema) = tool.parameters,
                  case .object(let props) = schema["properties"] else {
                return XCTFail("schema shape for \(name)")
            }
            XCTAssertNil(props["sandbox_permissions"], name)
            XCTAssertNil(props["justification"], name)
        }
    }

    // MARK: - renderPolicyContext（110 位逐字）

    func testRenderPolicyContextVerbatim() {
        XCTAssertEqual(SandboxPolicy.renderPolicyContext(.readOnly),
            "Current DSH file policy: read-only. Any available operation enforced "
                + "by the DSH file sandbox cannot modify files in the standing mode. Do not "
                + "refuse a required modification from this policy alone: try an available "
                + "tool normally and follow any denial and escalation guidance it returns.")
        XCTAssertEqual(SandboxPolicy.renderPolicyContext(.workspaceWrite),
            "Current DSH file policy: workspace-write. Any available operation "
                + "enforced by the DSH file sandbox may modify files under the session "
                + "workspace: \"/var/wanwo/workspace\". Some platform temporary areas may also be writable.")
        XCTAssertEqual(SandboxPolicy.renderPolicyContext(.dangerFullAccess),
            "Current DSH file policy: danger-full-access. The DSH file sandbox does "
                + "not restrict file modifications by available operations.")
    }

    // MARK: - 提权审批通道（never 短路 / fail closed 闭包形态）

    @MainActor
    func testEscalationApproverNeverShortCircuit() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        let coordinator = ApprovalCoordinator(writer: writer, presenter: presenter)
        let permission = PermissionCoordinator(writer: writer)
        // never：dispatch 之前确定性 rejected（不呈现、不落审计对——dsh :266）。
        permission.knobs.approval = .never
        let neverApprover: SandboxEscalationApprover = { [permission, coordinator] tool, callId, reason in
            if permission.knobs.approval == .never { return .rejected }
            return await coordinator.request(tool: tool, callId: callId, reason: reason)
        }
        let outcome = await neverApprover("write", "c1", "escalate sandbox to workspace-write: why")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(presenter.presented.isEmpty, "never 短路不得呈现")
        XCTAssertTrue(writer.events.isEmpty, "never 短路不得落审计对")
        // 无 presenter（无 answerer）→ 协调器 fail closed unavailable。
        permission.knobs.approval = .ask
        let noPresenter = ApprovalCoordinator(writer: writer, presenter: nil)
        let askApprover: SandboxEscalationApprover = { [noPresenter] tool, callId, reason in
            await noPresenter.request(tool: tool, callId: callId, reason: reason)
        }
        let unavailable = await askApprover("write", "c1", "escalate sandbox to workspace-write: why")
        XCTAssertEqual(unavailable, .unavailable)
    }

    // MARK: - 会话写柄（与 ApprovalCoordinatorTests 同模式）

    private func makeWriter() async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = SessionHeader(id: "test-session",
                                   createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                   cwd: nil)
        let log = try JsonlEventLog.create(header: header,
                                           at: dir.appendingPathComponent("session.jsonl"))
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite3").path)
        let writer = try await SessionWriter(id: header.id, header: header,
                                             log: log, database: database)
        return (writer, dir)
    }
}
