//
//  PermissionTests.swift
//  WanWoTests
//
//  【M3 T2 单测】规则引擎矩阵（prefix 多选一 / wrapper 拆段 / network 精确
//  禁通配 / 多层取最严）+ 禁推黑名单沉淀拒绝 + 签名去重与落盘重载 + 缓存键
//  失效（策略指纹随规则库变化）+ 预设 derive（custom 派生 / still-matching）
//  + approval/policy 事件往返与 resume 折叠。
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

    private func makeStore() -> PermissionRulesStore {
        PermissionRulesStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-rules-\(UUID().uuidString).jsonl"))
    }

    private func prefixRule(_ pattern: [[String]], _ verdict: String,
                            id: String) -> PermissionRule {
        PermissionRule(id: id, kind: "prefix", pattern: pattern, host: nil,
                       verdict: verdict, source: "manual", origin: nil, createdAtMs: 0)
    }

    private func bashArgs(_ command: String) -> JSONValue {
        .object(["command": .string(command)])
    }

    // MARK: - 词法

    func testTokenizeQuotesAndWhitespace() {
        XCTAssertEqual(PermissionRulesEngine.tokenize("ls -la 'a b' \"c d\""),
                       ["ls", "-la", "a b", "c d"])
        XCTAssertEqual(PermissionRulesEngine.tokenize("  npm   run build "),
                       ["npm", "run", "build"])
    }

    // MARK: - 规则引擎

    func testPrefixRuleSingleAndAlternatives() {
        let engine = PermissionRulesEngine(layers: [[
            prefixRule([["ls"]], "allow", id: "r1"),
            prefixRule([["npm", "pnpm"], ["run", "test"]], "prompt", id: "r2"),
        ]])
        XCTAssertEqual(engine.decide(tool: "bash", args: bashArgs("ls -la")), .allow)
        XCTAssertEqual(engine.decide(tool: "bash", args: bashArgs("npm run build")), .prompt)
        XCTAssertEqual(engine.decide(tool: "bash", args: bashArgs("pnpm test")), .prompt)
        // 未命中 → nil（回落启发式矩阵）。
        XCTAssertNil(engine.decide(tool: "bash", args: bashArgs("rm -rf /tmp/x")))
    }

    func testWrapperInnerCommandMustBeCovered() {
        // 仅外层 bash -c 有规则 → 内层未覆盖 → 整体 nil（fail closed）。
        let outerOnly = PermissionRulesEngine(layers: [[
            prefixRule([["bash"], ["-c"]], "allow", id: "r1"),
        ]])
        XCTAssertNil(outerOnly.decide(tool: "bash", args: bashArgs("bash -c 'echo hi'")))
        // 内外层都覆盖 → 取最严（两段均 allow）。
        let full = PermissionRulesEngine(layers: [[
            prefixRule([["bash"], ["-c"]], "allow", id: "r1"),
            prefixRule([["echo"]], "allow", id: "r2"),
        ]])
        XCTAssertEqual(full.decide(tool: "bash", args: bashArgs("bash -c 'echo hi'")), .allow)
    }

    func testStrictestAcrossLayersAndDuplicates() {
        let low = prefixRule([["git"]], "allow", id: "l1")
        let high = prefixRule([["git"], ["push"]], "forbidden", id: "h1")
        // 同名重复无害（low 出现两次）；层间低→高全量参与取最严。
        let engine = PermissionRulesEngine(layers: [[low, low], [high]])
        XCTAssertEqual(engine.decide(tool: "bash",
                                     args: bashArgs("git push origin main")), .forbidden)
        XCTAssertEqual(engine.decide(tool: "bash", args: bashArgs("git status")), .allow)
    }

    func testNetworkRuleExactHostNoWildcard() {
        let engine = PermissionRulesEngine(layers: [[
            PermissionRule(id: "n1", kind: "network", pattern: nil,
                           host: "api.example.com", verdict: "forbidden",
                           source: "manual", origin: nil, createdAtMs: 0),
        ]])
        XCTAssertEqual(engine.decide(tool: "web_fetch",
            args: .object(["url": .string("https://api.example.com/v1")])), .forbidden)
        // 精确匹配：相似 host 不命中。
        XCTAssertNil(engine.decide(tool: "web_fetch",
            args: .object(["url": .string("https://evil-api.example.com")])))
        // 通配规则永不命中（fail closed）。
        let wildcard = PermissionRulesEngine(layers: [[
            PermissionRule(id: "n2", kind: "network", pattern: nil,
                           host: "*.example.com", verdict: "forbidden",
                           source: "manual", origin: nil, createdAtMs: 0),
        ]])
        XCTAssertNil(wildcard.decide(tool: "web_fetch",
            args: .object(["url": .string("https://sub.example.com")])))
    }

    // MARK: - 沉淀与规则库

    func testSedimentRefusesBannedPrefix() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer, rules: makeStore())
        XCTAssertTrue(coordinator.sedimentPrefixRule(fromCommand: "sudo rm -rf /")
            .contains("禁推黑名单"))
        XCTAssertTrue(coordinator.sedimentPrefixRule(fromCommand: "python -c 'x'")
            .contains("禁推黑名单"))
        XCTAssertTrue(coordinator.rules.rules.isEmpty, "黑名单命中不得落盘")
    }

    func testSedimentDedupesAndPersists() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-rules-\(UUID().uuidString).jsonl")
        let coordinator = PermissionCoordinator(writer: writer,
                                                rules: PermissionRulesStore(fileURL: url))
        XCTAssertTrue(coordinator.sedimentPrefixRule(fromCommand: "npm run build")
            .contains("已记住"))
        // 同签名重复追加 → 幂等 no-op。
        XCTAssertFalse(coordinator.rules.add(
            PermissionRule(id: UUID().uuidString, kind: "prefix",
                           pattern: [["npm"], ["run"], ["build"]], host: nil,
                           verdict: "allow", source: "remembered",
                           origin: "npm run build", createdAtMs: 0)))
        // 落盘重载（新实例读同文件——持久化生效）。
        let reloaded = PermissionRulesStore(fileURL: url)
        XCTAssertEqual(reloaded.rules.count, 1)
        XCTAssertEqual(reloaded.rules[0].source, "remembered")
        XCTAssertEqual(reloaded.rules[0].origin, "npm run build")
    }

    func testCacheKeyInvalidatedByRulesVersion() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore()
        let coordinator = PermissionCoordinator(writer: writer, rules: store)
        let args = bashArgs("ls -la")
        XCTAssertFalse(coordinator.cachedApproval(tool: "bash", args: args))
        coordinator.rememberApproval(tool: "bash", args: args)
        XCTAssertTrue(coordinator.cachedApproval(tool: "bash", args: args))
        // 规则库版本变化 → 指纹变 → 旧键失效（gap1 §八.3 键完备性）。
        _ = store.add(prefixRule([["git"]], "allow", id: "g1"))
        XCTAssertFalse(coordinator.cachedApproval(tool: "bash", args: args))
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

    // MARK: - approval/policy + sandbox/mode 事件往返 + resume 折叠

    func testApprovalPolicyRoundtripAndRestore() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await writer.append(.extensionEvent(
            kind: "approval/policy", payload: .object(["policy": .string("never")])))
        // resume 折叠：新协调器从事件流恢复 never。
        let coordinator = PermissionCoordinator(writer: writer, rules: makeStore())
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
        let coordinator = PermissionCoordinator(writer: writer, rules: makeStore())
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
        let restored = PermissionCoordinator(writer: writer, rules: makeStore())
        XCTAssertEqual(restored.knobs.sandbox, .dangerFullAccess)
        XCTAssertEqual(restored.knobs.approval, .never)
        XCTAssertEqual(restored.knobs.currentPresetName(), "danger-full-access")
    }

    /// T2.1：applyPreset diff 写——同值旋钮不落事件。
    func testApplyPresetDiffWriteSkipsUnchangedKnob() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer, rules: makeStore())
        // workspace-write→workspace-write(+ask) 为当前态 → 无切换。
        let noop = await coordinator.applyPreset(named: "workspace-write")
        XCTAssertTrue(noop.contains("已处于"), noop)
        XCTAssertTrue(writer.events.filter {
            if case .extensionEvent = $0.payload { return true }
            return false
        }.isEmpty)
        // diff 写单旋钮形态：预置 approval=never（事件折叠进内存）后切回
        // workspace-write——approval never→ask 变化、sandbox 复位→两旋钮均变，
        // 验证事件序列顺序稳定（先 approval 后 sandbox）。
        try await writer.append(.extensionEvent(
            kind: "approval/policy", payload: .object(["policy": .string("never")])))
        let custom = PermissionCoordinator(writer: writer, rules: makeStore())
        let before = writer.events.count
        let result = await custom.applyPreset(named: "workspace-write")
        XCTAssertTrue(result.contains("已切换"), result)
        let kinds = writer.events.dropFirst(before).compactMap { event -> String? in
            if case .extensionEvent(let kind, _) = event.payload { return kind }
            return nil
        }
        XCTAssertEqual(kinds, ["approval/policy", "sandbox/mode"],
                       "事件顺序稳定：先 approval/policy 后 sandbox/mode")
    }

    /// T2.1：/permission 分支——custom 拒绝 + 未知名报错带清单 + 空输入查询。
    func testApplyPresetRejectsCustomAndUnknown() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer, rules: makeStore())
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
}
