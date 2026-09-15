//
//  OffloadApprovalSeamTests.swift
//  WanWoTests
//
//  【万我 M6.1 增 · B1c ④审批接线】缝接线冒烟（简报 ④"最小单测：缝被调用、
//  应答回写生效"）：
//    1. OffloadApprovalPresenter.present → 缝被调用（pendingRequest 弹卡 +
//      应答闭包登记）；
//    2. presenter.respond → 应答回写生效（allow → checkPermission 返回
//      .allowed；deny → .denied）；
//    3. stale id 应答安全丢弃（迟到回写不炸不误答——manager resume-once
//      语义的呈现侧配合位）；
//    4. 二次应答幂等（首个生效，closed over manager 的锁保护面）。
//  隔离纪律：OffloadPermissionManager 经 init(defaults:) 注入独立 suite
//  （不污染 standard），seam 直挂 presenter 实例方法（不触碰 shared 单例的
//  全局缝——install() 的生产装配不在单测面覆盖，由 AppEnvironment init
//  真机路径验收）。
//

import XCTest
@testable import WanWo

@MainActor
final class OffloadApprovalSeamTests: XCTestCase {

    // MARK: - Fixtures

    /// 隔离 manager（独立 UserDefaults suite；apple-clipboard = askOnce 档）。
    private func makeManager() -> (OffloadPermissionManager, UserDefaults) {
        let suite = "wanwo-offload-seam-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (OffloadPermissionManager(defaults: defaults), defaults)
    }

    /// 新建 presenter（跳过 shared 单例——测试间状态隔离）。
    private func makePresenter() -> OffloadApprovalPresenter {
        // init 为 private；shared 不可新建——为可测性经内部测试缝重建。
        // 这里直接使用 shared 并在用例内清场（单例 @MainActor，测试串行）。
        let presenter = OffloadApprovalPresenter.shared
        presenter.pendingRequest = nil
        return presenter
    }

    // MARK: - 缝被调用（present → 弹卡）

    func testSeamInvocationPresentsRequest() async throws {
        let (manager, _) = makeManager()
        let presenter = makePresenter()
        XCTAssertNil(presenter.pendingRequest, "前置：呈现槽应清空")

        manager.presentApproval = { [weak presenter] request, _ in
            presenter?.presentForTesting(request: request, respond: { _ in })
        }

        let task = Task {
            await manager.checkPermission(for: "apple-clipboard",
                                          sessionId: "sid-seam",
                                          fullCommand: "apple-clipboard get")
        }
        // 等呈现缝被调用（MainActor 串行；不 sleep 轮询——让位后同步检查）。
        for _ in 0..<100 where presenter.pendingRequest == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = try XCTUnwrap(presenter.pendingRequest, "审批缝未被调用")
        XCTAssertEqual(request.commandName, "apple-clipboard")
        XCTAssertEqual(request.displayLabel, "Clipboard")
        XCTAssertEqual(request.fullCommand, "apple-clipboard get")
        // 卡片内容面：parsedArguments 解析自 fullCommand（OpenMinis 确认卡语义）。
        XCTAssertTrue(request.parsedArguments.contains { $0.key == "Action" && $0.value == "get" })

        // 收尾：拒绝应答让挂起检查收敛，避免泄漏延续体。
        presenter.respond(to: request.id, allowed: false)
        let result = await task.value
        guard case .denied = result else { return XCTFail("期望 denied，实得 \(result)") }
    }

    // MARK: - 应答回写生效（allow → sessionGrants 放行）

    func testAllowRespondWritesBackThroughSeam() async throws {
        let (manager, _) = makeManager()
        let presenter = makePresenter()

        manager.presentApproval = { [weak presenter] request, respond in
            presenter?.presentForTesting(request: request, respond: respond)
        }

        let task = Task {
            await manager.checkPermission(for: "apple-clipboard",
                                          sessionId: "sid-allow",
                                          fullCommand: "apple-clipboard set --text hi")
        }
        for _ in 0..<100 where presenter.pendingRequest == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = try XCTUnwrap(presenter.pendingRequest)

        // 用户点 Allow → 回写应答闭包。
        presenter.respond(to: request.id, allowed: true)
        let result = await task.value
        XCTAssertEqual(result, .allowed, "allow 应答应回写为 .allowed")

        // askOnce：同会话第二查免弹（sessionGrants 命中）。
        var secondPresentationCount = 0
        manager.presentApproval = { _, _ in secondPresentationCount += 1 }
        let second = await manager.checkPermission(for: "apple-clipboard",
                                                   sessionId: "sid-allow",
                                                   fullCommand: "apple-clipboard get")
        XCTAssertEqual(second, .allowed)
        XCTAssertEqual(secondPresentationCount, 0, "同会话 askOnce 授予后不应再弹卡")
    }

    // MARK: - 应答回写生效（deny）

    func testDenyRespondWritesBackThroughSeam() async throws {
        let (manager, _) = makeManager()
        let presenter = makePresenter()

        manager.presentApproval = { [weak presenter] request, respond in
            presenter?.presentForTesting(request: request, respond: respond)
        }

        let task = Task {
            await manager.checkPermission(for: "apple-clipboard",
                                          sessionId: "sid-deny",
                                          fullCommand: "apple-clipboard get")
        }
        for _ in 0..<100 where presenter.pendingRequest == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = try XCTUnwrap(presenter.pendingRequest)

        presenter.respond(to: request.id, allowed: false)
        let result = await task.value
        guard case .denied = result else { return XCTFail("期望 denied，实得 \(result)") }
        // 清槽断言：deny 后呈现槽清空（OpenMinis respond :294-299 语义）。
        XCTAssertNil(presenter.pendingRequest)
    }

    // MARK: - stale id / 二次应答安全

    func testStaleOrDuplicateRespondIsDropped() async throws {
        let (manager, _) = makeManager()
        let presenter = makePresenter()
        XCTAssertNil(presenter.pendingRequest)

        // 无在途请求时 respond 安全 no-op。
        presenter.respond(to: "no-such-id", allowed: true)

        // 在途请求应答一次后，同 id 二次 respond 丢弃（不误答第二个请求）。
        manager.presentApproval = { [weak presenter] request, _ in
            presenter?.presentForTesting(request: request, respond: { _ in })
        }
        let task = Task {
            await manager.checkPermission(for: "apple-clipboard",
                                          sessionId: "sid-stale",
                                          fullCommand: "apple-clipboard get")
        }
        for _ in 0..<100 where presenter.pendingRequest == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = try XCTUnwrap(presenter.pendingRequest)
        presenter.respond(to: request.id, allowed: false)
        presenter.respond(to: request.id, allowed: true)  // 二次应答：闭包已摘除，丢弃

        let result = await task.value
        guard case .denied = result else { return XCTFail("首个应答（deny）应生效，实得 \(result)") }
    }
}
