//
//  PermissionTests.swift
//  WanWoTests
//
//  【M3 权限单测 · P1-4 砍 F022 后保留面】预设 derive（custom 派生 /
//  still-matching）+ approval/policy 与 sandbox/mode 事件往返与 resume 折叠
//  + /permission 分支（custom 拒绝 / 未知名报错 / 空输入查询）。
//  P1-4（用户裁决 2026-09-10）：F022 规则引擎（prefix/network）、禁推黑名单、
//  签名去重落盘、会话审批缓存键、沉淀路径全部砍除——相关测试随行删除；
//  审批只由沙箱提权请求触发（P1-3，见 P13SandboxGateTests）。
//

import XCTest
@testable import WanWo

final class PermissionTests: XCTestCase {

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

    // MARK: - 预设 derive（dsh 语义）

    func testPresetDeriveCustomAndStillMatching() {
        let knobs = PermissionKnobs()
        XCTAssertEqual(knobs.currentPresetName(), "workspace-write")
        // danger-full-access 捆绑 approval=never。
        knobs.sandbox = .dangerFullAccess
        knobs.approval = .never
        knobs.lastSelection = "danger-full-access"
        XCTAssertEqual(knobs.currentPresetName(), "danger-full-access")
        // 组合不在表内 → custom（派生态）。
        knobs.sandbox = .workspaceWrite
        XCTAssertEqual(knobs.currentPresetName(), PermissionPresets.custom)
        // still-matching：显式选择失效后回落表命中。
        knobs.sandbox = .dangerFullAccess
        knobs.lastSelection = nil
        XCTAssertEqual(knobs.currentPresetName(), "danger-full-access")
    }

    // MARK: - 新会话默认源缝（T2.2 + P1-4 四层顺序第③层）

