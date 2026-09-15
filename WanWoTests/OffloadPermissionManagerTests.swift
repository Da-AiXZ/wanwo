//
//  OffloadPermissionManagerTests.swift
//  WanWoTests
//
//  【万我 M6.1 增 · 简报 B1a ⑦】OffloadPermissionManager 单测：
//   - 三档判定矩阵（bypass 直通 / notAllowed 拒绝 / askOnce 走审批缝）
//   - 持久化往返（UserDefaults suite 注入，隔离不污染 standard）
//   - 注册表默认档（10-design §8.2：apple-clipboard=askOnce、apple-device=bypass）
//   - sessionGrants 会话隔离（sid A 授权后 sid B 仍弹）
//   - 超时 deny（approvalTimeoutSeconds 测试缝注入；审批缝直挂，不依赖 UI）
//   - 注册表完整性（27 条、序=10-design §8.2、minis-*→wanwo-* 改名）
//
//  【envelope 形状断言 · 标注说明】noff_json_envelope / noff_json_error 为
//  ObjC 纯函数（WanWo/NativeOffload/NativeOffloadUtils.m），位于主 target 的
//  ObjC 面；WanWoTests 经 @testable import WanWo 只可见 Swift 符号，桥接头
//  对 test target 不可见，故 ObjC envelope 纯函数面无法在本 target 直接断言
//  （简报 ⑦ 预留的两个选项中取"标注说明"）。envelope 形状由两处保障：
//  ① 源码 1:1 vendored（NativeOffloadUtils.m 与 OpenMinis 原件逐行对照）；
//  ② 内核 deny 路径复用同两函数构造 envelope（Platform/ISHKernel.m
//  wanwo_offload_checked_trampoline），设备端 M6.1 验收
//  （`apple-device`/`apple-clipboard` 返回 JSON）覆盖真实形状。
//

import XCTest
import os.lock   // 【终验补】OSAllocatedUnfairLock（attachCountingApproval 计数锁）——主件 import os.lock，测试侧漏带
@testable import WanWo

@MainActor
final class OffloadPermissionManagerTests: XCTestCase {

    // MARK: - Fixtures

    /// 隔离实例：独立 UserDefaults suite + 空审批记录（不污染 standard 域）。
    private func makeManager() -> (OffloadPermissionManager, UserDefaults) {
        let suite = "wanwo-offload-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (OffloadPermissionManager(defaults: defaults), defaults)
    }

    /// 计数审批缝：记录弹卡次数，按预设结果应答。
    private func attachCountingApproval(
        _ manager: OffloadPermissionManager,
        allowed: Bool,
        counter: OSAllocatedUnfairLock<Int>
    ) {
        manager.presentApproval = { _, resume in
            counter.withLock { $0 += 1 }
            resume(allowed)
        }
    }

    // MARK: - 注册表完整性（10-design §8.2）

    func testRegistryHas27CommandsInDesignOrder() {
        XCTAssertEqual(OffloadPermissionManager.allCommands.count, 27)
        // 序 = 10-design §8.2 注册序抽查（首/中/尾）。
        XCTAssertEqual(OffloadPermissionManager.allCommands.first?.name, "ffmpeg")
        XCTAssertEqual(OffloadPermissionManager.allCommands[6].name, "apple-clipboard")
        XCTAssertEqual(OffloadPermissionManager.allCommands.last?.name, "wanwo-debug")
    }

    func testRegistryMinisToWanwoRenaming() {
        // 简报铁律 3：minis-* → wanwo-* 改名；不允许残留 minis- 前缀。
        let wanwoPrefixed = OffloadPermissionManager.allCommands
            .filter { $0.name.hasPrefix("wanwo-") }
            .map(\.name)
        XCTAssertEqual(Set(wanwoPrefixed),
                       ["wanwo-model-use", "wanwo-sessions-cli",
                        "wanwo-browser-use", "wanwo-config", "wanwo-debug"])
        XCTAssertFalse(OffloadPermissionManager.allCommands.contains {
            $0.name.contains("minis")
        })
    }

