//
//  T22InteractionTests.swift
//  WanWoTests
//
//  【M3 T2.2 单测】composer 路由顺序（A1：提问先于审批——dsh 笔记 :19）+
//  主按钮状态机（A5 primaryStops）+ Full access 命令门控判定（A4）+
//  新会话默认权限源（A2：PermissionDefaultStore 持久化 + restoreKnobs 缺省
//  回落）+ read-only 宿主预设可切换（A2/A3 前置）+ 会话统计折叠（C8：
//  SessionStatsFold turns/steps/llmMs/toolMs/分组线）。
//

import XCTest
@testable import WanWo

final class T22InteractionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // E1 通道 schema 注册（与生产装配一致；写侧门校验词汇恒合法）。
        ExtensionEventRegistry.shared.resetForTests()
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: PermissionCoordinator.policyEventKind,
            requiredFields: [ExtensionFieldSchema(
                "policy", .string,
                allowedValues: [.string(ApprovalPolicy.ask.rawValue),
                                .string(ApprovalPolicy.never.rawValue)])],
            projection: .logOnly,
            pairing: .none))
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: PermissionCoordinator.sandboxEventKind,
            requiredFields: [ExtensionFieldSchema(
                "mode", .string,
                allowedValues: [.string(ApprovalDecisionMatrix.SandboxMode.readOnly.rawValue),
                                .string(ApprovalDecisionMatrix.SandboxMode.workspaceWrite.rawValue),
                                .string(ApprovalDecisionMatrix.SandboxMode.dangerFullAccess.rawValue)])],
            projection: .logOnly,
            pairing: .none))
    }

    override func tearDown() {
        ExtensionEventRegistry.shared.resetForTests()
        super.tearDown()
    }

    // MARK: - 装配

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

    private func makeDefaultStore(name: String) -> PermissionDefaultStore {
        let store = PermissionDefaultStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("perm-default-\(UUID().uuidString).json"))
        XCTAssertTrue(store.setDefault(named: name))
        return store
    }

    // MARK: - A1 composer 路由顺序（提问先于审批）

    func testComposerRouteQuestionWinsOverApproval() {
        XCTAssertEqual(
            ComposerSeatRoute.route(hasPendingQuestion: true, hasPendingApproval: true),
            .question,
            "dsh 笔记 :19：first pending question ahead of concurrent approvals")
    }

    func testComposerRouteApprovalAndInputFallbacks() {
        XCTAssertEqual(
            ComposerSeatRoute.route(hasPendingQuestion: false, hasPendingApproval: true),
            .approval)
        XCTAssertEqual(
            ComposerSeatRoute.route(hasPendingQuestion: false, hasPendingApproval: false),
            .input)
    }

    // MARK: - A5 主按钮状态机

    func testPrimaryStopsStateMachine() {
        // 运行中 + 无草稿 → 主按钮变停止。
        XCTAssertTrue(ChatViewModel.primaryStops(running: true, draftEmpty: true))
        // 运行中 + 有草稿 → 保持发送（Queue 语义随 M7，本构建禁用）。
        XCTAssertFalse(ChatViewModel.primaryStops(running: true, draftEmpty: false))
        // 空闲 → 恒发送。
        XCTAssertFalse(ChatViewModel.primaryStops(running: false, draftEmpty: true))
        XCTAssertFalse(ChatViewModel.primaryStops(running: false, draftEmpty: false))
    }

    // MARK: - A4 Full access 命令门控

    func testFullAccessCommandGate() {
        XCTAssertTrue(ChatViewModel.isFullAccessCommand(
            name: "permission", args: "danger-full-access"))
        XCTAssertTrue(ChatViewModel.isFullAccessCommand(
            name: "permission", args: "  danger-full-access  "))
        // 其他预设带参直达（语义保留）；空参查询不门控。
        XCTAssertFalse(ChatViewModel.isFullAccessCommand(
            name: "permission", args: "workspace-write"))
        XCTAssertFalse(ChatViewModel.isFullAccessCommand(
            name: "permission", args: nil))
        XCTAssertFalse(ChatViewModel.isFullAccessCommand(
            name: "plan", args: "danger-full-access"))
    }

    // MARK: - A2 新会话默认权限源

    func testPermissionDefaultStorePersistenceAndValidation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-default-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PermissionDefaultStore(fileURL: url)
        // 出厂默认 = workspace-write（dsh BootHostOptions 部署默认）。
        XCTAssertEqual(store.defaultPreset, "workspace-write")
        // 合法写入 + 落盘往返。
        XCTAssertTrue(store.setDefault(named: "read-only"))
        let reloaded = PermissionDefaultStore(fileURL: url)
        XCTAssertEqual(reloaded.defaultPreset, "read-only")
        // 非法值拒绝（fail closed）。
        XCTAssertFalse(store.setDefault(named: "custom"))
        XCTAssertFalse(store.setDefault(named: "no-such-preset"))
        XCTAssertEqual(store.defaultPreset, "read-only")
    }

    func testPermissionDefaultStoreRejectsCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-default-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        // 损坏文件 → 回落出厂默认（fail closed）。
        let store = PermissionDefaultStore(fileURL: url)
        XCTAssertEqual(store.defaultPreset, "workspace-write")
    }

    func testCoordinatorUsesAppDefaultSourceForNewSession() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 默认源 = read-only → 新会话（无旋钮历史）初始双旋钮取默认值。
        let store = makeDefaultStore(name: "read-only")
        let coordinator = PermissionCoordinator(
            writer: writer, rules: PermissionRulesStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("perm-rules-\(UUID().uuidString).jsonl")),
            newSessionDefaults: { store.newSessionKnobs() })
        XCTAssertEqual(coordinator.knobs.sandbox, .readOnly)
        XCTAssertEqual(coordinator.knobs.approval, .ask)
        XCTAssertEqual(coordinator.knobs.currentPresetName(), "read-only")
        // 事件值优先：有历史的会话 resume 不被默认源覆盖。
        try await writer.append(.extensionEvent(
            kind: PermissionCoordinator.policyEventKind,
            payload: .object(["policy": .string(ApprovalPolicy.never.rawValue)])))
        try await writer.append(.extensionEvent(
            kind: PermissionCoordinator.sandboxEventKind,
            payload: .object(["mode": .string(ApprovalDecisionMatrix.SandboxMode
                .dangerFullAccess.rawValue)])))
        let resumed = PermissionCoordinator(
            writer: writer, rules: PermissionRulesStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("perm-rules-\(UUID().uuidString).jsonl")),
            newSessionDefaults: { store.newSessionKnobs() })
        XCTAssertEqual(resumed.knobs.sandbox, .dangerFullAccess)
        XCTAssertEqual(resumed.knobs.approval, .never)
    }

    // MARK: - A2/A3 read-only 宿主预设可切换

    func testReadOnlyHostPresetSwitchable() async throws {
        let (writer, dir) = try await makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = PermissionCoordinator(writer: writer, rules: PermissionRulesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("perm-rules-\(UUID().uuidString).jsonl")))
        XCTAssertEqual(PermissionPresets.spec(named: "read-only")?.sandbox, .readOnly)
        let result = await coordinator.applyPreset(named: "read-only")
        XCTAssertTrue(result.contains("已切换"), result)
        XCTAssertEqual(coordinator.knobs.sandbox, .readOnly)
        XCTAssertEqual(coordinator.knobs.approval, .ask)
        // custom 恒不在切换面（PermissionSelect.tsx:108-117 滤除语义）。
        let customResult = await coordinator.applyPreset(named: "custom")
        XCTAssertTrue(customResult.contains("派生态"), customResult)
    }

    // MARK: - C8 会话统计折叠

    private func event(_ payload: SessionEvent.Payload, at ms: Int64) -> SessionEvent {
        SessionEvent(seq: Int(ms), timeMs: ms, payload: payload)
    }

    private func assistantMessage(_ text: String) -> AssistantMessage {
        AssistantMessage(id: UUID().uuidString, provider: "test", model: "test-model",
                         content: [.text(text)])
    }

    func testSessionStatsFoldCountsAndTimings() {
        let events: [SessionEvent] = [
            event(.turnStart(turn: 1), at: 0),
            event(.stepStart(turn: 1, step: 1), at: 100),
            // 步 1：LLM 墙钟 900ms；usage 带缓存命中（600/1000 → 60%）。
            event(.assistantMessage(turn: 1, step: 1,
                                    message: assistantMessage("a"),
                                    usage: TokenUsage(inputTokens: 1000, outputTokens: 50,
                                                      cacheReadTokens: 600),
                                    interrupted: false), at: 1_000),
            event(.toolCall(turn: 1, step: 1, callId: "c1", name: "bash",
                            arguments: "{}"), at: 1_100),
            // 工具墙钟 400ms。
            event(.toolResult(turn: 1, step: 1, callId: "c1", content: "ok",
                              isError: false, errorName: nil, errorCode: nil,
                              meta: nil), at: 1_500),
            event(.turnEnd(turn: 1, reason: .completed), at: 1_600),
            event(.turnStart(turn: 2), at: 2_000),
            event(.stepStart(turn: 2, step: 1), at: 2_050),
            // 步 2：LLM 墙钟 450ms；无 usage（不计 token）。
            event(.assistantMessage(turn: 2, step: 1,
                                    message: assistantMessage("b"),
                                    usage: nil, interrupted: false), at: 2_500),
        ]
        let stats = SessionStatsFold.fold(events: events)
        XCTAssertEqual(stats.turns, 2)
        XCTAssertEqual(stats.steps, 2)
        XCTAssertEqual(stats.llmMs, 900 + 450)
        XCTAssertEqual(stats.toolMs, 400)
        XCTAssertEqual(stats.inputTokens, 1000)
        XCTAssertEqual(stats.outputTokens, 50)
        XCTAssertEqual(stats.cacheReadTokens, 600)
        // 分组线：计数组 + token 组（缓存命中 60% + 输入/输出）。
        let line = SessionStatsFold.line(for: stats)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("2 轮 · 2 步"), line!)
        XCTAssertTrue(line!.contains("LLM 1.4s"), line!)
        XCTAssertTrue(line!.contains("工具 0.4s"), line!)
        XCTAssertTrue(line!.contains("缓存命中 60%"), line!)
        XCTAssertTrue(line!.contains("输入 1.0k · 输出 50"), line!)
    }

    func testSessionStatsFoldEmptyLineAndDurationFormat() {
        // 全空 → nil 不渲染（a group with no data drops out whole）。
        XCTAssertNil(SessionStatsFold.line(for: SessionStatsFold.fold(events: [])))
        // 时长形态：一分钟内 45.2s，之外 2m42s（StatsLine.tsx:86-94）。
        XCTAssertEqual(SessionStatsFold.formatDuration(45_200), "45.2s")
        XCTAssertEqual(SessionStatsFold.formatDuration(162_000), "2m42s")
    }
}