    /// 无事件历史 → 双旋钮取 newSessionDefaults；有事件 → 事件值优先
    /// （两旋钮独立判定——T2.2 派单项 2 / P1-4 保缝验证）。
    func testNewSessionDefaultsSeamRespected() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 无历史：默认源供值（read-only 挡 + ask）。
        let defaults = PermissionCoordinator(writer: writer, newSessionDefaults: {
            (.readOnly, .ask)
        })
        XCTAssertEqual(defaults.knobs.sandbox, .readOnly)
        XCTAssertEqual(defaults.knobs.approval, .ask)
        // 有 sandbox/mode 事件：sandbox 取事件值，approval 仍走默认源。
        try await writer.append(.extensionEvent(
            kind: PermissionCoordinator.sandboxEventKind,
            payload: .object(["mode": .string(SandboxMode.dangerFullAccess.rawValue)])))
        let mixed = PermissionCoordinator(writer: writer, newSessionDefaults: {
            (.readOnly, .never)
        })
        XCTAssertEqual(mixed.knobs.sandbox, .dangerFullAccess)
        XCTAssertEqual(mixed.knobs.approval, .never)
    }

    // MARK: - approval/policy + sandbox/mode 事件往返 + resume 折叠

    func testApprovalPolicyRoundtripAndRestore() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await writer.append(.extensionEvent(
            kind: "approval/policy", payload: .object(["policy": .string("never")])))
        // resume 折叠：新协调器从事件流恢复 never。
        let coordinator = PermissionCoordinator(writer: writer)
        XCTAssertEqual(coordinator.knobs.approval, .never)
        // JSONL 往返保真（wire type "extension/approval/policy"）。
        XCTAssertEqual(writer.events[0].wireType, "extension/approval/policy")
        XCTAssertTrue(writer.events[0].ignorable, "extension 事件 wire 恒 ignorable")
        let encoded = try JSONEncoder().encode(writer.events[0])
        let decoded = try JSONDecoder().decode(SessionEvent.self, from: encoded)
        XCTAssertEqual(decoded.payload, writer.events[0].payload)
    }

    /// T2.1：applyPreset 双旋钮持久化（sandbox/mode 事件落盘 + resume 折叠）。
    func testApplyPresetPersistsBothKnobsAndRestores() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer)
        let result = await coordinator.applyPreset(named: "danger-full-access")
        XCTAssertTrue(result.contains("已切换"), result)
        XCTAssertEqual(coordinator.knobs.sandbox, .dangerFullAccess)
        XCTAssertEqual(coordinator.knobs.approval, .never)
        // 双事件均落盘（diff 写：两旋钮都变 → 两条事件）。
        let kinds = writer.events.compactMap { event -> String? in
            if case .extensionEvent(let kind, _) = event.payload { return kind }
            return nil
        }
        XCTAssertEqual(kinds, ["approval/policy", "sandbox/mode"])
        // resume 折叠：新协调器双旋钮均恢复。
        let restored = PermissionCoordinator(writer: writer)
        XCTAssertEqual(restored.knobs.sandbox, .dangerFullAccess)
        XCTAssertEqual(restored.knobs.approval, .never)
        XCTAssertEqual(restored.knobs.currentPresetName(), "danger-full-access")
    }

    /// T2.1：applyPreset diff 写——同值旋钮不落事件。
    func testApplyPresetDiffWriteSkipsUnchangedKnob() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer)
        // workspace-write→workspace-write(+ask) 为当前态 → 无切换。
        let noop = await coordinator.applyPreset(named: "workspace-write")
        XCTAssertTrue(noop.contains("已处于"), noop)
        XCTAssertTrue(writer.events.filter {
            if case .extensionEvent = $0.payload { return true }
            return false
        }.isEmpty)
        // diff 写单旋钮形态：预置 approval=never（事件折叠进内存）后切回
        // workspace-write——approval never→ask 变化落事件；sandbox 无历史、
        // 恢复即 workspace-write（=目标值）→ 不落事件（值没变不写）。
        try await writer.append(.extensionEvent(
            kind: "approval/policy", payload: .object(["policy": .string("never")])))
        let custom = PermissionCoordinator(writer: writer)
        let before = writer.events.count
        let result = await custom.applyPreset(named: "workspace-write")
        XCTAssertTrue(result.contains("已切换"), result)
        let kinds = writer.events.dropFirst(before).compactMap { event -> String? in
            if case .extensionEvent(let kind, _) = event.payload { return kind }
            return nil
        }
        XCTAssertEqual(kinds, ["approval/policy"],
                       "diff 写：值没变的旋钮不落事件")
    }

    /// T2.1：/permission 分支——custom 拒绝 + 未知名报错带清单 + 空输入查询。
    func testApplyPresetRejectsCustomAndUnknown() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer)
        let customResult = await coordinator.applyPreset(named: "custom")
        XCTAssertTrue(customResult.contains("派生态"), customResult)
        let unknownResult = await coordinator.applyPreset(named: "no-such-preset")
        XCTAssertTrue(unknownResult.contains("未知权限预设"), unknownResult)
        let statusResult = await coordinator.applyPreset(named: nil)
        XCTAssertTrue(statusResult.contains("当前权限预设"), statusResult)
        let kinds = writer.events.compactMap { event -> String? in
            if case .extensionEvent(let kind, _) = event.payload { return kind }
            return nil
        }
        XCTAssertTrue(kinds.isEmpty, "拒绝/查询路径不得落任何旋钮事件")
    }

    // MARK: - 动态上下文位（P1-3 对齐：110/115 逐字）

    /// 115 位：ASK/NEVER_SENTENCE 逐字随旋钮切换。
    func testApprovalPolicyContextLineVerbatim() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer)
        XCTAssertEqual(coordinator.approvalPolicyContextLine,
                       "Approval policy: ask. Operations that require approval may ask "
                           + "through the configured answerers; without an available answerer, "
                           + "the request fails closed.")
        coordinator.knobs.approval = .never
        XCTAssertEqual(coordinator.approvalPolicyContextLine,
                       "Approval prompts are disabled in this session: actions that "
                           + "require approval are rejected automatically — do not request "
                           + "sandbox escalation (do not set `sandbox_permissions`).")
        // 110 位：renderPolicyContext 随沙箱旋钮。
        coordinator.knobs.sandbox = .dangerFullAccess
        XCTAssertEqual(coordinator.sandboxPolicyContextLine,
                       SandboxPolicy.renderPolicyContext(.dangerFullAccess))
    }
}