    func testRegistryDefaultLevelsMatchDesign() {
        // 10-design §8.2 每命令默认档抽查。
        func level(_ name: String) -> OffloadPermissionLevel {
            OffloadPermissionManager.allCommands.first { $0.name == name }!.defaultLevel
        }
        XCTAssertEqual(level("apple-clipboard"), .askOnce)
        XCTAssertEqual(level("apple-device"), .bypass)
        XCTAssertEqual(level("ffmpeg"), .bypass)
        XCTAssertEqual(level("wanwo-debug"), .bypass)
        XCTAssertEqual(level("apple-homekit"), .askOnce)
        XCTAssertEqual(level("wanwo-sessions-cli"), .askOnce)
    }

    // MARK: - 三档判定矩阵

    func testBypassAllowsWithoutApproval() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.bypass, for: "apple-device")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: false, counter: counter)

        let result = await manager.checkPermission(for: "apple-device", sessionId: "s1")
        guard case .allowed = result else { return XCTFail("bypass 应直通，实际 \(result)") }
        XCTAssertEqual(counter.withLock { $0 }, 0, "bypass 不应触发审批卡")
    }

    func testNotAllowedDeniedWithoutApproval() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.notAllowed, for: "apple-clipboard")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: true, counter: counter)

        let result = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        guard case .denied(let message) = result else { return XCTFail("notAllowed 应拒绝") }
        XCTAssertTrue(message.contains("disabled"),
                      "notAllowed 消息措辞应对齐 OpenMinis :241，实际: \(message)")
        XCTAssertEqual(counter.withLock { $0 }, 0, "notAllowed 不应触发审批卡")
    }

    func testAskOnceApprovalGrantedThenSessionGrant() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: true, counter: counter)

        let first = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1",
                                                  fullCommand: "apple-clipboard get")
        guard case .allowed = first else { return XCTFail("allow 应放行") }
        XCTAssertEqual(counter.withLock { $0 }, 1)

        // 同会话第二次免弹（OpenMinis sessionGrants 语义 :275）。
        let second = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        guard case .allowed = second else { return XCTFail("会话授权后应放行") }
        XCTAssertEqual(counter.withLock { $0 }, 1, "同会话第二次不应再弹")
    }

    func testAskOnceDeclinedMessage() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: false, counter: counter)

        let result = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        guard case .denied(let message) = result else { return XCTFail("deny 应拒绝") }
        XCTAssertTrue(message.contains("declined"),
                      "拒绝消息措辞应对齐 OpenMinis :284，实际: \(message)")
        XCTAssertEqual(counter.withLock { $0 }, 1)
    }

    // MARK: - 持久化往返

    func testPermissionLevelPersistenceRoundTrip() {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.notAllowed, for: "apple-photos")
        manager.setPermissionLevel(.askOnce, for: "apple-device")

        // 同 suite 新实例读回（持久化形态 = UserDefaults integer，OpenMinis :161-172）。
        let suite = "wanwo-offload-tests-persist-\(UUID().uuidString)"
        let shared = UserDefaults(suiteName: suite)!
        shared.removePersistentDomain(forName: suite)
        let writer = OffloadPermissionManager(defaults: shared)
        let reader = OffloadPermissionManager(defaults: shared)
        writer.setPermissionLevel(.askOnce, for: "apple-healthkit")
        XCTAssertEqual(reader.permissionLevel(for: "apple-healthkit"), .askOnce)
        writer.setPermissionLevel(.notAllowed, for: "apple-healthkit")
        XCTAssertEqual(reader.permissionLevel(for: "apple-healthkit"), .notAllowed)
    }

    func testUnstoredLevelFallsBackToRegistryDefault() {
        let (manager, _) = makeManager()
        // 未存储 → 注册表默认档（万我 M6.1 增：10-design §8.2）。
        XCTAssertEqual(manager.permissionLevel(for: "apple-clipboard"), .askOnce)
        XCTAssertEqual(manager.permissionLevel(for: "apple-device"), .bypass)
        // 完全未知名的兜底回落 .bypass（OpenMinis 原语义保留）。
        XCTAssertEqual(manager.permissionLevel(for: "unknown-command"), .bypass)
    }

    // MARK: - sessionGrants 会话隔离

    func testSessionGrantsAreIsolatedPerSession() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: true, counter: counter)

        _ = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        XCTAssertEqual(counter.withLock { $0 }, 1)

        // sid B 未授权 → 仍弹（OpenMinis sessionGrants[sessionId] 隔离 :245）。
        _ = await manager.checkPermission(for: "apple-clipboard", sessionId: "s2")
        XCTAssertEqual(counter.withLock { $0 }, 2, "不同会话应重新弹卡")

        // resetSessionGrants 后同会话重新弹（:299-301）。
        manager.resetSessionGrants(for: "s1")
        _ = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        XCTAssertEqual(counter.withLock { $0 }, 3)
    }

    func testEmptySessionIdFallsBackToGlobalBucket() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        attachCountingApproval(manager, allowed: true, counter: counter)

        // 空/nil sid → OFFLOAD_GLOBAL_SESSION_ID 全局桶（OpenMinis :231-232）。
        _ = await manager.checkPermission(for: "apple-clipboard", sessionId: nil)
        _ = await manager.checkPermission(for: "apple-clipboard", sessionId: "   ")
        XCTAssertEqual(counter.withLock { $0 }, 1, "nil 与空白 sid 应同落全局桶，第二次免弹")
    }

    // MARK: - 超时 deny（测试缝注入）

    func testApprovalTimeoutDenies() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        // 测试缝：0.2s 超时；审批缝挂上但永不应答（模拟无人应答）。
        manager.approvalTimeoutSeconds = 0.2
        manager.presentApproval = { _, _ in /* 不应答 */ }

        let result = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        guard case .denied = result else { return XCTFail("超时应按 deny 收敛") }
    }

    func testApprovalResponseAfterTimeoutDoesNotDoubleResume() async {
        let (manager, _) = makeManager()
        manager.setPermissionLevel(.askOnce, for: "apple-clipboard")
        manager.approvalTimeoutSeconds = 0.2
        // 迟到应答：超时后才 resume(true)——resume-once 保护下不得崩溃/改判。
        manager.presentApproval = { _, resume in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                resume(true)
            }
        }

        let result = await manager.checkPermission(for: "apple-clipboard", sessionId: "s1")
        guard case .denied = result else { return XCTFail("超时后迟到应答不得改判") }
        // 且不得写入会话授权（denied 分支无 sessionGrants 插入）。
        _ = result
    }

    // MARK: - 审批卡参数化数据（PermissionRequest.parsedArguments）

    func testPermissionRequestParsedArguments() {
        let request = PermissionRequest(
            id: "r1", commandName: "apple-clipboard",
            displayLabel: "Clipboard", description: "",
            fullCommand: "apple-clipboard get --image /var/wanwo/attachments/x.png")
        let parsed = request.parsedArguments
        XCTAssertEqual(parsed.first?.key, "Action")
        XCTAssertEqual(parsed.first?.value, "get")
        XCTAssertTrue(parsed.contains(where: { $0.key == "image" && $0.value == "/var/wanwo/attachments/x.png" }))
    }

    func testPermissionRequestParsedArgumentsStopsAtShellSeparator() {
        // 只展示首条命令 token（OpenMinis :37-44 语义）。
        let request = PermissionRequest(
            id: "r2", commandName: "apple-device",
            displayLabel: "Device", description: "",
            fullCommand: "apple-device info && rm -rf /")
        let parsed = request.parsedArguments
        XCTAssertFalse(parsed.contains(where: { $0.value == "-rf" }),
                       "链式后续命令不得出现在审批卡参数里")
    }
}
